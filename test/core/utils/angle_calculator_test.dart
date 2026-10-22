import 'package:flutter_test/flutter_test.dart';
// Adjust 'wakefit' if your pubspec `name:` differs.
import 'package:wakefit/core/utils/angle_calculator.dart';

void main() {
  group('AngleCalculator.threePointAngle', () {
    test('right angle is 90', () {
      final angle = AngleCalculator.threePointAngle(
        const Point3(0, 1),
        const Point3(0, 0),
        const Point3(1, 0),
      );
      expect(angle, closeTo(90.0, 1e-9));
    });

    test('straight arm is 180', () {
      final angle = AngleCalculator.threePointAngle(
        const Point3(-1, 0),
        const Point3(0, 0),
        const Point3(1, 0),
      );
      expect(angle, closeTo(180.0, 1e-9));
    });

    test('fully folded arm is 0', () {
      final angle = AngleCalculator.threePointAngle(
        const Point3(1, 0),
        const Point3(0, 0),
        const Point3(2, 0),
      );
      expect(angle, closeTo(0.0, 1e-9));
    });

    test('45 degrees', () {
      final angle = AngleCalculator.threePointAngle(
        const Point3(1, 0),
        const Point3(0, 0),
        const Point3(1, 1),
      );
      expect(angle, closeTo(45.0, 1e-9));
    });

    test('uses z when use3D is true', () {
      final angle = AngleCalculator.threePointAngle(
        const Point3(1, 0, 0),
        const Point3(0, 0, 0),
        const Point3(0, 0, 1),
      );
      expect(angle, closeTo(90.0, 1e-9));
    });

    test('ignores z when use3D is false (c collapses onto b -> null)', () {
      final angle = AngleCalculator.threePointAngle(
        const Point3(1, 0, 0),
        const Point3(0, 0, 0),
        const Point3(0, 0, 1),
        use3D: false,
      );
      expect(angle, isNull);
    });

    test('degenerate (zero-length) vectors return null', () {
      expect(
        AngleCalculator.threePointAngle(
          const Point3(5, 5),
          const Point3(5, 5),
          const Point3(9, 1),
        ),
        isNull,
      );
    });

    test('is stable at 180 degrees with tiny numeric noise', () {
      final angle = AngleCalculator.threePointAngle(
        const Point3(-100, 0.0000001),
        const Point3(0, 0),
        const Point3(100, 0),
      );
      expect(angle, greaterThan(179.99));
      expect(angle, lessThanOrEqualTo(180.0));
    });
  });

  group('MovingAverage', () {
    test('averages over a 3-sample window', () {
      final avg = MovingAverage(windowSize: 3);
      expect(avg.value, isNull);
      expect(avg.add(10), closeTo(10, 1e-9));
      expect(avg.add(20), closeTo(15, 1e-9));
      expect(avg.add(30), closeTo(20, 1e-9));
      expect(avg.add(40), closeTo(30, 1e-9)); // (20 + 30 + 40) / 3
      expect(avg.length, 3);
    });

    test('reset clears history', () {
      final avg = MovingAverage()..add(100)..add(100);
      avg.reset();
      expect(avg.value, isNull);
      expect(avg.add(10), closeTo(10, 1e-9));
    });
  });

  group('SmoothedAngleCalculator', () {
    test('smooths a single-frame spike', () {
      final calc = SmoothedAngleCalculator();
      const shoulder = Point3(0, 0);
      const elbow = Point3(100, 0);
      // 180 degrees (straight).
      expect(calc.update(shoulder, elbow, const Point3(200, 0)),
          closeTo(180, 1e-9));
      expect(calc.update(shoulder, elbow, const Point3(200, 0)),
          closeTo(180, 1e-9));
      // One frame of 90 degrees: mean = (180 + 180 + 90) / 3 = 150.
      expect(calc.update(shoulder, elbow, const Point3(100, 100)),
          closeTo(150, 1e-9));
    });

    test('degenerate input returns null and keeps history', () {
      final calc = SmoothedAngleCalculator();
      calc.update(const Point3(0, 0), const Point3(100, 0), const Point3(200, 0));
      final result = calc.update(
        const Point3(100, 0),
        const Point3(100, 0),
        const Point3(200, 0),
      );
      expect(result, isNull);
      expect(calc.current, closeTo(180, 1e-9));
    });
  });
}