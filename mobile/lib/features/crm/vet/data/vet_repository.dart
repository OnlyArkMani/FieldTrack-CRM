import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_exceptions.dart';
import '../../../../core/theme/app_theme.dart' show sharedPreferencesProvider;
import '../../../../local_db/database_helper.dart';
import '../../farmers/models/farmer.dart'
    show CustomerType, placeholderIdFromLocalId;
import '../models/vet_request.dart';

final vetRepositoryProvider = Provider<VetRepository>((ref) {
  return VetRepository(
    ref.watch(apiClientProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

/// Wrapper over the /vet-requests API (Vet dashboard).
///
/// `list()` falls back to the last successful response when offline (same
/// pattern as leads/follow-ups/farmers), AND merges in any vet requirement
/// raised offline via `VisitRepository.setVet()` that hasn't synced yet —
/// otherwise a vet request created during an offline visit would be
/// invisible on this screen until the whole visit syncs.
class VetRepository {
  VetRepository(this._api, this._prefs);
  final ApiClient _api;
  final SharedPreferences _prefs;
  final _db = DatabaseHelper.instance;
  static const _cacheKey = 'cached_vet_requests';

  Future<List<VetRequest>> list({String? status}) async {
    // Same bug/fix as LeadRepository.myLeads(): a missing cache used to
    // throw before ever reaching the pending-requests merge below.
    List<VetRequest>? base;
    ApiException? networkError;
    try {
      final data = await _api.getList('/vet-requests', query: {
        if (status != null) 'status': status,
      });
      unawaited(_prefs.setString(_cacheKey, jsonEncode(data)));
      base = data.map((e) => VetRequest.fromJson(e as Map<String, dynamic>)).toList();
    } on NoConnectionException catch (e) {
      base = _cachedVetRequests();
      networkError = e;
    } on TimeoutException catch (e) {
      base = _cachedVetRequests();
      networkError = e;
    }

    final pending = await _pendingVetRequests();
    if (base == null && pending.isEmpty) throw networkError!;
    final merged = pending.isEmpty
        ? base!
        : [
            ...pending,
            // A pending entry for the same visit (already synced past
            // check-in, only the vet field itself hasn't synced) replaces
            // the server's stale copy rather than duplicating it.
            ...(base ?? const <VetRequest>[])
                .where((v) => !pending.any((p) => p.visitId == v.visitId)),
          ];
    if (status == null) return merged;
    return merged.where((v) => v.vetStatus == status).toList();
  }

  List<VetRequest>? _cachedVetRequests() {
    final json = _prefs.getString(_cacheKey);
    if (json == null) return null;
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.map((e) => VetRequest.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return null;
    }
  }

  Future<List<VetRequest>> _pendingVetRequests() async {
    final visits = await _db.getAllUnsyncedVisits();
    final result = <VetRequest>[];
    for (final v in visits) {
      if (v.vetJson == null) continue;
      final vet = jsonDecode(v.vetJson!) as Map<String, dynamic>;
      if (vet['vet_required'] != true) continue;
      final farmer = await _resolveFarmerDisplay(v.farmerServerId, v.farmerLocalId);
      result.add(VetRequest(
        // Real id if check-in already synced (only the vet field is
        // pending); otherwise the same placeholder the visit is known by
        // elsewhere in the app.
        visitId: v.visitServerId ?? placeholderIdFromLocalId(v.localId),
        farmerId: farmer?.id,
        farmerName: farmer?.name ?? 'Unknown',
        customerType: farmer?.customerType ?? CustomerType.farmer,
        village: farmer?.village,
        vetCattleCount: vet['vet_cattle_count'] as int?,
        vetNotes: vet['vet_notes'] as String?,
        vetStatus: 'REQUESTED',
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

  Future<VetRequest> updateStatus(int visitId, String status) async {
    final data = await _api.patch('/vet-requests/$visitId/status', body: {
      'vet_status': status,
    });
    return VetRequest.fromJson(data);
  }
}

/// All vet requests visible to the caller, optionally filtered by status.
final vetRequestsProvider =
    FutureProvider.family<List<VetRequest>, String?>((ref, status) async {
  return ref.watch(vetRepositoryProvider).list(status: status);
});
