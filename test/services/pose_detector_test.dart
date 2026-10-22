import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
// Adjust 'wakefit' if your pubspec `name:` differs.
import 'package:wakefit/services/pose_detector_service.dart';

PoseLandmark _lm(PoseLandmarkType type, double x, double y, double like) =>
    PoseLandmark(type: type, x: x, y: y, z: 0, likelihood: like);

/// Builds a pose where each arm has the given elbow angle (degrees).
/// Shoulder (0,0), elbow (100,0), wrist placed so the angle at the elbow is
/// exactly [angle].
Pose _armPose(
  double angle, {
  double leftLike = 0.9,
  double rightLike = 0.9,
}) {
  final rad = angle * math.pi / 180.0;
  final wristX = 100 - 100 * math.cos(rad);
  final wristY = 100 * math.sin(rad);
  return Pose(landmarks: {
    PoseLandmarkType.leftShoulder: _lm(PoseLandmarkType.leftShoulder, 0, 0, leftLike),
    PoseLandmarkType.leftElbow: _lm(PoseLandmarkType.leftElbow, 100, 0, leftLike),
    PoseLandmarkType.leftWrist: _lm(PoseLandmarkType.leftWrist, wristX, wristY, leftLike),
    PoseLandmarkType.rightShoulder: _lm(PoseLandmarkType.rightShoulder, 0, 0, rightLike),
    PoseLandmarkType.rightElbow: _lm(PoseLandmarkType.rightElbow, 100, 0, rightLike),
    PoseLandmarkType.rightWrist: _lm(PoseLandmarkType.rightWrist, wristX, wristY, rightLike),
  });
}

