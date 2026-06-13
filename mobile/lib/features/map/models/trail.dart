import 'package:latlong2/latlong.dart';

/// A single recorded point for trail replay.
class TrailPoint {
  const TrailPoint({
    required this.position,
    required this.timestamp,
    this.speed,
    this.accuracy,
    this.isMockGps = false,
    this.attendanceState,
  });

  final LatLng position;
  final DateTime timestamp;
  final double? speed; // m/s
  final double? accuracy;
  final bool isMockGps;
  final String? attendanceState; // STARTED | ON_BREAK | RESUMED | null

  factory TrailPoint.fromJson(Map<String, dynamic> j) => TrailPoint(
        position: LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        timestamp: DateTime.parse(j['timestamp'] as String),
        speed: (j['speed'] as num?)?.toDouble(),
        accuracy: (j['accuracy'] as num?)?.toDouble(),
        isMockGps: (j['is_mock_gps'] as bool?) ?? false,
        attendanceState: j['attendance_state'] as String?,
      );
}

/// An attendance state-machine marker (START/BREAK/RESUME/END).
class TrailSession {
  const TrailSession({required this.type, required this.timestamp, this.position});

  final String type; // START | BREAK | RESUME | END
  final DateTime timestamp;
  final LatLng? position;

  factory TrailSession.fromJson(Map<String, dynamic> j) => TrailSession(
        type: j['type'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
        position: (j['lat'] != null && j['lng'] != null)
            ? LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble())
            : null,
      );
}

/// Full trail-replay payload for an employee's day.
class TrailRoute {
  const TrailRoute({
    required this.points,
    required this.sessions,
    required this.totalDistanceMeters,
    required this.totalDurationMinutes,
  });

  final List<TrailPoint> points;
  final List<TrailSession> sessions;
  final double totalDistanceMeters;
  final int totalDurationMinutes;

  bool get isEmpty => points.isEmpty;

  factory TrailRoute.fromJson(Map<String, dynamic> j) => TrailRoute(
        points: ((j['points'] as List<dynamic>?) ?? [])
            .map((e) => TrailPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        sessions: ((j['sessions'] as List<dynamic>?) ?? [])
            .map((e) => TrailSession.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalDistanceMeters:
            ((j['total_distance_meters'] as num?) ?? 0).toDouble(),
        totalDurationMinutes: (j['total_duration_minutes'] as int?) ?? 0,
      );
}
