import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/alarm_scheduler_service.dart';
import '../../services/audio_player_service.dart';
import '../../services/pose_detector_service.dart';

enum ChallengePhase { ringing, preparationCountdown, inProgress, success, failure }

enum FailureReason { timeout, bodyLost }

enum CameraStatus { initializing, ready, error }

/// Why the screen is allowed to close.
enum ChallengeOutcome { completed, snoozed, penaltyEnded, cameraDismissed }

/// Owns everything behind the ring / push-up challenge screen:
/// camera + pose service lifecycle, phase machine, timers, watchdog,
/// audio hand-off and the single allowed snooze.
///
/// Time accounting is wall-clock based (one 100 ms ticker, each delta clamped
/// to 1 s so a backgrounded app is never penalised for the stall).
class ChallengeProvider extends ChangeNotifier {
  ChallengeProvider({
    required this.ring,
    AlarmSchedulerService? scheduler,
    AudioPlayerService? audio,
    this.prepDuration = const Duration(seconds: 10),
    this.penaltyDuration = const Duration(seconds: 60),
    this.maxPausedDuration = const Duration(seconds: 15),
    this.cameraInitTimeout = const Duration(seconds: 10),
  })  : scheduler = scheduler ?? AlarmSchedulerService.instance,
        audio = audio ?? AudioPlayerService.instance,
        targetReps = math.max(1, ring.alarm?.targetPushups ?? 10),
        challengeTotalMs =
            math.max(1, ring.alarm?.challengeTimeoutSeconds ?? 60) * 1000,
        muteDuringChallenge = ring.alarm?.muteDuringChallenge ?? true;

  // ----- configuration ----------------------------------------------------

  final RingEvent ring;
  final AlarmSchedulerService scheduler;
  final AudioPlayerService audio;
  final Duration prepDuration;
  final Duration penaltyDuration;
  final Duration maxPausedDuration;
  final Duration cameraInitTimeout;

  final int targetReps;
  final int challengeTotalMs;
  final bool muteDuringChallenge;

  static const Duration _tick = Duration(milliseconds: 100);
  static const int _maxTickGapMs = 1000;
  static const Duration _successHold = Duration(milliseconds: 2200);

  // ----- state ------------------------------------------------------------

  ChallengePhase _phase = ChallengePhase.ringing;
  FailureReason? _failureReason;
  ChallengeOutcome? _outcome;
  bool _finished = false;
  bool _disposed = false;

  CameraStatus _cameraStatus = CameraStatus.initializing;
  String? _cameraError;
  CameraController? _controller;
  PoseDetectorService? _pose;

  int _reps = 0;
  int _prepRemainingMs = 0;
  late int _remainingMs = challengeTotalMs;
  int _pausedMs = 0;
  int _penaltyRemainingMs = 0;

  bool _snoozeUsed = false;
  bool _snoozeBusy = false;
  bool _starting = false;
  String? _message;

  bool showSkeleton = true;

  Timer? _ticker;
  Timer? _closeTimer;
  DateTime _lastTick = DateTime.now();

  // ----- public read-only state ------------------------------------------

  ChallengePhase get phase => _phase;
  FailureReason? get failureReason => _failureReason;
  ChallengeOutcome? get outcome => _outcome;
  bool get finished => _finished;

  CameraStatus get cameraStatus => _cameraStatus;
  String? get cameraError => _cameraError;
  CameraController? get cameraController => _controller;
  PoseDetectorService? get pose => _pose;

  int get reps => _reps;
  int get prepRemainingMs => _prepRemainingMs;
  int get remainingMs => _remainingMs;
  int get pausedMs => _pausedMs;
  int get penaltyRemainingMs => _penaltyRemainingMs;
  double get timeFraction =>
      (_remainingMs / challengeTotalMs).clamp(0.0, 1.0).toDouble();
  double get penaltyFraction =>
      (_penaltyRemainingMs / penaltyDuration.inMilliseconds)
          .clamp(0.0, 1.0)
          .toDouble();

  bool get isBodyVisible => _pose?.isBodyVisible ?? false;

  /// Timer is frozen while the challenge runs and nobody is detected.
  bool get isTimerPaused =>
      _phase == ChallengePhase.inProgress && !isBodyVisible;

  bool get canStart =>
      _phase == ChallengePhase.ringing &&
      _cameraStatus == CameraStatus.ready &&
      !_starting;

  /// One snooze per ring session, only before the challenge begins.
  bool get canSnooze =>
      _phase == ChallengePhase.ringing &&
      ring.canSnooze &&
      !_snoozeUsed &&
      !_snoozeBusy &&
      !_starting;

