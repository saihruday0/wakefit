import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakefit/presentation/widgets/skeleton_painter.dart';
import 'package:wakefit/services/pose_detector_service.dart';

/// Practice / calibration screen: live camera + pose detection + rep counter,
/// with no alarm involved.
///
/// Uses PoseDetectorService exactly like the challenge does:
///   createController -> initialize -> start(controller) -> startChallenge()
/// `startChallenge()` is what arms rep counting (before it, detection and the
/// skeleton run but nothing counts). The body-lost watchdog is effectively
/// disabled here (`maxInvisibleDuration`) because this is a practice screen.
class StandaloneTestScreen extends StatefulWidget {
  const StandaloneTestScreen({super.key});

  @override
  State<StandaloneTestScreen> createState() => _StandaloneTestScreenState();
}

class _StandaloneTestScreenState extends State<StandaloneTestScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  PoseDetectorService? _pose;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;

  bool _starting = false;
  bool _permissionDenied = false;
  bool _permanentlyDenied = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Preview, painter and ML Kit rotation are all computed for portrait.
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    unawaited(_init());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(const []);
    unawaited(_releaseCamera(rebuild: false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_releaseCamera());
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null && _cameras.isNotEmpty && !_permissionDenied) {
        unawaited(_startCamera());
      }
    }
  }

  // ----- camera lifecycle -------------------------------------------------

  void _retry() {
    setState(() {
      _error = null;
      _permissionDenied = false;
      _permanentlyDenied = false;
    });
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;
      if (!status.isGranted) {
        setState(() {
          _permissionDenied = true;
          _permanentlyDenied = status.isPermanentlyDenied || status.isRestricted;
        });
        return;
      }
      _cameras = await availableCameras();
      if (!mounted) return;
      if (_cameras.isEmpty) {
        setState(() => _error = 'No camera found on this device.');
        return;
      }
      // Prefer the front camera: you can see the screen in push-up position.
      final front =
          _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.front);
      _cameraIndex = front >= 0 ? front : 0;
      await _startCamera();
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera error: $e');
    }
  }

  Future<void> _startCamera() async {
    if (_starting || _cameras.isEmpty || !mounted) return;
    _starting = true;
    await _releaseCamera();
    if (!mounted) {
      _starting = false;
      return;
    }

    final description = _cameras[_cameraIndex];
    final controller = PoseDetectorService.createController(description);
    PoseDetectorService? pose;
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      pose = PoseDetectorService(
        camera: description,
        maxInvisibleDuration: const Duration(days: 1), // no watchdog in practice
      );
      await pose.start(controller);
      pose.startChallenge(); // arm rep counting
      _controller = controller;
      _pose = pose;
      setState(() => _error = null);
    } on CameraException catch (e) {
      pose?.dispose();
      await controller.dispose();
      _controller = null;
      _pose = null;
      if (mounted) {
        setState(() => _error = 'Camera error: ${e.description ?? e.code}');
      }
    } catch (e) {
      pose?.dispose();
      await controller.dispose();
      _controller = null;
      _pose = null;
      if (mounted) setState(() => _error = 'Camera error: $e');
    } finally {
      _starting = false;
    }
  }

  /// Order matters: drop references and rebuild first (so no widget touches a
  /// disposed controller), stop the image stream, dispose the pose service,
  /// and only then dispose the camera.
  Future<void> _releaseCamera({bool rebuild = true}) async {
    final pose = _pose;
    final controller = _controller;
    _pose = null;
    _controller = null;
    if (pose == null && controller == null) return;
    if (rebuild && mounted) setState(() {});
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

  // ----- actions ----------------------------------------------------------

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _startCamera();
  }

  /// startChallenge() resets reps, the state machine and the watchdog, and
  /// requires a freshly observed UP before the next rep can begin.
  void _resetCounter() => _pose?.startChallenge();

  void _finish() {
    final reps = _pose?.repCount ?? 0;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          'Test completed: $reps push-up${reps == 1 ? '' : 's'} counted.',
        ),
      ));
  }

  // ----- UI ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calibrate / Test Push-ups'),
        actions: [
          if (_cameras.length > 1)
            IconButton(
              tooltip: 'Switch camera',
              icon: const Icon(Icons.cameraswitch_outlined),
              onPressed: _starting ? null : _switchCamera,
            ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_permissionDenied) {
      return _Message(
        icon: Icons.no_photography_outlined,
        title: 'Camera permission needed',
        body:
            'WakeFit needs the camera to count your push-ups. Nothing is recorded or uploaded.',
        actionLabel: _permanentlyDenied ? 'Open settings' : 'Grant permission',
        onAction: _permanentlyDenied ? () => openAppSettings() : _retry,
      );
    }
    if (_error != null) {
      return _Message(
        icon: Icons.error_outline,
        title: 'Camera unavailable',
        body: _error!,
        actionLabel: 'Try again',
        onAction: _retry,
      );
    }

    final controller = _controller;
    final pose = _pose;
    if (controller == null || pose == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Expanded(
          child: ClipRect(
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: AspectRatio(
                // previewSize is landscape; the portrait preview is its inverse.
                // The overlay shares this exact box, so landmarks line up.
                aspectRatio: 1 / controller.value.aspectRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraPreview(controller),
                    SkeletonOverlay(
                      frameListenable: pose.frameNotifier,
                      showDebugAngle: true,
                    ),
                    Positioned(
                      left: 12,
                      top: 12,
                      child: ValueListenableBuilder<PoseFrame?>(
                        valueListenable: pose.frameNotifier,
                        builder: (_, frame, __) => _DebugPanel(frame: frame),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Place the phone on the floor, side-on, so your shoulders, elbows and wrists are all in view.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _resetCounter,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Reset counter'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _finish,
                      icon: const Icon(Icons.check),
                      label: const Text('Test completed'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Reads straight from PoseDetectorService's per-frame [PoseFrame].
class _DebugPanel extends StatelessWidget {
  const _DebugPanel({required this.frame});

  final PoseFrame? frame;

  @override
  Widget build(BuildContext context) {
    final f = frame;
    final reps = f?.repCount ?? 0;
    final angle = f?.angle;
    final state = f == null ? '--' : f.state.name.toUpperCase();
    final visible = f?.isBodyVisible ?? false;

    const mono =
        TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$reps',
            style: Theme.of(context)
                .textTheme
                .displayMedium
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const Text('REPS', style: mono),
          const SizedBox(height: 8),
          Text(
            'Elbow: ${angle == null ? '--' : '${angle.toStringAsFixed(0)}\u00B0'}',
            style: mono,
          ),
          Text('State: $state', style: mono),
          Text(
            visible ? 'Body: visible' : 'Body: not fully visible',
            style: mono.copyWith(
              color: visible ? Colors.lightGreenAccent : Colors.orangeAccent,
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: scheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}