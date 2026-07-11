import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../../../../local_db/database_helper.dart';
import '../../farmers/models/farmer.dart' show placeholderIdFromLocalId;
import '../models/follow_up.dart';

final followUpRepositoryProvider = Provider<FollowUpRepository>((ref) {
  return FollowUpRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

/// Wrapper over the /follow-ups API. `my()` falls back to the last
/// successful response when offline — same pattern as leads/farmers —
/// AND merges in any follow-ups from offline-completed visits that
/// haven't synced yet.
class FollowUpRepository {
  FollowUpRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;
  final _db = DatabaseHelper.instance;
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
    List<FollowUpItem>? base;
    ApiException? networkError;
    try {
      final data = await _api.getList('/follow-ups/my', query: {
        if (dateFrom != null) 'date_from': _ymd(dateFrom),
        if (dateTo != null) 'date_to': _ymd(dateTo),
        if (status != null) 'status': status,
      });
      unawaited(_prefs.setString(_cacheKey, jsonEncode(data)));
      base = data
          .map((e) => FollowUpItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } on NoConnectionException catch (e) {
      base = _cachedFollowUps();
      networkError = e;
    } on TimeoutException catch (e) {
      base = _cachedFollowUps();
      networkError = e;
    }

    final pending = await _pendingFollowUps(
      dateFrom: dateFrom,
      dateTo: dateTo,
      status: status,
    );
    if (base == null && pending.isEmpty) throw networkError!;
    if (pending.isEmpty) return base!;
    return [
      ...pending,
      ...(base ?? const <FollowUpItem>[])
          .where((f) => !pending.any((p) => p.farmerId == f.farmerId)),
    ];
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

  Future<List<FollowUpItem>> _pendingFollowUps({
    DateTime? dateFrom,
    DateTime? dateTo,
    String? status,
  }) async {
    final visits = await _db.getAllUnsyncedVisits();
    final result = <FollowUpItem>[];
    for (final v in visits) {
      if (v.completeJson == null) continue;
      final complete = jsonDecode(v.completeJson!) as Map<String, dynamic>;
      final dateStr = complete['follow_up_date'] as String?;
      if (dateStr == null) continue; // visit had no follow-up
      final scheduledDate = DateTime.tryParse(dateStr);
      if (scheduledDate == null) continue;
      if (dateFrom != null && scheduledDate.isBefore(dateFrom)) continue;
      if (dateTo != null && scheduledDate.isAfter(dateTo)) continue;
      if (status != null && status != 'PENDING') continue; // pending visits always create PENDING follow-ups

      final farmerName = await _resolveFarmerName(v.farmerServerId, v.farmerLocalId);
      // Use the server id when available; for offline-created farmers use the
      // same stable negative placeholder as the farmers list so tapping
      // navigates to the pending farmer detail rather than doing nothing.
      final farmerId = v.farmerServerId ??
          (v.farmerLocalId != null
              ? placeholderIdFromLocalId(v.farmerLocalId!)
              : null);
      result.add(FollowUpItem(
        id: -(v.visitServerId ?? v.localId.hashCode.abs()),
        farmerId: farmerId,
        farmerName: farmerName,
        scheduledDate: scheduledDate,
        scheduledTime: complete['follow_up_time'] as String?,
        purpose: complete['follow_up_purpose'] as String?,
        status: 'PENDING',
      ));
    }
    return result;
  }

  Future<String?> _resolveFarmerName(int? farmerServerId, String? farmerLocalId) async {
    if (farmerServerId != null) {
      final json = await _db.getCachedFarmerJson(farmerServerId);
      if (json != null) {
        return (jsonDecode(json) as Map<String, dynamic>)['name'] as String?;
      }
      return 'Unknown';
    }
    if (farmerLocalId != null) {
      final row = await _db.getPendingFarmer(farmerLocalId);
      if (row != null) {
        return (jsonDecode(row.payloadJson) as Map<String, dynamic>)['name'] as String?;
      }
    }
    return null;
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
