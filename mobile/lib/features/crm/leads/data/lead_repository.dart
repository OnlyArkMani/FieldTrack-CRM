import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../../../auth/providers/auth_provider.dart';
import '../../farmers/models/farmer.dart' show LeadStatus;
import '../models/lead.dart';

final leadRepositoryProvider = Provider<LeadRepository>((ref) {
  return LeadRepository(ref.watch(apiClientProvider));
});

class LeadRepository {
  LeadRepository(this._api);
  final ApiClient _api;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<List<LeadItem>> myLeads({LeadStatus? status}) async {
    final data = await _api.getList('/leads/my', query: {
      if (status != null) 'status': status.wire,
    });
    return data
        .map((e) => LeadItem.fromJson(e as Map<String, dynamic>))
        .toList();
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
