import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../core/utils/angle_calculator.dart';

enum PushUpState { up, down }

enum ArmSide { left, right }

// ---------------------------------------------------------------------------
// State machine (pure Dart - unit-testable without any plugin)
// ---------------------------------------------------------------------------

/// Counts a rep only on a strict UP -> DOWN -> UP sequence.
///
/// * angle >= [upThreshold]   -> UP
/// * angle <= [downThreshold] -> DOWN
/// * anything in between     -> no change (hysteresis band)
///
/// A rep needs an *observed* UP first. Starting in the DOWN position and
/// pushing up does not count, because the UP -> DOWN leg was never seen.
class PushUpStateMachine {
  PushUpStateMachine({this.upThreshold = 155.0, this.downThreshold = 95.0})
      : assert(upThreshold > downThreshold);

  final double upThreshold;
  final double downThreshold;

  PushUpState? _state;
  bool _cycleArmed = false; // true once we went UP -> DOWN
  int _repCount = 0;

  /// Last state that was actually observed, null before the first reading.
  PushUpState? get confirmedState => _state;

  /// Convenience: defaults to [PushUpState.up] before the first reading.
  PushUpState get state => _state ?? PushUpState.up;

  int get repCount => _repCount;

  /// Feed one smoothed angle. Returns true if this reading completed a rep.
  bool update(double angle) {
    final PushUpState next;
    if (angle >= upThreshold) {
      next = PushUpState.up;
    } else if (angle <= downThreshold) {
      next = PushUpState.down;
    } else {
      return false;
    }

    final prev = _state;
    if (next == prev) return false;
    _state = next;

    if (next == PushUpState.down) {
      _cycleArmed = prev == PushUpState.up;
      return false;
    }

    // next == up
    final completed = prev == PushUpState.down && _cycleArmed;
    _cycleArmed = false;
    if (completed) _repCount++;
    return completed;
  }

  void reset() {
    _state = null;
    _cycleArmed = false;
    _repCount = 0;
  }
}

// ---------------------------------------------------------------------------
// Per-frame snapshot published to the UI / painter
// ---------------------------------------------------------------------------

@immutable
class PoseFrame {
  const PoseFrame({
    required this.pose,
    required this.imageSize,
    required this.rotation,
    required this.lensDirection,
    required this.activeSide,
    required this.angle,
    required this.state,
    required this.repCount,
    required this.isBodyVisible,
    required this.visibilityThreshold,
    this.leftAngle,
    this.rightAngle,
    this.usedBothArms = false,
    this.processingMs = 0,
  });

  /// Smoothed per-arm angles (null when that arm failed the visibility check).
  final double? leftAngle;
  final double? rightAngle;

  /// True when [angle] is the average of both arms.
  final bool usedBothArms;

  /// Last ML Kit processing time, for the debug HUD.
  final int processingMs;

  /// Raw ML Kit result (null if no person detected this frame).
  final Pose? pose;

  /// Size of the camera image as delivered (unrotated).
  final Size imageSize;

  /// Rotation ML Kit applied; needed to map landmarks onto the preview.
  final InputImageRotation rotation;
  final CameraLensDirection lensDirection;

  /// Side whose angle drives the state machine this frame (null = none valid).
  final ArmSide? activeSide;

  /// Smoothed elbow angle of [activeSide], degrees.
  final double? angle;

  final PushUpState state;
  final int repCount;
  final bool isBodyVisible;
  final double visibilityThreshold;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Camera frames -> ML Kit pose -> smoothed elbow angle -> push-up reps.
///
/// Two notification channels, so the UI stays cheap:
///  * [frameNotifier] fires on every processed frame (feed it to the painter).
///  * [notifyListeners] fires only on discrete changes: rep counted, up/down
///    state change, visibility change, active-side change, watchdog failure.
///
/// Lifecycle:
///  1. `final c = PoseDetectorService.createController(camera);`
///     `await c.initialize();`
///  2. `await service.start(c);`  - detection + skeleton run, nothing counts.
///  3. After the 10 s prep countdown: `service.startChallenge();`
///  4. `service.stopChallenge()` on success/fail, then `service.dispose()`.
class PoseDetectorService extends ChangeNotifier {
  PoseDetectorService({
    required this.camera,
    this.visibilityThreshold = 0.5,
    double upThreshold = 145.0,
    double downThreshold = 105.0,
    int smoothingWindow = 3,
    bool use3DAngles = false,
    this.model = PoseDetectionModel.accurate,
    this.maxArmAngleDisagreement = 40.0,
    this.maxInvisibleDuration = const Duration(seconds: 15),
    this.visibilityGrace = const Duration(milliseconds: 400),
    PoseDetector? detector,
  })  : _machine = PushUpStateMachine(
          upThreshold: upThreshold,
          downThreshold: downThreshold,
        ),
        _smoothers = {
          ArmSide.left: SmoothedAngleCalculator(
            windowSize: smoothingWindow,
            use3D: use3DAngles,
          ),
          ArmSide.right: SmoothedAngleCalculator(
            windowSize: smoothingWindow,
            use3D: use3DAngles,
          ),
        },
        _detector = detector;

