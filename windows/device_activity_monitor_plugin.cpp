#include "device_activity_monitor_plugin.h"

#include <windows.h>
#include <PowrProf.h>
#include <flutter/standard_method_codec.h>
#include <xinput.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <hidpi.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>

#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>
#include <chrono>
#include <sstream>

#pragma comment(lib, "XInput.lib")
#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "hid.lib")

namespace device_activity_monitor {

// ════════════════════════════════════════════════════════════════════════
// Static members
// ════════════════════════════════════════════════════════════════════════
std::weak_ptr<DeviceActivityMonitorPlugin> DeviceActivityMonitorPlugin::instance_;
std::mutex DeviceActivityMonitorPlugin::instanceMutex_;

// ════════════════════════════════════════════════════════════════════════
// SEH-isolated helpers — identical pattern to WindowFocus, kept local
// ════════════════════════════════════════════════════════════════════════

static bool GetPeakFromMeterSEH(IAudioMeterInformation* meter, float* peak) {
    *peak = 0.0f;
    __try {
        HRESULT hr = meter->GetPeakValue(peak);
        return SUCCEEDED(hr);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static DWORD XInputGetStateSEH(DWORD index, XINPUT_STATE* state, bool* ex) {
    *ex = false;
    __try { return XInputGetState(index, state); }
    __except (EXCEPTION_EXECUTE_HANDLER) { *ex = true; return ERROR_DEVICE_NOT_CONNECTED; }
}

static bool ReadHIDDeviceSEH(HANDLE h, BYTE* buf, DWORD sz,
                              OVERLAPPED* ovl, DWORD* read, DWORD* err) {
    *read = 0; *err = ERROR_SUCCESS;
    __try {
        if (ReadFile(h, buf, sz, read, ovl)) { *err = ERROR_SUCCESS; return true; }
        *err = GetLastError(); return false;
    } __except (EXCEPTION_EXECUTE_HANDLER) { *err = GetExceptionCode(); return false; }
}

static bool GetOverlappedResultSEH(HANDLE h, OVERLAPPED* ovl,
                                    DWORD* read, DWORD* err) {
    *err = ERROR_SUCCESS;
    __try {
        if (GetOverlappedResult(h, ovl, read, FALSE)) return true;
        *err = GetLastError(); return false;
    } __except (EXCEPTION_EXECUTE_HANDLER) { *err = GetExceptionCode(); return false; }
}

static bool GetHIDAttributesSEH(HANDLE h, HIDD_ATTRIBUTES* attr) {
    __try { return HidD_GetAttributes(h, attr) ? true : false; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static bool GetHIDPreparsedDataSEH(HANDLE h, PHIDP_PREPARSED_DATA* data) {
    __try { return HidD_GetPreparsedData(h, data) ? true : false; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static bool GetHIDCapsSEH(PHIDP_PREPARSED_DATA data, HIDP_CAPS* caps) {
    __try { return HidP_GetCaps(data, caps) == HIDP_STATUS_SUCCESS; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static bool FreePreparsedDataSEH(PHIDP_PREPARSED_DATA data) {
    __try { HidD_FreePreparsedData(data); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static HANDLE CreateHIDHandleSEH(const WCHAR* path) {
    __try {
        return CreateFileW(path, GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
            OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return INVALID_HANDLE_VALUE; }
}

static bool CancelIoSEH(HANDLE h) {
    __try { return CancelIo(h) ? true : false; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static bool CloseHandleSEH(HANDLE h) {
    __try { return CloseHandle(h) ? true : false; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static bool IsHandleValid(HANDLE h) {
    if (!h || h == INVALID_HANDLE_VALUE) return false;
    __try { DWORD f = 0; return GetHandleInformation(h, &f) ? true : false; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

// ════════════════════════════════════════════════════════════════════════
// RAII guards
// ════════════════════════════════════════════════════════════════════════

struct OverlappedGuard {
    OVERLAPPED ovl{};
    HANDLE     hEvent = nullptr;
    HANDLE     deviceHandle = INVALID_HANDLE_VALUE;
    bool       completed = false;

    explicit OverlappedGuard(HANDLE dev) : deviceHandle(dev) {
        hEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
        if (hEvent) ovl.hEvent = hEvent;
    }
    ~OverlappedGuard() {
        if (!completed && deviceHandle != INVALID_HANDLE_VALUE && IsHandleValid(deviceHandle))
            CancelIoSEH(deviceHandle);
        if (hEvent) {
            if (!completed) WaitForSingleObject(hEvent, 3000);
            CloseHandleSEH(hEvent);
        }
    }
    bool IsValid() const { return hEvent != nullptr; }
    void MarkComplete() { completed = true; }
    void InvalidateDevice() { deviceHandle = INVALID_HANDLE_VALUE; }
    OVERLAPPED* Get() { return &ovl; }

    OverlappedGuard(const OverlappedGuard&) = delete;
    OverlappedGuard& operator=(const OverlappedGuard&) = delete;
};

// ════════════════════════════════════════════════════════════════════════
// AudioMeterCache — cached COM objects, recreated on failure / 60s refresh
// ════════════════════════════════════════════════════════════════════════

class AudioMeterCache {
public:
    AudioMeterCache() = default;
    ~AudioMeterCache() { Reset(); }

    float GetPeak(bool debug) {
        auto now = std::chrono::steady_clock::now();
        bool needsRefresh = !meter_ ||
            consecutiveFailures_ > 3 ||
            (now - lastInitTime_) > kRefreshInterval;

        if (needsRefresh) {
            Reset();
            if (!Init(debug)) return 0.0f;
        }

        float peak = 0.0f;
        if (!GetPeakFromMeterSEH(meter_, &peak)) {
            consecutiveFailures_++;
            return 0.0f;
        }
        consecutiveFailures_ = 0;
        return peak;
    }

    void Invalidate() { Reset(); }

private:
    IAudioMeterInformation* meter_      = nullptr;
    IMMDevice*              device_     = nullptr;
    IMMDeviceEnumerator*    enumerator_ = nullptr;
    int consecutiveFailures_ = 0;
    std::chrono::steady_clock::time_point lastInitTime_{};
    static constexpr auto kRefreshInterval = std::chrono::seconds(60);

    bool Init(bool debug) {
        HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
            CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), (void**)&enumerator_);
        if (FAILED(hr) || !enumerator_) { Reset(); return false; }

        hr = enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &device_);
        if (FAILED(hr) || !device_) { Reset(); return false; }

        hr = device_->Activate(__uuidof(IAudioMeterInformation),
            CLSCTX_ALL, nullptr, (void**)&meter_);
        if (FAILED(hr) || !meter_) { Reset(); return false; }

        lastInitTime_ = std::chrono::steady_clock::now();
        consecutiveFailures_ = 0;
        return true;
    }

    void Reset() {
        if (meter_)      { try { meter_->Release(); }      catch (...) {} meter_      = nullptr; }
        if (device_)     { try { device_->Release(); }     catch (...) {} device_     = nullptr; }
        if (enumerator_) { try { enumerator_->Release(); } catch (...) {} enumerator_ = nullptr; }
        consecutiveFailures_ = 0;
    }

    AudioMeterCache(const AudioMeterCache&) = delete;
    AudioMeterCache& operator=(const AudioMeterCache&) = delete;
};

// ════════════════════════════════════════════════════════════════════════
// PlatformTaskDispatcher — posts lambdas onto the Flutter/UI thread
// ════════════════════════════════════════════════════════════════════════

class PlatformTaskDispatcher {
public:
    struct TaskPacket {
        std::function<void()> fn;
        uint64_t generation;
    };

    static PlatformTaskDispatcher& Get() {
        static PlatformTaskDispatcher inst;
        return inst;
    }

    void Initialize() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (hwnd_) return;

        WNDCLASSEX wc{};
        wc.cbSize        = sizeof(wc);
        wc.lpfnWndProc   = WndProc;
        wc.hInstance     = GetModuleHandle(nullptr);
        wc.lpszClassName = L"DAMPluginDispatcher";
        RegisterClassEx(&wc);

        hwnd_ = CreateWindowEx(0, L"DAMPluginDispatcher", nullptr, 0,
            0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandle(nullptr), nullptr);
        currentGeneration_++;

        if (hwnd_)
            powerNotify_ = RegisterSuspendResumeNotification(
                hwnd_, DEVICE_NOTIFY_WINDOW_HANDLE);
    }

    void Shutdown() {
        HWND hwnd = nullptr;
        HPOWERNOTIFY pn = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!hwnd_) return;
            hwnd = hwnd_; pn = powerNotify_;
            hwnd_ = nullptr; powerNotify_ = nullptr;
            currentGeneration_++;
        }
        if (pn) UnregisterSuspendResumeNotification(pn);
        MSG msg;
        while (PeekMessage(&msg, hwnd, WM_APP + 2, WM_APP + 2, PM_REMOVE)) {
            delete reinterpret_cast<TaskPacket*>(msg.lParam);
        }
        DestroyWindow(hwnd);
    }

    void PostTask(std::function<void()> task) {
        HWND hwnd = nullptr;
        uint64_t gen = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (pendingCount_ > 500) return;
            hwnd = hwnd_;
            gen  = currentGeneration_;
            pendingCount_++;
        }
        if (!hwnd) { std::lock_guard<std::mutex> l(mutex_); pendingCount_--; return; }

        auto* packet = new TaskPacket{ std::move(task), gen };
        if (!PostMessage(hwnd, WM_APP + 2, 0, reinterpret_cast<LPARAM>(packet))) {
            delete packet;
            std::lock_guard<std::mutex> l(mutex_); pendingCount_--;
        }
    }

private:
    HWND hwnd_ = nullptr;
    std::mutex mutex_;
    std::atomic<uint64_t> currentGeneration_{ 0 };
    int pendingCount_ = 0;
    HPOWERNOTIFY powerNotify_ = nullptr;

    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
        if (msg == WM_APP + 2) {
            auto* packet = reinterpret_cast<TaskPacket*>(lParam);
            if (packet) {
                auto& d = PlatformTaskDispatcher::Get();
                { std::lock_guard<std::mutex> l(d.mutex_); if (d.pendingCount_ > 0) d.pendingCount_--; }
                if (packet->generation == d.currentGeneration_.load())
                    try { packet->fn(); } catch (...) {}
                delete packet;
            }
            return 0;
        }
        if (msg == WM_POWERBROADCAST) {
            if (wParam == PBT_APMRESUMEAUTOMATIC || wParam == PBT_APMRESUMESUSPEND) {
                std::shared_ptr<DeviceActivityMonitorPlugin> inst;
                {
                    std::lock_guard<std::mutex> l(DeviceActivityMonitorPlugin::instanceMutex_);
                    inst = DeviceActivityMonitorPlugin::instance_.lock();
                }
                if (inst && !inst->IsShuttingDown()) inst->OnSystemResume();
            }
            return TRUE;
        }
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }
};

// ════════════════════════════════════════════════════════════════════════
// Thread join helper
// ════════════════════════════════════════════════════════════════════════

static void JoinThreads(std::vector<std::thread>& threads) {
    for (auto& t : threads) {
        if (!t.joinable()) continue;
        HANDLE h = t.native_handle();
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        bool exited = false;
        while (!exited && std::chrono::steady_clock::now() < deadline) {
            MSG msg;
            while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
                TranslateMessage(&msg); DispatchMessage(&msg);
            }
            if (WaitForSingleObject(h, 50) == WAIT_OBJECT_0) exited = true;
        }
        if (t.joinable()) { if (exited) t.join(); else t.detach(); }
    }
    threads.clear();
}

// ════════════════════════════════════════════════════════════════════════
// RegisterWithRegistrar
// ════════════════════════════════════════════════════════════════════════

// static
void DeviceActivityMonitorPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {

    PlatformTaskDispatcher::Get().Initialize();

    auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(),
        "expert.harman/device_activity_monitor",
        &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_shared<DeviceActivityMonitorPlugin>();
    plugin->channel_ = channel;

    {
        std::lock_guard<std::mutex> lock(instanceMutex_);
        instance_ = plugin;
    }

    channel->SetMethodCallHandler(
        [weak = std::weak_ptr<DeviceActivityMonitorPlugin>(plugin)](
            const auto& call,
            std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
            if (auto p = weak.lock()) {
                p->HandleMethodCall(call, std::move(result));
            } else {
                result->Error("PLUGIN_DESTROYED", "Plugin has been destroyed.");
            }
        });

    struct Owner : public flutter::Plugin {
        std::shared_ptr<DeviceActivityMonitorPlugin> ptr;
        explicit Owner(std::shared_ptr<DeviceActivityMonitorPlugin> p) : ptr(std::move(p)) {}
    };
    registrar->AddPlugin(std::make_unique<Owner>(plugin));
}

// ════════════════════════════════════════════════════════════════════════
// Constructor / Destructor
// ════════════════════════════════════════════════════════════════════════

DeviceActivityMonitorPlugin::DeviceActivityMonitorPlugin()
    : isShuttingDown_(false)
    , monitorAudio_(false)
    , monitorHID_(false)
    , monitorControllers_(false)
    , enableDebug_(false)
    , userIsActive_(true)
    , needsHIDReinit_(false)
    , needsAudioCacheReset_(false)
    , initialized_(false)
    , threadsStarted_(false)
    , audioThreshold_(0.001f)
    , idleThresholdMs_(300000) {
    lastActivityTime_ = std::chrono::steady_clock::now();
    ZeroMemory(lastControllerStates_, sizeof(lastControllerStates_));
}

DeviceActivityMonitorPlugin::~DeviceActivityMonitorPlugin() {
    isShuttingDown_.store(true, std::memory_order_release);

    {
        std::lock_guard<std::mutex> lock(instanceMutex_);
        if (instance_.lock().get() == this) instance_.reset();
    }

    { std::lock_guard<std::mutex> lock(shutdownMutex_); shutdownCv_.notify_all(); }

    { std::lock_guard<std::mutex> lock(threadsMutex_); JoinThreads(threads_); }

    CloseHIDDevices();
    PlatformTaskDispatcher::Get().Shutdown();

    { std::lock_guard<std::mutex> lock(channelMutex_); channel_ = nullptr; }
}

// ════════════════════════════════════════════════════════════════════════
// HandleMethodCall
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

    const auto& name = call.method_name();

    // ── initialize ───────────────────────────────────────────────────────
    if (name == "initialize") {
        if (initialized_.load()) { result->Success(); return; }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) { result->Error("BAD_ARGS", "Expected map"); return; }

        auto getBool = [&](const char* key, bool def) -> bool {
            auto it = args->find(flutter::EncodableValue(key));
            if (it != args->end() && std::holds_alternative<bool>(it->second))
                return std::get<bool>(it->second);
            return def;
        };
        auto getDouble = [&](const char* key, double def) -> double {
            auto it = args->find(flutter::EncodableValue(key));
            if (it != args->end() && std::holds_alternative<double>(it->second))
                return std::get<double>(it->second);
            return def;
        };
        auto getInt = [&](const char* key, int def) -> int {
            auto it = args->find(flutter::EncodableValue(key));
            if (it != args->end() && std::holds_alternative<int>(it->second))
                return std::get<int>(it->second);
            return def;
        };

        Initialize(
            getBool("monitorAudio", true),
            getBool("monitorHID", true),
            getBool("monitorControllers", true),
            getDouble("audioThreshold", 0.001),
            getInt("idleThresholdMs", 300000),
            getBool("debug", false));

        result->Success();
        return;
    }

    // ── dispose ──────────────────────────────────────────────────────────
    if (name == "dispose") {
        isShuttingDown_.store(true, std::memory_order_release);
        { std::lock_guard<std::mutex> lock(shutdownMutex_); shutdownCv_.notify_all(); }
        result->Success();
        return;
    }

    // ── setAudioMonitoring ───────────────────────────────────────────────
    if (name == "setAudioMonitoring") {
        if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("enabled"));
            if (it != args->end() && std::holds_alternative<bool>(it->second)) {
                bool val = std::get<bool>(it->second);
                bool old = monitorAudio_.exchange(val, std::memory_order_acq_rel);

                if (val && !old) {
                    // Audio just enabled — create cache if thread is already running
                    // (if not running yet, StartMonitorThread will create it)
                    if (threadsStarted_.load(std::memory_order_acquire)) {
                        std::lock_guard<std::mutex> l(audioMeterMutex_);
                        if (!audioMeterCache_) {
                            // Cache will be created inside the monitor thread on
                            // next iteration — signal via needsAudioCacheReset_
                            needsAudioCacheReset_.store(false, std::memory_order_release);
                        }
                    }
                    EnsureThreadsStarted();
                } else if (!val && old) {
                    // Audio just disabled — destroy cache immediately so no COM
                    // objects remain open for a disabled monitor
                    std::lock_guard<std::mutex> l(audioMeterMutex_);
                    if (audioMeterCache_) {
                        audioMeterCache_->Invalidate();
                    }
                }

                result->Success(); return;
            }
        }
        result->Error("BAD_ARGS", "Expected bool 'enabled'"); return;
    }

    // ── setHIDMonitoring ─────────────────────────────────────────────────
    if (name == "setHIDMonitoring") {
        if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("enabled"));
            if (it != args->end() && std::holds_alternative<bool>(it->second)) {
                bool val = std::get<bool>(it->second);
                bool old = monitorHID_.exchange(val, std::memory_order_acq_rel);
                if (val && !old) {
                    InitializeHIDDevices();
                    EnsureThreadsStarted();
                }
                if (!val && old) CloseHIDDevices();
                result->Success(); return;
            }
        }
        result->Error("BAD_ARGS", "Expected bool 'enabled'"); return;
    }

    // ── setControllerMonitoring ──────────────────────────────────────────
    if (name == "setControllerMonitoring") {
        if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("enabled"));
            if (it != args->end() && std::holds_alternative<bool>(it->second)) {
                bool val = std::get<bool>(it->second);
                bool old = monitorControllers_.exchange(val, std::memory_order_acq_rel);
                if (val && !old) EnsureThreadsStarted();
                result->Success(); return;
            }
        }
        result->Error("BAD_ARGS", "Expected bool 'enabled'"); return;
    }

    // ── setAudioThreshold ────────────────────────────────────────────────
    if (name == "setAudioThreshold") {
        if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("threshold"));
            if (it != args->end() && std::holds_alternative<double>(it->second)) {
                audioThreshold_.store(
                    static_cast<float>(std::get<double>(it->second)),
                    std::memory_order_release);
                result->Success(); return;
            }
        }
        result->Error("BAD_ARGS", "Expected double 'threshold'"); return;
    }

    // ── setIdleThreshold ─────────────────────────────────────────────────
    if (name == "setIdleThreshold") {
        if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("idleThresholdMs"));
            if (it != args->end() && std::holds_alternative<int>(it->second)) {
                idleThresholdMs_.store(std::get<int>(it->second), std::memory_order_release);
                result->Success(); return;
            }
        }
        result->Error("BAD_ARGS", "Expected int 'idleThresholdMs'"); return;
    }

    result->NotImplemented();
}

