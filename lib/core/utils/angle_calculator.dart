import 'dart:math' as math;

/// Minimal immutable 3D point used by the angle maths.
///
/// ML Kit landmarks expose x/y in image pixels and a rough z estimate
/// (same scale as x). Pass z = 0 for pure 2D maths.
class Point3 {
  const Point3(this.x, this.y, [this.z = 0.0]);

  final double x;
  final double y;
  final double z;
}

/// Stateless vector maths for joint angles.
class AngleCalculator {
  AngleCalculator._();

  static const double _epsilon = 1e-9;

  /// Interior angle at [b] (the vertex) between rays b->a and b->c, in
  /// degrees, range 0..180.
  ///
  /// Uses `atan2(|BA x BC|, BA . BC)`, which is numerically stable near 0°
  /// and 180° (unlike `acos(dot / (|BA||BC|))`, which blows up from rounding
  /// when the arm is fully extended - exactly where the UP threshold lives).
  ///
  /// Returns `null` when either ray has zero length (degenerate landmarks).
  /// Set [use3D] to false to ignore z (ML Kit's z is only an estimate and is
  /// noisier than x/y).
  static double? threePointAngle(
    Point3 a,
    Point3 b,
    Point3 c, {
    bool use3D = true,
  }) {
    final bax = a.x - b.x;
    final bay = a.y - b.y;
    final baz = use3D ? a.z - b.z : 0.0;

    final bcx = c.x - b.x;
    final bcy = c.y - b.y;
    final bcz = use3D ? c.z - b.z : 0.0;

    final lenBA = math.sqrt(bax * bax + bay * bay + baz * baz);
    final lenBC = math.sqrt(bcx * bcx + bcy * bcy + bcz * bcz);
    if (lenBA < _epsilon || lenBC < _epsilon) return null;

    final dot = bax * bcx + bay * bcy + baz * bcz;

    final crossX = bay * bcz - baz * bcy;
    final crossY = baz * bcx - bax * bcz;
    final crossZ = bax * bcy - bay * bcx;
    final crossMag =
        math.sqrt(crossX * crossX + crossY * crossY + crossZ * crossZ);

    return math.atan2(crossMag, dot) * 180.0 / math.pi;
  }
}

/// Fixed-window moving average. Default window is 3 frames: enough to kill
/// single-frame landmark jitter while adding only ~1 frame of lag.
class MovingAverage {
  MovingAverage({this.windowSize = 3})
      : assert(windowSize >= 1, 'windowSize must be >= 1'),
        _buffer = List<double>.filled(windowSize, 0.0);

  final int windowSize;
  final List<double> _buffer;
  int _count = 0;
  int _next = 0;

  /// Number of samples currently in the window (<= [windowSize]).
  int get length => _count;

  /// Mean of the current window, or null if no samples yet.
  double? get value => _count == 0 ? null : _mean();

  /// Adds [sample] and returns the new mean. Until the window is full, the
  /// mean is taken over the samples seen so far (no artificial zeros).
  double add(double sample) {
    _buffer[_next] = sample;
    _next = (_next + 1) % windowSize;
    if (_count < windowSize) _count++;
    return _mean();
  }

  void reset() {
    _count = 0;
    _next = 0;
  }

  double _mean() {
    // Recomputed each time (window is tiny) so no floating-point drift.
    var sum = 0.0;
    for (var i = 0; i < _count; i++) {
      sum += _buffer[i];
    }
    return sum / _count;
  }
}

/// Convenience wrapper: raw 3-point angle -> smoothed angle.
class SmoothedAngleCalculator {
  SmoothedAngleCalculator({int windowSize = 3, this.use3D = true})
      : _average = MovingAverage(windowSize: windowSize);

  final bool use3D;
  final MovingAverage _average;

  /// Latest smoothed angle, or null if nothing has been fed since [reset].
  double? get current => _average.value;

  /// Feeds one frame and returns the smoothed angle at [elbow].
  /// Returns null (and leaves the window untouched) if the geometry is
  /// degenerate.
  double? update(Point3 shoulder, Point3 elbow, Point3 wrist) {
    final raw = AngleCalculator.threePointAngle(
      shoulder,
      elbow,
      wrist,
      use3D: use3D,
    );
    if (raw == null) return null;
    return _average.add(raw);
  }

  /// Clear history (call when the arm was lost, so stale angles from before
  /// the gap are not blended with fresh ones).
  void reset() => _average.reset();
}