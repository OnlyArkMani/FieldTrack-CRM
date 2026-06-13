import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin, BEST-EFFORT wrapper for the "sync is stuck" persistent notification.
///
/// Everything here is wrapped so a platform that isn't set up for local
/// notifications (or a missing channel) can never crash the sync engine — the
/// notification is a courtesy, not part of the data path.
class SyncNotifications {
  SyncNotifications._();
  static final SyncNotifications instance = SyncNotifications._();

  static const _channelId = 'fieldtrack_sync';
  static const _notificationId = 9100; // stable id => show/cancel the same one

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: darwin),
      );
      _initialized = true;
    } catch (e) {
      debugPrint('SyncNotifications init skipped: $e');
    }
  }

  /// Show / update the ongoing "sync failing" notification.
  Future<void> showSyncStuck({required int pendingCount}) async {
    await _ensureInit();
    if (!_initialized) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Sync',
          channelDescription: 'Background data sync status',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true, // persistent — can't be swiped away
          autoCancel: false,
          onlyAlertOnce: true,
          showWhen: false,
        ),
      );
      await _plugin.show(
        _notificationId,
        'FieldTrack — sync delayed',
        '$pendingCount record(s) waiting to upload. We’ll keep retrying.',
        details,
      );
    } catch (e) {
      debugPrint('SyncNotifications show skipped: $e');
    }
  }

  Future<void> dismiss() async {
    if (!_initialized) return;
    try {
      await _plugin.cancel(_notificationId);
    } catch (_) {/* best-effort */}
  }
}