// ════════════════════════════════════════════════════════════════════════
// Initialize
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::Initialize(
    bool monitorAudio, bool monitorHID, bool monitorControllers,
    double audioThreshold, int idleThresholdMs, bool debug) {

    enableDebug_.store(debug, std::memory_order_relaxed);
    monitorAudio_.store(monitorAudio, std::memory_order_release);
    monitorHID_.store(monitorHID, std::memory_order_release);
    monitorControllers_.store(monitorControllers, std::memory_order_release);
    audioThreshold_.store(static_cast<float>(audioThreshold), std::memory_order_release);
    idleThresholdMs_.store(idleThresholdMs, std::memory_order_release);

    const bool anyEnabled = monitorAudio || monitorHID || monitorControllers;

    if (!anyEnabled) {
        // Nothing to monitor — no threads, no HID handles, no COM objects.
        // Runtime toggles will call EnsureThreadsStarted() if something
        // is enabled later.
        if (debug) std::cout << "[DAM] All monitors disabled — no threads started" << std::endl;
        initialized_.store(true, std::memory_order_release);
        return;
    }

    if (monitorHID) InitializeHIDDevices();

    StartMonitorThread();
    StartInactivityThread();
    threadsStarted_.store(true, std::memory_order_release);

    initialized_.store(true, std::memory_order_release);

    if (debug) std::cout << "[DAM] Initialized" << std::endl;
}

