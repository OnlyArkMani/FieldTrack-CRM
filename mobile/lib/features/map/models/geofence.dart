import 'package:latlong2/latlong.dart';

/// A geofence — either a POLYGON (outer ring) or a CIRCLE (centre + radius).
/// Backend sends polygon coordinates as [[lng, lat], ...] (GeoJSON, closed);
/// we convert to flutter_map's LatLng(lat, lng) and drop the closing dup. For
/// circles, `center` + `radiusMeters` come from dedicated columns so we draw a
/// true circle rather than the 64-point server approximation.
class Geofence {
  const Geofence({
    required this.id,
    required this.name,
    required this.shapeType,
    required this.points,
    this.description,
    this.center,
    this.radiusMeters,
    this.scope = 'UNIVERSAL',
    this.teamId,
    this.teamName,
    this.areaSqMeters,
  });

  final int id;
  final String name;
  final String? description;
  final String shapeType; // 'POLYGON' | 'CIRCLE'
  final List<LatLng> points; // polygon ring (also populated for circles)
  final LatLng? center; // circle only
  final double? radiusMeters; // circle only
  final String scope; // 'UNIVERSAL' | 'TEAM'
  final int? teamId;
  final String? teamName;
  final double? areaSqMeters;

  bool get isCircle =>
      shapeType == 'CIRCLE' && center != null && radiusMeters != null;

  bool get isTeamScoped => scope == 'TEAM';

  /// Geometric centre used to anchor the zone's label marker. Circle: its
  /// centre; polygon: the average of its ring vertices (a simple centroid).
  LatLng get labelAnchor {
    if (center != null) return center!;
    if (points.isEmpty) return const LatLng(0, 0);
    var lat = 0.0, lng = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }

  /// True if [p] lies inside this geofence (circle: within radius; polygon:
  /// even-odd ray cast). Used for tap hit-testing on the map.
  bool contains(LatLng p) {
    if (isCircle) {
      const distance = Distance();
      return distance.as(LengthUnit.Meter, center!, p) <= radiusMeters!;
    }
    if (points.length < 3) return false;
    var inside = false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      final pi = points[i], pj = points[j];
      final intersect = (pi.latitude > p.latitude) != (pj.latitude > p.latitude) &&
          p.longitude <
              (pj.longitude - pi.longitude) *
                      (p.latitude - pi.latitude) /
                      (pj.latitude - pi.latitude) +
                  pi.longitude;
      if (intersect) inside = !inside;
    }
    return inside;
  }

  factory Geofence.fromJson(Map<String, dynamic> json) {
    final coords = (json['coordinates'] as List<dynamic>? ?? [])
        .map((p) => LatLng(
              (p[1] as num).toDouble(), // lat
              (p[0] as num).toDouble(), // lng
            ))
        .toList();
    if (coords.length > 1 && coords.first == coords.last) {
      coords.removeLast(); // PolygonLayer closes the ring itself
    }

    final cLat = json['center_lat'];
    final cLng = json['center_lng'];
    final center = (cLat != null && cLng != null)
        ? LatLng((cLat as num).toDouble(), (cLng as num).toDouble())
        : null;

    return Geofence(
      id: json['id'] as int,
      name: json['name'] as String,
      description: json['description'] as String?,
      shapeType: (json['shape_type'] as String?) ?? 'POLYGON',
      points: coords,
      center: center,
      radiusMeters: (json['radius_meters'] as num?)?.toDouble(),
      scope: (json['scope'] as String?) ?? 'UNIVERSAL',
      teamId: json['team_id'] as int?,
      teamName: json['team_name'] as String?,
      areaSqMeters: (json['area_sq_meters'] as num?)?.toDouble(),
    );
  }
}

/// A zone the current employee visited today (from /geofences/employee/{id}/today).
class ZoneVisit {
  const ZoneVisit({
    required this.geofenceId,
    required this.geofenceName,
    required this.visits,
    required this.totalMinutes,
  });

  final int geofenceId;
  final String geofenceName;
  final int visits;
  final double totalMinutes;

  factory ZoneVisit.fromJson(Map<String, dynamic> json) => ZoneVisit(
        geofenceId: json['geofence_id'] as int,
        geofenceName: (json['geofence_name'] as String?) ?? '',
        visits: (json['visits'] as num?)?.toInt() ?? 0,
        totalMinutes: (json['total_minutes'] as num?)?.toDouble() ?? 0,
      );
}

/// One team member's presence in a zone today (from /geofences/{id}/presence).
class ZonePresence {
  const ZonePresence({
    required this.userId,
    this.employeeName,
    required this.enteredAt,
    this.exitedAt,
    this.durationMinutes,
  });

  final int userId;
  final String? employeeName;
  final DateTime enteredAt;
  final DateTime? exitedAt;
  final double? durationMinutes;

  factory ZonePresence.fromJson(Map<String, dynamic> json) => ZonePresence(
        userId: json['user_id'] as int,
        employeeName: json['employee_name'] as String?,
        enteredAt: DateTime.parse(json['entered_at'] as String).toLocal(),
        exitedAt: json['exited_at'] != null
            ? DateTime.parse(json['exited_at'] as String).toLocal()
            : null,
        durationMinutes: (json['duration_minutes'] as num?)?.toDouble(),
      );
}
