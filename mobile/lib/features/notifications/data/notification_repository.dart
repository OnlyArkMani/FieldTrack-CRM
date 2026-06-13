import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/app_notification.dart';

final notificationRepositoryProvider =
    Provider<NotificationRepository>((ref) {
  return NotificationRepository(ref.watch(apiClientProvider));
});

/// A page of notifications (mirrors the backend CursorPage envelope).
class NotificationPage {
  const NotificationPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    required this.total,
  });

  final List<AppNotification> items;
  final String? nextCursor;
  final bool hasMore;
  final int total;
}

class NotificationRepository {
  NotificationRepository(this._api);
  final ApiClient _api;

  Future<NotificationPage> list({String? cursor, int limit = 20}) async {
    final data = await _api.get('/notifications', query: {
      'limit': limit,
      if (cursor != null) 'cursor': cursor,
    });
    final rawItems = (data['items'] as List<dynamic>? ?? []);
    return NotificationPage(
      items: rawItems
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList(),
      nextCursor: data['next_cursor'] as String?,
      hasMore: (data['has_more'] ?? false) as bool,
      total: (data['total'] ?? 0) as int,
    );
  }

  Future<int> unreadCount() async {
    final data = await _api.get('/notifications/unread-count');
    return (data['unread'] ?? 0) as int;
  }

  /// Marks one read; returns the server's fresh unread count.
  Future<int> markRead(int id) async {
    final data = await _api.patch('/notifications/$id/read');
    return (data['unread'] ?? 0) as int;
  }

  Future<void> markAllRead() async {
    await _api.patch('/notifications/read-all');
  }

  /// Register/refresh this device's FCM token. Best-effort from the caller's
  /// side — failures are logged, never surfaced.
  Future<void> registerDevice({
    required String fcmToken,
    String? deviceModel,
    String? osVersion,
    String? appVersion,
  }) async {
    await _api.post('/devices/token', body: {
      'fcm_token': fcmToken,
      if (deviceModel != null) 'device_model': deviceModel,
      if (osVersion != null) 'os_version': osVersion,
      if (appVersion != null) 'app_version': appVersion,
    });
  }

  /// Tell the backend the user turned location off (best-effort; the employee
  /// gets no signal they were flagged — anti-gaming).
  Future<void> reportGpsDisabled() async {
    await _api.post('/devices/gps-disabled');
  }
}