  /// Camera fallback: available in every unfinished phase once the camera failed.
  bool get showCameraFallback => _cameraStatus == CameraStatus.error && !_finished;

  String? get message => _message;

  // ----- camera -----------------------------------------------------------

  Future<void> initCamera() async {
    _cameraStatus = CameraStatus.initializing;
    _notify();
    try {
      final perm = await Permission.camera.request();
      if (_disposed) return;
      if (!perm.isGranted) throw StateError('Camera permission denied');

      final cameras = await availableCameras().timeout(cameraInitTimeout);
      if (_disposed) return;
      if (cameras.isEmpty) throw StateError('No camera found');
      final cam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = PoseDetectorService.createController(cam);
      _controller = controller; // assigned early so dispose() can clean up
      controller.addListener(_onControllerChanged);
      await controller.initialize().timeout(cameraInitTimeout);
      if (_disposed) return;

      final pose = PoseDetectorService(camera: cam)
        ..onWatchdogFailed = _onPoseWatchdog;
      pose.addListener(_onPoseChanged);
      _pose = pose;
      await pose.start(controller);
      if (_disposed) return;

      if (_cameraStatus != CameraStatus.error) {
        _cameraStatus = CameraStatus.ready;
        _notify();
      }
    } catch (e, st) {
      debugPrint('Camera init failed: $e\n$st');
      if (!_disposed) _setCameraError(e.toString());
    }
  }

  void _onControllerChanged() {
    final c = _controller;
    if (c == null || _disposed) return;
    if (c.value.hasError && _cameraStatus != CameraStatus.error) {
      _setCameraError(c.value.errorDescription ?? 'Camera error');
    }
  }

  void _setCameraError(String description) {
    _cameraStatus = CameraStatus.error;
    _cameraError = description;
    final pose = _pose;
    if (pose != null) unawaited(pose.stop());
    _notify();
  }

  // ----- user actions -----------------------------------------------------

  /// "Start Challenge": hand sound over to the in-app player, begin prep.
  Future<void> startChallenge() async {
    if (!canStart) return;
    _starting = true;
    _message = null;
    _notify();
    try {
      // Overlap on purpose: start in-app audio first so there is no silent gap.
      await audio.play(
        customPath: ring.alarm?.customAudioPath,
        volume: 1.0,
      );
      await scheduler.silenceRingingAlarm(ring.nativeId);
    } catch (e) {
      debugPrint('Audio hand-off failed: $e');
    }
    if (_disposed || _finished) return;

    _phase = ChallengePhase.preparationCountdown;
    _prepRemainingMs = prepDuration.inMilliseconds;
    _startTicker();
    _starting = false;
    _notify();
  }

  /// Single snooze, only while ringing. Scheduler enforces the limit as well.
  Future<void> snooze() async {
    if (!canSnooze) return;
    _snoozeBusy = true;
    _message = null;
    _notify();
    try {
      final r = await scheduler.snooze(ring.nativeId);
      if (_disposed) return;
      if (r.ok) {
        _snoozeUsed = true;
        await _finish(ChallengeOutcome.snoozed);
        return;
      }
      if (r.status == SnoozeStatus.limitReached) {
        _snoozeUsed = true;
        _message = 'No snoozes left.';
      } else {
        _message = 'Could not snooze. Start the challenge to dismiss.';
      }
    } catch (e) {
      _message = 'Could not snooze. Start the challenge to dismiss.';
    } finally {
      _snoozeBusy = false;
      _notify();
    }
  }

  /// "Dismiss (Camera Error)": always completes the alarm, whatever the phase.
  Future<void> dismissCameraError() async {
    if (!showCameraFallback) return;
    _cancelTimers();
    _pose?.stopChallenge();
    await _stopAudioSafe();
    await _completeSafe();
    await _finish(ChallengeOutcome.cameraDismissed);
  }

  void setShowSkeleton(bool value) {
    showSkeleton = value;
    _notify();
  }

  // ----- ticker -----------------------------------------------------------

  void _startTicker() {
    _lastTick = DateTime.now();
    _ticker?.cancel();
    _ticker = Timer.periodic(_tick, _onTick);
  }

