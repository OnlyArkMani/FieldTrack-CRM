import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/village.dart';

final villageRepositoryProvider = Provider<VillageRepository>((ref) {
  return VillageRepository(ref.watch(apiClientProvider));
});

/// Wrapper over GET /villages — reuses the app's shared ApiClient, so it
/// hits the same Env.apiBaseUrl and gets the same session token / 401-refresh
/// handling as every other request, no separate host or credential.
class VillageRepository {
  VillageRepository(this._api);
  final ApiClient _api;

  Future<List<Village>> search(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final data =
        await _api.getList('/villages', query: {'q': q, 'limit': limit});
    return data
        .map((e) => Village.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }
}
