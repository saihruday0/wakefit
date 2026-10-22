import 'dart:async';
import 'dart:math' as math;

import 'package:alarm/alarm.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/utils/permission_manager.dart';
import '../data/models/alarm_model.dart';
import 'audio_player_service.dart';

enum ScheduleStatus {
  scheduled,
  permissionDenied,
  invalidAlarm,
  noUpcomingTime,
  audioMissing,
  failed,
}

class ScheduleResult {
  const ScheduleResult(
    this.status, {
    this.triggerAt,
    this.usedFallbackAudio = false,
    this.error,
  });
  final ScheduleStatus status;
  final DateTime? triggerAt;
  final bool usedFallbackAudio; // custom sound missing -> default used
  final Object? error;
  bool get ok => status == ScheduleStatus.scheduled;
}

enum SnoozeStatus { snoozed, limitReached, alarmNotFound, busy, failed }

class SnoozeResult {
  const SnoozeResult(this.status, {this.until});
  final SnoozeStatus status;
  final DateTime? until;
  bool get ok => status == SnoozeStatus.snoozed;
}

/// Emitted when an alarm starts ringing.
class RingEvent {
  const RingEvent({
    required this.alarmId,
    required this.nativeId,
    required this.isSnoozeRing,
    required this.alarm,
  });
  final int alarmId; // Hive / model id
  final int nativeId; // id known to the `alarm` package (differs for snooze)
  final bool isSnoozeRing;
  final AlarmModel? alarm;

  /// UI should only show Snooze when this is true.
  bool get canSnooze =>
      alarm != null && alarm!.snoozeCount < AlarmModel.maxSnoozeCount;
}

class AlarmSchedulerService {
  AlarmSchedulerService._();
  static final AlarmSchedulerService instance = AlarmSchedulerService._();

  /// Snooze alarms use id + this offset so they never clobber the base alarm.
  static const int snoozeIdOffset = 1000000000;
  static int snoozeIdFor(int id) => id + snoozeIdOffset;
  static bool isSnoozeId(int id) => id >= snoozeIdOffset;
  static int baseIdOf(int id) => isSnoozeId(id) ? id - snoozeIdOffset : id;

  Box<AlarmModel>? _box;
  StreamSubscription? _ringSub;
  final StreamController<RingEvent> _ringCtrl =
      StreamController<RingEvent>.broadcast();
  final Set<int> _snoozing = <int>{};
  bool _ready = false;

  // Direct hook for the UI layer (main.dart sets it). Called synchronously on
  // every ring so the challenge can be pushed through the global navigatorKey
  // without depending on a stream subscriber being attached at that moment.
  void Function(RingEvent event)? _ringHandler;

  // A ring that arrived before any handler existed (cold start race). It is
  // delivered as soon as a handler is registered, if still ringing.
  RingEvent? _pendingRing;

  set ringHandler(void Function(RingEvent event)? handler) {
    _ringHandler = handler;
    final pending = _pendingRing;
    if (handler != null && pending != null) {
      _pendingRing = null;
      unawaited(_deliverIfStillRinging(pending));
    }
  }

  Future<void> _deliverIfStillRinging(RingEvent ring) async {
    try {
      if (!await Alarm.isRinging(ring.nativeId)) return; // stale
    } catch (_) {}
    _dispatch(ring);
  }

  void _dispatch(RingEvent ring) {
    final h = _ringHandler;
    if (h == null) {
      _pendingRing = ring;
      return;
    }
    try {
      h(ring);
    } catch (e, st) {
      debugPrint('ringHandler failed: $e\n$st');
    }
  }

  Stream<RingEvent> get ringEvents => _ringCtrl.stream;

  Box<AlarmModel> get _b {
    final b = _box;
    if (b == null || !b.isOpen) {
      throw StateError('AlarmSchedulerService.init() has not completed.');
    }
    return b;
  }

  // ---------------------------------------------------------------- init

