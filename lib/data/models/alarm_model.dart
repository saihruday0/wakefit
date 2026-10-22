import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Alarm record persisted in Hive.
///
/// Annotations are kept for documentation / future codegen; the adapter below is
/// hand-written so NO build_runner or hive_generator is needed.
@HiveType(typeId: AlarmModel.hiveTypeId)
class AlarmModel {
  static const int hiveTypeId = 0;
  static const String boxName = 'alarms';
  static const int maxSnoozeCount = 1;
  static const int maxSnoozeMinutes = 5;

  /// Native alarm ids must stay below this (snooze ids live at id + 1e9).
  static const int maxId = 999999999;

  @HiveField(0)
  final int id;
  @HiveField(1)
  final DateTime time;
  @HiveField(2)
  final bool isEnabled;
  @HiveField(3)
  final int targetPushups;
  @HiveField(4)
  final int challengeTimeoutSeconds;
  @HiveField(5)
  final int snoozeMinutes;
  @HiveField(6)
  final int snoozeCount;
  @HiveField(7)
  final String? customAudioPath;
  @HiveField(8)
  final bool muteDuringChallenge;

  /// 1 = Monday ... 7 = Sunday (matches DateTime.weekday). Empty = one-time.
  @HiveField(9)
  final List<int> repeatDays;

  AlarmModel({
    required this.id,
    required this.time,
    this.isEnabled = true,
    this.targetPushups = 10,
    this.challengeTimeoutSeconds = 60,
    int snoozeMinutes = 5,
    int snoozeCount = 0,
    this.customAudioPath,
    this.muteDuringChallenge = true,
    List<int> repeatDays = const [],
  })  : snoozeMinutes = snoozeMinutes.clamp(1, maxSnoozeMinutes).toInt(),
        snoozeCount = snoozeCount.clamp(0, maxSnoozeCount).toInt(),
        repeatDays = List.unmodifiable(
          (repeatDays.where((d) => d >= 1 && d <= 7).toSet().toList())..sort(),
        );

  /// Unique id in [1, maxId] that is not already used in [box].
  static int newId(Box<AlarmModel> box) {
    final rng = Random();
    for (var i = 0; i < 50; i++) {
      final candidate = 1 + rng.nextInt(maxId);
      if (!box.containsKey(candidate)) return candidate;
    }
    throw StateError('Could not allocate a unique alarm id');
  }

  AlarmModel copyWith({
    DateTime? time,
    bool? isEnabled,
    int? targetPushups,
    int? challengeTimeoutSeconds,
    int? snoozeMinutes,
    int? snoozeCount,
    String? customAudioPath,
    bool clearCustomAudio = false,
    bool? muteDuringChallenge,
    List<int>? repeatDays,
  }) {
    return AlarmModel(
      id: id,
      time: time ?? this.time,
      isEnabled: isEnabled ?? this.isEnabled,
      targetPushups: targetPushups ?? this.targetPushups,
      challengeTimeoutSeconds:
          challengeTimeoutSeconds ?? this.challengeTimeoutSeconds,
      snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
      snoozeCount: snoozeCount ?? this.snoozeCount,
      customAudioPath:
          clearCustomAudio ? null : (customAudioPath ?? this.customAudioPath),
      muteDuringChallenge: muteDuringChallenge ?? this.muteDuringChallenge,
      repeatDays: repeatDays ?? this.repeatDays,
    );
  }

  bool get isRecurring => repeatDays.isNotEmpty;

  /// Next time this alarm should fire after [now].
  ///
  /// One-time: uses the stored date if still in the future; otherwise, when
  /// [rollOver] is true, the next occurrence of its hour:minute (today/tomorrow);
  /// when false returns null (used by reboot recovery so missed one-time
  /// alarms don't ring a day late).
  /// Recurring: next matching weekday strictly after [now].
  DateTime? nextTrigger({DateTime? now, bool rollOver = true}) {
    final n = now ?? DateTime.now();
    DateTime on(DateTime base, int addDays) =>
        DateTime(base.year, base.month, base.day + addDays, time.hour, time.minute);

    if (repeatDays.isEmpty) {
      final exact = on(time, 0);
      if (exact.isAfter(n)) return exact;
      if (!rollOver) return null;
      final today = on(n, 0);
      return today.isAfter(n) ? today : on(n, 1);
    }
    for (var i = 0; i <= 7; i++) {
      final c = on(n, i);
      if (repeatDays.contains(c.weekday) && c.isAfter(n)) return c;
    }
    return null;
  }

  // ---- Hive setup -------------------------------------------------------

  static void registerAdapters() {
    if (!Hive.isAdapterRegistered(hiveTypeId)) {
      Hive.registerAdapter(AlarmModelAdapter());
    }
  }

  /// Call once at startup (before runApp / before AlarmSchedulerService.init).
  static Future<Box<AlarmModel>> openBox() async {
    await Hive.initFlutter();
    registerAdapters();
    try {
      return await Hive.openBox<AlarmModel>(boxName);
    } catch (e, st) {
      // Corrupt box: recreate rather than leave the app unusable.
      debugPrint('Alarm box failed to open ($e). Recreating.\n$st');
      await Hive.deleteBoxFromDisk(boxName);
      return Hive.openBox<AlarmModel>(boxName);
    }
  }

  @override
  String toString() =>
      'AlarmModel(id: $id, time: $time, enabled: $isEnabled, repeat: $repeatDays, '
      'snoozeCount: $snoozeCount)';
}

/// Hand-written adapter. Field-number based, so adding fields later is
/// backward-compatible; missing fields fall back to defaults.
class AlarmModelAdapter extends TypeAdapter<AlarmModel> {
  @override
  int get typeId => AlarmModel.hiveTypeId;

  @override
  AlarmModel read(BinaryReader reader) {
    final count = reader.readByte();
    final f = <int, dynamic>{
      for (var i = 0; i < count; i++) reader.readByte(): reader.read(),
    };
    return AlarmModel(
      id: f[0] as int,
      time: f[1] as DateTime,
      isEnabled: f[2] as bool? ?? true,
      targetPushups: f[3] as int? ?? 10,
      challengeTimeoutSeconds: f[4] as int? ?? 60,
      snoozeMinutes: f[5] as int? ?? 5,
      snoozeCount: f[6] as int? ?? 0,
      customAudioPath: f[7] as String?,
      muteDuringChallenge: f[8] as bool? ?? true,
      repeatDays: (f[9] as List?)?.cast<int>() ?? const [],
    );
  }

  @override
  void write(BinaryWriter writer, AlarmModel obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.time)
      ..writeByte(2)
      ..write(obj.isEnabled)
      ..writeByte(3)
      ..write(obj.targetPushups)
      ..writeByte(4)
      ..write(obj.challengeTimeoutSeconds)
      ..writeByte(5)
      ..write(obj.snoozeMinutes)
      ..writeByte(6)
      ..write(obj.snoozeCount)
      ..writeByte(7)
      ..write(obj.customAudioPath)
      ..writeByte(8)
      ..write(obj.muteDuringChallenge)
      ..writeByte(9)
      ..write(obj.repeatDays);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlarmModelAdapter && typeId == other.typeId;
}