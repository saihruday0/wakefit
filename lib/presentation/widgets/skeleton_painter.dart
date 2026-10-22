import 'dart:math' as math;

import 'package:camera/camera.dart' show CameraLensDirection;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart'
    show InputImageRotation;
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../../services/pose_detector_service.dart';

/// Draws shoulders, elbows, wrists and the connecting lines over the camera
/// preview. Repaints directly from [frameListenable] (no widget rebuilds).
///
/// Colours:
///  * green  - active arm (the one driving rep counting), confident
///  * cyan   - other arm, confident
///  * orange - landmark below the visibility threshold
///
/// In debug mode the active elbow gets an "angle + state" label.
///
/// IMPORTANT: the canvas must cover exactly the same area as the camera
/// preview (same size / aspect ratio, no cropping), otherwise the skeleton
/// will be offset. See [SkeletonOverlay].
class SkeletonPainter extends CustomPainter {
  SkeletonPainter({
    required this.frameListenable,
    bool? showDebugAngle,
    this.strokeWidth = 4.0,
    this.landmarkRadius = 7.0,
  })  : showDebugAngle = showDebugAngle ?? kDebugMode,
        super(repaint: frameListenable);

  final ValueListenable<PoseFrame?> frameListenable;
  final bool showDebugAngle;
  final double strokeWidth;
  final double landmarkRadius;

  static const Color _activeColor = Color(0xFF00E676);
  static const Color _passiveColor = Color(0xFF18FFFF);
  static const Color _lowConfidenceColor = Color(0xFFFF9100);

  static (PoseLandmarkType, PoseLandmarkType, PoseLandmarkType) _armTypes(
    ArmSide side,
  ) {
    return side == ArmSide.left
        ? (
            PoseLandmarkType.leftShoulder,
            PoseLandmarkType.leftElbow,
            PoseLandmarkType.leftWrist,
          )
        : (
            PoseLandmarkType.rightShoulder,
            PoseLandmarkType.rightElbow,
            PoseLandmarkType.rightWrist,
          );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final frame = frameListenable.value;
    if (frame == null) return;

    if (showDebugAngle && !frame.isBodyVisible) {
      _drawText(
        canvas,
        size,
        'BODY NOT VISIBLE',
        const Offset(12, 12),
        background: const Color(0xCCB71C1C),
      );
    }

    final pose = frame.pose;
    if (pose == null) return;

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;
    final dotPaint = Paint()..style = PaintingStyle.fill;

    final threshold = frame.visibilityThreshold;

    // --- Lines -------------------------------------------------------------
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
    if (leftShoulder != null && rightShoulder != null) {
      linePaint.color = _lineColor(leftShoulder, rightShoulder, threshold,
          active: false);
      canvas.drawLine(
        _translate(leftShoulder, size, frame),
        _translate(rightShoulder, size, frame),
        linePaint,
      );
    }

    for (final side in ArmSide.values) {
      final (s, e, w) = _armTypes(side);
      final shoulder = pose.landmarks[s];
      final elbow = pose.landmarks[e];
      final wrist = pose.landmarks[w];
      final isActive = frame.activeSide == side;

      if (shoulder != null && elbow != null) {
        linePaint.color =
            _lineColor(shoulder, elbow, threshold, active: isActive);
        canvas.drawLine(
          _translate(shoulder, size, frame),
          _translate(elbow, size, frame),
          linePaint,
        );
      }
      if (elbow != null && wrist != null) {
        linePaint.color = _lineColor(elbow, wrist, threshold, active: isActive);
        canvas.drawLine(
          _translate(elbow, size, frame),
          _translate(wrist, size, frame),
          linePaint,
        );
      }
    }

    // --- Landmarks (drawn after lines so dots sit on top) ------------------
    for (final side in ArmSide.values) {
      final (s, e, w) = _armTypes(side);
      final isActive = frame.activeSide == side;
      for (final type in [s, e, w]) {
        final lm = pose.landmarks[type];
        if (lm == null) continue;
        dotPaint.color = _pointColor(lm, threshold, active: isActive);
        canvas.drawCircle(
          _translate(lm, size, frame),
          landmarkRadius,
          dotPaint,
        );
      }
    }

    // --- Debug angle label near the active elbow ---------------------------
    if (showDebugAngle) {
      final side = frame.activeSide;
      final angle = frame.angle;
      if (side != null && angle != null) {
        final elbow = pose.landmarks[_armTypes(side).$2];
        if (elbow != null) {
          final at = _translate(elbow, size, frame);
          _drawText(
            canvas,
            size,
            '${angle.toStringAsFixed(0)}\u00B0 ${frame.state.name.toUpperCase()}',
            at + const Offset(14, -34),
          );
        }
      }
    }
  }

