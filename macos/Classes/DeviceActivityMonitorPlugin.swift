import Cocoa
import FlutterMacOS
import GameController
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

    // ── State ─────────────────────────────────────────────────────────
    private let channel: FlutterMethodChannel

    var monitorAudio:    Bool  = false
    var audioThreshold:  Float = 0.001

    private var monitorHID         = false
    private var monitorControllers = false
    private var idleThresholdMs: Int  = 300_000
    private var debug              = false

    private var userIsActive       = true
    private var lastActivityTime   = Date()
    private let activityLock       = NSLock()

    // Audio — property listener on default output device
    private var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var audioMonitoringActive = false
    private var audioPollingTimer: Timer?
    private var runningListenerInstalled = false
    private var deviceChangeListenerInstalled = false

    // HID — NSEvent monitors (sandbox-compatible)
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

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
    // Activity signal
    // ════════════════════════════════════════════════════════════════════

    func recordActivity() {
        activityLock.lock()
        lastActivityTime = Date()
        activityLock.unlock()

        if !userIsActive {
            userIsActive = true
            DispatchQueue.main.async { [weak self] in
                self?.channel.invokeMethod("onUserActive", arguments: nil)
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
        let elapsed = Date().timeIntervalSince(lastActivityTime) * 1000
        activityLock.unlock()

        if elapsed > Double(idleThresholdMs) && userIsActive {
            userIsActive = false
            if debug { print("[DAM] Inactivity after \(Int(elapsed))ms") }
            channel.invokeMethod("onUserInactivity", arguments: nil)
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
            recordActivity()
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
            recordActivity()
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
                if self.debug { print("[DAM] Audio: still running — activity") }
                self.recordActivity()
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
            recordActivity()
            startAudioPolling()
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // HID — NSEvent Global + Local Monitors (sandbox-compatible)
    //
    // Replaces IOHIDManager which cannot work inside the App Sandbox.
    // Monitors mouse, trackpad, tablet (Wacom etc.), scroll, gesture
    // events system-wide. Does NOT monitor keyboard (that would require
    // Accessibility permission).
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
            // Mouse
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDown,
            .otherMouseUp,
            .otherMouseDragged,
            .scrollWheel,
            // Tablet (drawing tablets)
            .tabletPoint,
            .tabletProximity,
            // Trackpad gestures
            .gesture,
            .magnify,
            .swipe,
            .rotate,
            .smartMagnify,
            .pressure,
            .directTouch,
        ]

        // Global — events in OTHER applications
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let self = self, self.monitorHID else { return }
            if self.debug {
                print("[DAM] Global event: type=\(event.type.rawValue)")
            }
            self.recordActivity()
        }

        // Local — events in OUR application
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let self = self, self.monitorHID else { return event }
            if self.debug {
                print("[DAM] Local event: type=\(event.type.rawValue)")
            }
            self.recordActivity()
            return event
        }

        if debug { print("[DAM] HID monitoring started (NSEvent monitors)") }
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
    // Controllers — GameController framework
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerConnected(_:)),
            name: .GCControllerDidConnect,
            object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDisconnected(_:)),
            name: .GCControllerDidDisconnect,
            object: nil)

        for controller in GCController.controllers() {
            registerControllerHandlers(controller)
        }

        GCController.startWirelessControllerDiscovery {}

        if debug {
            print("[DAM] Controller monitoring started (\(GCController.controllers().count) connected)")
        }
    }

    private func stopControllerMonitoring() {
        NotificationCenter.default.removeObserver(self, name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.removeObserver(self, name: .GCControllerDidDisconnect, object: nil)
        GCController.stopWirelessControllerDiscovery()

        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.microGamepad?.valueChangedHandler    = nil
        }

        if debug { print("[DAM] Controller monitoring stopped") }
    }

    @objc private func controllerConnected(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        if debug { print("[DAM] Controller connected: \(controller.vendorName ?? "unknown")") }
        registerControllerHandlers(controller)
    }

    @objc private func controllerDisconnected(_ notification: Notification) {
        if debug { print("[DAM] Controller disconnected") }
    }

    private func registerControllerHandlers(_ controller: GCController) {
        controller.extendedGamepad?.valueChangedHandler = {
            [weak self] (gamepad: GCExtendedGamepad, element: GCControllerElement) in
            guard let self = self, self.monitorControllers else { return }
            if self.debug { print("[DAM] Extended gamepad input") }
            self.recordActivity()
        }

        controller.microGamepad?.valueChangedHandler = {
            [weak self] (gamepad: GCMicroGamepad, element: GCControllerElement) in
            guard let self = self, self.monitorControllers else { return }
            if self.debug { print("[DAM] Micro gamepad input") }
            self.recordActivity()
        }
    }
}