  /// Call after AlarmModel.openBox(). Safe to call more than once.
  Future<void> init({Box<AlarmModel>? box}) async {
    if (_ready) return;
    await Alarm.init();
    _box = box ??
        (Hive.isBoxOpen(AlarmModel.boxName)
            ? Hive.box<AlarmModel>(AlarmModel.boxName)
            : await AlarmModel.openBox());
    _ringSub = Alarm.ringing.listen(
      (event) => _onRinging(event),
      onError: (Object e) => debugPrint('Alarm.ringing error: $e'),
    );
    _ready = true;
    await recoverAlarms();
  }

  Future<void> dispose() async {
    await _ringSub?.cancel();
    _ringSub = null;
    _ready = false;
  }

  /// `Alarm.ringing` may deliver an `AlarmSet` (has `.alarms`) or a single
  /// `AlarmSettings`, depending on the alarm package version. Accept both.
  /// (Reading `.id` on an AlarmSet used to throw NoSuchMethodError, which the
  /// catch below swallowed, so the ring was silently dropped.)
  static Iterable<dynamic> _alarmsIn(dynamic event) {
    try {
      final list = event.alarms;
      if (list is Iterable) return list;
    } catch (_) {}
    return [event];
  }

  Future<void> _onRinging(dynamic event) async {
    for (final s in _alarmsIn(event)) {
      try {
        final int nativeId = s.id as int;
        final base = baseIdOf(nativeId);
        final snoozeRing = isSnoozeId(nativeId);
        var alarm = _b.get(base);
        // A fresh (non-snooze) ring starts a new snooze budget.
        if (alarm != null && !snoozeRing && alarm.snoozeCount != 0) {
          alarm = alarm.copyWith(snoozeCount: 0);
          await _b.put(base, alarm);
        }
        final ring = RingEvent(
          alarmId: base,
          nativeId: nativeId,
          isSnoozeRing: snoozeRing,
          alarm: alarm,
        );
        if (!_ringCtrl.isClosed) _ringCtrl.add(ring);
        _dispatch(ring);
      } catch (e, st) {
        debugPrint('Ring handling failed for $s: $e\n$st');
      }
    }
  }

  /// For cold start via the full-screen intent: which alarm is ringing now?
  Future<RingEvent?> currentlyRinging() async {
    try {
      for (final s in await Alarm.getAlarms()) {
        if (await Alarm.isRinging(s.id)) {
          final base = baseIdOf(s.id);
          return RingEvent(
            alarmId: base,
            nativeId: s.id,
            isSnoozeRing: isSnoozeId(s.id),
            alarm: _b.get(base),
          );
        }
      }
    } catch (e) {
      debugPrint('currentlyRinging failed: $e');
    }
    return null;
  }

  /// Polls [currentlyRinging] for a short while. On a cold start through the
  /// full-screen intent the native ring state can lag the Dart isolate by a
  /// few hundred ms, so a single check right after init can miss it.
  Future<RingEvent?> waitForRinging({
    int attempts = 8,
    Duration interval = const Duration(milliseconds: 400),
  }) async {
    for (var i = 0; i < attempts; i++) {
      final r = await currentlyRinging();
      if (r != null) return r;
      if (i < attempts - 1) await Future<void>.delayed(interval);
    }
    return null;
  }

  // ------------------------------------------------------------ scheduling

