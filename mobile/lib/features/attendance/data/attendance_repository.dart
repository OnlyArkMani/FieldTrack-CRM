import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../../../core/storage/token_storage.dart';
import '../../../local_db/database_helper.dart';
import '../../../services/sync/connectivity_service.dart';
import '../models/attendance.dart';

final attendanceRepositoryProvider = Provider<AttendanceRepository>((ref) {
  return AttendanceRepository(
    ref.watch(apiClientProvider),
    ref.watch(tokenStorageProvider),
    ref.watch(connectivityServiceProvider),
  );
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
  AttendanceRepository(this._api, this._tokens, this._connectivity);
  final ApiClient _api;
  final TokenStorage _tokens;
  final ConnectivityService _connectivity;
  final _db = DatabaseHelper.instance;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Falls back to the last successful response when there's no connection,
  /// instead of losing the check-in time / current state on every screen
  /// rebuild while offline (this screen re-fetches on every resume and on
  /// every auth-state change — see AttendanceNotifier.build/_onResume).
  Future<TodayAttendance> today() async {
    try {
      final data = await _api.get('/attendance/today');
      await _tokens.saveAttendanceTodayJson(jsonEncode(data));
      return TodayAttendance.fromJson(data);
    } on NoConnectionException catch (e) {
      return _cachedToday() ?? (throw e);
    } on TimeoutException catch (e) {
      return _cachedToday() ?? (throw e);
    }
  }

  TodayAttendance? _cachedToday() {
    final json = _tokens.attendanceTodayJson;
    if (json == null) return null;
    try {
      return TodayAttendance.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<Attendance> start(double lat, double lng) =>
      _transition('start', lat, lng);

  /// `date` defaults to today; pass a future date to request leave ahead of
  /// time. The server rejects a date that still has planned visits on it
  /// (409) until they're rescheduled or skipped — that validation can only
  /// happen online, so a future-dated leave request is NOT queued offline
  /// (see below); only a leave for the current day is.
  Future<Attendance> markLeave({DateTime? date}) async {
    final now = DateTime.now();
    final isToday = date == null ||
        (date.year == now.year && date.month == now.month && date.day == now.day);

    if (!_connectivity.current && isToday) {
      final leaveDate = _ymd(now);
      await _db.upsertPendingLeaveRequest(leaveDate);
      final synthetic = Attendance(
        id: -1,
        userId: 0,
        date: now,
        status: 'ON_LEAVE',
        totalDurationMinutes: 0,
        totalDistanceMeters: 0,
        currentState: MachineState.onLeave,
        sessions: const [],
      );
      // Keep today() consistent while still offline — otherwise the next
      // rebuild (resume, auth-state change) would read the stale cached
      // "today" and show STARTED/ENDED again instead of ON_LEAVE.
      await _tokens.saveAttendanceTodayJson(jsonEncode({
        'has_attendance': true,
        'current_state': 'ON_LEAVE',
        'attendance': {
          'id': -1,
          'user_id': 0,
          'date': now.toIso8601String(),
          'status': 'ON_LEAVE',
          'total_duration_minutes': 0,
          'total_distance_meters': 0.0,
          'current_state': 'ON_LEAVE',
          'sessions': <dynamic>[],
        },
      }));
      return synthetic;
    }

    final data = await _api.post(
      '/attendance/leave',
      body: date == null ? null : {'date': _ymd(date)},
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

  /// The first page (no cursor) of the most recent successful query is
  /// cached and served back when offline — "show the last fetched
  /// attendance history" rather than a raw error. Later pages (infinite
  /// scroll) aren't cached; offline paging just stops at what's cached.
  Future<AttendanceHistoryResponse> getHistory({
    required DateTime startDate,
    required DateTime endDate,
    String? cursor,
    int limit = 30,
  }) async {
    final startStr = startDate.toIso8601String().substring(0, 10);
    final endStr = endDate.toIso8601String().substring(0, 10);
    try {
      final data = await _api.get(
        '/attendance/history',
        query: {
          'start_date': startStr,
          'end_date': endStr,
          'limit': limit,
          if (cursor != null) 'cursor': cursor,
        },
      );
      if (cursor == null) {
        await _tokens.saveAttendanceHistoryJson(jsonEncode(data));
      }
      return _historyFromJson(data);
    } on NoConnectionException catch (e) {
      if (cursor == null) return _cachedHistory() ?? (throw e);
      rethrow;
    } on TimeoutException catch (e) {
      if (cursor == null) return _cachedHistory() ?? (throw e);
      rethrow;
    }
  }

  AttendanceHistoryResponse _historyFromJson(Map<String, dynamic> data) {
    final list = data['items'] as List;
    final items =
        list.map((json) => Attendance.fromJson(json as Map<String, dynamic>)).toList();
    return AttendanceHistoryResponse(
      items: items,
      nextCursor: data['next_cursor'] as String?,
      hasMore: (data['has_more'] as bool?) ?? false,
      total: (data['total'] as int?) ?? 0,
    );
  }

  AttendanceHistoryResponse? _cachedHistory() {
    final json = _tokens.attendanceHistoryJson;
    if (json == null) return null;
    try {
      return _historyFromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
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
