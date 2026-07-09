import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../models/pending_order.dart';

final orderRepositoryProvider = Provider<OrderRepository>((ref) {
  return OrderRepository(ref.watch(apiClientProvider));
});

/// Thin wrapper over the /orders API (managers/admin approval workflow).
class OrderRepository {
  OrderRepository(this._api);
  final ApiClient _api;

  /// SUBMITTED orders awaiting approval. Admin sees all (optional team filter);
  /// manager is locked to their own team server-side.
  Future<List<PendingOrder>> pending({int? teamId}) async {
    final data = await _api.getList('/orders/pending', query: {
      if (teamId != null) 'team_id': teamId,
    });
    return data
        .map((e) => PendingOrder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<PendingOrder> review(
    int orderId, {
    required String action, // APPROVE / REJECT
    String? rejectionReason,
  }) async {
    final data = await _api.post('/orders/$orderId/review', body: {
      'action': action,
      if (rejectionReason != null && rejectionReason.isNotEmpty)
        'rejection_reason': rejectionReason,
    });
    return PendingOrder.fromJson(data);
  }
}

/// Pending orders for the approval screen.
final pendingOrdersProvider = FutureProvider<List<PendingOrder>>((ref) async {
  return ref.watch(orderRepositoryProvider).pending();
});
