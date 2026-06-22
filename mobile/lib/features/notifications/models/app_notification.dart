import 'package:flutter/material.dart';

/// Canonical notification types — mirror the backend's NotificationType. Used
/// to pick an icon/colour and to deep-link on tap. Unknown wire values fall
/// back to [AppNotificationType.unknown] so a new server-side category never
/// crashes an old build.
enum AppNotificationType {
  attendanceReminder('ATTENDANCE_REMINDER'),
  endWorkReminder('END_WORK_REMINDER'),
  gpsDisabled('GPS_DISABLED'),
  syncFailed('SYNC_FAILED'),
  geofenceEnter('GEOFENCE_ENTER'),
  geofenceExit('GEOFENCE_EXIT'),
  adminAnnouncement('ADMIN_ANNOUNCEMENT'),
  unknown('UNKNOWN');

  const AppNotificationType(this.wire);
  final String wire;

  static AppNotificationType fromWire(String? value) =>
      AppNotificationType.values.firstWhere(
        (t) => t.wire == value,
        orElse: () => AppNotificationType.unknown,
      );

  /// Where an in-app tap on this notification should go. null = not actionable
  /// (stay on the list). Employee-detail targets aren't reachable from the
  /// in-app row (no employee_id is stored), so geofence/GPS alerts fall back to
  /// the map; the push-tap path (FcmController) deep-links to the employee.
  String? get inAppRoute => switch (this) {
        AppNotificationType.attendanceReminder ||
        AppNotificationType.endWorkReminder =>
          '/home/attendance',
        AppNotificationType.gpsDisabled ||
        AppNotificationType.geofenceEnter ||
        AppNotificationType.geofenceExit =>
          '/home/map',
        AppNotificationType.syncFailed => '/home/dashboard',
        AppNotificationType.adminAnnouncement ||
        AppNotificationType.unknown =>
          null,
      };

  IconData get icon => switch (this) {
        AppNotificationType.attendanceReminder => Icons.fingerprint_rounded,
        AppNotificationType.endWorkReminder => Icons.bedtime_rounded,
        AppNotificationType.gpsDisabled => Icons.location_off_rounded,
        AppNotificationType.syncFailed => Icons.sync_problem_rounded,
        // Location pin + arrow-in / arrow-out (zone entry/exit).
        AppNotificationType.geofenceEnter => Icons.where_to_vote_rounded,
        AppNotificationType.geofenceExit => Icons.wrong_location_rounded,
        AppNotificationType.adminAnnouncement => Icons.campaign_rounded,
        AppNotificationType.unknown => Icons.notifications_rounded,
      };

  /// Optional type-specific accent (null = use the default amber/grey accent).
  /// Geofence entry reads green ("you're in"), exit reads coral ("you left").
  Color? get accentColor => switch (this) {
        AppNotificationType.geofenceEnter => const Color(0xFF34C759), // green
        AppNotificationType.geofenceExit => const Color(0xFFE8645A), // coral
        _ => null,
      };
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.isRead,
    required this.createdAt,
  });

  final int id;
  final String title;
  final String body;
  final AppNotificationType type;
  final bool isRead;
  final DateTime createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as int,
        title: (json['title'] ?? '') as String,
        body: (json['body'] ?? '') as String,
        type: AppNotificationType.fromWire(json['type'] as String?),
        isRead: (json['is_read'] ?? false) as bool,
        // Server sends UTC ISO8601; parse to local for "2h ago" display.
        createdAt:
            DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
      );

  AppNotification copyWith({bool? isRead}) => AppNotification(
        id: id,
        title: title,
        body: body,
        type: type,
        isRead: isRead ?? this.isRead,
        createdAt: createdAt,
      );

  /// Compact relative timestamp ("now", "5m", "2h", "3d", or a date).
  String get relativeTime {
    final diff = DateTime.now().difference(createdAt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
  }
}
