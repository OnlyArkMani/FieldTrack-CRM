import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    return DsrDetail.fromJson(data as Map<String, dynamic>);
  }

  /// Submit the DSR (employee action).
  Future<DsrSummary> submit(int reportId, {String? endOfDayNote}) async {
    final data = await _api.post('/daily-reports/$reportId/submit', body: {
      if (endOfDayNote != null && endOfDayNote.isNotEmpty)
        'end_of_day_note': endOfDayNote,
    });
    return DsrSummary.fromJson(data as Map<String, dynamic>);
  }
}
