import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'tile_cache_service.dart';

/// Pure map helpers: the OSM tile layer (offline-aware), polyline construction
/// with smoothing, and Haversine distance. No widgets, no state — easy to test.
class MapService {
  MapService._();

  static const osmUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const userAgent = 'com.fieldtrack.mobile';

  /// Minimum spacing between consecutive route points. GPS jitter produces
  /// clusters of near-identical fixes while standing still; dropping points
  /// closer than this keeps the polyline light and clean without visibly
  /// changing the path.
  static const smoothingMinMeters = 5.0;

  static const earthRadiusMeters = 6371000.0;

  /// The base tile layer. Uses the FMTC cache provider when the cache is ready
  /// (offline tiles + auto-caching as you browse); falls back to plain network
  /// tiles otherwise, so the map always renders.
  static TileLayer tileLayer() {
    return TileLayer(
      urlTemplate: osmUrlTemplate,
      userAgentPackageName: userAgent,
      maxZoom: 19,
      tileProvider: TileCacheService.instance.tileProviderOrNull(),
    );
  }

  /// Drop points closer than [minMeters] to the previously kept point.
  /// Always keeps the first and last fix so the route's true endpoints stay.
  static List<LatLng> smoothRoute(
    List<LatLng> points, {
    double minMeters = smoothingMinMeters,
  }) {
    if (points.length <= 2) return List.of(points);
    final result = <LatLng>[points.first];
    for (var i = 1; i < points.length - 1; i++) {
      if (haversineMeters(result.last, points[i]) >= minMeters) {
        result.add(points[i]);
      }
    }
    result.add(points.last);
    return result;
  }

  /// Great-circle distance between two coords, in metres (Haversine — no
  /// external API, exactly per the project's "do not use Directions API").
  static double haversineMeters(LatLng a, LatLng b) {
    final lat1 = _rad(a.latitude);
    final lat2 = _rad(b.latitude);
    final dLat = _rad(b.latitude - a.latitude);
    final dLng = _rad(b.longitude - a.longitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return earthRadiusMeters * c;
  }

  /// Total path length: sum of Haversine segment distances, in metres.
  static double totalDistanceMeters(List<LatLng> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += haversineMeters(points[i - 1], points[i]);
    }
    return total;
  }

  static double _rad(double deg) => deg * math.pi / 180.0;
}