  // ----- configuration -----------------------------------------------------

  final CameraDescription camera;

  /// Shoulder, elbow and wrist of an arm must all reach this likelihood for
  /// that arm to be used.
  final double visibilityThreshold;

  /// ML Kit model. `accurate` copes much better with horizontal (plank-like)
  /// bodies than `base`; use `base` if frame times are too high.
  final PoseDetectionModel model;

  /// When both arms are valid they are averaged only if their angles agree
  /// within this many degrees (the far arm in a side view is often a guess).
  final double maxArmAngleDisagreement;

  /// Aggregate time the user may be out of view during a challenge.
  final Duration maxInvisibleDuration;

  /// Body must be continuously lost this long before [isBodyVisible] flips to
  /// false (stops UI flicker on single bad frames; the watchdog only counts
  /// time after this grace, so it can never penalise a one-frame dropout).
  final Duration visibilityGrace;

  // ----- callbacks (optional alternative to addListener) ------------------

  ValueChanged<int>? onRepCounted;
  ValueChanged<bool>? onVisibilityChanged;
  VoidCallback? onWatchdogFailed;

  /// Per-frame snapshot for painters.
  final ValueNotifier<PoseFrame?> frameNotifier =
      ValueNotifier<PoseFrame?>(null);

  // ----- internals --------------------------------------------------------

  static const Map<DeviceOrientation, int> _orientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Other side must beat the active side by this much to take over
  /// (prevents flip-flopping between near-equal sides).
  static const double _sideSwitchMargin = 0.05;

  /// Cap on a single inter-frame gap when accumulating invisible time, so a
  /// stalled camera / backgrounded app is not counted against the user.
  static const int _maxFrameGapMs = 1000;

  final PushUpStateMachine _machine;
  final Map<ArmSide, SmoothedAngleCalculator> _smoothers;
  PoseDetector? _detector;
  CameraController? _controller;

  bool _isBusy = false;
  bool _isDisposed = false;

  ArmSide? _activeSide;
  bool _isBodyVisible = false;
  DateTime? _invisibleSince;
  DateTime? _lastFrameTime;

  bool _challengeActive = false;
  bool _watchdogFailed = false;
  int _invisibleMs = 0;
  int _repCount = 0;

  // Rotation self-calibration (see _calibrateRotation).
  static const int _framesBeforeRotationRetry = 24;
  static const int _framesToLockRotation = 5;
  int _rotationOffset = 0;
  bool _rotationLocked = false;
  int _noSolidStreak = 0;
  int _goodStreak = 0;
  int _conversionFailures = 0;
  int _effectiveRotationDegrees = 0;
  DateTime _lastLogAt = DateTime.fromMillisecondsSinceEpoch(0);

  PoseFrame? _lastFrame;
  int _processedFrames = 0;
  int _droppedFrames = 0;
  int _lastProcessingMs = 0;

  PoseDetector get _poseDetector => _detector ??= PoseDetector(
        options: PoseDetectorOptions(
          mode: PoseDetectionMode.stream,
          model: PoseDetectionModel.base,
        ),
      );

  // ----- public read-only state -------------------------------------------

  int get repCount => _repCount;
  PushUpState get state => _machine.state;
  ArmSide? get activeSide => _activeSide;
  double? get currentAngle => _lastFrame?.angle;
  PoseFrame? get lastFrame => _lastFrame;

  /// False when the active arm's shoulder/elbow/wrist are below
  /// [visibilityThreshold] (debounced by [visibilityGrace]).
  bool get isBodyVisible => _isBodyVisible;