// ════════════════════════════════════════════════════════════════════════
// PostToMainThread / SafeInvokeMethod
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::PostToMainThread(std::function<void()> task) {
    PlatformTaskDispatcher::Get().PostTask(std::move(task));
}

void DeviceActivityMonitorPlugin::SafeInvokeMethod(const std::string& method) {
    if (isShuttingDown_.load(std::memory_order_acquire)) return;
    try {
        std::lock_guard<std::mutex> lock(channelMutex_);
        if (channel_ && !isShuttingDown_.load(std::memory_order_acquire))
            channel_->InvokeMethod(method,
                std::make_unique<flutter::EncodableValue>(flutter::EncodableValue()));
    } catch (...) {}
}

// ════════════════════════════════════════════════════════════════════════
// Activity tracking
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::UpdateLastActivityTime() {
    std::lock_guard<std::mutex> lock(activityMutex_);
    lastActivityTime_ = std::chrono::steady_clock::now();
}

bool DeviceActivityMonitorPlugin::IsShuttingDown() const {
    return isShuttingDown_.load(std::memory_order_acquire);
}

// ════════════════════════════════════════════════════════════════════════
// OnSystemResume
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::OnSystemResume() {
    if (isShuttingDown_.load(std::memory_order_acquire)) return;
    if (enableDebug_.load(std::memory_order_relaxed))
        std::cout << "[DAM] System resume" << std::endl;

    UpdateLastActivityTime();
    needsHIDReinit_.store(true, std::memory_order_release);
    needsAudioCacheReset_.store(true, std::memory_order_release);

    if (!userIsActive_.load(std::memory_order_acquire)) {
        userIsActive_.store(true, std::memory_order_release);
        std::weak_ptr<DeviceActivityMonitorPlugin> weak;
        { std::lock_guard<std::mutex> l(instanceMutex_); weak = instance_; }
        PostToMainThread([weak]() {
            if (auto p = weak.lock())
                if (!p->isShuttingDown_.load(std::memory_order_acquire))
                    p->SafeInvokeMethod("onUserActive");
        });
    }
}

