import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:wakefit/presentation/screens/alarm_edit_screen.dart';
import 'package:wakefit/data/models/alarm_model.dart';
import 'package:wakefit/presentation/providers/alarm_provider.dart';

/// Alarm list. Tapping "Add alarm" or an existing alarm opens [AlarmEditScreen].
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _repeatLabel(AlarmModel a) {
    if (a.repeatDays.isEmpty) return 'Once';
    if (a.repeatDays.length == 7) return 'Every day';
    return a.repeatDays.map((d) => _dayNames[d - 1]).join(' ');
  }

  static bool _hasCustomRingtone(AlarmModel a) {
    final path = a.customAudioPath;
    return path != null && path.isNotEmpty;
  }

  static String _subtitle(AlarmModel a) {
    final parts = <String>[
      '${a.targetPushups} push-ups',
      '${a.challengeTimeoutSeconds}s limit',
      if (_hasCustomRingtone(a)) 'Custom ringtone',
      _repeatLabel(a),
    ];
    return parts.join(' • ');
  }

  void _report(BuildContext context, bool ok) {
    if (ok) return;
    final msg = context.read<AlarmProvider>().error ?? 'Something went wrong.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addAlarm(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AlarmEditScreen()),
    );
  }

  Future<void> _editAlarm(BuildContext context, AlarmModel alarm) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AlarmEditScreen(alarm: alarm)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AlarmProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('WakeFit'),
        actions: [
          IconButton(
            tooltip: 'Calibrate / test push-ups',
            icon: const Icon(Icons.fitness_center),
            onPressed: () => Navigator.of(context).pushNamed('/test_pushup'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addAlarm(context),
        icon: const Icon(Icons.add_alarm),
        label: const Text('Add alarm'),
      ),
      body: !provider.hasLoaded
          ? const Center(child: CircularProgressIndicator())
          : provider.alarms.isEmpty
              ? const Center(child: Text('No alarms yet'))
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: provider.alarms.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final a = provider.alarms[i];
                    return ListTile(
                      onTap: () => _editAlarm(context, a),
                      title: Text(
                        DateFormat.jm().format(a.time),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      subtitle: Text(
                        _subtitle(a),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: a.isEnabled,
                            onChanged: (v) async {
                              final ok = await provider.toggleAlarm(a.id, v);
                              if (context.mounted) _report(context, ok);
                            },
                          ),
                          IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final ok = await provider.deleteAlarm(a.id);
                              if (context.mounted) _report(context, ok);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}