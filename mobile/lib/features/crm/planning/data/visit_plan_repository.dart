import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../models/visit_plan.dart';

final visitPlanRepositoryProvider = Provider<VisitPlanRepository>((ref) {
  return VisitPlanRepository(ref.watch(apiClientProvider));
});

/// Thin wrapper over the /visit-plans API.
class VisitPlanRepository {
  VisitPlanRepository(this._api);
  final ApiClient _api;

  static String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<MyPlan> myPlan(DateTime date) async {
    final data = await _api.get('/visit-plans/my/${ymd(date)}');
    return MyPlan.fromJson(data);
  }

  /// Upsert the day's plan. Items are sent in their current order; the server
  /// stores sequence_order and flips status to SUBMITTED.
  Future<MyPlan> savePlan(DateTime date, List<PlanItem> items) async {
    final body = {
      'plan_date': ymd(date),
      'items': [
        for (var i = 0; i < items.length; i++) items[i].toInput(i),
      ],
    };
    final data = await _api.post('/visit-plans', body: body);
    return MyPlan.fromJson(data);
  }

  Future<MyPlan> updateItemStatus(
    int planId,
    int itemId, {
    required String status,
  }) async {
    final data = await _api.patch(
      '/visit-plans/$planId/items/$itemId',
      body: {'status': status},
    );
    return MyPlan.fromJson(data);
  }

  /// Reschedule a missed (carried-over) item onto [targetDate] with an optional
  /// time. The source item is skipped server-side. Returns the target plan.
  Future<MyPlan> carryOver(
    int itemId, {
    required DateTime targetDate,
    String? timeSlot, // "HH:MM:SS"
  }) async {
    final data = await _api.post('/visit-plans/items/$itemId/carry-over', body: {
      'target_date': ymd(targetDate),
      if (timeSlot != null) 'time_slot': timeSlot,
    });
    return MyPlan.fromJson(data);
  }

  /// Drop a missed (carried-over) item — marks it SKIPPED server-side.
  Future<MyPlan> skipItem(int itemId) async {
    final data = await _api.post('/visit-plans/items/$itemId/skip');
    return MyPlan.fromJson(data);
  }
}