  bool get isChallengeActive => _challengeActive;
  bool get watchdogFailed => _watchdogFailed;
  Duration get invisibleDuration => Duration(milliseconds: _invisibleMs);

  /// Diagnostics for verifying the "low latency / no backlog" requirement.
  int get processedFrames => _processedFrames;
  int get droppedFrames => _droppedFrames;
  int get lastProcessingMs => _lastProcessingMs;
  int get conversionFailures => _conversionFailures;
  int get rotationDegrees => _effectiveRotationDegrees;
  int get rotationOffset => _rotationOffset;
  bool get rotationLocked => _rotationLocked;

  // ----- camera helpers ---------------------------------------------------

  /// Controller configured for this service: 480p (fast), no audio, NV21
  /// output (ML Kit's native Android format, so no conversion is needed).
  /// If a device ignores NV21 and delivers YUV_420_888, the service converts
  /// it itself.
  static CameraController createController(CameraDescription camera) {
    return CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
  }

  /// Starts streaming frames from an *initialized* [controller].
  Future<void> start(CameraController controller) async {
    _controller = controller;
    if (controller.value.isStreamingImages) return;
    await controller.startImageStream((CameraImage image) {
      unawaited(
        processCameraImage(image, controller.value.deviceOrientation),
      );
    });
  }

  Future<void> stop() async {
    final c = _controller;
    if (c == null) return;
    try {
      if (c.value.isInitialized && c.value.isStreamingImages) {
        await c.stopImageStream();
      }
    } catch (e) {
      debugPrint('PoseDetectorService.stop: $e');
    }
  }

  // ----- challenge control ------------------------------------------------

  /// Call when the prep countdown ends. Resets reps/watchdog and requires a
  /// freshly observed UP before the first rep can begin.
  void startChallenge() {
    _machine.reset();
    _repCount = 0;
    _invisibleMs = 0;
    _watchdogFailed = false;
    _challengeActive = true;
    _lastFrameTime = null;
    _notify();
  }

  void stopChallenge() {
    _challengeActive = false;
    _notify();
  }

  // ----- frame pipeline ---------------------------------------------------

  /// Entry point for every camera frame. Frames that arrive while a previous
  /// frame is still being processed are discarded immediately, so latency
  /// never accumulates a queue.
  Future<void> processCameraImage(
    CameraImage image,
    DeviceOrientation deviceOrientation,
  ) async {
    if (_isDisposed) return;
    if (_isBusy) {
      _droppedFrames++;
      return;
    }
    _isBusy = true;
    final stopwatch = Stopwatch()..start();
    try {
      final input = _toInputImage(image, deviceOrientation);
      if (input == null) {
        _conversionFailures++;
        _log('frame -> InputImage failed (#$_conversionFailures): '
            'group=${image.format.group} raw=${image.format.raw} '
            'planes=${image.planes.length} ${image.width}x${image.height}');
        return;
      }
      final metadata = input.metadata!;

      final poses = await _poseDetector.processImage(input);
      if (_isDisposed) return;

      stopwatch.stop();
      _lastProcessingMs = stopwatch.elapsedMilliseconds;
      _processedFrames++;

      final pose = poses.isEmpty ? null : poses.first;
      _calibrateRotation(pose);
      ingestPose(
        pose,
        imageSize: metadata.size,
        rotation: metadata.rotation,
        now: DateTime.now(),
      );
    } catch (e, st) {
      debugPrint('PoseDetectorService frame error: $e\n$st');
    } finally {
      _isBusy = false;
    }
  }

