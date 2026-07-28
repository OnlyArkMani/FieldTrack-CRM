import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/network/api_client.dart';
import '../models/report_models.dart';
import '../models/report_preview_models.dart';

final reportRepositoryProvider = Provider<ReportRepository>((ref) {
  return ReportRepository(ref.watch(apiClientProvider));
});

class ReportRepository {
  ReportRepository(this._api);
  final ApiClient _api;

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Kick off generation. Returns the report_id to poll.
  Future<String> generate({
    required ReportType type,
    required ReportFormat format,
    required Map<String, dynamic> filters,
  }) async {
    final data = await _api.post('/reports/generate', body: {
      'type': type.wire,
      'format': format.wire,
      'filters': filters,
    });
    return data['report_id'] as String;
  }

  /// Kick off a single-FPO/farmer Excel export (full history).
  Future<String> generateFarmerExport(int farmerId) async {
    final data = await _api.post('/reports/generate', body: {
      'type': 'FARMER_EXPORT',
      'format': 'EXCEL',
      'filters': {'farmer_id': farmerId},
    });
    return data['report_id'] as String;
  }

  Future<ReportStatusResult> status(String reportId) async {
    final data = await _api.get('/reports/$reportId/status');
    return ReportStatusResult.fromJson(data);
  }

  Future<List<int>> downloadBytes(String reportId) async {
    try {
      final resp = await _api.dio.get<List<int>>(
        '/reports/$reportId/download',
        options: Options(responseType: ResponseType.bytes),
      );
      return resp.data ?? const <int>[];
    } on DioException catch (e) {
      throw ApiClient.mapError(e);
    }
  }

  Future<File> download(String reportId, {required String filename}) async {
    try {
      final resp = await _api.dio.get<List<int>>(
        '/reports/$reportId/download',
        options: Options(responseType: ResponseType.bytes),
      );
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(resp.data ?? const <int>[], flush: true);
      return file;
    } on DioException catch (e) {
      throw ApiClient.mapError(e);
    }
  }

  /// Fetch dynamic preview data for tabular rendering on the mobile Reports screen,
  /// calling backend calculation engine (POST /reports/preview).
  Future<ReportTableData> fetchPreviewData({
    required ReportType type,
    DateTimeRange? range,
    DateTime? month,
    int? teamId,
  }) async {
    final Map<String, dynamic> filters = {};

    if (range != null) {
      filters['start_date'] = _ymd(range.start);
      filters['end_date'] = _ymd(range.end);
    }
    if (month != null) {
      filters['month'] = _ymd(month);
    }
    if (teamId != null) {
      filters['team_id'] = teamId;
    }

    try {
      final res = await _api.post('/reports/preview', body: {
        'type': type.wire,
        'filters': filters,
      });

      final tables = res['tables'] as List<dynamic>? ?? [];
      if (tables.isEmpty) {
        return const ReportTableData(columns: [], rows: []);
      }

      final firstTbl = tables[0] as Map<String, dynamic>;
      final rawCols = (firstTbl['columns'] as List<dynamic>?)?.cast<String>() ?? [];
      final rawRows = (firstTbl['rows'] as List<dynamic>?) ?? [];

      final columns = rawCols.map((colName) {
        final isSessionHistory = colName.toLowerCase().contains('session history');
        final w = isSessionHistory
            ? 200.0
            : (colName.contains('Employee') || colName.contains('Summary'))
                ? 140.0
                : 110.0;
        return ReportTableColumn(label: colName, width: w, isSessionHistory: isSessionHistory);
      }).toList();

      final rows = <ReportTableRow>[];
      for (var rIdx = 0; rIdx < rawRows.length; rIdx++) {
        final rowList = (rawRows[rIdx] as List<dynamic>?) ?? [];
        final cells = rowList.map((val) {
          final str = val?.toString() ?? '—';
          final isBadge = str == 'PRESENT' || str == 'COMPLIANT' || str == 'SUBMITTED' || str == 'YES' ||
              str == 'ABSENT' || str == 'LEAVE' || str == 'PENDING' || str == 'NO';
          
          if (isBadge) {
            Color bg = const Color(0xFF34C759);
            if (str.contains('LEAVE') || str.contains('PENDING')) bg = const Color(0xFFF5A623);
            if (str.contains('ABSENT') || str == 'NO') bg = const Color(0xFFE8645A);
            return ReportTableCell(str, badgeColor: bg.withValues(alpha: 0.15), badgeTextColor: bg);
          }

          return ReportTableCell(str);
        }).toList();

        rows.add(ReportTableRow(id: '$rIdx', cells: cells));
      }

      return ReportTableData(
        columns: columns,
        rows: rows,
        totalRecords: rows.length,
        summarySubtitle: res['subtitle'] as String?,
      );
    } catch (_) {
      return const ReportTableData(columns: [], rows: []);
    }
  }
}
