import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../../core/theme/app_colors.dart';
import '../models/geofence.dart';

/// flutter_map layers for the active geofences. Polygons render via
/// PolygonLayer; circles via CircleLayer (true geographic circle, radius in
/// metres) — both with the FieldTrack amber fill (20%) + 2px amber border.
///
/// Returns a LIST of layers (polygon + circle), so callers spread it into a
/// FlutterMap's children: `...geofenceLayers(geofences)`.
List<Widget> geofenceLayers(List<Geofence> geofences) {
  final fill = AppPalette.amber.withValues(alpha: 0.20);

  final polygons = <Polygon>[
    for (final g in geofences)
      if (!g.isCircle)
        Polygon(
          points: g.points,
          color: fill,
          borderColor: AppPalette.amber,
          borderStrokeWidth: 2,
        ),
  ];

  final circles = <CircleMarker>[
    for (final g in geofences)
      if (g.isCircle)
        CircleMarker(
          point: g.center!,
          radius: g.radiusMeters!,
          useRadiusInMeter: true, // radius is metres, not pixels
          color: fill,
          borderColor: AppPalette.amber,
          borderStrokeWidth: 2,
        ),
  ];

  return [
    if (polygons.isNotEmpty) PolygonLayer(polygons: polygons),
    if (circles.isNotEmpty) CircleLayer(circles: circles),
  ];
}
