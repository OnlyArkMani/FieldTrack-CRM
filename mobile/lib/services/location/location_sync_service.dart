import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../local_db/database_helper.dart';

/// Uploads pending locations in batches of <=50 (server cap is 100).
///
/// ISOLATE-SAFE BY DESIGN: this is used from BOTH the foreground app and the
/// background-locator isolate, so it deliberately does NOT use the Riverpod-
/// wired ApiClient. It reads base URL + access token from SharedPreferences
/// (written by the main app at boot/login).
///
/// NO TOKEN REFRESH HERE — on 401 rows simply stay pending. Reason: the
/// backend rotates refresh tokens with reuse detection; two isolates
/// refreshing concurrently would race, trip the detector, and kill the whole
/// session. The foreground app (which owns refresh) syncs the backlog on next
/// open. Losing a sync cycle is cheap; losing the session is not.
class LocationSyncService {
  LocationSyncService._();

  static const kApiBaseUrlPref = 'sync_api_base_url';
  static const kAccessTokenPref = 'auth_access_token'; // TokenStorage's key
  static const _batchSize = 50;

  static bool _flushing = false;

  /// Returns the number of records the server accepted. Never throws.
  static Future<int> flushPendingLocations() async {
    if (_flushing) return 0; // single-flight within this isolate
    _flushing = true;
    try {
      return await _flush();
    } catch (_) {
      return 0;
    } finally {
      _flushing = false;
    }
  }

  static Future<int> _flush() async {
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) return 0;

    final prefs = await SharedPreferences.getInstance();
    // Reload: this isolate's prefs cache may be stale (token rotated by the
    // other isolate since our last read).
    await prefs.reload();
    final baseUrl = prefs.getString(kApiBaseUrlPref);
    final token = prefs.getString(kAccessTokenPref);
    if (baseUrl == null || token == null) return 0;

    final db = DatabaseHelper.instance;
    await db.requeueFailed(); // failed rows get another chance each pass

    final dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Authorization': 'Bearer $token'},
    ));

    var totalAccepted = 0;
    while (true) {
      final batch = await db.getPendingLocations(limit: _batchSize);
      if (batch.isEmpty) break;

      try {
        await dio.post(
          '/location/batch',
          data: {'records': batch.map((r) => r.toApiJson()).toList()},
        );
        // processed OR deduped-as-skipped — either way the server has them.
        await db.markSynced([for (final r in batch) r.id!]);
        totalAccepted += batch.length;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 422) {
          // Whole batch rejected by validation — isolate the poison rows so
          // the rest of the queue isn't blocked behind them.
          for (final r in batch) {
            await db.markFailed(r.id!, 'validation rejected');
          }
          continue;
        }
        // 401 / network / 5xx: stop quietly, retry next cycle.
        break;
      }
    }

    await db.pruneSynced();
    return totalAccepted;
  }
}
