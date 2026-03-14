import 'dart:async';
import 'package:flutter/material.dart';
import 'package:device_activity_monitor/device_activity_monitor.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Device Activity Monitor Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const MonitorPage(),
    );
  }
}

class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  late final DeviceActivityMonitor _monitor;

  // ── Subscriptions ──────────────────────────────────────────────────
  StreamSubscription<void>? _activeSub;
  StreamSubscription<void>? _inactiveSub;
  StreamSubscription<DeviceActivityError>? _errorSub;

  // ── UI state ───────────────────────────────────────────────────────
  bool _userActive = true;
  bool _monitorAudio = true;
  bool _monitorHID = true;
  bool _monitorController = true;

  final List<String> _log = [];

  // ── Idle threshold ─────────────────────────────────────────────────
  // Using 10 seconds so you can see inactivity fire quickly in the demo.
  // In your screen-time app this will be minutes.
  static const _idleThreshold = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();

    _monitor = DeviceActivityMonitor(
      monitorAudio: _monitorAudio,
      monitorHID: _monitorHID,
      monitorControllers: _monitorController,
      idleThreshold: _idleThreshold,
      audioThreshold: 0.001,
      debug: true,
    );

    _activeSub = _monitor.addUserActiveListener(() {
      setState(() {
        _userActive = true;
        _addLog('▶ User active');
      });
    });

    _inactiveSub = _monitor.addUserInactivityListener(() {
      setState(() {
        _userActive = false;
        _addLog('⏸ User inactive');
      });
    });

    _errorSub = _monitor.addErrorListener((error) {
      _addLog('⚠ ${error.type.name}: ${error.message}');
    });
  }

  @override
  void dispose() {
    _activeSub?.cancel();
    _inactiveSub?.cancel();
    _errorSub?.cancel();
    _monitor.dispose();
    super.dispose();
  }

  void _addLog(String entry) {
    final time = TimeOfDay.now().format(context);
    setState(() {
      _log.insert(0, '[$time] $entry');
      if (_log.length > 50) _log.removeLast();
    });
  }

  // ── Toggle handlers ────────────────────────────────────────────────

  Future<void> _toggleAudio(bool value) async {
    setState(() => _monitorAudio = value);
    await _monitor.setAudioMonitoring(value);
    _addLog('Audio monitoring: ${value ? "ON" : "OFF"}');
  }

  Future<void> _toggleHID(bool value) async {
    setState(() => _monitorHID = value);
    await _monitor.setHIDMonitoring(value);
    _addLog('HID monitoring: ${value ? "ON" : "OFF"}');
  }

  Future<void> _toggleController(bool value) async {
    setState(() => _monitorController = value);
    await _monitor.setControllerMonitoring(value);
    _addLog('Controller monitoring: ${value ? "ON" : "OFF"}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Activity Monitor'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // ── Status banner ────────────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 20),
            color: _userActive ? Colors.green.shade600 : Colors.grey.shade600,
            child: Column(
              children: [
                Icon(
                  _userActive ? Icons.sensors : Icons.sensors_off,
                  color: Colors.white,
                  size: 36,
                ),
                const SizedBox(height: 6),
                Text(
                  _userActive ? 'User Active' : 'User Inactive',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Idle threshold: ${_idleThreshold.inSeconds}s',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),

          // ── Monitor toggles ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Card(
              child: Column(
                children: [
                  _MonitorTile(
                    icon: Icons.volume_up,
                    label: 'Audio Output',
                    subtitle: 'Detects system audio playback',
                    value: _monitorAudio,
                    onChanged: _toggleAudio,
                  ),
                  const Divider(height: 1),
                  _MonitorTile(
                    icon: Icons.sports_esports,
                    label: 'HID Devices',
                    subtitle: 'Gamepads, tablets, wheels, etc.',
                    value: _monitorHID,
                    onChanged: _toggleHID,
                  ),
                  const Divider(height: 1),
                  _MonitorTile(
                    icon: Icons.gamepad,
                    label: 'Game Controllers',
                    subtitle: 'XInput / GameController framework',
                    value: _monitorController,
                    onChanged: _toggleController,
                  ),
                ],
              ),
            ),
          ),

          // ── Event log ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  'Event log',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _log.clear()),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _log.isEmpty
                ? const Center(
                    child: Text(
                      'No events yet',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _log.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        _log[i],
                        style: TextStyle(
                          fontSize: 13,
                          color: _log[i].contains('inactive')
                              ? Colors.grey
                              : _log[i].contains('⚠')
                              ? Colors.red
                              : Colors.green.shade800,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Reusable toggle tile ────────────────────────────────────────────────

class _MonitorTile extends StatelessWidget {
  const _MonitorTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(
        icon,
        color: value ? Theme.of(context).colorScheme.primary : Colors.grey,
      ),
      title: Text(label),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}
