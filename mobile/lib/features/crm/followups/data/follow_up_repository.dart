import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../models/follow_up.dart';

final followUpRepositoryProvider = Provider<FollowUpRepository>((ref) {
  return FollowUpRepository(ref.watch(apiClientProvider));
});

class FollowUpRepository {
  FollowUpRepository(this._api);
  final ApiClient _api;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<List<FollowUpItem>> my({
    DateTime? dateFrom,
    DateTime? dateTo,
    String? status,
  }) async {
    final data = await _api.getList('/follow-ups/my', query: {
      if (dateFrom != null) 'date_from': _ymd(dateFrom),
      if (dateTo != null) 'date_to': _ymd(dateTo),
      if (status != null) 'status': status,
    });
    return data
        .map((e) => FollowUpItem.fromJson(e as Map<String, dynamic>))
        .toList();
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
