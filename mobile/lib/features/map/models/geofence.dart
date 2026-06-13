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
  });

  final int id;
  final String name;
  final String? description;
  final String shapeType; // 'POLYGON' | 'CIRCLE'
  final List<LatLng> points; // polygon ring (also populated for circles)
  final LatLng? center; // circle only
  final double? radiusMeters; // circle only

  bool get isCircle =>
      shapeType == 'CIRCLE' && center != null && radiusMeters != null;

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
    );
  }
}
