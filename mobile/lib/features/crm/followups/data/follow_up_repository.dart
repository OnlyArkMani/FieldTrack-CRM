import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../models/follow_up.dart';

final followUpRepositoryProvider = Provider<FollowUpRepository>((ref) {
  return FollowUpRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

/// Wrapper over the /follow-ups API. `my()` falls back to the last
/// successful response when offline — same pattern as leads/farmers.
class FollowUpRepository {
  FollowUpRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;
  static const _cacheKey = 'cached_my_follow_ups';

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<List<FollowUpItem>> my({
    DateTime? dateFrom,
    DateTime? dateTo,
    String? status,
  }) async {
    try {
      final data = await _api.getList('/follow-ups/my', query: {
        if (dateFrom != null) 'date_from': _ymd(dateFrom),
        if (dateTo != null) 'date_to': _ymd(dateTo),
        if (status != null) 'status': status,
      });
      unawaited(_prefs.setString(_cacheKey, jsonEncode(data)));
      return data
          .map((e) => FollowUpItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } on NoConnectionException catch (e) {
      return _cachedFollowUps() ?? (throw e);
    } on TimeoutException catch (e) {
      return _cachedFollowUps() ?? (throw e);
    }
  }

  List<FollowUpItem>? _cachedFollowUps() {
    final json = _prefs.getString(_cacheKey);
    if (json == null) return null;
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => FollowUpItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> acknowledge(int id) async {
    await _api.post('/follow-ups/$id/acknowledge');
  }

  Future<void> complete(int id, {int? visitId}) async {
    await _api.post('/follow-ups/$id/complete', body: {
      if (visitId != null) 'completed_visit_id': visitId,
    });
  }
}

/// The current employee's follow-ups for the next 8 days (today + 7).
final myFollowUpsProvider = FutureProvider<List<FollowUpItem>>((ref) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return ref.watch(followUpRepositoryProvider).my(
        dateFrom: today,
        dateTo: today.add(const Duration(days: 7)),
      );
});

/// Selected date on the follow-ups calendar strip.
final selectedFollowUpDateProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});