  /// Schedules (or reschedules) a one-time or recurring alarm and persists it.
  /// Recurring alarms arm only the next occurrence; the following one is armed
  /// when this one rings/finishes (see [_afterFire]) and in [recoverAlarms].
  Future<ScheduleResult> schedule(AlarmModel alarm) async {
    if (alarm.id < 1 || alarm.id > AlarmModel.maxId) {
      return const ScheduleResult(ScheduleStatus.invalidAlarm);
    }
    final trigger = alarm.nextTrigger();
    if (trigger == null) {
      return const ScheduleResult(ScheduleStatus.noUpcomingTime);
    }
    if (await PermissionManager.checkExactAlarm() !=
        PermissionOutcome.granted) {
      return const ScheduleResult(ScheduleStatus.permissionDenied);
    }

    final fresh = alarm.copyWith(
      isEnabled: true,
      snoozeCount: 0,
      // One-time alarms store the concrete date they will fire on.
      time: alarm.isRecurring ? alarm.time : trigger,
    );

    await _stopNative(snoozeIdFor(fresh.id)); // drop any stale snooze
    final result = await _arm(fresh.id, trigger, fresh);
    if (result.ok) await _b.put(fresh.id, fresh);
    return result;
  }

  /// Disables the alarm and cancels everything pending for it.
  Future<void> cancel(int id) async {
    await _stopNative(id);
    await _stopNative(snoozeIdFor(id));
    final a = _b.get(id);
    if (a != null) {
      await _b.put(id, a.copyWith(isEnabled: false, snoozeCount: 0));
    }
  }

  Future<void> delete(int id) async {
    await _stopNative(id);
    await _stopNative(snoozeIdFor(id));
    await _b.delete(id);
  }

  Future<ScheduleResult> _arm(
    int nativeId,
    DateTime when,
    AlarmModel alarm,
  ) async {
    try {
      final audio = await AudioPlayerService.resolveAlarmAudio(
        alarm.customAudioPath,
      );
      if (audio == null) return const ScheduleResult(ScheduleStatus.audioMissing);

      final ok = await Alarm.set(
        alarmSettings: AlarmSettings(
          id: nativeId,
          dateTime: when,
          assetAudioPath: audio.path,
          loopAudio: true,
          vibrate: true,
          warningNotificationOnKill: true,
          androidFullScreenIntent: true,
          volumeSettings: VolumeSettings.fixed(
            volume: 1.0,
            volumeEnforced: true,
          ),
          // androidFullScreenIntent (above) makes Android launch this app over
          // the lock screen; on Android 14+ the notification below is what
          // carries that intent, so it must have a title and body.
          // No stop button: the alarm may only end via the in-app challenge.
          notificationSettings: NotificationSettings(
            title: 'WakeFit',
            body: isSnoozeId(nativeId)
                ? 'Snooze over. Time to get up.'
                : 'Wake up! Push-ups are waiting.',
            stopButton: null,
          ),
        ),
      );
      return ok
          ? ScheduleResult(
              ScheduleStatus.scheduled,
              triggerAt: when,
              usedFallbackAudio: audio.fallback,
            )
          : const ScheduleResult(ScheduleStatus.failed);
    } catch (e, st) {
      debugPrint('Arming alarm $nativeId failed: $e\n$st');
      return ScheduleResult(ScheduleStatus.failed, error: e);
    }
  }

  Future<void> _stopNative(int nativeId) async {
    try {
      await Alarm.stop(nativeId);
    } catch (e) {
      debugPrint('Alarm.stop($nativeId) failed: $e');
    }
  }

  // ---------------------------------------------------------------- snooze

  /// Strictly one snooze per ring session. The count is persisted BEFORE the
  /// snooze is armed, so double taps or a crash cannot grant a second snooze.
  /// Length is clamped to 1..5 minutes.
  Future<SnoozeResult> snooze(int alarmId) async {
    final base = baseIdOf(alarmId);
    if (!_snoozing.add(base)) return const SnoozeResult(SnoozeStatus.busy);
    try {
      final alarm = _b.get(base);
      if (alarm == null) return const SnoozeResult(SnoozeStatus.alarmNotFound);
      if (alarm.snoozeCount >= AlarmModel.maxSnoozeCount) {
        return const SnoozeResult(SnoozeStatus.limitReached);
      }

      final minutes = math.min(
        math.max(alarm.snoozeMinutes, 1),
        AlarmModel.maxSnoozeMinutes,
      );
      final until = DateTime.now().add(Duration(minutes: minutes));

      await _b.put(base, alarm.copyWith(snoozeCount: alarm.snoozeCount + 1));

      // Arm the snooze first; only silence the current ring if that worked.
      final armed = await _arm(snoozeIdFor(base), until, alarm);
      if (!armed.ok) {
        await _b.put(base, alarm); // roll back the count
        return const SnoozeResult(SnoozeStatus.failed);
      }
      await _stopNative(alarmId);
      await _afterFire(base);
      return SnoozeResult(SnoozeStatus.snoozed, until: until);
    } catch (e, st) {
      debugPrint('Snooze failed: $e\n$st');
      return const SnoozeResult(SnoozeStatus.failed);
    } finally {
      _snoozing.remove(base);
    }
  }

