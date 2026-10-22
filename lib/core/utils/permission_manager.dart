import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

enum PermissionOutcome { granted, denied, permanentlyDenied, restricted }

/// Thin, exception-safe wrapper around permission_handler.
/// Every method returns an outcome; none throw.
class PermissionManager {
  PermissionManager._();

  static PermissionOutcome _map(PermissionStatus s) {
    switch (s) {
      case PermissionStatus.granted:
      case PermissionStatus.limited:
      case PermissionStatus.provisional:
        return PermissionOutcome.granted;
      case PermissionStatus.permanentlyDenied:
        return PermissionOutcome.permanentlyDenied;
      case PermissionStatus.restricted:
        return PermissionOutcome.restricted;
      case PermissionStatus.denied:
        return PermissionOutcome.denied;
    }
  }

  static Future<PermissionOutcome> _status(Permission p) async {
    try {
      return _map(await p.status);
    } catch (e) {
      debugPrint('Permission status check failed ($p): $e');
      return PermissionOutcome.denied;
    }
  }

  static Future<PermissionOutcome> _request(Permission p) async {
    try {
      return _map(await p.request());
    } catch (e) {
      debugPrint('Permission request failed ($p): $e');
      return PermissionOutcome.denied;
    }
  }

  // Camera
  static Future<PermissionOutcome> checkCamera() => _status(Permission.camera);
  static Future<PermissionOutcome> requestCamera() async {
    final current = await checkCamera();
    if (current == PermissionOutcome.granted) return current;
    return _request(Permission.camera);
  }

  // Exact alarms (auto-granted below Android 12; USE_EXACT_ALARM covers 13+;
  // on 12/12L this opens the system "Alarms & reminders" screen)
  static Future<PermissionOutcome> checkExactAlarm() =>
      _status(Permission.scheduleExactAlarm);
  static Future<PermissionOutcome> requestExactAlarm() async {
    final current = await checkExactAlarm();
    if (current == PermissionOutcome.granted) return current;
    await _request(Permission.scheduleExactAlarm);
    return checkExactAlarm(); // re-check after returning from settings
  }

  // Notifications (Android 13+; granted automatically below)
  static Future<PermissionOutcome> checkNotification() =>
      _status(Permission.notification);
  static Future<PermissionOutcome> requestNotification() async {
    final current = await checkNotification();
    if (current == PermissionOutcome.granted) return current;
    return _request(Permission.notification);
  }

  // Audio files (READ_MEDIA_AUDIO on 13+, READ_EXTERNAL_STORAGE below)
  static Future<PermissionOutcome> checkAudioAccess() async {
    if (await _status(Permission.audio) == PermissionOutcome.granted) {
      return PermissionOutcome.granted;
    }
    return _status(Permission.storage);
  }

  static Future<PermissionOutcome> requestAudioAccess() async {
    if (await checkAudioAccess() == PermissionOutcome.granted) {
      return PermissionOutcome.granted;
    }
    final audio = await _request(Permission.audio);
    if (audio == PermissionOutcome.granted) return audio;
    return _request(Permission.storage);
  }

  /// Everything the alarm needs to fire reliably. Camera is requested
  /// separately (before the first challenge) via [requestCamera].
  static Future<Map<String, PermissionOutcome>> requestAlarmEssentials() async {
    return {
      'notification': await requestNotification(),
      'exactAlarm': await requestExactAlarm(),
    };
  }

  static Future<Map<String, PermissionOutcome>> checkAll() async => {
        'camera': await checkCamera(),
        'exactAlarm': await checkExactAlarm(),
        'notification': await checkNotification(),
        'audio': await checkAudioAccess(),
      };

  static Future<bool> openSettings() async {
    try {
      return await openAppSettings();
    } catch (e) {
      debugPrint('openAppSettings failed: $e');
      return false;
    }
  }
}