// ════════════════════════════════════════════════════════════════════════
// Audio
// ════════════════════════════════════════════════════════════════════════

bool DeviceActivityMonitorPlugin::CheckSystemAudio() {
    if (!monitorAudio_.load(std::memory_order_acquire) ||
        isShuttingDown_.load(std::memory_order_acquire)) return false;

    float peak = 0.0f;
    bool debug = enableDebug_.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(audioMeterMutex_);
        if (!audioMeterCache_) return false;
        if (needsAudioCacheReset_.exchange(false, std::memory_order_acq_rel))
            audioMeterCache_->Invalidate();
        peak = audioMeterCache_->GetPeak(debug);
    }

    if (peak > audioThreshold_.load(std::memory_order_acquire)) {
        if (debug) std::cout << "[DAM] Audio peak: " << peak << std::endl;
        return true;
    }
    return false;
}

// ════════════════════════════════════════════════════════════════════════
// Controllers
// ════════════════════════════════════════════════════════════════════════

bool DeviceActivityMonitorPlugin::CheckControllerInput() {
    if (!monitorControllers_.load(std::memory_order_acquire) ||
        isShuttingDown_.load(std::memory_order_acquire)) return false;

    for (DWORD i = 0; i < XUSER_MAX_COUNT; i++) {
        if (isShuttingDown_.load(std::memory_order_acquire)) break;
        XINPUT_STATE state{}; bool ex = false;
        if (XInputGetStateSEH(i, &state, &ex) == ERROR_SUCCESS && !ex) {
            if (state.dwPacketNumber != lastControllerStates_[i].dwPacketNumber) {
                lastControllerStates_[i] = state;
                if (enableDebug_.load(std::memory_order_relaxed))
                    std::cout << "[DAM] Controller " << i << " activity" << std::endl;
                return true;
            }
        }
    }
    return false;
}

