import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/team.dart';

final teamRepositoryProvider = Provider<TeamRepository>((ref) {
  return TeamRepository(ref.watch(apiClientProvider));
});

class TeamRepository {
  TeamRepository(this._api);
  final ApiClient _api;

  Future<List<Team>> list() async {
    // GET /teams returns a bare JSON array — getList preserves error mapping.
    final data = await _api.getList('/teams');
    return data.map((e) => Team.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Team> detail(int id) async {
    final data = await _api.get('/teams/$id');
    return Team.fromJson(data);
  }

  Future<Team> create({
    required String name,
    String? description,
    int? supervisorId,
  }) async {
    final data = await _api.post('/teams', body: {
      'name': name,
      if (description != null && description.isNotEmpty)
        'description': description,
      if (supervisorId != null) 'supervisor_id': supervisorId,
    });
    return Team.fromJson(data);
  }

  Future<Team> update(int id, Map<String, dynamic> changes) async {
    final data = await _api.put('/teams/$id', body: changes);
    return Team.fromJson(data);
  }

  Future<void> delete(int id) async {
    await _api.delete('/teams/$id');
  }

  Future<Team> addMember(int teamId, int userId) async {
    final data =
        await _api.post('/teams/$teamId/members', body: {'user_id': userId});
    return Team.fromJson(data);
  }

  Future<Team> removeMember(int teamId, int userId) async {
    final data = await _api.delete('/teams/$teamId/members/$userId');
    return Team.fromJson(data);
  }
}
