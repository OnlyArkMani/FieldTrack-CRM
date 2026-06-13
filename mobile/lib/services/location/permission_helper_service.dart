import 'package:android_intent_plus/android_intent.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Manufacturer-aware permission flow. Background GPS on Android dies in two
/// places: (1) missing OS permissions, (2) OEM "battery savers" that kill
/// foreground services (MIUI autostart, Samsung sleeping apps, ColorOS/
/// OxygenOS auto-launch). This service handles both.
///
/// FLOW (call [requestAllForTracking] before the first attendance START):
///   fine location -> background location ("Allow all the time") ->
///   battery-optimization exemption -> OEM-specific screen if needed.
class PermissionHelperService {
  PermissionHelperService._();
  static final PermissionHelperService instance = PermissionHelperService._();

  String? _manufacturerCache;

  Future<String> manufacturer() async {
    final cached = _manufacturerCache;
    if (cached != null) return cached;
    final info = await DeviceInfoPlugin().androidInfo;
    return _manufacturerCache = info.manufacturer.toLowerCase().trim();
  }

  // ── OS permissions ──────────────────────────────────────────────────────
  /// Returns true when tracking can run. Order matters: Android only shows
  /// "Allow all the time" AFTER fine location is granted (API 30+ sends the
  /// user to settings for it — that's OS behavior, not a bug).
  Future<TrackingPermissionResult> requestAllForTracking() async {
    if (!await Permission.location.request().isGranted) {
      return TrackingPermissionResult.locationDenied;
    }
    if (!await Permission.locationAlways.request().isGranted) {
      return TrackingPermissionResult.backgroundDenied;
    }
    // Battery optimization exemption (the Samsung/stock-Android killer).
    // ignore: avoid_redundant_argument_values
    await Permission.ignoreBatteryOptimizations.request();
    return TrackingPermissionResult.granted;
  }

  // ── OEM kill-list handling ─────────────────────────────────────────────
  /// True if this device's OEM needs a manual settings step beyond standard
  /// permissions. UI shows [instructionsFor] + an "Open settings" button
  /// wired to [openManufacturerSettings].
  Future<bool> needsManufacturerStep() async {
    final m = await manufacturer();
    return m.contains('xiaomi') ||
        m.contains('redmi') ||
        m.contains('poco') ||
        m.contains('oppo') ||
        m.contains('realme') ||
        m.contains('vivo') ||
        m.contains('oneplus') ||
        m.contains('samsung');
  }

  Future<String> instructionsFor() async {
    final m = await manufacturer();
    if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
      return 'MIUI stops background apps by default.\n\n'
          '1. Tap Open Settings below\n'
          '2. Enable "Autostart" for FieldTrack\n'
          '3. In Battery saver, set FieldTrack to "No restrictions"';
    }
    if (m.contains('oppo') || m.contains('realme')) {
      return 'ColorOS limits background apps.\n\n'
          '1. Tap Open Settings below\n'
          '2. Enable "Auto-launch" for FieldTrack\n'
          '3. Battery > FieldTrack > Allow background activity';
    }
    if (m.contains('vivo')) {
      return 'FunTouch OS limits background apps.\n\n'
          '1. Tap Open Settings below\n'
          '2. Enable autostart for FieldTrack\n'
          '3. Battery > High background power consumption > allow FieldTrack';
    }
    if (m.contains('oneplus')) {
      return 'OxygenOS battery optimization can stop tracking.\n\n'
          '1. Tap Open Settings below\n'
          '2. Battery > Battery optimization > FieldTrack > Don\'t optimize\n'
          '3. Disable "Advanced optimization" if tracking still stops';
    }
    if (m.contains('samsung')) {
      return 'Samsung may put FieldTrack to sleep.\n\n'
          '1. Tap Open Settings below\n'
          '2. Battery > Background usage limits\n'
          '3. Make sure FieldTrack is NOT in "Sleeping apps" and add it to '
          '"Never sleeping apps"';
    }
    return 'If tracking stops when the screen is off, open your battery '
        'settings and exclude FieldTrack from optimization.';
  }

  /// Deep link to the OEM's autostart/battery screen. Every component name
  /// here is undocumented OEM internals and can vanish in any OS update —
  /// hence the try/cascade ending at plain app settings (always works).
  Future<void> openManufacturerSettings() async {
    final m = await manufacturer();
    final candidates = <(String pkg, String cls)>[
      if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco'))
        (
          'com.miui.securitycenter',
          'com.miui.permcenter.autostart.AutoStartManagementActivity'
        ),
      if (m.contains('oppo') || m.contains('realme')) ...[
        (
          'com.coloros.safecenter',
          'com.coloros.safecenter.permission.startup.StartupAppListActivity'
        ),
        (
          'com.oppo.safe',
          'com.oppo.safe.permission.startup.StartupAppListActivity'
        ),
      ],
      if (m.contains('vivo'))
        (
          'com.vivo.permissionmanager',
          'com.vivo.permissionmanager.activity.BgStartUpManagerActivity'
        ),
      if (m.contains('oneplus'))
        (
          'com.oneplus.security',
          'com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity'
        ),
      // Samsung: no stable autostart activity — battery settings is the
      // right destination and the standard intent below covers it.
    ];

    for (final (pkg, cls) in candidates) {
      try {
        await AndroidIntent(
          action: 'android.intent.action.MAIN',
          package: pkg,
          componentName: cls,
        ).launch();
        return;
      } on PlatformException {
        continue; // component missing on this OS version — try next
      }
    }

    // Samsung + everyone else: standard battery-optimization settings,
    // falling back to the app's own settings page.
    try {
      await const AndroidIntent(
        action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
      ).launch();
    } on PlatformException {
      await openAppSettings();
    }
  }
}

enum TrackingPermissionResult { granted, locationDenied, backgroundDenied }
