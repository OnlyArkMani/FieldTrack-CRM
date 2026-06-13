import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/network/api_client.dart';
import '../models/report_models.dart';

final reportRepositoryProvider = Provider<ReportRepository>((ref) {
  return ReportRepository(ref.watch(apiClientProvider));
});

class ReportRepository {
  ReportRepository(this._api);
  final ApiClient _api;

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

  Future<ReportStatusResult> status(String reportId) async {
    final data = await _api.get('/reports/$reportId/status');
    return ReportStatusResult.fromJson(data);
  }

  /// Download the finished file to a temp path and return it (ready to share /
  /// open). Goes through the raw Dio so we can pull bytes; the auth interceptor
  /// still attaches the bearer token.
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
}
