import 'package:flutter/material.dart';

import '../../services/pose_detector_service.dart';

/// Live readout of what the push-up detector sees. Rebuilds per frame via
/// [PoseDetectorService.frameNotifier] only (not the whole screen).
class PoseDebugHud extends StatelessWidget {
  const PoseDebugHud({super.key, required this.pose});

  final PoseDetectorService pose;

  static String _deg(double? v) => v == null ? '--' : '${v.round()}°';

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<PoseFrame?>(
        valueListenable: pose.frameNotifier,
        builder: (context, f, _) {
          final detected = f?.pose != null;
          final driving = f?.angle;
          final state = f?.state.name.toUpperCase() ?? '--';
          final stateColor = switch (f?.state) {
            PushUpState.up => Colors.greenAccent,
            PushUpState.down => Colors.orangeAccent,
            null => Colors.white54,
          };
          return Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: DefaultTextStyle(
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Elbow ${_deg(driving)}'
                    '${f?.usedBothArms == true ? ' (avg)' : ''}',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: driving == null ? Colors.white54 : Colors.white,
                    ),
                  ),
                  Text('L ${_deg(f?.leftAngle)}   R ${_deg(f?.rightAngle)}'),
                  Text('State $state   Reps ${pose.repCount}',
                      style: TextStyle(color: stateColor)),
                  Text(
                    detected ? 'Pose: detected' : 'Pose: NOT detected',
                    style: TextStyle(
                      color: detected ? Colors.white : Colors.redAccent,
                    ),
                  ),
                  Text('UP ≥155°  DOWN ≤95°   arm ≥'
                      '${(f?.visibilityThreshold ?? 0).toStringAsFixed(2)}'),
                  Text('rot ${pose.rotationDegrees}°'
                      '${pose.rotationLocked ? ' locked' : ' searching'}  '
                      '${f?.processingMs ?? 0} ms  '
                      'drop ${pose.droppedFrames}  '
                      'convFail ${pose.conversionFailures}'),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}