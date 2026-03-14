# device_activity_monitor

A Flutter plugin that detects user activity via **audio output**, **HID/tablet input**, and **game controllers** on Windows and macOS. Designed as a companion to `window_focus` for screen-time inactivity detection — both plugins expose identical stream names so your app treats them interchangeably.

---

## Table of Contents

- [How it works](#how-it-works)
- [Installation](#installation)
- [Windows setup](#windows-setup)
- [macOS setup](#macos-setup)
- [Basic usage](#basic-usage)
- [Using alongside window_focus](#using-alongside-window_focus)
- [Runtime toggles](#runtime-toggles)
- [Error handling](#error-handling)
- [API reference](#api-reference)
- [Platform behaviour notes](#platform-behaviour-notes)

---

## How it works

| Source | Windows | macOS |
|---|---|---|
| Audio output | `IAudioMeterInformation` COM peak meter, polled every 100ms | `kAudioDevicePropertyDeviceIsRunningSomewhere` property listener + 5s polling timer |
| HID devices | `SetupAPI` + overlapped `ReadFile`, polled every 100ms | `NSEvent` global/local monitors for tablet, trackpad gesture, pressure, touch events |
| Game controllers | `XInputGetState` polled every 100ms | `IOHIDManager` with controller-specific usage page matching, event-driven |

**macOS audio logic:** Audio activity alone does **not** reset the idle state. It only keeps the user marked active if there was also recent human input (HID or controller) within the idle threshold. This prevents a movie playing unattended from keeping the session active indefinitely.

**Idle detection:** A Dart-side `Timer` resets every time `onUserActive` fires. If the timer expires with no `onUserActive` → `onUserInactivity` emits.

---

## Installation

Since this is a local plugin, add it via path in your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  device_activity_monitor:
    path: ../device_activity_monitor   # adjust to your directory layout
```

Then run:

```bash
flutter pub get
```

---

## Windows setup

No special permissions or manifest changes required. All three sources work without elevated privileges.

**Minimum Windows version:** Windows 10 (`_WIN32_WINNT=0x0A00`).

---

## macOS setup

### 1. Add entitlements

Add to **both** `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<!-- Wired USB controllers (IOHIDManager) -->
<key>com.apple.security.device.usb</key>
<true/>

<!-- Wireless Bluetooth controllers (IOHIDManager) -->
<key>com.apple.security.device.bluetooth</key>
<true/>
```

Full example:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.usb</key>
    <true/>
    <key>com.apple.security.device.bluetooth</key>
    <true/>

    <!-- existing Flutter entitlements -->
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
```

> **No Input Monitoring entitlement needed.** The plugin uses controller-specific HID usage page matching (`0x01/0x04` joystick, `0x01/0x05` gamepad, `0x02` simulation, `0x05` game controls) which is not protected by Input Monitoring. `NSEvent` monitors for tablet/gesture events also require no special permission.

### 2. Minimum macOS version

Ensure your `macos/Podfile` has:

```ruby
platform :osx, '10.15'
```

And your Xcode project deployment target is set to `10.15` or later.

---

## Basic usage

```dart
import 'package:device_activity_monitor/device_activity_monitor.dart';

class MyState extends State<MyWidget> {
  late final DeviceActivityMonitor _monitor;
  StreamSubscription<void>? _activeSub;
  StreamSubscription<void>? _inactiveSub;

  @override
  void initState() {
    super.initState();

    _monitor = DeviceActivityMonitor(
      monitorAudio:       true,
      monitorHID:         true,
      monitorControllers: true,
      idleThreshold:      const Duration(minutes: 10),
      audioThreshold:     0.001,
      debug:              false,
    );

    _activeSub = _monitor.addUserActiveListener(() {
      print('Activity detected');
    });

    _inactiveSub = _monitor.addUserInactivityListener(() {
      print('No activity for 10 minutes — user is idle');
    });
  }

  @override
  void dispose() {
    _activeSub?.cancel();
    _inactiveSub?.cancel();
    _monitor.dispose();
    super.dispose();
  }
}
```

---

## Using alongside window_focus

Both plugins expose `onUserActive` and `onUserInactivity`. Disable audio/HID/controllers in `WindowFocus` so the same sources aren't double-monitored:

```dart
class ActivityCoordinator {
  late final WindowFocus _windowFocus;
  late final DeviceActivityMonitor _deviceMonitor;

  void init() {
    _windowFocus = WindowFocus(
      // Disable sources covered by DeviceActivityMonitor
      monitorAudio:       false,
      monitorControllers: false,
      monitorHIDDevices:  false,
      duration:           const Duration(minutes: 10),
    );

    _deviceMonitor = DeviceActivityMonitor(
      monitorAudio:       true,
      monitorHID:         true,
      monitorControllers: true,
      idleThreshold:      const Duration(minutes: 10),
    );

    // Both feed the same handler
    _windowFocus.addUserActiveListener((_) => _onActivity());
    _deviceMonitor.addUserActiveListener(() => _onActivity());

    _windowFocus.addUserActiveListener((_) => _onIdle());
    _deviceMonitor.addUserInactivityListener(() => _onIdle());
  }

  void _onActivity() {
    print('Active');
  }

  void _onIdle() {
    print('Idle');
  }

  void dispose() {
    _windowFocus.dispose();
    _deviceMonitor.dispose();
  }
}
```

---

## Runtime toggles

All three monitors can be independently enabled or disabled after initialization:

```dart
// Toggle individual sources
await _monitor.setAudioMonitoring(false);
await _monitor.setHIDMonitoring(true);
await _monitor.setControllerMonitoring(false);

// Adjust audio sensitivity (0.0–1.0, default 0.001)
await _monitor.setAudioThreshold(0.01);   // less sensitive
await _monitor.setAudioThreshold(0.0005); // more sensitive

// Change idle threshold at runtime
await _monitor.setIdleThreshold(const Duration(minutes: 5));
```

**Lazy start:** If you initialize with all three set to `false`, nothing runs natively. The background thread (Windows) and OS callbacks (macOS) start only when the first monitor is enabled via a runtime toggle.

---

## Error handling

```dart
_monitor.addErrorListener((DeviceActivityError error) {
  print('${error.type}: ${error.message}');
  if (error.originalError != null) {
    print('Caused by: ${error.originalError}');
  }
});
```

Errors are non-fatal — the plugin keeps running after emitting one. A failed monitor source does not affect the others.

---

## API reference

### Constructor

```dart
DeviceActivityMonitor({
  bool monitorAudio = true,
  bool monitorHID = true,
  bool monitorControllers = true,
  double audioThreshold = 0.001,
  Duration idleThreshold = const Duration(minutes: 5),
  bool debug = false,
})
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `monitorAudio` | `bool` | `true` | Monitor system audio output |
| `monitorHID` | `bool` | `true` | Monitor tablet/trackpad gestures (macOS) or HID devices (Windows) |
| `monitorControllers` | `bool` | `true` | Monitor game controllers |
| `audioThreshold` | `double` | `0.001` | Windows only — audio peak level (0.0–1.0) above which activity is signalled |
| `idleThreshold` | `Duration` | `5 min` | Time with no activity before `onUserInactivity` fires |
| `debug` | `bool` | `false` | Print debug logs to console |

### Streams

```dart
Stream<void> get onUserActive      // activity detected from any source
Stream<void> get onUserInactivity  // idle threshold elapsed with no activity
Stream<DeviceActivityError> get onError
```

### Listener helpers

```dart
StreamSubscription<void> addUserActiveListener(void Function() listener)
StreamSubscription<void> addUserInactivityListener(void Function() listener)
StreamSubscription<DeviceActivityError> addErrorListener(void Function(DeviceActivityError) listener)
```

### Runtime configuration

```dart
Future<void> setAudioMonitoring(bool enabled)
Future<void> setHIDMonitoring(bool enabled)
Future<void> setControllerMonitoring(bool enabled)
Future<void> setAudioThreshold(double threshold)
Future<void> setIdleThreshold(Duration duration)
```

### Lifecycle

```dart
bool get isInitialized
void dispose()
```

---

## Platform behaviour notes

### macOS audio — passive detection only

Audio is detected via `kAudioDevicePropertyDeviceIsRunningSomewhere` — a system property that becomes true when any process is actively rendering to the output device. This fires instantly when playback starts or stops. A 5-second polling timer then confirms the device stays running.

**Important:** Audio alone does not reset idle state. It only keeps the user marked active if there was also human input (HID or controller) within the idle threshold in the same session. A movie playing with no one at the computer will not prevent the idle state.

### macOS HID — tablet and gesture events only

Uses `NSEvent` global and local monitors. This covers drawing tablets, trackpad gestures (pinch, rotate, swipe, smart magnify), pressure input, and direct touch. Standard mouse movement and keyboard are intentionally excluded — those are handled by `window_focus`. No Input Monitoring permission is required.

### macOS controllers — works in background

`IOHIDManager` with controller-specific usage page matching works even when the app is not frontmost, unlike the `GameController` framework which only delivers events to the active app. The specific usage pages matched (joystick `0x01/0x04`, gamepad `0x01/0x05`, multi-axis `0x01/0x08`, simulation `0x02`, game controls `0x05`) are not subject to Input Monitoring restrictions, so no permission prompt appears.

### Windows audio

Uses `IAudioMeterInformation` COM peak meter via a cached `AudioMeterCache` object. The cache is recreated every 60 seconds or after 3 consecutive failures, and is invalidated on system resume from sleep.

### Windows HID filtering

Keyboards (usage page `0x01`, usage `0x06`) and mice (`0x01/0x02`) are excluded from HID monitoring — those are handled by `window_focus`. All other HID devices with a non-zero `InputReportByteLength` are monitored.

### Windows power resume

After waking from sleep the plugin automatically resets the activity timestamp, reinitializes HID device handles (sleep disconnects them), invalidates the audio COM cache, and emits `onUserActive`.

### All monitors disabled

If all three monitors are `false` at construction time, nothing initializes natively — no threads, no OS callbacks, no device handles. Enabling a monitor later via `setXxxMonitoring(true)` starts the native side lazily at that point.