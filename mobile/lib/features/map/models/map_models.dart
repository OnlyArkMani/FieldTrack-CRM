import 'package:latlong2/latlong.dart';

import '../../../core/widgets/status_badge.dart';

/// A day's route (already simplified server-side when large).
class RouteData {
  const RouteData({
    required this.userId,
    required this.date,
    required this.points,
    required this.rawCount,
    required this.simplified,
  });

  final int userId;
  final String date;
  final List<LatLng> points;
  final int rawCount;
  final bool simplified;

  factory RouteData.fromJson(Map<String, dynamic> json) => RouteData(
        userId: json['user_id'] as int,
        date: json['date'] as String,
        rawCount: (json['raw_count'] as int?) ?? 0,
        simplified: (json['simplified'] as bool?) ?? false,
        points: ((json['points'] as List<dynamic>?) ?? [])
            .map((e) => LatLng(
                  (e['lat'] as num).toDouble(),
                  (e['lng'] as num).toDouble(),
                ))
            .toList(),
      );
}

enum LiveStatusValue {
  active('ACTIVE'),
  idle('IDLE'),
  offline('OFFLINE');

  const LiveStatusValue(this.wire);
  final String wire;

  static LiveStatusValue fromWire(String? v) => LiveStatusValue.values.firstWhere(
        (s) => s.wire == v,
        orElse: () => LiveStatusValue.offline,
      );

  EmployeeStatus get badge => switch (this) {
        LiveStatusValue.active => EmployeeStatus.active,
        LiveStatusValue.idle => EmployeeStatus.idle,
        LiveStatusValue.offline => EmployeeStatus.offline,
      };
}

/// One team member's live position for the supervisor map.
class TeamLiveMember {
  const TeamLiveMember({
    required this.userId,
    required this.name,
    required this.status,
    required this.attendanceState,
    this.photoUrl,
    this.lat,
    this.lng,
    this.lastSeen,
    this.batteryLevel,
    this.source = 'none',
  });

  final int userId;
  final String name;
  final LiveStatusValue status;
  final String attendanceState;
  final String? photoUrl;
  final double? lat;
  final double? lng;
  final DateTime? lastSeen;
  final int? batteryLevel;
  final String source;

  bool get hasPosition => lat != null && lng != null;
  LatLng? get position => hasPosition ? LatLng(lat!, lng!) : null;

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  factory TeamLiveMember.fromJson(Map<String, dynamic> json) => TeamLiveMember(
        userId: json['user_id'] as int,
        name: json['name'] as String,
        status: LiveStatusValue.fromWire(json['status'] as String?),
        attendanceState: (json['attendance_state'] as String?) ?? 'NULL',
        photoUrl: json['photo_url'] as String?,
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
        lastSeen: json['last_seen'] != null
            ? DateTime.tryParse(json['last_seen'] as String)
            : null,
        batteryLevel: json['battery_level'] as int?,
        source: (json['source'] as String?) ?? 'none',
      );
}