// ════════════════════════════════════════════════════════════════════════
// HID devices
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::InitializeHIDDevices() {
    std::lock_guard<std::mutex> lock(hidDevicesMutex_);

    for (HANDLE h : hidDeviceHandles_) {
        if (h && h != INVALID_HANDLE_VALUE) { CancelIoSEH(h); CloseHandleSEH(h); }
    }
    hidDeviceHandles_.clear();
    lastHIDStates_.clear();

    if (isShuttingDown_.load(std::memory_order_acquire)) return;

    GUID hidGuid;
    HidD_GetHidGuid(&hidGuid);

    HDEVINFO devInfo = SetupDiGetClassDevs(
        &hidGuid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devInfo == INVALID_HANDLE_VALUE) return;

    SP_DEVICE_INTERFACE_DATA ifData{};
    ifData.cbSize = sizeof(ifData);
    DWORD idx = 0;

    while (!isShuttingDown_.load(std::memory_order_acquire) &&
           SetupDiEnumDeviceInterfaces(devInfo, nullptr, &hidGuid, idx++, &ifData)) {

        DWORD needed = 0;
        SetupDiGetDeviceInterfaceDetail(devInfo, &ifData, nullptr, 0, &needed, nullptr);
        if (!needed) continue;

        std::vector<BYTE> buf(needed);
        auto* detail = reinterpret_cast<PSP_DEVICE_INTERFACE_DETAIL_DATA>(buf.data());
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA);
        if (!SetupDiGetDeviceInterfaceDetail(devInfo, &ifData, detail, needed, nullptr, nullptr))
            continue;

        HANDLE h = CreateHIDHandleSEH(detail->DevicePath);
        if (h == INVALID_HANDLE_VALUE) continue;

        HIDD_ATTRIBUTES attr{}; attr.Size = sizeof(attr);
        if (!GetHIDAttributesSEH(h, &attr)) { CloseHandleSEH(h); continue; }

        PHIDP_PREPARSED_DATA preparsed = nullptr;
        if (!GetHIDPreparsedDataSEH(h, &preparsed)) { CloseHandleSEH(h); continue; }

        HIDP_CAPS caps{};
        bool ok = GetHIDCapsSEH(preparsed, &caps);
        FreePreparsedDataSEH(preparsed);
        if (!ok) { CloseHandleSEH(h); continue; }

        // Exclude audio, keyboard, mouse — same logic as WindowFocus
        bool isAudio    = (caps.UsagePage == 0x0B || caps.UsagePage == 0x0C);
        bool isKeyboard = (caps.UsagePage == 0x01 && caps.Usage == 0x06);
        bool isMouse    = (caps.UsagePage == 0x01 && caps.Usage == 0x02);

        if (!isAudio && !isKeyboard && !isMouse && caps.InputReportByteLength > 0) {
            hidDeviceHandles_.push_back(h);
            lastHIDStates_.push_back(std::vector<BYTE>(caps.InputReportByteLength, 0));
            if (enableDebug_.load(std::memory_order_relaxed))
                std::cout << "[DAM] HID device: VID=" << std::hex
                          << attr.VendorID << " PID=" << attr.ProductID
                          << std::dec << std::endl;
        } else {
            CloseHandleSEH(h);
        }
    }

    SetupDiDestroyDeviceInfoList(devInfo);
    if (enableDebug_.load(std::memory_order_relaxed))
        std::cout << "[DAM] " << hidDeviceHandles_.size() << " HID devices ready" << std::endl;
}

