import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Outcome of the location-permission flow. The caller starts attendance only
/// for [grantedFull] or [grantedForegroundOnly]; the two denied cases already
/// had their messaging shown by the service.
enum PermissionResult {
  grantedFull, // "Allow all the time" (background) — best accuracy
  grantedForegroundOnly, // "While using the app" — works in foreground
  denied, // denied this time (can ask again)
  deniedForever, // permanently denied — needs app settings
}

/// Owns the full location-permission UX for attendance START. It shows its own
/// rationale sheets, denial snackbars, and the permanent-denial dialog, so the
/// caller just awaits [requestLocationPermissions] and branches on the enum.
///
/// Built on `geolocator` only (already a dependency): `LocationPermission.always`
/// == background granted, `whileInUse` == foreground only. No `permission_handler`
/// dependency needed.
class PermissionService {
  PermissionService._();
  static final PermissionService instance = PermissionService._();

  static const _kManufacturerCardShown = 'autostart_card_shown_v1';

  /// Full flow: rationale → request → background soft-prompt → manufacturer
  /// hint. Returns the resolved [PermissionResult]. UI messaging for the denied
  /// cases is shown here; the caller must NOT start attendance for those.
  Future<PermissionResult> requestLocationPermissions(
    BuildContext context,
  ) async {
    // Step 0 — device location services must be on at all.
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (context.mounted) {
        await _openSettingsDialog(
          context,
          title: 'Turn on location',
          body: 'Location services are off. Turn them on to start attendance.',
          onOpen: Geolocator.openLocationSettings,
        );
      }
      return PermissionResult.denied;
    }

    // Step 1 — current status.
    var status = await Geolocator.checkPermission();

    // Step 2 — rationale FIRST when we'll be prompting.
    if (status == LocationPermission.denied ||
        status == LocationPermission.deniedForever) {
      if (!context.mounted) return PermissionResult.denied;
      final proceed = await _rationaleSheet(
        context,
        title: 'Location Access Required',
        body: 'FieldTrack needs your location to track your attendance and '
            'field visits. Your location is only recorded during work hours.',
        confirmLabel: 'Allow Location',
      );
      if (proceed != true) {
        if (context.mounted) {
          _snack(context, 'Location permission required to start attendance.');
        }
        return PermissionResult.denied;
      }

      // Step 3 — request (system dialog).
      status = await Geolocator.requestPermission();
    }

    // Step 3 outcomes.
    if (status == LocationPermission.denied) {
      if (context.mounted) {
        _snack(context,
            'Location permission denied. Please allow location access to use attendance.');
      }
      return PermissionResult.denied;
    }
    if (status == LocationPermission.deniedForever) {
      if (context.mounted) {
        await _openSettingsDialog(
          context,
          title: 'Location permission needed',
          body: 'Location is permanently denied. Please enable it in your '
              "phone's settings.",
          onOpen: Geolocator.openAppSettings,
        );
      }
      return PermissionResult.deniedForever;
    }

    // Foreground granted (whileInUse or always). Manufacturer hint (one-time).
    if (context.mounted) await _maybeShowManufacturerCard(context);

    // Step 4 — background ("always"). Soft prompt only; user can proceed.
    if (status == LocationPermission.always) {
      return PermissionResult.grantedFull;
    }

    if (context.mounted) {
      await _rationaleSheet(
        context,
        title: 'Background Location',
        body: "For accurate tracking while your screen is off, FieldTrack "
            "needs 'Allow all the time' location access. Please select this "
            'option.',
        confirmLabel: 'Open Location Settings',
        onConfirm: Geolocator.openLocationSettings,
        dismissLabel: 'Later',
        soft: true,
      );
    }
    return PermissionResult.grantedForegroundOnly;
  }

  // ── Manufacturer autostart hint (Xiaomi/Oppo/Vivo/Realme) ────────────────
  Future<void> _maybeShowManufacturerCard(BuildContext context) async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kManufacturerCardShown) == true) return;

    String manufacturer = '';
    try {
      manufacturer =
          (await DeviceInfoPlugin().androidInfo).manufacturer.toLowerCase();
    } catch (_) {
      return;
    }
    const aggressive = ['xiaomi', 'redmi', 'poco', 'oppo', 'vivo', 'realme', 'iqoo'];
    if (!aggressive.any(manufacturer.contains)) return;
    if (!context.mounted) return;

    await prefs.setBool(_kManufacturerCardShown, true);
    if (!context.mounted) return;
    await _rationaleSheet(
      context,
      title: 'Enable AutoStart',
      body: 'For uninterrupted tracking, please enable AutoStart for '
          "FieldTrack in your phone's settings. Without it, the system may "
          'stop location updates in the background.',
      confirmLabel: 'Open Settings',
      onConfirm: () async {
        // Best-effort: the app's system settings page (AutoStart lives near it
        // on these ROMs). Falls back silently if unavailable.
        try {
          await Geolocator.openAppSettings();
        } catch (_) {/* ignore */}
      },
      dismissLabel: 'Got it',
      soft: true,
    );
  }

  // ── UI helpers ───────────────────────────────────────────────────────────

  /// Rationale bottom sheet. Returns true if the confirm button was tapped.
  /// [soft] sheets are informational (dismiss still resolves the flow).
  Future<bool?> _rationaleSheet(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
    Future<void> Function()? onConfirm,
    String dismissLabel = 'Not now',
    bool soft = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: soft,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.location_on_rounded, color: scheme.primary),
              ),
              const SizedBox(height: 16),
              Text(title,
                  style: Theme.of(ctx).textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Text(body, style: Theme.of(ctx).textTheme.bodyMedium),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(dismissLabel,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        if (onConfirm != null) {
                          await onConfirm();
                        }
                        if (ctx.mounted) Navigator.of(ctx).pop(true);
                      },
                      child: Text(confirmLabel,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSettingsDialog(
    BuildContext context, {
    required String title,
    required String body,
    required Future<bool> Function() onOpen,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              await onOpen();
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
