import 'dart:math' as math;

/// Lightweight geo helpers for the visit flow (checklist #18 — distance & ETA
/// to the next planned customer). Pure Dart, no plugins, no network: the
/// executive's current GPS fix and the farmer's recorded lat/lng are all we
/// need. ETA is a rough estimate (no routing API — the project is
/// OpenStreetMap/offline-first), assuming an average field travel speed.

const double _earthRadiusM = 6371000.0;

/// Great-circle distance in metres between two lat/lng points.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  final p1 = _rad(lat1);
  final p2 = _rad(lat2);
  final dPhi = _rad(lat2 - lat1);
  final dLmb = _rad(lng2 - lng1);
  final a = math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dLmb / 2) * math.sin(dLmb / 2);
  return 2 * _earthRadiusM * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Naive ETA in minutes for a straight-line distance, assuming an average
/// field-travel speed. Rural two-wheeler / small-vehicle default ≈ 25 km/h.
int etaMinutes(double meters, {double avgSpeedKmh = 25.0}) {
  if (meters <= 0 || avgSpeedKmh <= 0) return 0;
  final hours = (meters / 1000.0) / avgSpeedKmh;
  return (hours * 60).ceil();
}

/// "4.2 km" / "820 m" for display.
String formatDistance(double meters) {
  if (meters >= 1000) {
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
  return '${meters.round()} m';
}

/// "11 min" / "1 h 5 min" for display.
String formatEta(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

double _rad(double deg) => deg * math.pi / 180.0;
