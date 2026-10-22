import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/alarm_scheduler_service.dart';
import '../providers/challenge_provider.dart';
import '../widgets/skeleton_painter.dart';

/// Full-screen ring + push-up challenge. Pass the [RingEvent] from
/// `AlarmSchedulerService.ringEvents` or `currentlyRinging()`.
class ChallengeScreen extends StatelessWidget {
  const ChallengeScreen({super.key, required this.ring});

  final RingEvent ring;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ChallengeProvider>(
      create: (_) {
        final p = ChallengeProvider(ring: ring);
        unawaited(p.initCamera());
        return p;
      },
      child: const _ChallengeView(),
    );
  }
}

class _ChallengeView extends StatefulWidget {
  const _ChallengeView();

  @override
  State<_ChallengeView> createState() => _ChallengeViewState();
}

class _ChallengeViewState extends State<_ChallengeView> {
  late final ChallengeProvider _provider;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _provider = context.read<ChallengeProvider>();
    _provider.addListener(_onProviderChanged);
  }

  @override
  void dispose() {
    _provider.removeListener(_onProviderChanged);
    SystemChrome.setPreferredOrientations(const []);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onProviderChanged() {
    if (!_provider.finished || _closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(_provider.outcome);
      } else {
        SystemNavigator.pop(); // opened as root by the full-screen intent
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // The alarm can only end through the challenge (or the camera fallback).
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Consumer<ChallengeProvider>(
          builder: (context, p, _) => Stack(
            fit: StackFit.expand,
            children: [
              _CameraLayer(p: p),
              const _Scrim(),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    children: [
                      _TopBar(p: p),
                      Expanded(child: Center(child: _CenterBanner(p: p))),
                      _BottomPanel(p: p),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Camera + skeleton
// ---------------------------------------------------------------------------

class _CameraLayer extends StatelessWidget {
  const _CameraLayer({required this.p});
  final ChallengeProvider p;

  @override
  Widget build(BuildContext context) {
    final c = p.cameraController;
    if (p.cameraStatus == CameraStatus.error ||
        c == null ||
        !c.value.isInitialized ||
        c.value.previewSize == null) {
      return Container(
        color: const Color(0xFF101418),
        alignment: Alignment.center,
        child: p.cameraStatus == CameraStatus.error
            ? const Icon(Icons.videocam_off, color: Colors.white24, size: 96)
            : const CircularProgressIndicator(),
      );
    }

    // previewSize is landscape; the screen is locked to portrait.
    final size = c.value.previewSize!;
    final pose = p.pose;
    return RepaintBoundary(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.height,
          height: size.width,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(c),
              if (p.showSkeleton && pose != null)
                SkeletonOverlay(frameListenable: pose.frameNotifier),
            ],
          ),
        ),
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xB3000000), Color(0x00000000), Color(0xCC000000)],
            stops: [0.0, 0.45, 1.0],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar: phase chip + debug toggle
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({required this.p});
  final ChallengeProvider p;

  static const _labels = {
    ChallengePhase.ringing: 'ALARM RINGING',
    ChallengePhase.preparationCountdown: 'GET READY',
    ChallengePhase.inProgress: 'PUSH-UPS',
    ChallengePhase.success: 'COMPLETE',
    ChallengePhase.failure: 'FAILED',
  };

  static const _colors = {
    ChallengePhase.ringing: Colors.orangeAccent,
    ChallengePhase.preparationCountdown: Colors.amber,
    ChallengePhase.inProgress: Colors.lightBlueAccent,
    ChallengePhase.success: Colors.greenAccent,
    ChallengePhase.failure: Colors.redAccent,
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[p.phase]!;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            _labels[p.phase]!,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              fontSize: 12,
            ),
          ),
        ),
        const Spacer(),
        const Text('Skeleton',
            style: TextStyle(color: Colors.white70, fontSize: 12)),
        Switch(
          key: const Key('skeleton_toggle'),
          value: p.showSkeleton,
          onChanged: p.setShowSkeleton,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Centre banner (phase specific)
// ---------------------------------------------------------------------------

class _CenterBanner extends StatelessWidget {
  const _CenterBanner({required this.p});
  final ChallengeProvider p;

  @override
  Widget build(BuildContext context) {
    switch (p.phase) {
      case ChallengePhase.ringing:
        return _ringingInfo(context);
      case ChallengePhase.preparationCountdown:
        final secs = (p.prepRemainingMs / 1000).ceil().clamp(0, 99);
        return _Glass(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Get into push-up position',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
              const SizedBox(height: 4),
              Text('$secs',
                  key: const Key('prep_countdown'),
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 96,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  )),
              const Text('Challenge starts in…',
                  style: TextStyle(color: Colors.white70)),
            ],
          ),
        );
      case ChallengePhase.inProgress:
        return const SizedBox.shrink();
      case ChallengePhase.success:
        return const _Glass(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, color: Colors.greenAccent, size: 84),
              SizedBox(height: 8),
              Text('Alarm dismissed',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        );
      case ChallengePhase.failure:
        final secs = (p.penaltyRemainingMs / 1000).ceil();
        final why = p.failureReason == FailureReason.bodyLost
            ? 'You were out of view too long.'
            : "Time's up.";
        return _Glass(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.alarm_on, color: Colors.redAccent, size: 72),
              const SizedBox(height: 8),
              Text(why,
                  style: const TextStyle(color: Colors.white, fontSize: 18)),
              const SizedBox(height: 4),
              Text('Alarm stops in ${secs}s',
                  style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              SizedBox(
                width: 220,
                child: LinearProgressIndicator(
                  value: p.penaltyFraction,
                  color: Colors.redAccent,
                  backgroundColor: Colors.white12,
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _ringingInfo(BuildContext context) {
    final alarm = p.ring.alarm;
    final t = alarm?.time;
    final timeText = t == null
        ? '--:--'
        : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return _Glass(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(p.ring.isSnoozeRing ? 'Snooze over' : 'Wake up!',
              style: const TextStyle(color: Colors.white70, fontSize: 16)),
          Text(timeText,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 64,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            '${p.targetReps} push-ups in ${p.challengeTotalMs ~/ 1000}s to dismiss',
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom panel (phase specific controls + camera fallback)
// ---------------------------------------------------------------------------

class _BottomPanel extends StatelessWidget {
  const _BottomPanel({required this.p});
  final ChallengeProvider p;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    switch (p.phase) {
      case ChallengePhase.ringing:
        children.addAll(_ringingControls());
      case ChallengePhase.preparationCountdown:
        children.add(_repCounter(dim: true));
      case ChallengePhase.inProgress:
        children.addAll(_progress());
      case ChallengePhase.success:
      case ChallengePhase.failure:
        break;
    }

    if (p.showCameraFallback) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 12));
      children.addAll(_cameraFallback());
    }

    if (children.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }

  List<Widget> _ringingControls() {
    final cameraBusy = p.cameraStatus == CameraStatus.initializing;
    return [
      if (p.message != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(p.message!,
              style: const TextStyle(color: Colors.orangeAccent)),
        ),
      if (p.cameraStatus != CameraStatus.error)
        SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton.icon(
            key: const Key('start_challenge'),
            onPressed: p.canStart ? p.startChallenge : null,
            icon: cameraBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fitness_center),
            label: Text(cameraBusy ? 'Preparing camera…' : 'Start Challenge',
                style: const TextStyle(fontSize: 18)),
          ),
        ),
      if (p.canSnooze) ...[
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            key: const Key('snooze'),
            onPressed: p.snooze,
            icon: const Icon(Icons.snooze),
            label: Text(
              'Snooze ${p.ring.alarm?.snoozeMinutes ?? 5} min (1 left)',
            ),
          ),
        ),
      ],
    ];
  }

  Widget _repCounter({bool dim = false}) {
    return Text(
      '${p.reps} / ${p.targetReps}',
      key: const Key('rep_counter'),
      style: TextStyle(
        color: dim ? Colors.white54 : Colors.white,
        fontSize: 64,
        fontWeight: FontWeight.w800,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  List<Widget> _progress() {
    final secs = (p.remainingMs / 1000).ceil();
    final paused = p.isTimerPaused;
    final low = p.timeFraction < 0.25;
    final barColor = paused
        ? Colors.amber
        : low
            ? Colors.redAccent
            : Colors.lightBlueAccent;
    return [
      if (paused) _warningBadge(),
      _repCounter(),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                key: const Key('time_bar'),
                value: p.timeFraction,
                minHeight: 12,
                color: barColor,
                backgroundColor: Colors.white24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 52,
            child: Text(
              '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _warningBadge() {
    final used = (p.pausedMs / 1000).toStringAsFixed(1);
    final max = p.maxPausedDuration.inSeconds;
    return Container(
      key: const Key('body_warning'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade700,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.black87),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Body Not Detected - Timer Paused  ($used / ${max}s)',
              style: const TextStyle(
                  color: Colors.black87, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _cameraFallback() {
    return [
      Text(
        'Camera problem: ${p.cameraError ?? 'unknown error'}',
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
      ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        height: 56,
        child: FilledButton.icon(
          key: const Key('dismiss_camera_error'),
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
          onPressed: p.dismissCameraError,
          icon: const Icon(Icons.videocam_off),
          label: const Text('Dismiss (Camera Error)',
              style: TextStyle(fontSize: 18)),
        ),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------

class _Glass extends StatelessWidget {
  const _Glass({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}