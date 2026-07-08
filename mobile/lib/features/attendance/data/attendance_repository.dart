import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/attendance.dart';

final attendanceRepositoryProvider = Provider<AttendanceRepository>((ref) {
  return AttendanceRepository(ref.watch(apiClientProvider));
});

class AttendanceRepository {
  AttendanceRepository(this._api);
  final ApiClient _api;

  Future<TodayAttendance> today() async {
    final data = await _api.get('/attendance/today');
    return TodayAttendance.fromJson(data);
  }

  Future<Attendance> start(double lat, double lng) =>
      _transition('start', lat, lng);

  Future<Attendance> markLeave() async {
    final data = await _api.post('/attendance/leave');
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


  Future<List<Attendance>> getHistory({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 100,
  }) async {
    final startStr = startDate.toIso8601String().substring(0, 10);
    final endStr = endDate.toIso8601String().substring(0, 10);
    final data = await _api.get(
      '/attendance/history',
      query: {
        'start_date': startStr,
        'end_date': endStr,
        'limit': limit,
      },
    );
    final items = data['items'] as List;
    return items.map((json) => Attendance.fromJson(json as Map<String, dynamic>)).toList();
  }

  Future<Attendance> _transition(String action, double lat, double lng) async {
    final data =
        await _api.post('/attendance/$action', body: {'lat': lat, 'lng': lng});
    return Attendance.fromJson(data);
  }
}