  void _onTick(Timer _) {
    if (_disposed) return;
    final now = DateTime.now();
    final delta = math.min(
      math.max(now.difference(_lastTick).inMilliseconds, 0),
      _maxTickGapMs,
    );
    _lastTick = now;

    switch (_phase) {
      case ChallengePhase.preparationCountdown:
        _prepRemainingMs -= delta;
        if (_prepRemainingMs <= 0) {
          _prepRemainingMs = 0;
          _beginChallenge();
        }
      case ChallengePhase.inProgress:
        if (isBodyVisible) {
          _remainingMs -= delta;
        } else {
          _pausedMs += delta;
          if (_pausedMs > maxPausedDuration.inMilliseconds) {
            unawaited(_fail(FailureReason.bodyLost));
            return;
          }
        }
        if (_remainingMs <= 0) {
          _remainingMs = 0;
          // Last-tick race: a rep may have landed in the same instant.
          if (_reps >= targetReps) {
            unawaited(_succeed());
          } else {
            unawaited(_fail(FailureReason.timeout));
          }
          return;
        }
      case ChallengePhase.failure:
        _penaltyRemainingMs -= delta;
        if (_penaltyRemainingMs <= 0) {
          _penaltyRemainingMs = 0;
          unawaited(_endPenalty());
          return;
        }
      case ChallengePhase.ringing:
      case ChallengePhase.success:
        _ticker?.cancel();
        _ticker = null;
        return;
    }
    _notify();
  }

  // ----- phase transitions ------------------------------------------------

  void _beginChallenge() {
    _phase = ChallengePhase.inProgress;
    _reps = 0;
    _remainingMs = challengeTotalMs;
    _pausedMs = 0;
    _pose?.startChallenge();
    if (muteDuringChallenge) unawaited(audio.mute());
    _notify();
  }

  Future<void> _succeed() async {
    if (_phase != ChallengePhase.inProgress) return;
    _phase = ChallengePhase.success;
    _ticker?.cancel();
    _ticker = null;
    _pose?.stopChallenge();
    _notify();
    await _stopAudioSafe();
    await _completeSafe();
    final pose = _pose;
    if (pose != null) unawaited(pose.stop());
    if (_disposed) return;
    _closeTimer = Timer(_successHold, () {
      unawaited(_finish(ChallengeOutcome.completed));
    });
  }

  Future<void> _fail(FailureReason reason) async {
    if (_phase != ChallengePhase.inProgress) return;
    _phase = ChallengePhase.failure;
    _failureReason = reason;
    _penaltyRemainingMs = penaltyDuration.inMilliseconds;
    _lastTick = DateTime.now();
    _pose?.stopChallenge();
    _notify();
    // Max volume, unmuted (play() resets mute), auto-stops after the penalty.
    try {
      await audio.play(
        customPath: ring.alarm?.customAudioPath,
        volume: 1.0,
        autoStopAfter: penaltyDuration,
      );
    } catch (e) {
      debugPrint('Penalty audio failed: $e');
    }
  }

  Future<void> _endPenalty() async {
    if (_phase != ChallengePhase.failure || _finished) return;
    await _stopAudioSafe();
    await _completeSafe();
    await _finish(ChallengeOutcome.penaltyEnded);
  }

  // ----- pose callbacks ---------------------------------------------------

  void _onPoseChanged() {
    if (_disposed) return;
    final pose = _pose;
    if (pose != null && _phase == ChallengePhase.inProgress) {
      _reps = pose.repCount;
      if (_reps >= targetReps) {
        unawaited(_succeed());
        return;
      }
    }
    _notify();
  }

  /// Redundant with the paused-time accounting in [_onTick]; whichever trips
  /// first wins and [_fail] is idempotent.
  void _onPoseWatchdog() {
    if (_phase == ChallengePhase.inProgress) {
      unawaited(_fail(FailureReason.bodyLost));
    }
  }

  // ----- helpers ----------------------------------------------------------

  Future<void> _stopAudioSafe() async {
    try {
      await audio.stop();
    } catch (e) {
      debugPrint('audio.stop failed: $e');
    }
  }

  Future<void> _completeSafe() async {
    try {
      await scheduler.completeAlarm(ring.nativeId);
    } catch (e) {
      debugPrint('completeAlarm failed: $e');
    }
  }

  Future<void> _finish(ChallengeOutcome outcome) async {
    if (_finished) return;
    _finished = true;
    _outcome = outcome;
    _cancelTimers();
    final pose = _pose;
    if (pose != null) unawaited(pose.stop());
    _notify();
  }

  void _cancelTimers() {
    _ticker?.cancel();
    _ticker = null;
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ----- lifecycle --------------------------------------------------------

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    final pose = _pose;
    final controller = _controller;
    _pose = null;
    _controller = null;
    controller?.removeListener(_onControllerChanged);
    pose?.removeListener(_onPoseChanged);
    unawaited(_teardownCamera(pose, controller));
    super.dispose();
  }

  Future<void> _teardownCamera(
    PoseDetectorService? pose,
    CameraController? controller,
  ) async {
    try {
      await pose?.stop();
    } catch (_) {}
    try {
      pose?.dispose();
    } catch (_) {}
    try {
      await controller?.dispose();
    } catch (_) {}
  }
}