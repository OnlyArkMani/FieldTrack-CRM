import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../../services/map/map_service.dart';
import '../models/visit_plan.dart';
import '../providers/visit_plan_provider.dart';

/// Map view of the day's planned farmers — amber numbered markers in plan
/// order, so the employee can eyeball the route. Reads the live draft from
/// [visitPlanProvider]; farmers without a saved location are listed below.
class PlanMapScreen extends ConsumerWidget {
  const PlanMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(plannedItemsProvider);
    final located = items
        .where((i) => i.lat != null && i.lng != null)
        .toList(growable: false);
    final missing = items.length - located.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan route',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: located.isEmpty
            ? const EmptyStateView(
                icon: Icons.map_rounded,
                title: 'No mapped stops',
                message:
                    'Planned farmers show here once they have a saved location '
                    '(captured on their first visit). Save your plan to refresh.',
              )
            : Column(
                children: [
                  if (missing > 0)
                    _Banner(
                      text:
                          '$missing planned farmer${missing == 1 ? '' : 's'} '
                          'have no location yet and aren\'t shown.',
                    ),
                  Expanded(child: _Map(items: located)),
                ],
              ),
      ),
    );
  }
}

class _Map extends StatelessWidget {
  const _Map({required this.items});
  final List<PlanItem> items;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final points = [for (final i in items) LatLng(i.lat!, i.lng!)];
    final center = _centroid(points);

    return FlutterMap(
      options: MapOptions(
        initialCenter: center,
        initialZoom: 12,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom |
              InteractiveFlag.drag |
              InteractiveFlag.doubleTapZoom,
        ),
      ),
      children: [
        MapService.tileLayer(),
        MarkerLayer(
          markers: [
            for (var idx = 0; idx < items.length; idx++)
              Marker(
                point: points[idx],
                width: 36,
                height: 44,
                alignment: Alignment.topCenter,
                child: _NumberedPin(number: idx + 1, color: scheme.primary),
              ),
          ],
        ),
      ],
    );
  }

  LatLng _centroid(List<LatLng> pts) {
    var lat = 0.0;
    var lng = 0.0;
    for (final p in pts) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / pts.length, lng / pts.length);
  }
}

class _NumberedPin extends StatelessWidget {
  const _NumberedPin({required this.number, required this.color});
  final int number;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Text(
            '$number',
            style: AppTextStyles.caption.copyWith(
              color: Theme.of(context).colorScheme.onPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Icon(Icons.arrow_drop_down, color: color, size: 18),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.primary.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.grid * 2, vertical: AppDimens.grid),
      child: Text(
        text,
        style: AppTextStyles.caption.copyWith(color: colors.textSecondary),
      ),
    );
  }
}
