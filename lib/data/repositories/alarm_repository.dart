import 'package:hive_flutter/hive_flutter.dart';
import 'package:wakefit/data/models/alarm_model.dart';

/// Thin Hive-backed persistence layer for [AlarmModel].
///
/// OS scheduling is NOT done here; see AlarmSchedulerService. Both operate on
/// the same Hive box, so a read after either one always sees the latest record.
class AlarmRepository {
  AlarmRepository({Box<AlarmModel>? box}) : _boxOverride = box;

  final Box<AlarmModel>? _boxOverride;

  Box<AlarmModel> get _box {
    final b = _boxOverride ?? Hive.box<AlarmModel>(AlarmModel.boxName);
    if (!b.isOpen) {
      throw StateError('Alarm box is not open. Call AlarmModel.openBox() first.');
    }
    return b;
  }

  /// All alarms ordered by time of day, then id.
  List<AlarmModel> getAllAlarms() {
    final list = _box.values.toList();
    list.sort((a, b) {
      final byTime = (a.time.hour * 60 + a.time.minute)
          .compareTo(b.time.hour * 60 + b.time.minute);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return list;
  }

  AlarmModel? getAlarm(int id) => _box.get(id);

  Future<void> saveAlarm(AlarmModel alarm) => _box.put(alarm.id, alarm);

  Future<void> deleteAlarm(int id) => _box.delete(id);

  /// Unique id in [1, AlarmModel.maxId] not already used in the box.
  int newId() => AlarmModel.newId(_box);
}