import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../models/geofence.dart';
import '../models/map_models.dart';
import '../models/trail.dart';

final mapRepositoryProvider = Provider<MapRepository>((ref) {
  return MapRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

class MapRepository {
  MapRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;

  /// A user's route for [date] (defaults to today server-side if omitted).
  /// Falls back to the last cached response when offline; the returned
  /// [RouteData.isFromCache] flag tells the UI to show an "offline" badge.
  Future<RouteData> route(int userId, {DateTime? date}) async {
    final dateStr = date != null ? _ymd(date) : _ymd(DateTime.now());
    final cacheKey = 'cached_route_${userId}_$dateStr';
    final cacheAtKey = '${cacheKey}_at';
    try {
      final query = <String, dynamic>{};
      if (date != null) query['date'] = _ymd(date);
      final data = await _api.get('/location/route/$userId', query: query);
      unawaited(_prefs.setString(cacheKey, jsonEncode(data)));
      unawaited(
          _prefs.setString(cacheAtKey, DateTime.now().toIso8601String()));
      return RouteData.fromJson(data);
    } on NoConnectionException {
      return _cachedRoute(cacheKey, cacheAtKey);
    } on TimeoutException {
      return _cachedRoute(cacheKey, cacheAtKey);
    }
  }

  RouteData _cachedRoute(String cacheKey, String cacheAtKey) {
    final json = _prefs.getString(cacheKey);
    if (json == null) throw const NoConnectionException();
    final atStr = _prefs.getString(cacheAtKey);
    return RouteData.fromCached(
      jsonDecode(json) as Map<String, dynamic>,
      atStr != null ? DateTime.tryParse(atStr) : null,
    );
  }

  /// Enriched trail-replay route for [userId] on [date] (defaults to today).
  Future<TrailRoute> trail(int userId, {DateTime? date}) async {
    final query = <String, dynamic>{};
    if (date != null) query['date'] = _ymd(date);
    final data = await _api.get('/location/route/$userId', query: query);
    return TrailRoute.fromJson(data);
  }

  /// Live positions of the manager's team members.
  Future<List<TeamLiveMember>> teamLive() async {
    final data = await _api.getList('/location/team-live');
    return data
        .map((e) => TeamLiveMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Active geofences to render on the map (already role/team-scoped server-side).
  Future<List<Geofence>> geofences() async {
    final data = await _api.getList('/geofences');
    return data
        .map((e) => Geofence.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Zones the employee visited today (geofence_id → visits + minutes).
  Future<List<ZoneVisit>> employeeZonesToday(int userId, {DateTime? date}) async {
    final query = <String, dynamic>{};
    if (date != null) query['date'] = _ymd(date);
    final data = await _api.getList('/geofences/employee/$userId/today', query: query);
    return data
        .map((e) => ZoneVisit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Who from the team was inside [geofenceId] today (ENTER/EXIT pairs + dwell).
  Future<List<ZonePresence>> zonePresence(int geofenceId, {DateTime? date}) async {
    final query = <String, dynamic>{};
    if (date != null) query['date'] = _ymd(date);
    final data = await _api.getList('/geofences/$geofenceId/presence', query: query);
    return data
        .map((e) => ZonePresence.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
