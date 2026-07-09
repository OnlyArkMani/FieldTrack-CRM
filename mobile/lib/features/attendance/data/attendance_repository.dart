import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/attendance.dart';

final attendanceRepositoryProvider = Provider<AttendanceRepository>((ref) {
  return AttendanceRepository(ref.watch(apiClientProvider));
});

class AttendanceHistoryResponse {
  const AttendanceHistoryResponse({
    required this.items,
    this.nextCursor,
    required this.hasMore,
    required this.total,
  });

  final List<Attendance> items;
  final String? nextCursor;
  final bool hasMore;
  final int total;
}

class AttendanceRepository {
  AttendanceRepository(this._api);
  final ApiClient _api;

  Future<TodayAttendance> today() async {
    final data = await _api.get('/attendance/today');
    return TodayAttendance.fromJson(data);
  }

  Future<Attendance> start(double lat, double lng) =>
      _transition('start', lat, lng);

  /// `date` defaults to today; pass a future date to request leave ahead of
  /// time. The server rejects a date that still has planned visits on it
  /// (409) until they're rescheduled or skipped.
  Future<Attendance> markLeave({DateTime? date}) async {
    final data = await _api.post(
      '/attendance/leave',
      body: date == null
          ? null
          : {
              'date':
                  '${date.year.toString().padLeft(4, '0')}-'
                  '${date.month.toString().padLeft(2, '0')}-'
                  '${date.day.toString().padLeft(2, '0')}',
            },
    );
    return Attendance.fromJson(data);
  }

  Future<Attendance> breakk(double lat, double lng) =>
      _transition('break', lat, lng);

  Future<Attendance> resume(double lat, double lng) =>
      _transition('resume', lat, lng);

  Future<Attendance> end(
    double lat,
    double lng, {
    required String workSummary,
  }) async {
    final data = await _api.post('/attendance/end', body: {
      'lat': lat,
      'lng': lng,
      'work_summary': workSummary,
    });
    return Attendance.fromJson(data);
  }

  Future<AttendanceHistoryResponse> getHistory({
    required DateTime startDate,
    required DateTime endDate,
    String? cursor,
    int limit = 30,
  }) async {
    final startStr = startDate.toIso8601String().substring(0, 10);
    final endStr = endDate.toIso8601String().substring(0, 10);
    final data = await _api.get(
      '/attendance/history',
      query: {
        'start_date': startStr,
        'end_date': endStr,
        'limit': limit,
        if (cursor != null) 'cursor': cursor,
      },
    );
    final list = data['items'] as List;
    final items = list.map((json) => Attendance.fromJson(json as Map<String, dynamic>)).toList();
    return AttendanceHistoryResponse(
      items: items,
      nextCursor: data['next_cursor'] as String?,
      hasMore: (data['has_more'] as bool?) ?? false,
      total: (data['total'] as int?) ?? 0,
    );
  }

  Future<void> revokeLeave(int attendanceId) async {
    await _api.delete('/attendance/leave/$attendanceId');
  }

  Future<Attendance> _transition(String action, double lat, double lng) async {
    final data =
        await _api.post('/attendance/$action', body: {'lat': lat, 'lng': lng});
    return Attendance.fromJson(data);
  }
}