void main() {
  group('PushUpStateMachine', () {
    test('counts only on UP -> DOWN -> UP', () {
      final m = PushUpStateMachine();
      expect(m.update(170), isFalse); // UP
      expect(m.update(120), isFalse); // dead band, ignored
      expect(m.update(60), isFalse); // DOWN
      expect(m.update(170), isTrue); // UP -> rep
      expect(m.repCount, 1);
    });

    test('half reps in the dead band never count', () {
      final m = PushUpStateMachine();
      m.update(170);
      m.update(100); // not below 90
      m.update(170);
      expect(m.repCount, 0);
    });

    test('starting in DOWN does not count the first push up', () {
      final m = PushUpStateMachine();
      m.update(60);
      expect(m.update(170), isFalse);
      expect(m.repCount, 0);
      m.update(60);
      expect(m.update(170), isTrue);
      expect(m.repCount, 1);
    });

    test('thresholds are exclusive (155 and 90 exactly are dead band)', () {
      final m = PushUpStateMachine();
      m.update(155);
      expect(m.confirmedState, isNull);
      m.update(170);
      m.update(90);
      expect(m.state, PushUpState.up);
    });

    test('reset clears everything', () {
      final m = PushUpStateMachine()
        ..update(170)
        ..update(60)
        ..update(170);
      m.reset();
      expect(m.repCount, 0);
      expect(m.confirmedState, isNull);
    });
  });

  group('PoseDetectorService.ingestPose', () {
    late PoseDetectorService service;
    late DateTime t;
    const imageSize = Size(640, 480);

    setUp(() {
      service = PoseDetectorService(
        camera: const CameraDescription(
          name: 'test',
          lensDirection: CameraLensDirection.front,
          sensorOrientation: 270,
        ),
      );
      t = DateTime(2026, 1, 1);
    });

    tearDown(() => service.dispose());

    void feed(
      double angle, {
      int n = 1,
      double leftLike = 0.9,
      double rightLike = 0.9,
      int stepMs = 33,
    }) {
      for (var i = 0; i < n; i++) {
        t = t.add(Duration(milliseconds: stepMs));
        service.ingestPose(
          _armPose(angle, leftLike: leftLike, rightLike: rightLike),
          imageSize: imageSize,
          rotation: InputImageRotation.rotation270deg,
          now: t,
        );
      }
    }

    test('counts a full rep through the 3-frame smoothing', () {
      service.startChallenge();
      feed(170, n: 5);
      feed(60, n: 5);
      feed(170, n: 5);
      expect(service.repCount, 1);
      expect(service.state, PushUpState.up);
    });

    test('counts several consecutive reps', () {
      service.startChallenge();
      feed(170, n: 5);
      for (var i = 0; i < 3; i++) {
        feed(60, n: 5);
        feed(170, n: 5);
      }
      expect(service.repCount, 3);
    });

    test('does not count before startChallenge()', () {
      feed(170, n: 5);
      feed(60, n: 5);
      feed(170, n: 5);
      expect(service.repCount, 0);
    });

    test('low-confidence frames never change state or count reps', () {
      service.startChallenge();
      feed(170, n: 5);
      feed(60, n: 20, leftLike: 0.3, rightLike: 0.3); // ~660 ms, unseen
      expect(service.state, PushUpState.up);
      expect(service.repCount, 0);
      expect(service.isBodyVisible, isFalse); // past the 400 ms grace
      feed(170, n: 5);
      expect(service.repCount, 0);
      expect(service.isBodyVisible, isTrue);
    });

    test('a single bad frame does not flip visibility', () {
      feed(170, n: 5);
      feed(170, n: 1, leftLike: 0.1, rightLike: 0.1);
      expect(service.isBodyVisible, isTrue);
    });

    test('picks the more confident side', () {
      feed(170, n: 3, leftLike: 0.7, rightLike: 0.95);
      expect(service.activeSide, ArmSide.right);
    });

    test('falls back to the only valid side', () {
      feed(170, n: 3, leftLike: 0.2, rightLike: 0.8);
      expect(service.activeSide, ArmSide.right);
      expect(service.isBodyVisible, isTrue);
    });

    test('does not flip sides on a tiny confidence difference', () {
      feed(170, n: 3, leftLike: 0.9, rightLike: 0.85);
      expect(service.activeSide, ArmSide.left);
      feed(170, n: 3, leftLike: 0.88, rightLike: 0.90);
      expect(service.activeSide, ArmSide.left); // within 0.05 margin
      feed(170, n: 3, leftLike: 0.70, rightLike: 0.95);
      expect(service.activeSide, ArmSide.right); // clearly better
    });

    test('watchdog fails after >15 s aggregate invisibility', () {
      var failedCalls = 0;
      service.onWatchdogFailed = () => failedCalls++;
      service.startChallenge();

      feed(170, n: 3, leftLike: 0.1, rightLike: 0.1, stepMs: 500);
      feed(170, n: 20, leftLike: 0.1, rightLike: 0.1, stepMs: 500);
      expect(service.watchdogFailed, isFalse); // ~11.5 s

      feed(170, n: 20, leftLike: 0.1, rightLike: 0.1, stepMs: 500);
      expect(service.watchdogFailed, isTrue);
      expect(failedCalls, 1); // fired exactly once
    });

    test('watchdog time is aggregate across separate dropouts', () {
      service.startChallenge();
      for (var i = 0; i < 3; i++) {
        feed(170, n: 3); // visible
        feed(170, n: 11, leftLike: 0.1, rightLike: 0.1, stepMs: 500); // ~5 s
      }
      expect(service.watchdogFailed, isFalse); // ~15 s minus grace periods
      feed(170, n: 3);
      feed(170, n: 6, leftLike: 0.1, rightLike: 0.1, stepMs: 500);
      expect(service.watchdogFailed, isTrue);
    });

    test('stalled camera gaps are capped, not counted in full', () {
      service.startChallenge();
      feed(170, n: 3, leftLike: 0.1, rightLike: 0.1, stepMs: 33);
      // One 60 s gap between frames must add at most 1 s.
      feed(170, n: 1, leftLike: 0.1, rightLike: 0.1, stepMs: 60000);
      expect(service.invisibleDuration.inMilliseconds, lessThan(2000));
      expect(service.watchdogFailed, isFalse);
    });

    test('publishes a PoseFrame with the smoothed angle', () {
      feed(170, n: 3);
      expect(service.frameNotifier.value, isNotNull);
      expect(service.currentAngle, closeTo(170, 0.01));
    });
  });

  group('yuv420ToNv21', () {
    test('handles padded Y rows and semi-planar chroma (pixelStride 2)', () {
      const width = 4;
      const height = 4;
      const yStride = 6;
      final y = Uint8List(yStride * height);
      for (var r = 0; r < height; r++) {
        for (var c = 0; c < yStride; c++) {
          y[r * yStride + c] = c < width ? r * 10 + c : 255; // 255 = padding
        }
      }
      final u = Uint8List.fromList([1, 0, 2, 0, 3, 0, 4, 0]);
      final v = Uint8List.fromList([11, 0, 12, 0, 13, 0, 14, 0]);

      final out = PoseDetectorService.yuv420ToNv21(
        width: width,
        height: height,
        yBytes: y,
        yRowStride: yStride,
        uBytes: u,
        vBytes: v,
        uvRowStride: 4,
        uvPixelStride: 2,
      );

      expect(out.length, width * height * 3 ~/ 2);
      final expectedY = [
        for (var r = 0; r < height; r++)
          for (var c = 0; c < width; c++) r * 10 + c,
      ];
      expect(out.sublist(0, 16), expectedY);
      expect(out.sublist(16), [11, 1, 12, 2, 13, 3, 14, 4]); // V,U pairs
    });

    test('handles planar chroma (pixelStride 1)', () {
      final out = PoseDetectorService.yuv420ToNv21(
        width: 2,
        height: 2,
        yBytes: Uint8List.fromList([1, 2, 3, 4]),
        yRowStride: 2,
        uBytes: Uint8List.fromList([50]),
        vBytes: Uint8List.fromList([60]),
        uvRowStride: 1,
        uvPixelStride: 1,
      );
      expect(out, [1, 2, 3, 4, 60, 50]);
    });
  });
}