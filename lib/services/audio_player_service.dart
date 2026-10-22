import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

enum AudioPlayStatus { playingCustom, playingDefault, failed }

/// In-app looping alarm audio with mute / unmute / stop.
///
/// The `alarm` package plays the sound when the app is closed. Once the ring
/// screen is up, hand off to this service (see
/// AlarmSchedulerService.silenceRingingAlarm) for mute-during-challenge and the
/// 60 s penalty ring.
class AudioPlayerService {
  AudioPlayerService._();
  static final AudioPlayerService instance = AudioPlayerService._();

  /// Flutter asset path. Must be declared in pubspec.yaml.
  static const String defaultAsset = 'assets/alarm.mp3';

  AudioPlayer? _player;
  Timer? _autoStop;
  double _volume = 1.0;
  bool _muted = false;
  bool _playing = false;

  bool get isPlaying => _playing;
  bool get isMuted => _muted;

  /// Shared with the scheduler. Picks the custom file if it exists, else the
  /// bundled default. Returns null only if the default asset is also missing.
  static Future<({String path, bool fallback})?> resolveAlarmAudio(
  String? customPath,
) async {
  final hasCustom = customPath != null && customPath.isNotEmpty;
  if (hasCustom) {
    try {
      if (await File(customPath).exists()) {
        return (path: customPath, fallback: false);
      }
    } catch (e) {
      debugPrint('Custom audio check failed: $e');
    }
    debugPrint('Custom audio missing ($customPath); using default.');
  }

  // Directly return the default bundled asset path without checking rootBundle
  return (path: defaultAsset, fallback: hasCustom);
}

  Future<AudioPlayer> _ensurePlayer() async {
    var p = _player;
    if (p != null) return p;
    p = AudioPlayer();
    await p.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          usageType: AndroidUsageType.alarm,
          contentType: AndroidContentType.music,
          audioFocus: AndroidAudioFocus.gain,
          stayAwake: true,
        ),
      ),
    );
    await p.setReleaseMode(ReleaseMode.loop);
    _player = p;
    return p;
  }

  /// Starts looping playback. [autoStopAfter] is used for the penalty ring.
  /// Never throws; check the returned status.
  Future<AudioPlayStatus> play({
    String? customPath,
    double volume = 1.0,
    bool startMuted = false,
    Duration? autoStopAfter,
  }) async {
    await stop();
    _volume = volume.clamp(0.0, 1.0).toDouble();
    _muted = startMuted;

    final resolved = await resolveAlarmAudio(customPath);
    if (resolved == null) return AudioPlayStatus.failed;

    final status = await _tryPlay(resolved.path, resolved.fallback);
    if (status != AudioPlayStatus.failed) return _afterStart(status, autoStopAfter);

    // Custom file existed but could not be decoded: retry with the default.
    if (!resolved.fallback) {
      final retry = await resolveAlarmAudio(null);
      if (retry != null) {
        final s = await _tryPlay(retry.path, true);
        if (s != AudioPlayStatus.failed) return _afterStart(s, autoStopAfter);
      }
    }
    return AudioPlayStatus.failed;
  }

  AudioPlayStatus _afterStart(AudioPlayStatus s, Duration? autoStopAfter) {
    _playing = true;
    if (autoStopAfter != null) {
      _autoStop = Timer(autoStopAfter, () => unawaited(stop()));
    }
    return s;
  }

  Future<AudioPlayStatus> _tryPlay(String path, bool isDefault) async {
    try {
      final p = await _ensurePlayer();
      final isAsset = path == defaultAsset;
      final source = isAsset
          // AssetSource is relative to the assets/ folder.
          ? AssetSource(path.replaceFirst('assets/', ''))
          : DeviceFileSource(path);
      await p.setVolume(_muted ? 0.0 : _volume);
      await p.play(source);
      return isAsset || isDefault
          ? AudioPlayStatus.playingDefault
          : AudioPlayStatus.playingCustom;
    } catch (e, st) {
      debugPrint('Audio playback failed ($path): $e\n$st');
      return AudioPlayStatus.failed;
    }
  }

  /// Silences output but keeps the loop running so unmute is instant.
  Future<void> mute() async {
    _muted = true;
    try {
      await _player?.setVolume(0.0);
    } catch (e) {
      debugPrint('mute failed: $e');
    }
  }

  Future<void> unmute() async {
    _muted = false;
    try {
      await _player?.setVolume(_volume);
    } catch (e) {
      debugPrint('unmute failed: $e');
    }
  }

  Future<void> stop() async {
    _autoStop?.cancel();
    _autoStop = null;
    _playing = false;
    _muted = false;
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('stop failed: $e');
    }
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }
}