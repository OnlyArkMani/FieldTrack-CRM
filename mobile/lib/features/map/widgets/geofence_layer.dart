import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../../core/theme/app_colors.dart';
import '../models/geofence.dart';

/// flutter_map layers for the active geofences. Polygons render via
/// PolygonLayer; circles via CircleLayer (true geographic circle, radius in
/// metres) — both with the FieldTrack amber fill (15%) + 2px amber border.
/// Each zone also gets a centred label marker (small amber pill, white text).
///
/// Returns a LIST of layers (polygon + circle + labels), so callers spread it
/// into a FlutterMap's children: `...geofenceLayers(geofences)`.
List<Widget> geofenceLayers(List<Geofence> geofences) {
  final fill = AppPalette.amber.withValues(alpha: 0.15);

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

  // Centred name labels — amber pill, white text, ellipsised so a long zone
  // name never overflows.
  final labelMarkers = <Marker>[
    for (final g in geofences)
      Marker(
        point: g.labelAnchor,
        width: 130,
        height: 26,
        alignment: Alignment.center,
        child: _ZoneLabel(name: g.name),
      ),
  ];

  return [
    if (polygons.isNotEmpty) PolygonLayer(polygons: polygons),
    if (circles.isNotEmpty) CircleLayer(circles: circles),
    if (labelMarkers.isNotEmpty) MarkerLayer(markers: labelMarkers),
  ];
}

class _ZoneLabel extends StatelessWidget {
  const _ZoneLabel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppPalette.amber,
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
