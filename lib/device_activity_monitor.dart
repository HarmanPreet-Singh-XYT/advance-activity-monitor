import 'dart:async';
import 'package:flutter/services.dart';

/// Monitors audio output, HID devices, and game controllers for user activity.
///
/// Designed to work alongside WindowFocus — both plugins emit [onUserActive]
/// and [onUserInactivity] so your app can treat them identically.
///
/// Example:
/// ```dart
/// final monitor = DeviceActivityMonitor(
///   monitorAudio: true,
///   monitorHID: true,
///   monitorControllers: true,
/// );
///
/// monitor.onUserActive.listen((_) => resetInactivityTimer());
/// monitor.onUserInactivity.listen((_) => markUserInactive());
/// ```
class DeviceActivityMonitor {
  DeviceActivityMonitor({
    bool monitorAudio = true,
    bool monitorHID = true,
    bool monitorControllers = true,
    double audioThreshold = 0.001,
    Duration idleThreshold = const Duration(minutes: 5),
    bool debug = false,
  }) {
    _debug = debug;
    _channel.setMethodCallHandler(_handleMethodCall);
    _initialize(
      monitorAudio: monitorAudio,
      monitorHID: monitorHID,
      monitorControllers: monitorControllers,
      audioThreshold: audioThreshold,
      idleThreshold: idleThreshold,
      debug: debug,
    );
  }

  static const MethodChannel _channel = MethodChannel(
    'expert.harman/device_activity_monitor',
  );

  bool _debug = false;
  bool _isInitialized = false;

  final _userActiveController = StreamController<void>.broadcast();
  final _userInactivityController = StreamController<void>.broadcast();
  final _errorController = StreamController<DeviceActivityError>.broadcast();

  /// Fires when activity is detected from any monitored source.
  Stream<void> get onUserActive => _userActiveController.stream;

  /// Fires when no activity has been detected for the idle threshold duration.
  Stream<void> get onUserInactivity => _userInactivityController.stream;

  /// Fires when an internal error occurs.
  Stream<DeviceActivityError> get onError => _errorController.stream;

  bool get isInitialized => _isInitialized;

