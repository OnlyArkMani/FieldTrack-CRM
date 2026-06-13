import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/router/app_router.dart';
import '../../features/notifications/data/notification_repository.dart';

/// Background/terminated message handler. MUST be a top-level (or static)
/// function and annotated @pragma('vm:entry-point') — FCM spins up a fresh
/// isolate that calls it. We do NOT show a notification here: a message with a
/// `notification` block is rendered by the OS automatically when the app is
/// backgrounded. Data-only messages could be handled here later (e.g. silent
/// sync), so the hook exists.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Intentionally minimal — keep the isolate cheap. The in-app notifications
  // list (server-backed) is the source of truth when the user opens the app.
  debugPrint('FCM background message: ${message.messageId}');
}

/// THE FCM plumbing: permission, the foreground local-notification channel,
/// and turning a foreground RemoteMessage into a heads-up notification.
///
/// BEST-EFFORT throughout: a device without Play Services, a denied
/// permission, or an unconfigured Firebase project must never crash the app —
/// the server-backed in-app list still works. Push is only the nudge.
class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  static const _channelId = 'fieldtrack_push';
  static const _channelName = 'Alerts';
  static const _channelDescription =
      'Attendance reminders, GPS alerts and announcements';

  final _local = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Create the local-notification plugin + Android channel. Idempotent; safe
  /// to call from main() before runApp.
  Future<void> initialize({
    void Function(String? payloadType)? onLocalTap,
  }) async {
    if (_initialized) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _local.initialize(
        const InitializationSettings(android: android, iOS: darwin),
        onDidReceiveNotificationResponse: (resp) =>
            onLocalTap?.call(resp.payload),
      );
      // High-importance channel so foreground pushes pop a heads-up banner.
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.high,
            ),
          );
      _initialized = true;
    } catch (e) {
      debugPrint('FcmService init skipped: $e');
    }
  }

  /// Ask for notification permission. On Android 13+ (POST_NOTIFICATIONS) we
  /// show a short rationale FIRST when a context is available, so the user
  /// understands the ask before the system dialog — higher grant rates and the
  /// recommended UX. iOS shows its own dialog via requestPermission.
  Future<bool> requestPermission({BuildContext? rationaleContext}) async {
    try {
      final messaging = FirebaseMessaging.instance;
      final current = await messaging.getNotificationSettings();
      if (current.authorizationStatus == AuthorizationStatus.authorized ||
          current.authorizationStatus == AuthorizationStatus.provisional) {
        return true;
      }

      // Pre-permission rationale (Android 13+ / first ask) when we can show UI.
      if (rationaleContext != null &&
          rationaleContext.mounted &&
          Platform.isAndroid) {
        final proceed = await showDialog<bool>(
          context: rationaleContext,
          builder: (ctx) => AlertDialog(
            title: const Text('Stay in the loop'),
            content: const Text(
              'FieldTrack sends attendance reminders and important updates from '
              'your supervisor. Allow notifications to receive them.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
        if (proceed != true) return false;
      }

      final settings = await messaging.requestPermission();
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('FcmService permission request skipped: $e');
      return false;
    }
  }

  /// Render a foreground message as a heads-up local notification. (When
  /// backgrounded the OS draws it; foreground messages don't auto-display, so
  /// we do it here.)
  Future<void> showForeground(RemoteMessage message) async {
    if (!_initialized) await initialize();
    final notification = message.notification;
    if (notification == null) return; // data-only: nothing to show
    try {
      await _local.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: const AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: message.data['type'] as String?,
      );
    } catch (e) {
      debugPrint('FcmService showForeground skipped: $e');
    }
  }
}

/// App-level wiring: registers the device token, keeps it fresh, and routes
/// notification taps to the right screen. Watched by HomeShell so it lives for
/// the authenticated session and tears down on logout (token stays server-side
/// until the next login replaces it).
final fcmControllerProvider =
    NotifierProvider<FcmController, bool>(FcmController.new);

class FcmController extends Notifier<bool> {
  @override
  bool build() {
    Future.microtask(_start);
    return false; // "initialized?" — flips true once wiring completes
  }

  NotificationRepository get _repo => ref.read(notificationRepositoryProvider);

  Future<void> _start() async {
    final messaging = FirebaseMessaging.instance;

    await FcmService.instance.initialize(
      onLocalTap: (type) => _navigateForType(type, const {}),
    );

    // Permission (best-effort; no context at startup → system dialog only.
    // The Notifications screen re-prompts with a rationale if still denied).
    await FcmService.instance.requestPermission();

    // Register the current token, then keep it fresh (FCM rotates tokens).
    try {
      final token = await messaging.getToken();
      if (token != null) await _registerToken(token);
    } catch (e) {
      debugPrint('FCM getToken failed: $e');
    }
    messaging.onTokenRefresh.listen((t) {
      // ignore: discarded_futures
      _registerToken(t);
    });

    // Foreground: draw a heads-up notification ourselves.
    FirebaseMessaging.onMessage.listen(FcmService.instance.showForeground);

    // Tap (background → opened): deep-link.
    FirebaseMessaging.onMessageOpenedApp.listen(_handleOpened);

    // Cold start FROM a notification tap.
    final initial = await messaging.getInitialMessage();
    if (initial != null) _handleOpened(initial);

    state = true;
  }

  Future<void> _registerToken(String token) async {
    try {
      String? model;
      String? osVersion;
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        model = '${info.manufacturer} ${info.model}';
        osVersion = 'Android ${info.version.release} (SDK ${info.version.sdkInt})';
      } else if (Platform.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        model = info.utsname.machine;
        osVersion = '${info.systemName} ${info.systemVersion}';
      }
      String? appVersion;
      try {
        final pkg = await PackageInfo.fromPlatform();
        appVersion = '${pkg.version}+${pkg.buildNumber}';
      } catch (_) {/* non-fatal */}

      await _repo.registerDevice(
        fcmToken: token,
        deviceModel: model,
        osVersion: osVersion,
        appVersion: appVersion,
      );
    } catch (e) {
      debugPrint('FCM token registration failed: $e');
    }
  }

  void _handleOpened(RemoteMessage message) =>
      _navigateForType(message.data['type'] as String?, message.data);

  /// Map a notification's data to a route. `screen` (when present) wins; we
  /// fall back to a per-type default. Everything lands on a real screen so a
  /// tap is never a no-op.
  void _navigateForType(String? type, Map<String, dynamic> data) {
    final router = ref.read(routerProvider);
    final screen = data['screen'] as String?;
    final employeeId = data['employee_id'];

    String path;
    switch (screen) {
      case 'attendance':
        path = '/home/attendance';
      case 'dashboard':
        path = '/home/dashboard';
      case 'map':
        path = '/home/map';
      case 'employee':
        path = employeeId != null ? '/employee/$employeeId' : '/notifications';
      case 'notifications':
        path = '/notifications';
      default:
        path = switch (type) {
          'ATTENDANCE_REMINDER' || 'END_WORK_REMINDER' => '/home/attendance',
          'GPS_DISABLED' || 'GEOFENCE_ENTER' || 'GEOFENCE_EXIT' =>
            employeeId != null ? '/employee/$employeeId' : '/notifications',
          _ => '/notifications',
        };
    }
    router.go(path);
  }
}
