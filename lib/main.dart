import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:wakefit/data/models/alarm_model.dart';
import 'package:wakefit/data/repositories/alarm_repository.dart';
import 'package:wakefit/presentation/providers/alarm_provider.dart';
import 'package:wakefit/presentation/providers/challenge_provider.dart'
    show ChallengeOutcome;
import 'package:wakefit/presentation/screens/challenge_screen.dart';
import 'package:wakefit/presentation/screens/home_screen.dart';
import 'package:wakefit/presentation/screens/standalone_test_screen.dart';
import 'package:wakefit/services/alarm_scheduler_service.dart';

abstract final class Routes {
  static const home = '/';
  static const challenge = '/challenge'; // arguments: RingEvent
  static const testPushup = '/test_pushup';
}

final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hive.initFlutter() + adapter registration happen inside openBox()
  // (it also recreates the box if it is corrupt).
  final Box<AlarmModel> box = await AlarmModel.openBox();

  // Scheduler init also runs recoverAlarms() (reboot / update recovery).
  // A failure here must not brick the app, so log and carry on.
  RingEvent? ringing;
  try {
    await AlarmSchedulerService.instance.init(box: box);
    // Cold start through the full-screen intent: is an alarm ringing right now?
    ringing = await AlarmSchedulerService.instance.currentlyRinging();
  } catch (e, st) {
    debugPrint('Alarm scheduler init failed: $e\n$st');
  }

  runApp(WakeFitApp(box: box, initialRing: ringing));
}

class WakeFitApp extends StatefulWidget {
  const WakeFitApp({super.key, required this.box, this.initialRing});

  final Box<AlarmModel> box;

  /// Non-null when the process was started by (or found) a ringing alarm.
  final RingEvent? initialRing;

  @override
  State<WakeFitApp> createState() => _WakeFitAppState();
}

class _WakeFitAppState extends State<WakeFitApp> with WidgetsBindingObserver {
  late final AlarmRepository _repo = AlarmRepository(box: widget.box);
  late final AlarmProvider _alarms = AlarmProvider(repository: _repo);

  /// nativeId of the alarm whose challenge is on screen; guards against the
  /// same ring arriving twice (initial check + handler + resume/poll check).
  int? _showingNativeId;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_alarms.loadAlarms());

    // Cold start: the challenge is built on top of home in _initialRoutes, so
    // it is already "showing". Cleared when that route is popped.
    _showingNativeId = widget.initialRing?.nativeId;

    // Warm / background: the scheduler calls this directly on every ring (and
    // replays a ring that arrived before this line ran).
    AlarmSchedulerService.instance.ringHandler = _onRing;

    if (widget.initialRing == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Ask up front: a permission dialog must never appear mid-alarm.
        unawaited(_requestPermissions());
        // The native ring state can lag the first Dart frame after a
        // full-screen-intent launch, so look again for a few seconds.
        unawaited(_pollForRing());
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AlarmSchedulerService.instance.ringHandler = null;
    _alarms.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The full-screen intent brings an already-running process to the front;
    // resuming is the moment to check whether an alarm is ringing.
    if (state == AppLifecycleState.resumed) {
      unawaited(_pollForRing(attempts: 5));
    }
  }

  Future<void> _pollForRing({int attempts = 8}) async {
    if (_polling || _showingNativeId != null) return;
    _polling = true;
    try {
      final ring = await AlarmSchedulerService.instance
          .waitForRinging(attempts: attempts);
      if (ring != null) _onRing(ring);
    } finally {
      _polling = false;
    }
  }

  Future<void> _requestPermissions() async {
    try {
      // Exact-alarm permission is handled by the scheduler when scheduling.
      await [Permission.notification, Permission.camera].request();
    } catch (e) {
      debugPrint('Permission request failed: $e');
    }
  }

  // ----- challenge presentation -------------------------------------------

  /// Builds the challenge route. [exitWhenDone] closes the app after the
  /// challenge so it doesn't sit on top of the lock screen.
  MaterialPageRoute<ChallengeOutcome> _challengeRoute(
    RingEvent ring, {
    required bool exitWhenDone,
  }) {
    final route = MaterialPageRoute<ChallengeOutcome>(
      settings: RouteSettings(name: Routes.challenge, arguments: ring),
      fullscreenDialog: true,
      builder: (_) => ChallengeScreen(ring: ring),
    );
    unawaited(route.popped.whenComplete(() {
      _showingNativeId = null;
      _alarms.reload(); // one-time alarm switched off, snooze count, ...
      if (exitWhenDone) SystemNavigator.pop();
    }));
    return route;
  }

  /// Pushes the challenge over whatever is showing (home, lock screen, ...).
  void _onRing(RingEvent ring) {
    if (_showingNativeId != null) return;

    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      // Navigator not mounted yet; retry after the first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _onRing(ring));
      return;
    }

    final wasForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _showingNativeId = ring.nativeId;
    unawaited(nav.push(_challengeRoute(ring, exitWhenDone: !wasForeground)));
  }

  // ----- routing ----------------------------------------------------------

  List<Route<dynamic>> _initialRoutes(String initialRoute) {
    final home = _buildRoute(const RouteSettings(name: Routes.home));
    final ring = widget.initialRing;
    if (ring == null) return [home];
    // Challenge goes straight on top: the dashboard is never shown. Home sits
    // underneath only so the route can be popped normally (which clears
    // _showingNativeId); the app then exits via SystemNavigator.pop().
    return [home, _challengeRoute(ring, exitWhenDone: true)];
  }

  Route<dynamic> _buildRoute(RouteSettings settings) {
    switch (settings.name) {
      case Routes.challenge:
        final ring = settings.arguments;
        if (ring is RingEvent) {
          return _challengeRoute(ring, exitWhenDone: false);
        }
        break; // missing/invalid arguments -> fall back to home
      case Routes.testPushup:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const StandaloneTestScreen(),
        );
      case Routes.home:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const HomeScreen(),
        );
    }
    return MaterialPageRoute<void>(
      settings: const RouteSettings(name: Routes.home),
      builder: (_) => const HomeScreen(),
    );
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF6D00),
          brightness: brightness,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AlarmRepository>.value(value: _repo),
        Provider<AlarmSchedulerService>.value(
          value: AlarmSchedulerService.instance,
        ),
        ChangeNotifierProvider<AlarmProvider>.value(value: _alarms),
      ],
      child: MaterialApp(
        title: 'WakeFit',
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: ThemeMode.system,
        onGenerateInitialRoutes: _initialRoutes,
        onGenerateRoute: _buildRoute,
      ),
    );
  }
}