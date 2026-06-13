import 'package:battery_plus/battery_plus.dart';

/// Battery level reads for location records + the adaptive cadence.
/// (battery_plus added to pubspec for this — there is no battery API in the
/// spec'd package list; flagged in the pubspec comment.)
class BatteryInfo {
  BatteryInfo._();
  static final BatteryInfo instance = BatteryInfo._();

  final Battery _battery = Battery();

  static const lowBatteryThreshold = 20;

  /// Returns 0-100, or null if the platform read fails (never throws —
  /// a battery read must not be the reason a location point is lost).
  Future<int?> level() async {
    try {
      return await _battery.batteryLevel;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isLow() async {
    final l = await level();
    return l != null && l < lowBatteryThreshold;
  }
}
