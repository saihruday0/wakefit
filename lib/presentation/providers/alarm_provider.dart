import 'package:flutter/foundation.dart';
import 'package:wakefit/core/utils/audio_file_manager.dart';
import 'package:wakefit/data/models/alarm_model.dart';
import 'package:wakefit/data/repositories/alarm_repository.dart';
import 'package:wakefit/services/alarm_scheduler_service.dart';

/// Thrown when the scheduler reports anything other than [ScheduleStatus.scheduled].
/// AlarmSchedulerService.schedule() returns a result instead of throwing, so the
/// provider converts failures into exceptions to trigger its rollback logic.
class AlarmScheduleException implements Exception {
  AlarmScheduleException(this.status, [this.cause]);

  final ScheduleStatus status;
  final Object? cause;

  String get message => switch (status) {
        ScheduleStatus.permissionDenied =>
          'Exact-alarm permission is required. Grant it in system settings and try again.',
        ScheduleStatus.invalidAlarm => 'This alarm has an invalid id.',
        ScheduleStatus.noUpcomingTime =>
          'No upcoming time found for this alarm. Check its repeat days.',
        ScheduleStatus.audioMissing => 'The alarm sound could not be loaded.',
        ScheduleStatus.failed =>
          'The system rejected the alarm${cause == null ? '' : ' ($cause)'}.',
        ScheduleStatus.scheduled => 'Scheduled.',
      };

  @override
  String toString() => message;
}

/// Single source of truth for the alarm list.
///
/// Persistence goes through [AlarmRepository]; OS scheduling goes through
/// [AlarmSchedulerService] (`schedule`, `cancel`, `delete`). Every mutating
/// method returns `true` on success. On failure the persisted state is rolled
/// back so the UI never shows an alarm that will not actually ring, and
/// [error] holds a message.
class AlarmProvider extends ChangeNotifier {
  AlarmProvider({
    AlarmRepository? repository,
    AlarmSchedulerService? scheduler,
  })  : _repo = repository ?? AlarmRepository(),
        _scheduler = scheduler ?? AlarmSchedulerService.instance;

  final AlarmRepository _repo;
  final AlarmSchedulerService _scheduler;

  List<AlarmModel> _alarms = const [];
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _error;

  List<AlarmModel> get alarms => _alarms;
  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  String? get error => _error;

  AlarmModel? alarmById(int id) {
    for (final a in _alarms) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Unique id for a new alarm (see [AlarmModel.newId]).
  int allocateId() => _repo.newId();

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  Future<void> loadAlarms() async {
    _isLoading = true;
    notifyListeners();
    try {
      _alarms = List.unmodifiable(_repo.getAllAlarms());
      _error = null;
    } catch (e) {
      _error = 'Could not load alarms: $e';
    } finally {
      _isLoading = false;
      _hasLoaded = true;
      notifyListeners();
    }
  }

  /// Re-reads the box without the loading flicker. Call after the challenge
  /// screen closes: AlarmSchedulerService mutates records behind the provider's
  /// back (one-time alarms switch off after firing, snooze counts reset, ...).
  void reload() {
    try {
      _alarms = List.unmodifiable(_repo.getAllAlarms());
    } catch (e) {
      debugPrint('AlarmProvider.reload failed: $e');
    }
    notifyListeners();
  }

  Future<bool> addAlarm(AlarmModel alarm) async {
    try {
      await _repo.saveAlarm(alarm);
      await _sync(alarm);
      _error = null;
      _refresh();
      return true;
    } catch (e) {
      await _safeDelete(alarm.id);
      await _discardAudio(alarm.customAudioPath);
      _fail('Could not save alarm: $e');
      return false;
    }
  }

  Future<bool> updateAlarm(AlarmModel alarm) async {
    final previous = _repo.getAlarm(alarm.id);
    final audioChanged = previous?.customAudioPath != alarm.customAudioPath;
    try {
      await _repo.saveAlarm(alarm);
      await _sync(alarm);
      _error = null;
      _refresh();
      // The old copied sound is garbage once the alarm points elsewhere.
      if (audioChanged) await _discardAudio(previous?.customAudioPath);
      return true;
    } catch (e) {
      await _restore(previous, alarm.id);
      if (audioChanged) await _discardAudio(alarm.customAudioPath);
      _fail('Could not update alarm: $e');
      return false;
    }
  }

  Future<bool> toggleAlarm(int id, bool enabled) async {
    final current = _repo.getAlarm(id);
    if (current == null) {
      _fail('Alarm no longer exists.');
      return false;
    }
    // Re-enabling resets the snooze budget for the next ring.
    final updated = current.copyWith(
      isEnabled: enabled,
      snoozeCount: enabled ? 0 : current.snoozeCount,
    );
    try {
      await _repo.saveAlarm(updated);
      await _sync(updated);
      _error = null;
      _refresh();
      return true;
    } catch (e) {
      await _restore(current, id);
      _fail(enabled
          ? 'Could not enable alarm: $e'
          : 'Could not disable alarm: $e');
      return false;
    }
  }

  Future<bool> deleteAlarm(int id) async {
    try {
      final existing = _repo.getAlarm(id);
      // Scheduler first: it stops the native alarm + snooze and removes the
      // record. If that throws, we keep everything so the user can retry.
      await _scheduler.delete(id);
      await _repo.deleteAlarm(id); // no-op if the scheduler already removed it
      _error = null;
      _refresh();
      await _discardAudio(existing?.customAudioPath);
      return true;
    } catch (e) {
      _fail('Could not delete alarm: $e');
      return false;
    }
  }

  // ---- internals --------------------------------------------------------

  /// Enabled -> (re)schedule (replaces any existing schedule for this id);
  /// disabled -> cancel. Throws [AlarmScheduleException] if scheduling fails.
  Future<void> _sync(AlarmModel alarm) async {
    if (!alarm.isEnabled) {
      await _scheduler.cancel(alarm.id);
      return;
    }
    final result = await _scheduler.schedule(alarm);
    if (!result.ok) {
      throw AlarmScheduleException(result.status, result.error);
    }
  }

  Future<void> _restore(AlarmModel? previous, int id) async {
    try {
      if (previous == null) {
        await _scheduler.delete(id);
        await _repo.deleteAlarm(id);
      } else {
        await _repo.saveAlarm(previous);
        await _sync(previous);
      }
    } catch (e) {
      debugPrint('AlarmProvider rollback failed for $id: $e');
    }
  }

  Future<void> _safeDelete(int id) async {
    try {
      await _scheduler.delete(id);
      await _repo.deleteAlarm(id);
    } catch (e) {
      debugPrint('AlarmProvider cleanup failed for $id: $e');
    }
  }

  Future<void> _discardAudio(String? path) async {
    try {
      await AudioFileManager.deleteImported(path);
    } catch (e) {
      debugPrint('AlarmProvider audio cleanup failed for $path: $e');
    }
  }

  void _refresh() {
    _alarms = List.unmodifiable(_repo.getAllAlarms());
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    try {
      _alarms = List.unmodifiable(_repo.getAllAlarms());
    } catch (_) {}
    notifyListeners();
  }
}