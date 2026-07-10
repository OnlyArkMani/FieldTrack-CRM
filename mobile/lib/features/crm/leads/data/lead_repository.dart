import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../../../../local_db/database_helper.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../farmers/models/farmer.dart' show CustomerType, LeadStatus;
import '../models/lead.dart';

final leadRepositoryProvider = Provider<LeadRepository>((ref) {
  return LeadRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

/// Wrapper over the /leads API. `myLeads()` falls back to the last
/// successful response when offline instead of a raw "Something went
/// wrong" — same read-cache pattern as farmers/attendance/visit-plans —
/// AND merges in any lead-status change from an offline-completed visit
/// (`VisitRepository.complete()`) that hasn't synced yet, so completing a
/// visit offline is reflected here immediately rather than after the whole
/// visit syncs.
class LeadRepository {
  LeadRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;
  final _db = DatabaseHelper.instance;
  static const _cacheKey = 'cached_my_leads';

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<List<LeadItem>> myLeads({LeadStatus? status}) async {
    // Bug this fixes: previously a missing cache meant this threw
    // immediately on NoConnectionException/TimeoutException, before ever
    // reaching the pending-changes merge below — so completing a visit
    // offline (before this screen had ever loaded successfully) never
    // showed up here at all. Now the absence of a cache only degrades to
    // "no base list," it never skips the merge.
    List<LeadItem>? base;
    ApiException? networkError;
    try {
      final data = await _api.getList('/leads/my', query: {
        if (status != null) 'status': status.wire,
      });
      unawaited(_prefs.setString(_cacheKey, jsonEncode(data)));
      base = data.map((e) => LeadItem.fromJson(e as Map<String, dynamic>)).toList();
    } on NoConnectionException catch (e) {
      base = _cachedLeads();
      networkError = e;
    } on TimeoutException catch (e) {
      base = _cachedLeads();
      networkError = e;
    }

    final pending = await _pendingLeadChanges();
    if (base == null && pending.isEmpty) throw networkError!;
    final merged = pending.isEmpty
        ? base!
        : [
            ...pending,
            ...(base ?? const <LeadItem>[])
                .where((l) => !pending.any((p) => p.farmerId == l.farmerId)),
          ];
    return status == null ? merged : merged.where((l) => l.status == status).toList();
  }

  /// Serves the last-fetched (possibly differently-filtered) list — "last
  /// prefetch data" rather than an exact per-filter cache; filtering by
  /// status happens client-side back in [myLeads].
  List<LeadItem>? _cachedLeads() {
    final json = _prefs.getString(_cacheKey);
    if (json == null) return null;
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.map((e) => LeadItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
    }
  }

  Future<List<LeadItem>> _pendingLeadChanges() async {
    final visits = await _db.getAllUnsyncedVisits();
    final result = <LeadItem>[];
    for (final v in visits) {
      if (v.completeJson == null) continue;
      final complete = jsonDecode(v.completeJson!) as Map<String, dynamic>;
      final status = LeadStatus.fromWire(complete['lead_status'] as String?);
      if (status == null) continue;
      final farmer = await _resolveFarmerDisplay(v.farmerServerId, v.farmerLocalId);
      if (farmer == null || farmer.id == null) continue; // no farmer id, nothing to key the lead by
      result.add(LeadItem(
        farmerId: farmer.id!,
        farmerName: farmer.name,
        customerType: farmer.customerType,
        village: farmer.village,
        status: status,
        followUpDate: complete['follow_up_date'] != null
            ? DateTime.tryParse(complete['follow_up_date'] as String)
            : null,
        followUpTime: complete['follow_up_time'] as String?,
      ));
    }
    return result;
  }

  Future<
      ({
        int? id,
        String name,
        String? village,
        CustomerType customerType
      })?> _resolveFarmerDisplay(int? farmerServerId, String? farmerLocalId) async {
    if (farmerServerId != null) {
      final json = await _db.getCachedFarmerJson(farmerServerId);
      if (json == null) {
        return (id: farmerServerId, name: 'Unknown', village: null, customerType: CustomerType.farmer);
      }
      final f = jsonDecode(json) as Map<String, dynamic>;
      return (
        id: farmerServerId,
        name: (f['name'] as String?) ?? 'Unknown',
        village: f['village'] as String?,
        customerType: CustomerType.fromWire(f['customer_type'] as String?),
      );
    }
    if (farmerLocalId != null) {
      final row = await _db.getPendingFarmer(farmerLocalId);
      if (row != null) {
        final f = jsonDecode(row.payloadJson) as Map<String, dynamic>;
        return (
          id: null,
          name: (f['name'] as String?) ?? 'Unknown',
          village: f['village'] as String?,
          customerType: CustomerType.fromWire(f['customer_type'] as String?),
        );
      }
    }
    return null;
  }

  /// Change a farmer's lead status without a visit. reason must be >= 10 chars
  /// (enforced server-side too). A follow-up is scheduled for WARM/COLD when a
  /// date is provided.
  Future<void> updateStatus({
    required int farmerId,
    required LeadStatus status,
    required String reason,
    DateTime? followUpDate,
    String? followUpTime, // "HH:MM:SS"
    String? followUpPurpose,
  }) async {
    await _api.post('/leads/update-status', body: {
      'farmer_id': farmerId,
      'status': status.wire,
      'reason_note': reason,
      if (followUpDate != null) 'follow_up_date': _ymd(followUpDate),
      if (followUpTime != null) 'follow_up_time': followUpTime,
      if (followUpPurpose != null && followUpPurpose.isNotEmpty)
        'follow_up_purpose': followUpPurpose,
    });
  }
}

/// All of the current employee's leads (HOT→WARM→COLD). The pipeline screen
/// derives counts from this and filters client-side.
class MyLeadsNotifier extends AutoDisposeAsyncNotifier<List<LeadItem>> {
  @override
  FutureOr<List<LeadItem>> build() async {
    final auth = ref.watch(authProvider);
    if (auth.status != AuthStatus.authenticated) {
      return const [];
    }
    return ref.watch(leadRepositoryProvider).myLeads();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => ref.read(leadRepositoryProvider).myLeads());
  }
}

final myLeadsProvider =
    AsyncNotifierProvider.autoDispose<MyLeadsNotifier, List<LeadItem>>(
        MyLeadsNotifier.new);

/// Selected status filter on the pipeline screen (null = All).
final leadFilterProvider = StateProvider<LeadStatus?>((ref) => null);