  /// Core logic, separated from camera/ML Kit so it can be unit-tested with
  /// synthetic poses. [now] is injectable for deterministic timing tests.
  @visibleForTesting
  void ingestPose(
    Pose? pose, {
    required Size imageSize,
    required InputImageRotation rotation,
    DateTime? now,
  }) {
    if (_isDisposed) return;
    final t = now ?? DateTime.now();

    final gapMs = _lastFrameTime == null
        ? 0
        : math.min(
            math.max(t.difference(_lastFrameTime!).inMilliseconds, 0),
            _maxFrameGapMs,
          );
    _lastFrameTime = t;

    // 1. Read both arms (this also feeds / resets each side's smoother).
    final left = _readSide(ArmSide.left, pose);
    final right = _readSide(ArmSide.right, pose);

    // 2. Pick the more confident valid side (with hysteresis).
    final chosen = _chooseSide(left, right);

    // Driving angle: average of both arms when both are valid and agree,
    // otherwise the more confident arm.
    double? angle;
    var usedBoth = false;
    if (chosen != null) {
      final l = left.smoothedAngle;
      final r = right.smoothedAngle;
      if (l != null &&
          r != null &&
          (l - r).abs() <= maxArmAngleDisagreement) {
        angle = (l + r) / 2.0;
        usedBoth = true;
      } else {
        angle = (chosen == ArmSide.left ? left : right).smoothedAngle;
      }
    }
    final sideChanged =
        chosen != null && _activeSide != null && chosen != _activeSide;
    if (chosen != null) _activeSide = chosen;

    // 3. Visibility (debounced).
    var visibilityChanged = false;
    if (chosen != null) {
      _invisibleSince = null;
      if (!_isBodyVisible) {
        _isBodyVisible = true;
        visibilityChanged = true;
      }
    } else {
      _invisibleSince ??= t;
      if (_isBodyVisible &&
          t.difference(_invisibleSince!) >= visibilityGrace) {
        _isBodyVisible = false;
        visibilityChanged = true;
      }
    }

    // 4. Watchdog: aggregate invisible time during an active challenge.
    var watchdogTripped = false;
    if (_challengeActive && !_watchdogFailed && !_isBodyVisible) {
      _invisibleMs += gapMs;
      if (_invisibleMs > maxInvisibleDuration.inMilliseconds) {
        _watchdogFailed = true;
        watchdogTripped = true;
      }
    }

    // 5. State machine - only fed by confident, valid readings, so low
    //    confidence frames can never create or break a rep.
    final stateBefore = _machine.state;
    var repCompleted = false;
    if (angle != null) {
      final completed = _machine.update(angle);
      if (completed && _challengeActive && !_watchdogFailed) {
        _repCount++;
        repCompleted = true;
      }
    }

    // 6. Publish.
    final frame = PoseFrame(
      pose: pose,
      imageSize: imageSize,
      rotation: rotation,
      lensDirection: camera.lensDirection,
      activeSide: chosen,
      angle: angle,
      state: _machine.state,
      repCount: _repCount,
      isBodyVisible: _isBodyVisible,
      visibilityThreshold: visibilityThreshold,
      leftAngle: left.smoothedAngle,
      rightAngle: right.smoothedAngle,
      usedBothArms: usedBoth,
      processingMs: _lastProcessingMs,
    );
    _lastFrame = frame;
    frameNotifier.value = frame;

    if (repCompleted ||
        _machine.state != stateBefore ||
        visibilityChanged ||
        watchdogTripped ||
        sideChanged) {
      _notify();
    }

    _logStatus(t, frame, left, right);

    if (repCompleted) onRepCounted?.call(_repCount);
    if (visibilityChanged) onVisibilityChanged?.call(_isBodyVisible);
    if (watchdogTripped) onWatchdogFailed?.call();
  }

  _SideReading _readSide(ArmSide side, Pose? pose) {
    final isLeft = side == ArmSide.left;
    final shoulder = pose?.landmarks[
        isLeft ? PoseLandmarkType.leftShoulder : PoseLandmarkType.rightShoulder];
    final elbow = pose?.landmarks[
        isLeft ? PoseLandmarkType.leftElbow : PoseLandmarkType.rightElbow];
    final wrist = pose?.landmarks[
        isLeft ? PoseLandmarkType.leftWrist : PoseLandmarkType.rightWrist];

    final smoother = _smoothers[side]!;

    if (shoulder == null || elbow == null || wrist == null) {
      smoother.reset();
      return _SideReading(side: side, confidence: 0.0, smoothedAngle: null);
    }

    final confidence =
        (shoulder.likelihood + elbow.likelihood + wrist.likelihood) / 3.0;
    final minLikelihood = math.min(
      shoulder.likelihood,
      math.min(elbow.likelihood, wrist.likelihood),
    );

    if (minLikelihood < visibilityThreshold) {
      smoother.reset(); // don't blend stale angles with post-gap ones
      return _SideReading(
        side: side,
        confidence: confidence,
        smoothedAngle: null,
      );
    }

    final smoothed = smoother.update(
      Point3(shoulder.x, shoulder.y, shoulder.z),
      Point3(elbow.x, elbow.y, elbow.z),
      Point3(wrist.x, wrist.y, wrist.z),
    );
    return _SideReading(
      side: side,
      confidence: confidence,
      smoothedAngle: smoothed,
    );
  }

