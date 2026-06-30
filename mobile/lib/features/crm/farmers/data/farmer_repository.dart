import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../models/farmer.dart';

final farmerRepositoryProvider = Provider<FarmerRepository>((ref) {
  return FarmerRepository(ref.watch(apiClientProvider));
});

/// Thin wrapper over the /farmers API. Returns typed models; throws
/// ApiException (mapped by api_client) for the providers to surface.
class FarmerRepository {
  FarmerRepository(this._api);
  final ApiClient _api;

  Future<FarmerPage> list({
    String? cursor,
    int limit = 20,
    String? search,
    LeadStatus? leadStatus,
    int? teamId,
  }) async {
    final query = <String, dynamic>{'limit': limit};
    if (cursor != null) query['cursor'] = cursor;
    if (search != null && search.trim().isNotEmpty) {
      query['search'] = search.trim();
    }
    if (leadStatus != null) query['lead_status'] = leadStatus.wire;
    if (teamId != null) query['team_id'] = teamId;
    final data = await _api.get('/farmers', query: query);
    return FarmerPage.fromJson(data);
  }

  Future<FarmerDetail> detail(int id) async {
    final data = await _api.get('/farmers/$id');
    return FarmerDetail.fromJson(data);
  }

  Future<FarmerDetail> create({
    required String name,
    String? phone,
    String? village,
    String? district,
    String? address,
    int totalCattle = 0,
    String? notes,
    int? teamId,
  }) async {
    final data = await _api.post('/farmers', body: {
      'name': name,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (village != null && village.isNotEmpty) 'village': village,
      if (district != null && district.isNotEmpty) 'district': district,
      if (address != null && address.isNotEmpty) 'address': address,
      'total_cattle': totalCattle,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (teamId != null) 'team_id': teamId,
    });
    // POST returns the base FarmerResponse; re-fetch the full profile so the
    // detail screen has visits/leads/etc. populated.
    return detail(data['id'] as int);
  }

  Future<void> update(int id, Map<String, dynamic> changes) async {
    await _api.put('/farmers/$id', body: changes);
  }

  /// One page of full visit history (newest first). Returns the parsed items
  /// plus the next cursor for infinite scroll.
  Future<({List<VisitSummary> items, String? nextCursor, bool hasMore})>
      visitList(int id, {String? cursor, int limit = 20}) async {
    final query = <String, dynamic>{'limit': limit};
    if (cursor != null) query['cursor'] = cursor;
    final data = await _api.get('/farmers/$id/visits', query: query);
    final items = ((data['items'] as List<dynamic>?) ?? [])
        .map((e) => VisitSummary.fromJson(e as Map<String, dynamic>))
        .toList();
    return (
      items: items,
      nextCursor: data['next_cursor'] as String?,
      hasMore: (data['has_more'] as bool?) ?? false,
    );
  }

  Future<List<LivestockProfile>> livestockHistory(int id) async {
    final data = await _api.getList('/farmers/$id/livestock-history');
    return data
        .map((e) => LivestockProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<LeadHistoryItem>> leadHistory(int id) async {
    final data = await _api.getList('/farmers/$id/lead-history');
    return data
        .map((e) => LeadHistoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> updateLeadStatus(
    int id, {
    required LeadStatus status,
    required String reason,
    int? visitId,
  }) async {
    await _api.post('/farmers/$id/lead-status', body: {
      'status': status.wire,
      'reason_note': reason,
      if (visitId != null) 'visit_id': visitId,
    });
  }
}