  Future<void> _initialize({
    required bool monitorAudio,
    required bool monitorHID,
    required bool monitorControllers,
    required double audioThreshold,
    required Duration idleThreshold,
    required bool debug,
  }) async {
    try {
      await _channel.invokeMethod('initialize', {
        'monitorAudio': monitorAudio,
        'monitorHID': monitorHID,
        'monitorControllers': monitorControllers,
        'audioThreshold': audioThreshold,
        'idleThresholdMs': idleThreshold.inMilliseconds,
        'debug': debug,
      });
      _isInitialized = true;
      if (_debug) print('[DeviceActivityMonitor] Initialized successfully');
    } catch (e, st) {
      _emitError(
        DeviceActivityError(
          type: DeviceActivityErrorType.initialization,
          message: 'Failed to initialize: $e',
          originalError: e,
          stackTrace: st,
        ),
      );
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'onUserActive':
          if (!_userActiveController.isClosed) {
            _userActiveController.add(null);
          }
          break;
        case 'onUserInactivity':
          if (!_userInactivityController.isClosed) {
            _userInactivityController.add(null);
          }
          break;
        default:
          if (_debug) {
            print('[DeviceActivityMonitor] Unknown method: ${call.method}');
          }
      }
    } catch (e, st) {
      _emitError(
        DeviceActivityError(
          type: DeviceActivityErrorType.methodCall,
          message: 'Error handling method call ${call.method}: $e',
          originalError: e,
          stackTrace: st,
        ),
      );
    }
    return null;
  }

  void _emitError(DeviceActivityError error) {
    if (_debug) {
      print('[DeviceActivityMonitor] Error: ${error.message}');
    }
    if (!_errorController.isClosed) {
      _errorController.add(error);
    }
  }

  // ──────────────────────────────────────────────
  // Runtime toggles
  // ──────────────────────────────────────────────

  /// Enables or disables audio output monitoring at runtime.
  Future<void> setAudioMonitoring(bool enabled) async {
    try {
      await _channel.invokeMethod('setAudioMonitoring', {'enabled': enabled});
    } catch (e, st) {
      _emitError(
        DeviceActivityError(
          type: DeviceActivityErrorType.configuration,
          message: 'Failed to set audio monitoring: $e',
          originalError: e,
          stackTrace: st,
        ),
      );
    }
  }

  /// Enables or disables HID device monitoring at runtime.
  Future<void> setHIDMonitoring(bool enabled) async {
    try {
      await _channel.invokeMethod('setHIDMonitoring', {'enabled': enabled});
    } catch (e, st) {
      _emitError(
        DeviceActivityError(
          type: DeviceActivityErrorType.configuration,
          message: 'Failed to set HID monitoring: $e',
          originalError: e,
          stackTrace: st,
        ),
      );
    }
  }

  /// Enables or disables game controller monitoring at runtime.
  Future<void> setControllerMonitoring(bool enabled) async {
    try {
      await _channel.invokeMethod('setControllerMonitoring', {
        'enabled': enabled,
      });
    } catch (e, st) {
      _emitError(
        DeviceActivityError(
          type: DeviceActivityErrorType.configuration,
          message: 'Failed to set controller monitoring: $e',
          originalError: e,
          stackTrace: st,
        ),
      );
    }
  }

  /// Sets the audio peak threshold. Values above this are treated as activity.
  /// Range: 0.0 – 1.0. Default: 0.001.
  Future<void> setAudioThreshold(double threshold) async {
    try {
      await _channel.invokeMethod('setAudioThreshold', {
        'threshold': threshold,
      });
    } catch (e, st) {
      _emitError(
        DeviceActivityError(
          type: DeviceActivityErrorType.configuration,
          message: 'Failed to set audio threshold: $e',
          originalError: e,
          stackTrace: st,
        ),
      );
    }
  }

  /// Sets the inactivity threshold. Fires [onUserInactivity] after this
  /// duration of no detected activity.
  Future<void> setIdleThreshold(Duration duration) async {
    try {
      await _channel.invokeMethod('setIdleThreshold', {
        'idleThresholdMs': duration.inMilliseconds,
      });
    } catch (e, st) {
      _emitError(
        DeviceActivityError(
          type: DeviceActivityErrorType.configuration,
          message: 'Failed to set idle threshold: $e',
          originalError: e,
          stackTrace: st,
        ),
      );
    }
  }

  // ──────────────────────────────────────────────
  // Listener helpers — mirrors WindowFocus API
  // ──────────────────────────────────────────────

  StreamSubscription<void> addUserActiveListener(void Function() listener) {
    return onUserActive.listen((_) => listener(), cancelOnError: false);
  }

  StreamSubscription<void> addUserInactivityListener(void Function() listener) {
    return onUserInactivity.listen((_) => listener(), cancelOnError: false);
  }

  StreamSubscription<DeviceActivityError> addErrorListener(
    void Function(DeviceActivityError) listener,
  ) {
    return onError.listen(listener, cancelOnError: false);
  }

  void dispose() {
    try {
      _channel.invokeMethod('dispose');
    } catch (_) {}
    if (!_userActiveController.isClosed) _userActiveController.close();
    if (!_userInactivityController.isClosed) _userInactivityController.close();
    if (!_errorController.isClosed) _errorController.close();
  }
}

// ──────────────────────────────────────────────
// Error types
// ──────────────────────────────────────────────

enum DeviceActivityErrorType {
  initialization,
  methodCall,
  configuration,
  unknown,
}

class DeviceActivityError {
  final DeviceActivityErrorType type;
  final String message;
  final Object? originalError;
  final StackTrace? stackTrace;
  final DateTime timestamp;

  DeviceActivityError({
    required this.type,
    required this.message,
    this.originalError,
    this.stackTrace,
  }) : timestamp = DateTime.now();

  @override
  String toString() {
    final b = StringBuffer();
    b.writeln('DeviceActivityError(');
    b.writeln('  type: $type,');
    b.writeln('  message: $message,');
    b.writeln('  timestamp: $timestamp,');
    if (originalError != null) b.writeln('  originalError: $originalError,');
    if (stackTrace != null) b.writeln('  stackTrace: $stackTrace');
    b.write(')');
    return b.toString();
  }
}
