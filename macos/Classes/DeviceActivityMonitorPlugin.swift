import Cocoa
import FlutterMacOS
import IOKit
import IOKit.hid
import CoreAudio
import AudioToolbox

// ════════════════════════════════════════════════════════════════════════
// Plugin entry point
// ════════════════════════════════════════════════════════════════════════

public class DeviceActivityMonitorPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "expert.harman/device_activity_monitor",
            binaryMessenger: registrar.messenger)
        let instance = DeviceActivityMonitorPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // ── Activity source ───────────────────────────────────────────────
    enum ActivitySource {
        case hid
        case controller
        case audio
    }

    // ── State ─────────────────────────────────────────────────────────
    private let channel: FlutterMethodChannel

    var monitorAudio:    Bool  = false
    var audioThreshold:  Float = 0.001

    private var monitorHID         = false
    private var monitorControllers = false
    private var idleThresholdMs: Int  = 300_000
    private var debug              = false

    private var userIsActive            = true
    private var lastHumanActivityTime   = Date()
    private var lastAudioActivityTime   = Date()
    private var audioIsPlaying          = false
    private let activityLock            = NSLock()

    // Audio — property listener on default output device
    private var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var audioMonitoringActive = false
    private var audioPollingTimer: Timer?
    private var runningListenerInstalled = false
    private var deviceChangeListenerInstalled = false

    // HID — NSEvent monitors (sandbox-compatible, mouse/tablet/trackpad)
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    // Controllers — IOHIDManager (works in background, sandbox-safe for controllers)
    private var controllerHIDManager: IOHIDManager?

    // Inactivity timer
    private var inactivityTimer: Timer?

    // ── Init ──────────────────────────────────────────────────────────
    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    deinit {
        teardown()
    }

    // ════════════════════════════════════════════════════════════════════
    // FlutterPlugin method call handler
    // ════════════════════════════════════════════════════════════════════

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "initialize":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "BAD_ARGS", message: "Expected map", details: nil))
                return
            }
            initialize(
                monitorAudio:       args["monitorAudio"]       as? Bool   ?? true,
                monitorHID:         args["monitorHID"]         as? Bool   ?? true,
                monitorControllers: args["monitorControllers"] as? Bool   ?? true,
                audioThreshold:     args["audioThreshold"]     as? Double ?? 0.001,
                idleThresholdMs:    args["idleThresholdMs"]    as? Int    ?? 300_000,
                debug:              args["debug"]              as? Bool   ?? false)
            result(nil)

        case "dispose":
            teardown()
            result(nil)

        case "setAudioMonitoring":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "BAD_ARGS", message: "Expected bool 'enabled'", details: nil))
                return
            }
            setAudioMonitoring(enabled)
            result(nil)

        case "setHIDMonitoring":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "BAD_ARGS", message: "Expected bool 'enabled'", details: nil))
                return
            }
            setHIDMonitoring(enabled)
            result(nil)

        case "setControllerMonitoring":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "BAD_ARGS", message: "Expected bool 'enabled'", details: nil))
                return
            }
            setControllerMonitoring(enabled)
            result(nil)

        case "setAudioThreshold":
            guard let args = call.arguments as? [String: Any],
                  let threshold = args["threshold"] as? Double else {
                result(FlutterError(code: "BAD_ARGS", message: "Expected double 'threshold'", details: nil))
                return
            }
            audioThreshold = Float(threshold)
            result(nil)

        case "setIdleThreshold":
            guard let args = call.arguments as? [String: Any],
                  let ms = args["idleThresholdMs"] as? Int else {
                result(FlutterError(code: "BAD_ARGS", message: "Expected int 'idleThresholdMs'", details: nil))
                return
            }
            idleThresholdMs = ms
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Initialize
    // ════════════════════════════════════════════════════════════════════

    private func initialize(
        monitorAudio: Bool, monitorHID: Bool, monitorControllers: Bool,
        audioThreshold: Double, idleThresholdMs: Int, debug: Bool) {

        self.debug           = debug
        self.audioThreshold  = Float(audioThreshold)
        self.idleThresholdMs = idleThresholdMs

        let anyEnabled = monitorAudio || monitorHID || monitorControllers

        if !anyEnabled {
            if debug { print("[DAM] All monitors disabled — nothing started") }
            return
        }

        if monitorAudio       { setAudioMonitoring(true) }
        if monitorHID         { setHIDMonitoring(true) }
        if monitorControllers { setControllerMonitoring(true) }

        startInactivityTimer()

        if debug { print("[DAM] macOS initialized") }
    }

    private func teardown() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        setAudioMonitoring(false)
        setHIDMonitoring(false)
        setControllerMonitoring(false)
    }

    // ════════════════════════════════════════════════════════════════════
    // Activity signal — source-aware
    // ════════════════════════════════════════════════════════════════════

    func recordActivity(source: ActivitySource = .hid) {
        switch source {
        case .hid, .controller:
            activityLock.lock()
            lastHumanActivityTime = Date()
            activityLock.unlock()

            if !userIsActive {
                userIsActive = true
                DispatchQueue.main.async { [weak self] in
                    self?.channel.invokeMethod("onUserActive", arguments: nil)
                }
            }

        case .audio:
            activityLock.lock()
            lastAudioActivityTime = Date()
            audioIsPlaying = true
            activityLock.unlock()

            // Audio alone can mark active ONLY if there was recent human activity
            let humanElapsed = Date().timeIntervalSince(lastHumanActivityTime) * 1000
            if humanElapsed < Double(idleThresholdMs) && !userIsActive {
                userIsActive = true
                DispatchQueue.main.async { [weak self] in
                    self?.channel.invokeMethod("onUserActive", arguments: nil)
                }
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Inactivity timer
    // ════════════════════════════════════════════════════════════════════

    private func ensureInactivityTimerRunning() {
        guard inactivityTimer == nil else { return }
        startInactivityTimer()
    }

    private func stopInactivityTimerIfIdle() {
        guard !monitorAudio && !monitorHID && !monitorControllers else { return }
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        if debug { print("[DAM] All monitors disabled — inactivity timer stopped") }
    }

    private func startInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkInactivity()
        }
    }

    private func checkInactivity() {
        activityLock.lock()
        let humanElapsed = Date().timeIntervalSince(lastHumanActivityTime) * 1000
        let audioElapsed = Date().timeIntervalSince(lastAudioActivityTime) * 1000
        if audioElapsed > 10_000 { audioIsPlaying = false }
        let audioPlaying = audioIsPlaying
        activityLock.unlock()

        let humanIdle = humanElapsed > Double(idleThresholdMs)

        if humanIdle && userIsActive {
            userIsActive = false
            if debug {
                print("[DAM] User IDLE — no human input for \(Int(humanElapsed))ms (audio: \(audioPlaying))")
            }
            channel.invokeMethod("onUserInactivity", arguments: [
                "humanIdleMs": Int(humanElapsed),
                "audioPlaying": audioPlaying
            ])
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // Audio — kAudioDevicePropertyDeviceIsRunningSomewhere
    // ════════════════════════════════════════════════════════════════════

    private func setAudioMonitoring(_ enabled: Bool) {
        monitorAudio = enabled
        if enabled {
            startAudioMonitoring()
            ensureInactivityTimerRunning()
        } else {
            stopAudioMonitoring()
            stopInactivityTimerIfIdle()
        }
    }

    private func startAudioMonitoring() {
        guard !audioMonitoringActive else { return }

        let deviceID = getDefaultOutputDevice()
        guard deviceID != kAudioObjectUnknown else {
            if debug { print("[DAM] Audio: no default output device") }
            return
        }
        outputDeviceID = deviceID

        installRunningListener(on: deviceID)
        installDefaultDeviceChangeListener()

        if isOutputDeviceRunning() {
            if debug { print("[DAM] Audio: device \(deviceID) already running at start") }
            recordActivity(source: .audio)
            startAudioPolling()
        }

        audioMonitoringActive = true
        if debug { print("[DAM] Audio monitoring started (device \(deviceID))") }
    }

    private func stopAudioMonitoring() {
        guard audioMonitoringActive else { return }

        removeRunningListener()
        removeDefaultDeviceChangeListener()
        stopAudioPolling()

        audioMonitoringActive = false
        outputDeviceID = kAudioObjectUnknown

        if debug { print("[DAM] Audio monitoring stopped") }
    }

    private func getDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = kAudioObjectUnknown as AudioDeviceID
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &dataSize, &deviceID)

        if status != noErr {
            if debug { print("[DAM] Audio: failed to get default output (err \(status))") }
            return kAudioObjectUnknown
        }
        return deviceID
    }

    private func isOutputDeviceRunning() -> Bool {
        guard outputDeviceID != kAudioObjectUnknown else { return false }

        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)

        let status = AudioObjectGetPropertyData(
            outputDeviceID, &addr, 0, nil, &dataSize, &isRunning)

        return status == noErr && isRunning != 0
    }

    private func installRunningListener(on deviceID: AudioDeviceID) {
        guard !runningListenerInstalled else { return }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)

        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &addr,
            DispatchQueue.main
        ) { [weak self] (_, _) in
            guard let self = self, self.monitorAudio else { return }
            self.handleRunningStateChanged()
        }

        if status == noErr {
            runningListenerInstalled = true
        } else if debug {
            print("[DAM] Audio: failed to install running listener (err \(status))")
        }
    }

    private func removeRunningListener() {
        runningListenerInstalled = false
    }

    private func handleRunningStateChanged() {
        let running = isOutputDeviceRunning()
        if debug { print("[DAM] Audio: output device running = \(running)") }

        if running {
            recordActivity(source: .audio)
            startAudioPolling()
        } else {
            stopAudioPolling()
        }
    }

    private func startAudioPolling() {
        guard audioPollingTimer == nil else { return }

        audioPollingTimer = Timer.scheduledTimer(
            withTimeInterval: 5.0,
            repeats: true
        ) { [weak self] _ in
            guard let self = self, self.monitorAudio else {
                self?.stopAudioPolling()
                return
            }
            if self.isOutputDeviceRunning() {
                if self.debug { print("[DAM] Audio: still running") }
                self.recordActivity(source: .audio)
            } else {
                self.stopAudioPolling()
            }
        }
    }

    private func stopAudioPolling() {
        audioPollingTimer?.invalidate()
        audioPollingTimer = nil
    }

    private func installDefaultDeviceChangeListener() {
        guard !deviceChangeListenerInstalled else { return }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DispatchQueue.main
        ) { [weak self] (_, _) in
            guard let self = self, self.monitorAudio else { return }
            self.handleDefaultDeviceChanged()
        }

        if status == noErr {
            deviceChangeListenerInstalled = true
        }
    }

    private func removeDefaultDeviceChangeListener() {
        deviceChangeListenerInstalled = false
    }

    func handleDefaultDeviceChanged() {
        guard monitorAudio else { return }
        if debug { print("[DAM] Audio: default device changed") }

        removeRunningListener()
        stopAudioPolling()

        let newDeviceID = getDefaultOutputDevice()
        guard newDeviceID != kAudioObjectUnknown else {
            outputDeviceID = kAudioObjectUnknown
            return
        }

        outputDeviceID = newDeviceID
        installRunningListener(on: newDeviceID)

        if isOutputDeviceRunning() {
            recordActivity(source: .audio)
            startAudioPolling()
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // HID — NSEvent Global + Local Monitors (sandbox-compatible)
    // Tablet, trackpad gestures only — excludes mouse and keyboard
    // ════════════════════════════════════════════════════════════════════

    private func setHIDMonitoring(_ enabled: Bool) {
        monitorHID = enabled
        if enabled {
            startHIDMonitoring()
            ensureInactivityTimerRunning()
        } else {
            stopHIDMonitoring()
            stopInactivityTimerIfIdle()
        }
    }

    private func startHIDMonitoring() {
        guard globalEventMonitor == nil else { return }

        let eventMask: NSEvent.EventTypeMask = [
            .tabletPoint,
            .tabletProximity,
            .magnify,
            .rotate,
            .swipe,
            .smartMagnify,
            .pressure,
            .directTouch,
        ]

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let self = self, self.monitorHID else { return }
            if self.debug {
                print("[DAM] Global HID event: type=\(event.type.rawValue)")
            }
            self.recordActivity(source: .hid)
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let self = self, self.monitorHID else { return event }
            if self.debug {
                print("[DAM] Local HID event: type=\(event.type.rawValue)")
            }
            self.recordActivity(source: .hid)
            return event
        }

        if debug { print("[DAM] HID monitoring started (tablet/trackpad gestures only)") }
    }

    private func stopHIDMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if debug { print("[DAM] HID monitoring stopped") }
    }

    // ════════════════════════════════════════════════════════════════════
    // Controllers — IOHIDManager (works in background, sandbox-safe)
    //
    // GameController framework only delivers events when the app is
    // frontmost. IOHIDManager with controller-specific matching works
    // in the background AND inside the App Sandbox because game
    // controllers are not protected by Input Monitoring.
    // ════════════════════════════════════════════════════════════════════

    private func setControllerMonitoring(_ enabled: Bool) {
        monitorControllers = enabled
        if enabled {
            startControllerMonitoring()
            ensureInactivityTimerRunning()
        } else {
            stopControllerMonitoring()
            stopInactivityTimerIfIdle()
        }
    }

    private func startControllerMonitoring() {
        guard controllerHIDManager == nil else { return }

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone))

        // Match ONLY game controllers — NOT protected by Input Monitoring
        let matchingCriteria: [[String: Any]] = [
            // Joystick (Usage Page 0x01, Usage 0x04)
            [
                kIOHIDDeviceUsagePageKey as String: 0x01,
                kIOHIDDeviceUsageKey as String: 0x04
            ],
            // Game Pad (Usage Page 0x01, Usage 0x05)
            [
                kIOHIDDeviceUsagePageKey as String: 0x01,
                kIOHIDDeviceUsageKey as String: 0x05
            ],
            // Multi-axis Controller (Usage Page 0x01, Usage 0x08)
            [
                kIOHIDDeviceUsagePageKey as String: 0x01,
                kIOHIDDeviceUsageKey as String: 0x08
            ],
            // Simulation Controls (flight sticks, racing wheels)
            [
                kIOHIDDeviceUsagePageKey as String: 0x02
            ],
            // Game Controls
            [
                kIOHIDDeviceUsagePageKey as String: 0x05
            ],
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingCriteria as CFArray)

        // Device connected
        let matchCallback: IOHIDDeviceCallback = { context, _, _, device in
            guard let ctx = context else { return }
            let plugin = Unmanaged<DeviceActivityMonitorPlugin>
                .fromOpaque(ctx)
                .takeUnretainedValue()

            let name = IOHIDDeviceGetProperty(
                device, kIOHIDProductKey as CFString) as? String ?? "unknown"
            if plugin.debug {
                print("[DAM] Controller connected: \(name)")
            }
        }

        // Device disconnected
        let removeCallback: IOHIDDeviceCallback = { context, _, _, device in
            guard let ctx = context else { return }
            let plugin = Unmanaged<DeviceActivityMonitorPlugin>
                .fromOpaque(ctx)
                .takeUnretainedValue()

            if plugin.debug {
                print("[DAM] Controller disconnected")
            }
        }

        // Input — fires for every button press, stick move, trigger pull
        let inputCallback: IOHIDValueCallback = { context, _, _, value in
            guard let ctx = context else { return }
            let plugin = Unmanaged<DeviceActivityMonitorPlugin>
                .fromOpaque(ctx)
                .takeUnretainedValue()
            guard plugin.monitorControllers else { return }

            if plugin.debug {
                let element = IOHIDValueGetElement(value)
                let usagePage = IOHIDElementGetUsagePage(element)
                let usage = IOHIDElementGetUsage(element)
                let intValue = IOHIDValueGetIntegerValue(value)
                print("[DAM] Controller input: page=0x\(String(format: "%02X", usagePage)) usage=0x\(String(format: "%02X", usage)) value=\(intValue)")
            }

            plugin.recordActivity(source: .controller)
        }

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removeCallback, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, inputCallback, ctx)

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        if openResult == kIOReturnSuccess {
            controllerHIDManager = manager
            if debug {
                print("[DAM] Controller monitoring started (IOHIDManager — works in background)")
            }
        } else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue)
            if debug {
                print("[DAM] Controller HID manager open failed: \(openResult)")
            }
        }
    }

    private func stopControllerMonitoring() {
        guard let manager = controllerHIDManager else { return }

        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue)

        controllerHIDManager = nil
        if debug { print("[DAM] Controller monitoring stopped") }
    }
}