  Color _pointColor(PoseLandmark lm, double threshold, {required bool active}) {
    if (lm.likelihood < threshold) return _lowConfidenceColor;
    return active ? _activeColor : _passiveColor;
  }

  Color _lineColor(
    PoseLandmark a,
    PoseLandmark b,
    double threshold, {
    required bool active,
  }) {
    if (a.likelihood < threshold || b.likelihood < threshold) {
      return _lowConfidenceColor.withOpacity(0.6);
    }
    return (active ? _activeColor : _passiveColor).withOpacity(0.9);
  }

  /// Maps an ML Kit landmark (coordinates in the *rotated* image space) to
  /// canvas coordinates, mirroring for front cameras the same way the
  /// preview is mirrored.
  Offset _translate(PoseLandmark lm, Size canvas, PoseFrame frame) {
    final rotation = frame.rotation;
    final swapped = rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final rotatedWidth = swapped ? frame.imageSize.height : frame.imageSize.width;
    final rotatedHeight =
        swapped ? frame.imageSize.width : frame.imageSize.height;

    var x = lm.x * canvas.width / rotatedWidth;
    final y = lm.y * canvas.height / rotatedHeight;

    final mirror = switch (rotation) {
      InputImageRotation.rotation270deg => true,
      InputImageRotation.rotation90deg => false,
      _ => frame.lensDirection == CameraLensDirection.front,
    };
    if (mirror) x = canvas.width - x;
    return Offset(x, y);
  }

  void _drawText(
    Canvas canvas,
    Size size,
    String text,
    Offset position, {
    Color background = const Color(0xB3000000),
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const padX = 6.0;
    const padY = 3.0;
    final maxDx = math.max(padX, size.width - painter.width - padX);
    final maxDy = math.max(padY, size.height - painter.height - padY);
    final dx = math.min(math.max(position.dx, padX), maxDx);
    final dy = math.min(math.max(position.dy, padY), maxDy);

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          dx - padX,
          dy - padY,
          painter.width + padX * 2,
          painter.height + padY * 2,
        ),
        const Radius.circular(6),
      ),
      Paint()..color = background,
    );
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant SkeletonPainter oldDelegate) {
    return oldDelegate.frameListenable != frameListenable ||
        oldDelegate.showDebugAngle != showDebugAngle ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.landmarkRadius != landmarkRadius;
  }
}

/// Drop-in overlay: put it in a `Stack` on top of the `CameraPreview`, both
/// inside the same sized box, e.g.
///
/// ```dart
/// AspectRatio(
///   aspectRatio: 1 / controller.value.aspectRatio, // portrait
///   child: Stack(fit: StackFit.expand, children: [
///     CameraPreview(controller),
///     SkeletonOverlay(frameListenable: service.frameNotifier),
///   ]),
/// )
/// ```
class SkeletonOverlay extends StatelessWidget {
  const SkeletonOverlay({
    super.key,
    required this.frameListenable,
    this.showDebugAngle,
  });

  final ValueListenable<PoseFrame?> frameListenable;
  final bool? showDebugAngle;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: SkeletonPainter(
            frameListenable: frameListenable,
            showDebugAngle: showDebugAngle,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}