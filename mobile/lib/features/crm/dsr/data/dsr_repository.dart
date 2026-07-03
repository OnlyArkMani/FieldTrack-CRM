import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/network/api_client.dart';
import '../models/dsr.dart';

final dsrRepositoryProvider = Provider<DsrRepository>((ref) {
  return DsrRepository(ref.watch(apiClientProvider));
});

class DsrRepository {
  DsrRepository(this._api);
  final ApiClient _api;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Employee's DSR history, optionally filtered by month/year.
  Future<List<DsrSummary>> myHistory({int? month, int? year}) async {
    final data = await _api.getList('/daily-reports/my', query: {
      if (month != null) 'month': month.toString(),
      if (year != null) 'year': year.toString(),
    });
    return data
        .map((e) => DsrSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Full DSR detail for a specific date.
  Future<DsrDetail> myForDate(DateTime date) async {
    final data = await _api.get('/daily-reports/my/${_ymd(date)}');
    return DsrDetail.fromJson(data);
  }

  /// Supervisor: team DSR status for a date. Scope is auto-filtered to the
  /// caller's team on the backend.
  Future<List<TeamDsrItem>> teamDsrs(DateTime date) async {
    final data = await _api.getList('/daily-reports/team', query: {
      'report_date': _ymd(date),
    });
    return data
        .map((e) => TeamDsrItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Supervisor: read-only DSR detail for one team member on a date.
  Future<DsrDetail> teamMemberDsr(int employeeId, DateTime date) async {
    final data =
        await _api.get('/daily-reports/team/$employeeId/${_ymd(date)}');
    return DsrDetail.fromJson(data);
  }

  /// Download the caller's DSR for [date] as a CSV file (the per-day download
  /// button). Writes it to a temp file and returns the path for sharing.
  Future<String> downloadMyDsrCsv(DateTime date) async {
    final res = await _api.dio.get<List<int>>(
      '/daily-reports/my/${_ymd(date)}/download',
      options: Options(responseType: ResponseType.bytes),
    );
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/DSR_${_ymd(date)}.csv');
    await file.writeAsBytes(res.data ?? const <int>[]);
    return file.path;
  }

  /// Download a team member's DSR for [date] as CSV (supervisor).
  Future<String> downloadTeamDsrCsv(int employeeId, DateTime date) async {
    final res = await _api.dio.get<List<int>>(
      '/daily-reports/team/$employeeId/${_ymd(date)}/download',
      options: Options(responseType: ResponseType.bytes),
    );
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/DSR_${employeeId}_${_ymd(date)}.csv');
    await file.writeAsBytes(res.data ?? const <int>[]);
    return file.path;
  }

  /// Submit the DSR (employee action).
  Future<DsrSummary> submit(int reportId, {String? endOfDayNote}) async {
    final data = await _api.post('/daily-reports/$reportId/submit', body: {
      if (endOfDayNote != null && endOfDayNote.isNotEmpty)
        'end_of_day_note': endOfDayNote,
    });
    return DsrSummary.fromJson(data);
  }
}