void DeviceActivityMonitorPlugin::CloseHIDDevices() {
    std::lock_guard<std::mutex> lock(hidDevicesMutex_);
    for (HANDLE h : hidDeviceHandles_) {
        if (h && h != INVALID_HANDLE_VALUE) { CancelIoSEH(h); CloseHandleSEH(h); }
    }
    hidDeviceHandles_.clear();
    lastHIDStates_.clear();
}

bool DeviceActivityMonitorPlugin::CheckHIDDevices() {
    if (!monitorHID_.load(std::memory_order_acquire) ||
        isShuttingDown_.load(std::memory_order_acquire)) return false;

    std::lock_guard<std::mutex> lock(hidDevicesMutex_);
    if (hidDeviceHandles_.empty()) return false;

    bool detected = false;
    std::vector<size_t> invalid;

    for (size_t i = 0; i < hidDeviceHandles_.size(); i++) {
        if (isShuttingDown_.load(std::memory_order_acquire)) break;
        HANDLE h = hidDeviceHandles_[i];
        if (!IsHandleValid(h)) { invalid.push_back(i); continue; }

        auto& last = lastHIDStates_[i];
        if (last.empty()) continue;

        std::vector<BYTE> buf(last.size(), 0);
        OverlappedGuard ovl(h);
        if (!ovl.IsValid()) continue;

        DWORD read = 0, err = 0;
        bool ok = ReadHIDDeviceSEH(h, buf.data(), (DWORD)buf.size(), ovl.Get(), &read, &err);

        if (ok) {
            ovl.MarkComplete();
            if (read > 0 && buf != last) { detected = true; last = buf; }
        } else if (err == ERROR_IO_PENDING) {
            DWORD wait = WaitForSingleObject(ovl.ovl.hEvent, 10);
            if (wait == WAIT_OBJECT_0) {
                ovl.MarkComplete();
                DWORD oErr = 0;
                if (GetOverlappedResultSEH(h, ovl.Get(), &read, &oErr)) {
                    if (read > 0 && buf != last) { detected = true; last = buf; }
                } else if (oErr == ERROR_INVALID_HANDLE || oErr == ERROR_DEVICE_NOT_CONNECTED) {
                    ovl.InvalidateDevice(); ovl.MarkComplete(); invalid.push_back(i);
                }
            } else if (wait == WAIT_FAILED) {
                ovl.InvalidateDevice(); ovl.MarkComplete(); invalid.push_back(i);
            }
        } else if (err == ERROR_DEVICE_NOT_CONNECTED || err == ERROR_INVALID_HANDLE ||
                   err == ERROR_GEN_FAILURE || err == ERROR_BAD_DEVICE) {
            ovl.InvalidateDevice(); ovl.MarkComplete(); invalid.push_back(i);
        } else {
            ovl.InvalidateDevice(); ovl.MarkComplete(); invalid.push_back(i);
        }

        if (detected) break;
    }

    // Remove invalid devices in reverse order
    if (!invalid.empty()) {
        std::sort(invalid.begin(), invalid.end());
        invalid.erase(std::unique(invalid.begin(), invalid.end()), invalid.end());
        for (auto it = invalid.rbegin(); it != invalid.rend(); ++it) {
            size_t idx = *it;
            if (idx < hidDeviceHandles_.size()) {
                HANDLE h = hidDeviceHandles_[idx];
                if (h && h != INVALID_HANDLE_VALUE) { CancelIoSEH(h); CloseHandleSEH(h); }
                hidDeviceHandles_.erase(hidDeviceHandles_.begin() + idx);
                lastHIDStates_.erase(lastHIDStates_.begin() + idx);
            }
        }
    }

    return detected;
}

