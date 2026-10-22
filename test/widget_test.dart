import 'package:flutter_test/flutter_test.dart';
import 'package:wakefit/services/pose_detector_service.dart';

void main() {
  test('push-up counts only on UP -> DOWN -> UP', () {
    final m = PushUpStateMachine();
    m.update(170); // UP
    m.update(80);  // DOWN
    expect(m.update(170), isTrue); // UP completes the rep
    expect(m.repCount, 1);
  });
}