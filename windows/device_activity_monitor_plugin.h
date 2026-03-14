#ifndef DEVICE_ACTIVITY_MONITOR_PLUGIN_H_
#define DEVICE_ACTIVITY_MONITOR_PLUGIN_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>
#include <xinput.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <hidpi.h>

#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <functional>
#include <chrono>

namespace device_activity_monitor {

// ──────────────────────────────────────────────────────────────────────
// Forward declarations
// ──────────────────────────────────────────────────────────────────────
class AudioMeterCache;
class PlatformTaskDispatcher;

// ──────────────────────────────────────────────────────────────────────
// DeviceActivityMonitorPlugin
// ──────────────────────────────────────────────────────────────────────
class DeviceActivityMonitorPlugin
    : public std::enable_shared_from_this<DeviceActivityMonitorPlugin> {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  DeviceActivityMonitorPlugin();
  ~DeviceActivityMonitorPlugin();

  // Non-copyable
  DeviceActivityMonitorPlugin(const DeviceActivityMonitorPlugin&) = delete;
  DeviceActivityMonitorPlugin& operator=(const DeviceActivityMonitorPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Called by PlatformTaskDispatcher on power resume
  void OnSystemResume();
  bool IsShuttingDown() const;

  // Shared instance management (needed by PlatformTaskDispatcher)
  static std::weak_ptr<DeviceActivityMonitorPlugin> instance_;
  static std::mutex instanceMutex_;

 private:
  // ── Initialization ──────────────────────────────────────────────────
  void Initialize(
      bool monitorAudio,
      bool monitorHID,
      bool monitorControllers,
      double audioThreshold,
      int idleThresholdMs,
      bool debug);

  // Lazily starts monitor + inactivity threads when the first monitor
  // is enabled at runtime after an all-false initialization.
  void EnsureThreadsStarted();

  // ── Background threads ───────────────────────────────────────────────
  void StartMonitorThread();
  void StartInactivityThread();

  // ── Input checks ─────────────────────────────────────────────────────
  bool CheckSystemAudio();
  bool CheckControllerInput();
  bool CheckHIDDevices();

  // ── HID lifecycle ─────────────────────────────────────────────────────
  void InitializeHIDDevices();
  void CloseHIDDevices();

  // ── Activity tracking ─────────────────────────────────────────────────
  void UpdateLastActivityTime();

  // ── Main-thread dispatch ──────────────────────────────────────────────
  void PostToMainThread(std::function<void()> task);
  void SafeInvokeMethod(const std::string& methodName);

  // ── Channel ───────────────────────────────────────────────────────────
  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::mutex channelMutex_;

  // ── Flags ─────────────────────────────────────────────────────────────
  std::atomic<bool> isShuttingDown_;
  std::atomic<bool> monitorAudio_;
  std::atomic<bool> monitorHID_;
  std::atomic<bool> monitorControllers_;
  std::atomic<bool> enableDebug_;
  std::atomic<bool> userIsActive_;
  std::atomic<bool> needsHIDReinit_;
  std::atomic<bool> needsAudioCacheReset_;
  std::atomic<bool> initialized_;
  // True once StartMonitorThread/StartInactivityThread have been called.
  // Guards against double-starting when EnsureThreadsStarted is called
  // concurrently from multiple runtime toggle calls.
  std::atomic<bool> threadsStarted_;

  // ── Thresholds ────────────────────────────────────────────────────────
  std::atomic<float> audioThreshold_;
  std::atomic<int>   idleThresholdMs_;

  // ── Controller state ──────────────────────────────────────────────────
  XINPUT_STATE lastControllerStates_[XUSER_MAX_COUNT];

  // ── HID state ─────────────────────────────────────────────────────────
  std::vector<HANDLE>              hidDeviceHandles_;
  std::vector<std::vector<BYTE>>   lastHIDStates_;
  std::mutex                       hidDevicesMutex_;

  // ── Audio ─────────────────────────────────────────────────────────────
  AudioMeterCache* audioMeterCache_ = nullptr;
  std::mutex       audioMeterMutex_;

  // ── Activity tracking ─────────────────────────────────────────────────
  std::chrono::steady_clock::time_point lastActivityTime_;
  std::mutex                            activityMutex_;

  // ── Thread management ─────────────────────────────────────────────────
  std::vector<std::thread> threads_;
  std::mutex               threadsMutex_;
  std::mutex               shutdownMutex_;
  std::condition_variable  shutdownCv_;
};

}  // namespace device_activity_monitor

#endif  // DEVICE_ACTIVITY_MONITOR_PLUGIN_H_