// ════════════════════════════════════════════════════════════════════════
// EnsureThreadsStarted — called by runtime toggles when a monitor is
// enabled after initialization with all-false flags.
// Safe to call multiple times — checks threadsStarted_ atomically.
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::EnsureThreadsStarted() {
    // Already running or shutting down — nothing to do
    if (threadsStarted_.load(std::memory_order_acquire)) return;
    if (isShuttingDown_.load(std::memory_order_acquire)) return;

    // CAS to ensure only one caller wins the race
    bool expected = false;
    if (!threadsStarted_.compare_exchange_strong(expected, true,
            std::memory_order_acq_rel, std::memory_order_acquire)) return;

    if (enableDebug_.load(std::memory_order_relaxed))
        std::cout << "[DAM] Starting monitor threads (lazy)" << std::endl;

    StartMonitorThread();
    StartInactivityThread();
    // threadsStarted_ was already set true by the CAS above
}

// ════════════════════════════════════════════════════════════════════════
// Monitor thread — polls all three sources every 100ms
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::StartMonitorThread() {
    std::weak_ptr<DeviceActivityMonitorPlugin> weak = shared_from_this();

    std::lock_guard<std::mutex> tlock(threadsMutex_);
    threads_.emplace_back([weak]() {
        // COM initialised unconditionally — audio may be enabled later at
        // runtime and we cannot re-init COM on a running thread.
        bool comOk = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));

        // Only create AudioMeterCache if audio monitoring is currently on.
        // If it gets enabled later via setAudioMonitoring(true) the cache
        // will be created then (see setAudioMonitoring handler below).
        std::unique_ptr<AudioMeterCache> audioCache;
        {
            auto self = weak.lock();
            if (self && self->monitorAudio_.load(std::memory_order_acquire)) {
                audioCache = std::make_unique<AudioMeterCache>();
                std::lock_guard<std::mutex> l(self->audioMeterMutex_);
                self->audioMeterCache_ = audioCache.get();
            }
        }

        auto lastHIDReinit     = std::chrono::steady_clock::now();
        auto lastFullHIDRefresh = std::chrono::steady_clock::now();
        const auto kHIDReinit   = std::chrono::seconds(30);
        const auto kHIDRefresh  = std::chrono::minutes(5);

        while (true) {
            auto self = weak.lock();
            if (!self || self->isShuttingDown_.load(std::memory_order_acquire)) break;

            {
                std::unique_lock<std::mutex> lock(self->shutdownMutex_);
                if (self->shutdownCv_.wait_for(lock, std::chrono::milliseconds(100),
                    [&] { return self->isShuttingDown_.load(std::memory_order_acquire); })) break;
            }

            self = weak.lock();
            if (!self || self->isShuttingDown_.load(std::memory_order_acquire)) break;

            bool activity = false;
            try {
                if (!self->isShuttingDown_.load(std::memory_order_acquire))
                    if (self->CheckSystemAudio())     activity = true;
                if (!self->isShuttingDown_.load(std::memory_order_acquire))
                    if (self->CheckControllerInput()) activity = true;
                if (!self->isShuttingDown_.load(std::memory_order_acquire))
                    if (self->CheckHIDDevices())      activity = true;
            } catch (...) {}

            // System resume: reinit HID + invalidate audio
            if (self->needsHIDReinit_.exchange(false, std::memory_order_acq_rel)) {
                if (self->monitorHID_.load(std::memory_order_acquire) &&
                    !self->isShuttingDown_.load(std::memory_order_acquire)) {
                    self->CloseHIDDevices();
                    self->InitializeHIDDevices();
                    lastHIDReinit = lastFullHIDRefresh = std::chrono::steady_clock::now();
                }
            }

            // Periodic HID re-init if device list emptied
            if (self->monitorHID_.load(std::memory_order_acquire) &&
                !self->isShuttingDown_.load(std::memory_order_acquire)) {
                auto now = std::chrono::steady_clock::now();
                if (now - lastHIDReinit > kHIDReinit) {
                    lastHIDReinit = now;
                    bool empty;
                    { std::lock_guard<std::mutex> l(self->hidDevicesMutex_);
                      empty = self->hidDeviceHandles_.empty(); }
                    if (empty) self->InitializeHIDDevices();
                }
                if (now - lastFullHIDRefresh > kHIDRefresh) {
                    lastFullHIDRefresh = now;
                    self->CloseHIDDevices();
                    self->InitializeHIDDevices();
                }
            }

            if (activity && !self->isShuttingDown_.load(std::memory_order_acquire)) {
                self->UpdateLastActivityTime();
                if (!self->userIsActive_.load(std::memory_order_acquire)) {
                    self->userIsActive_.store(true, std::memory_order_release);
                    self->PostToMainThread([weak]() {
                        if (auto p = weak.lock())
                            if (!p->isShuttingDown_.load(std::memory_order_acquire))
                                p->SafeInvokeMethod("onUserActive");
                    });
                }
            }

            self.reset();
        }

        // Unregister audio cache before exit
        {
            auto self = weak.lock();
            if (self) {
                std::lock_guard<std::mutex> l(self->audioMeterMutex_);
                self->audioMeterCache_ = nullptr;
            }
        }
        audioCache.reset();
        if (comOk) CoUninitialize();
    });
}

