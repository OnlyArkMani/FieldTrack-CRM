import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../auth/providers/auth_provider.dart';
import '../data/map_repository.dart';
import '../models/geofence.dart';
import '../models/map_models.dart';
import '../models/trail.dart';

/// Employee map toggle: today's route vs the last-7-days heatmap.
enum MapViewMode { today, week }

final mapViewModeProvider = StateProvider<MapViewMode>((ref) => MapViewMode.today);

/// Current user's route for today (own-location employee view).
final todayRouteProvider = FutureProvider.autoDispose<RouteData?>((ref) async {
  final uid = ref.watch(authProvider).user?.id;
  if (uid == null) return null;
  return ref.watch(mapRepositoryProvider).route(uid);
});

/// Flattened points across the last 7 days, for the heatmap overlay. Each day
/// is fetched independently; a day that fails is skipped, not fatal.
final weekRouteProvider = FutureProvider.autoDispose<List<LatLng>>((ref) async {
  final uid = ref.watch(authProvider).user?.id;
  if (uid == null) return const [];
  final repo = ref.watch(mapRepositoryProvider);
  final now = DateTime.now();
  final all = <LatLng>[];
  for (var i = 0; i < 7; i++) {
    try {
      final r = await repo.route(uid, date: now.subtract(Duration(days: i)));
      all.addAll(r.points);
    } catch (_) {
      // skip a failed day
    }
  }
  return all;
});

/// One-shot device location for the blue "you are here" dot. Null if location
/// is off/denied — the map still renders the route.
final deviceLocationProvider = FutureProvider.autoDispose<LatLng?>((ref) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );
    return LatLng(pos.latitude, pos.longitude);
  } catch (_) {
    return null;
  }
});

/// Trail-replay route for an employee on a day (YYYY-MM-DD). autoDispose so
/// switching dates / closing the screen frees the data.
typedef TrailArgs = ({int userId, String date});

final trailProvider =
    FutureProvider.autoDispose.family<TrailRoute, TrailArgs>((ref, args) async {
  return ref.watch(mapRepositoryProvider).trail(
        args.userId,
        date: DateTime.parse(args.date),
      );
});

/// Active geofences (rarely change) — cached for the map overlays.
final geofencesProvider = FutureProvider.autoDispose<List<Geofence>>((ref) async {
  return ref.watch(mapRepositoryProvider).geofences();
});

/// Whether geofence overlays are visible on the map (Show/Hide Zones toggle).
/// Defaults to visible.
final showZonesProvider = StateProvider<bool>((ref) => true);

/// The current employee's zone visits today (geofence_id → visit). Drives the
/// "You visited this zone today" line in the employee zone sheet.
final employeeZonesTodayProvider =
    FutureProvider.autoDispose<Map<int, ZoneVisit>>((ref) async {
  final uid = ref.watch(authProvider).user?.id;
  if (uid == null) return const {};
  final list = await ref.watch(mapRepositoryProvider).employeeZonesToday(uid);
  return {for (final v in list) v.geofenceId: v};
});

/// Team presence inside a given zone today (supervisor zone sheet). Keyed by
/// geofence id so each tapped zone fetches independently.
final zonePresenceProvider =
    FutureProvider.autoDispose.family<List<ZonePresence>, int>((ref, gid) async {
  return ref.watch(mapRepositoryProvider).zonePresence(gid);
});

/// Supervisor team-live, polled every 30s. autoDispose => polling stops when
/// the map screen is closed (no wasted requests in the background).
final teamLiveProvider =
    StreamProvider.autoDispose<List<TeamLiveMember>>((ref) async* {
  final repo = ref.watch(mapRepositoryProvider);
  var last = const <TeamLiveMember>[];
  while (true) {
    try {
      last = await repo.teamLive();
    } catch (_) {
      // keep the last good snapshot; retry next tick
    }
    yield last;
    await Future<void>.delayed(const Duration(seconds: 30));
  }
});