  ArmSide? _chooseSide(_SideReading left, _SideReading right) {
    if (!left.isValid && !right.isValid) return null;
    if (!right.isValid) return ArmSide.left;
    if (!left.isValid) return ArmSide.right;

    // Both valid.
    final active = _activeSide;
    if (active != null) {
      final current = active == ArmSide.left ? left : right;
      final other = active == ArmSide.left ? right : left;
      return other.confidence > current.confidence + _sideSwitchMargin
          ? other.side
          : active;
    }
    return right.confidence > left.confidence ? ArmSide.right : ArmSide.left;
  }

  // ----- CameraImage -> InputImage ----------------------------------------

  InputImageRotation? _computeRotation(DeviceOrientation orientation) {
    final compensation = _orientationDegrees[orientation];
    if (compensation == null) return null;
    final sensor = camera.sensorOrientation;
    final degrees = camera.lensDirection == CameraLensDirection.front
        ? (sensor + compensation) % 360
        : (sensor - compensation + 360) % 360;
    // _rotationOffset stays 0 unless auto-calibration had to step in.
    final effective = (degrees + _rotationOffset) % 360;
    _effectiveRotationDegrees = effective;
    return InputImageRotationValue.fromRawValue(effective);
  }

  /// Safety net for devices / camera backends (e.g. CameraX) whose frames
  /// don't match the textbook rotation maths: ML Kit then sees a sideways or
  /// upside-down person and returns nothing. Until a confident pose has been
  /// seen, step the rotation by 90 degrees every [_framesBeforeRotationRetry]
  /// frames without one, and lock in the first rotation that works.
  void _calibrateRotation(Pose? pose) {
    if (_rotationLocked) return;
    var solid = false;
    if (pose != null) {
      final ls = pose.landmarks[PoseLandmarkType.leftShoulder]?.likelihood ?? 0;
      final rs = pose.landmarks[PoseLandmarkType.rightShoulder]?.likelihood ?? 0;
      solid = math.max(ls, rs) >= 0.7;
    }
    if (solid) {
      _noSolidStreak = 0;
      if (++_goodStreak >= _framesToLockRotation) {
        _rotationLocked = true;
        _log('rotation locked: ${_effectiveRotationDegrees}deg '
            '(offset +$_rotationOffset)');
      }
    } else {
      _goodStreak = 0;
      if (++_noSolidStreak >= _framesBeforeRotationRetry) {
        _noSolidStreak = 0;
        _rotationOffset = (_rotationOffset + 90) % 360;
        _log('no confident pose; trying rotation offset +$_rotationOffset');
      }
    }
  }

  InputImage? _toInputImage(CameraImage image, DeviceOrientation orientation) {
    final rotation = _computeRotation(orientation);
    if (rotation == null) return null;

    final width = image.width;
    final height = image.height;
    Uint8List? nv21;

    final group = image.format.group;
    if (group == ImageFormatGroup.bgra8888 || group == ImageFormatGroup.jpeg) {
      return null; // not produced on Android
    }

    // Decide by plane layout rather than trusting the reported group alone:
    // some backends report `unknown`/YUV for what is really a packed NV21
    // buffer. The buffer handed to ML Kit is always NV21, so the metadata
    // format below is always InputImageFormat.nv21.
    if (image.planes.length == 1) {
      final plane = image.planes.first;
      nv21 = _normalizeNv21(plane.bytes, width, height, plane.bytesPerRow);
    } else if (image.planes.length == 3) {
      final y = image.planes[0];
      final u = image.planes[1];
      final v = image.planes[2];
      nv21 = yuv420ToNv21(
        width: width,
        height: height,
        yBytes: y.bytes,
        yRowStride: y.bytesPerRow,
        uBytes: u.bytes,
        vBytes: v.bytes,
        uvRowStride: u.bytesPerRow,
        uvPixelStride: u.bytesPerPixel ?? 1,
      );
    } else {
      return null;
    }
    if (nv21 == null) return null;

    return InputImage.fromBytes(
      bytes: nv21,
      metadata: InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: width, // tightly packed after normalisation
      ),
    );
  }

