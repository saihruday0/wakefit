import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:wakefit/data/models/alarm_model.dart';
import '../providers/alarm_provider.dart';

const List<String> _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Create (alarm == null) or edit an alarm. Pops `true` when saved.
class AlarmEditScreen extends StatefulWidget {
  const AlarmEditScreen({super.key, this.alarm});

  final AlarmModel? alarm;

  @override
  State<AlarmEditScreen> createState() => _AlarmEditScreenState();
}

class _AlarmEditScreenState extends State<AlarmEditScreen> {
  late TimeOfDay _time;
  late Set<int> _days;
  late double _pushups;
  late double _timeoutSeconds;
  late double _snoozeMinutes;
  late bool _mute;
  String? _audioPath;
  String? _audioError;
  bool _saving = false;
  bool _pickingAudio = false;

  bool get _isEditing => widget.alarm != null;

  @override
  void initState() {
    super.initState();
    final a = widget.alarm;
    if (a != null) {
      _time = TimeOfDay.fromDateTime(a.time);
      _days = a.repeatDays.toSet();
      _pushups = a.targetPushups.clamp(1, 50).toDouble();
      _timeoutSeconds = _snapTimeout(a.challengeTimeoutSeconds);
      _snoozeMinutes = a.snoozeMinutes.clamp(1, AlarmModel.maxSnoozeMinutes).toDouble();
      _mute = a.muteDuringChallenge;
      _audioPath = a.customAudioPath;
    } else {
      _time = TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 1)));
      _days = <int>{};
      _pushups = 10;
      _timeoutSeconds = 60;
      _snoozeMinutes = 5;
      _mute = true;
      _audioPath = null;
    }
  }

  /// Slider uses 10 s steps between 30 and 180.
  static double _snapTimeout(int seconds) {
    final clamped = seconds.clamp(30, 180);
    return ((clamped / 10).round() * 10).clamp(30, 180).toDouble();
  }

  static String _formatSeconds(int s) {
    if (s < 60) return '$s s';
    final m = s ~/ 60;
    final r = s % 60;
    return r == 0 ? '$m min' : '$m min $r s';
  }

  static String _fileName(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null && mounted) setState(() => _time = picked);
  }

  Future<void> _pickAudio() async {
    if (_pickingAudio) return;
    setState(() => _pickingAudio = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );
      final path = result?.files.single.path;
      if (!mounted) return;
      if (result != null && path == null) {
        setState(() => _audioError = 'That file could not be accessed. Try another one.');
      } else if (path != null) {
        setState(() {
          _audioPath = path;
          _audioError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _audioError = 'Could not open file picker: $e');
    } finally {
      if (mounted) setState(() => _pickingAudio = false);
    }
  }

  void _clearAudio() => setState(() {
        _audioPath = null;
        _audioError = null;
      });

  Future<void> _save() async {
    if (_saving) return;

    // Validation
    final path = _audioPath;
    if (path != null && !File(path).existsSync()) {
      setState(() => _audioError =
          'The selected audio file is no longer available. Choose another or use the default sound.');
      return;
    }
    if (_pushups < 1 || _pushups > 50) return;

    setState(() => _saving = true);
    final provider = context.read<AlarmProvider>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final now = DateTime.now();
    final picked = DateTime(now.year, now.month, now.day, _time.hour, _time.minute);
    final days = _days.toList()..sort();
    final existing = widget.alarm;

    // Build the model with a provisional time, then store its real next trigger
    // so one-time alarms carry a meaningful date.
    var model = existing != null
        ? existing.copyWith(
            time: picked,
            isEnabled: true,
            targetPushups: _pushups.round(),
            challengeTimeoutSeconds: _timeoutSeconds.round(),
            snoozeMinutes: _snoozeMinutes.round(),
            snoozeCount: 0,
            customAudioPath: _audioPath,
            clearCustomAudio: _audioPath == null,
            muteDuringChallenge: _mute,
            repeatDays: days,
          )
        : AlarmModel(
            id: provider.allocateId(),
            time: picked,
            targetPushups: _pushups.round(),
            challengeTimeoutSeconds: _timeoutSeconds.round(),
            snoozeMinutes: _snoozeMinutes.round(),
            customAudioPath: _audioPath,
            muteDuringChallenge: _mute,
            repeatDays: days,
          );
    final next = model.nextTrigger();
    if (next != null) model = model.copyWith(time: next);

    final ok = _isEditing ? await provider.updateAlarm(model) : await provider.addAlarm(model);
    if (!mounted) return;
    if (ok) {
      navigator.pop(true);
    } else {
      setState(() => _saving = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(provider.error ?? 'Could not save alarm.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit alarm' : 'New alarm'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ---- Time ----
            Card(
              elevation: 0,
              color: scheme.secondaryContainer.withOpacity(0.55),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _pickTime,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    children: [
                      Text(
                        _time.format(context),
                        style: text.displayMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text('Tap to change time',
                          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ---- Repeat ----
            Text('Repeat', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              _days.isEmpty ? 'One-time alarm' : 'Repeats on selected days',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var i = 0; i < 7; i++)
                  FilterChip(
                    label: Text(_dayLabels[i]),
                    selected: _days.contains(i + 1),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _days.add(i + 1);
                      } else {
                        _days.remove(i + 1);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 24),

            // ---- Challenge ----
            Text('Challenge', style: text.titleMedium),
            const SizedBox(height: 8),
            _SliderTile(
              title: 'Push-up target',
              valueLabel: '${_pushups.round()} reps',
              value: _pushups,
              min: 1,
              max: 50,
              divisions: 49,
              onChanged: (v) => setState(() => _pushups = v),
            ),
            _SliderTile(
              title: 'Challenge time limit',
              valueLabel: _formatSeconds(_timeoutSeconds.round()),
              value: _timeoutSeconds,
              min: 30,
              max: 180,
              divisions: 15,
              onChanged: (v) => setState(() => _timeoutSeconds = v),
            ),
            _SliderTile(
              title: 'Snooze duration',
              valueLabel: '${_snoozeMinutes.round()} min',
              value: _snoozeMinutes,
              min: 1,
              max: AlarmModel.maxSnoozeMinutes.toDouble(),
              divisions: AlarmModel.maxSnoozeMinutes - 1,
              onChanged: (v) => setState(() => _snoozeMinutes = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mute alarm sound during push-up challenge'),
              value: _mute,
              onChanged: (v) => setState(() => _mute = v),
            ),
            const SizedBox(height: 16),

            // ---- Audio ----
            Text('Alarm sound', style: text.titleMedium),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _audioError == null ? scheme.outlineVariant : scheme.error,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(
                    _audioPath == null ? Icons.notifications_active_outlined : Icons.music_note,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _audioPath == null ? 'Default alarm sound' : _fileName(_audioPath!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_audioPath != null)
                    IconButton(
                      tooltip: 'Use default sound',
                      icon: const Icon(Icons.close),
                      onPressed: _clearAudio,
                    ),
                  FilledButton.tonal(
                    onPressed: _pickingAudio ? null : _pickAudio,
                    child: Text(_audioPath == null ? 'Choose file' : 'Change'),
                  ),
                ],
              ),
            ),
            if (_audioError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  _audioError!,
                  style: text.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            const SizedBox(height: 32),

            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(_isEditing ? 'Save changes' : 'Create alarm'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: text.bodyLarge)),
              Text(valueLabel,
                  style: text.titleSmall?.copyWith(color: scheme.primary)),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}