import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../models/vet_request.dart';

final vetRepositoryProvider = Provider<VetRepository>((ref) {
  return VetRepository(ref.watch(apiClientProvider));
});

/// Thin wrapper over the /vet-requests API (Vet dashboard).
class VetRepository {
  VetRepository(this._api);
  final ApiClient _api;

  Future<List<VetRequest>> list({String? status}) async {
    final data = await _api.getList('/vet-requests', query: {
      if (status != null) 'status': status,
    });
    return data
        .map((e) => VetRequest.fromJson(e as Map<String, dynamic>))
        .toList();
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