  /// Ensures an NV21 buffer is tightly packed (row stride == width), since
  /// ML Kit's Android path ignores stride.
  static Uint8List? _normalizeNv21(
    Uint8List bytes,
    int width,
    int height,
    int rowStride,
  ) {
    final expected = width * height * 3 ~/ 2;
    if (rowStride <= width) {
      if (bytes.length == expected) return bytes;
      if (bytes.length > expected) {
        return Uint8List.sublistView(bytes, 0, expected);
      }
      return null;
    }
    // Padded rows: compact Y and interleaved VU separately.
    if (bytes.length < rowStride * height * 3 ~/ 2) return null;
    final out = Uint8List(expected);
    var o = 0;
    for (var r = 0; r < height; r++) {
      out.setRange(o, o + width, bytes, r * rowStride);
      o += width;
    }
    final uvStart = rowStride * height;
    for (var r = 0; r < height ~/ 2; r++) {
      out.setRange(o, o + width, bytes, uvStart + r * rowStride);
      o += width;
    }
    return out;
  }

  /// Android YUV_420_888 (3 planes, arbitrary row/pixel strides) -> NV21
  /// (Y plane followed by interleaved V,U). Handles padded Y rows and both
  /// planar (pixelStride 1) and semi-planar (pixelStride 2) chroma layouts.
  @visibleForTesting
  static Uint8List yuv420ToNv21({
    required int width,
    required int height,
    required Uint8List yBytes,
    required int yRowStride,
    required Uint8List uBytes,
    required Uint8List vBytes,
    required int uvRowStride,
    required int uvPixelStride,
  }) {
    final ySize = width * height;
    final chromaW = (width + 1) ~/ 2;
    final chromaH = (height + 1) ~/ 2;
    final out = Uint8List(ySize + 2 * chromaW * chromaH);

    // Luma.
    if (yRowStride == width) {
      out.setRange(0, ySize, yBytes);
    } else {
      for (var r = 0; r < height; r++) {
        out.setRange(r * width, r * width + width, yBytes, r * yRowStride);
      }
    }

    // Chroma: NV21 order is V then U.
    var o = ySize;
    for (var r = 0; r < chromaH; r++) {
      final rowStart = r * uvRowStride;
      for (var c = 0; c < chromaW; c++) {
        final i = rowStart + c * uvPixelStride;
        out[o++] = vBytes[i];
        out[o++] = uBytes[i];
      }
    }
    return out;
  }

  // ----- debug logging ----------------------------------------------------

  void _log(String msg) {
    if (kDebugMode) debugPrint('[PoseDetector] $msg');
  }

  /// Live status line, at most twice a second.
  void _logStatus(
    DateTime t,
    PoseFrame f,
    _SideReading left,
    _SideReading right,
  ) {
    if (!kDebugMode) return;
    if (t.difference(_lastLogAt).inMilliseconds < 500) return;
    _lastLogAt = t;
    String a(double? v) => v == null ? '--' : v.toStringAsFixed(0);
    _log('pose=${f.pose != null ? 'yes' : 'NO'} '
        'L=${a(left.smoothedAngle)}(${left.confidence.toStringAsFixed(2)}) '
        'R=${a(right.smoothedAngle)}(${right.confidence.toStringAsFixed(2)}) '
        'drive=${a(f.angle)}${f.usedBothArms ? ' avg' : ''} '
        'state=${f.state.name} reps=$_repCount '
        'visible=$_isBodyVisible active=$_challengeActive '
        'rot=$_effectiveRotationDegrees${_rotationLocked ? ' locked' : ''} '
        'ms=$_lastProcessingMs frames=$_processedFrames dropped=$_droppedFrames '
        'convFail=$_conversionFailures');
  }

  // ----- lifecycle --------------------------------------------------------

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    final controller = _controller;
    final detector = _detector;
    _controller = null;
    _detector = null;
    unawaited(_shutdown(controller, detector));
    frameNotifier.dispose();
    super.dispose();
  }

  Future<void> _shutdown(
    CameraController? controller,
    PoseDetector? detector,
  ) async {
    try {
      if (controller != null &&
          controller.value.isInitialized &&
          controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await detector?.close();
    } catch (_) {}
  }
}

class _SideReading {
  const _SideReading({
    required this.side,
    required this.confidence,
    required this.smoothedAngle,
  });

  final ArmSide side;

  /// Mean likelihood of shoulder/elbow/wrist (0 if any landmark missing).
  final double confidence;

  /// Non-null only when all three landmarks passed the visibility threshold.
  final double? smoothedAngle;

  bool get isValid => smoothedAngle != null;
}