// ════════════════════════════════════════════════════════════════════════
// Inactivity thread — checks elapsed time every second
// ════════════════════════════════════════════════════════════════════════

void DeviceActivityMonitorPlugin::StartInactivityThread() {
    std::weak_ptr<DeviceActivityMonitorPlugin> weak = shared_from_this();

    std::lock_guard<std::mutex> tlock(threadsMutex_);
    threads_.emplace_back([weak]() {
        while (true) {
            auto self = weak.lock();
            if (!self || self->isShuttingDown_.load(std::memory_order_acquire)) break;

            {
                std::unique_lock<std::mutex> lock(self->shutdownMutex_);
                if (self->shutdownCv_.wait_for(lock, std::chrono::seconds(1),
                    [&] { return self->isShuttingDown_.load(std::memory_order_acquire); })) break;
            }

            self = weak.lock();
            if (!self || self->isShuttingDown_.load(std::memory_order_acquire)) break;

            int64_t elapsed;
            {
                std::lock_guard<std::mutex> l(self->activityMutex_);
                elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - self->lastActivityTime_).count();
            }

            if (elapsed > self->idleThresholdMs_.load(std::memory_order_acquire) &&
                self->userIsActive_.load(std::memory_order_acquire)) {
                self->userIsActive_.store(false, std::memory_order_release);
                if (self->enableDebug_.load(std::memory_order_relaxed))
                    std::cout << "[DAM] Inactivity after " << elapsed << "ms" << std::endl;
                self->PostToMainThread([weak]() {
                    if (auto p = weak.lock())
                        if (!p->isShuttingDown_.load(std::memory_order_acquire))
                            p->SafeInvokeMethod("onUserInactivity");
                });
            }

            self.reset();
        }
    });
}

}  // namespace device_activity_monitor