  // ------------------------------------------------------ ring lifecycle

  /// Stops the native (`alarm` package) sound only, e.g. when handing audio to
  /// AudioPlayerService for mute-during-challenge. The alarm is NOT dismissed;
  /// the next occurrence is armed so a crash mid-challenge can't lose it.
  Future<void> silenceRingingAlarm(int nativeId) async {
    await _stopNative(nativeId);
    await _afterFire(baseIdOf(nativeId));
  }

  /// Call when the alarm is truly finished: challenge passed, penalty ring
  /// ended, or the "Dismiss (Camera Error)" fallback was used.
  Future<void> completeAlarm(int nativeId) async {
    final base = baseIdOf(nativeId);
    await _stopNative(nativeId);
    await _stopNative(snoozeIdFor(base));
    await _afterFire(base);
    final a = _b.get(base);
    if (a != null && a.snoozeCount != 0) {
      await _b.put(base, a.copyWith(snoozeCount: 0));
    }
  }

  /// Post-fire bookkeeping: one-time alarms switch off, recurring alarms arm
  /// their next occurrence (skipped if one is already pending).
  Future<void> _afterFire(int baseId) async {
    final a = _b.get(baseId);
    if (a == null) return;
    if (!a.isRecurring) {
      if (a.isEnabled) await _b.put(baseId, a.copyWith(isEnabled: false));
      return;
    }
    if (!a.isEnabled) return;
    try {
      final existing = await Alarm.getAlarm(baseId);
      if (existing != null && existing.dateTime.isAfter(DateTime.now())) return;
    } catch (_) {}
    final next = a.nextTrigger();
    if (next != null) await _arm(baseId, next, a);
  }

  // -------------------------------------------------------------- recovery

  /// Reconciles Hive with the native alarm store. Run on every app start
  /// (init() does this). Covers reboot, app update, cleared native state.
  /// - enabled alarm with no pending native alarm -> re-armed
  /// - missed one-time alarm -> disabled (never rings a day late)
  /// - native alarm with no Hive record -> removed
  Future<void> recoverAlarms() async {
    final now = DateTime.now();
    try {
      final pending = {for (final s in await Alarm.getAlarms()) s.id: s};

      for (final alarm in _b.values.toList()) {
        if (!alarm.isEnabled) continue;
        final existing = pending[alarm.id];
        if (existing != null && existing.dateTime.isAfter(now)) continue;
        if (existing != null && await Alarm.isRinging(alarm.id)) continue;

        final next = alarm.nextTrigger(now: now, rollOver: false);
        if (next == null) {
          if (!alarm.isRecurring) {
            await _b.put(alarm.id, alarm.copyWith(isEnabled: false));
          }
          continue;
        }
        final r = await _arm(alarm.id, next, alarm);
        if (!r.ok) {
          debugPrint('Recovery could not re-arm ${alarm.id}: ${r.status}');
        }
      }

      for (final s in pending.values) {
        if (!_b.containsKey(baseIdOf(s.id))) await _stopNative(s.id);
      }
    } catch (e, st) {
      debugPrint('recoverAlarms failed: $e\n$st');
    }
  }
}