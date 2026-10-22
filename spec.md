# WakeFit Technical Specification (spec.md)

## 1. System Overview
WakeFit is an offline, zero-backend Android alarm app built in Flutter. Alarms can only be dismissed by completing a camera-verified push-up challenge.

## 2. Technical Stack
- Flutter SDK (latest stable) & Dart
- `alarm: ^4.0.0` (or `android_alarm_manager_plus` with custom full-screen Intent service)
- `google_mlkit_pose_detection: ^0.12.0`
- `camera: ^0.11.0+2`
- `hive_flutter: ^1.1.0` (for local persistence)
- `audioplayers: ^6.0.0`
- `permission_handler: ^11.3.0`
- `provider: ^6.1.2`

## 3. Data Models
### AlarmModel (Hive typeId: 0)
- `id`: int (unique ID)
- `time`: DateTime
- `isEnabled`: bool (default: true)
- `targetPushups`: int (default: 10)
- `challengeTimeoutSeconds`: int (default: 60)
- `snoozeMinutes`: int (default: 5)
- `snoozeCount`: int (default: 0, max: 1)
- `customAudioPath`: String? (null = default system sound)
- `muteDuringChallenge`: bool (default: true)
- `repeatDays`: List<int> (1=Mon ... 7=Sun)

## 4. Push-up State Machine & Angles
- Landmarks: Left/Right Shoulder, Left/Right Elbow, Left/Right Wrist.
- Angle calculation: $\angle(\text{shoulder}, \text{elbow}, \text{wrist})$ using 3D dot product/atan2.
- States:
  - `UP` state: Angle > 155°
  - `DOWN` state: Angle < 90°
- Transition rule: Rep incremented only on `UP -> DOWN -> UP`.
- Visibility Rule: Key landmarks must have confidence score >= 0.65.
- Watchdog: If user disappears for > 15s aggregate, challenge fails.

## 5. Alarm Ringing & Failure Rules
1. Pre-challenge: Alarm triggers full-screen activity over lock screen. Rings sound.
2. User taps "Start Challenge" -> 10-second prep countdown begins.
3. If `muteDuringChallenge == true`, sound stops during exercise.
4. Timer hits 0 without target met -> Alarm rings for 60s at max volume, then auto-shuts off.
5. If camera hardware error occurs -> Present instant fallback button: "Dismiss (Camera Error)".