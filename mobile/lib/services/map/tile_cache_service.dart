import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';

/// Offline tile caching via flutter_map_tile_caching (FMTC v9, ObjectBox
/// backend). Everything is BEST-EFFORT: if the cache can't initialise, the map
/// silently falls back to plain network tiles, so a caching failure never
/// breaks the map.
///
/// SIZE CAP: the 200 MB limit is enforced by ObjectBox's `maxDatabaseSize`
/// (writes beyond it are rejected rather than growing unbounded). FMTC v9.1.4
/// doesn't expose a public per-tile LRU eviction call; browse-cached tiles are
/// naturally refreshed on re-fetch, and [clearCache] gives the user a manual
/// reset. (A finer LRU would need a backend that exposes last-access ordering.)
class TileCacheService {
  TileCacheService._();
  static final TileCacheService instance = TileCacheService._();

  static const _storeName = 'fieldtrack_tiles';
  static const _maxDbSizeKiB = 200 * 1024; // 200 MB
  static const _urlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const _userAgent = 'com.fieldtrack.mobile';

  static const _store = FMTCStore(_storeName);

  bool _ready = false;
  bool _downloading = false;
  DateTime? _lastUpdated;

  bool get isReady => _ready;

  /// Call once at app start (before the first map renders). Idempotent and
  /// hot-restart safe.
  Future<void> initializeCache() async {
    if (_ready) return;
    try {
      try {
        await FMTCObjectBoxBackend().initialise(maxDatabaseSize: _maxDbSizeKiB);
      } on RootAlreadyInitialised {
        // Hot restart: the backend is already up — carry on.
      }
      try {
        await _store.manage.create(); // no-op if it already exists
      } catch (_) {/* already created */}
      _ready = true;
    } catch (e) {
      _ready = false;
      debugPrint('Tile cache unavailable, using network tiles: $e');
    }
  }

  /// Tile provider for a [TileLayer], or null (→ default network provider) when
  /// the cache isn't ready.
  TileProvider? tileProviderOrNull() {
    if (!_ready) return null;
    try {
      return _store.getTileProvider();
    } catch (e) {
      debugPrint('FMTC tile provider unavailable: $e');
      return null;
    }
  }

  /// Pre-download tiles around [center] for offline use (zoom 12–16 by
  /// default). Called on attendance START for a 5 km radius. Single-flight:
  /// a second call while one is running is ignored.
  Future<void> preCacheRegion(
    LatLng center,
    double radiusKm, {
    int minZoom = 12,
    int maxZoom = 16,
  }) async {
    if (!_ready || _downloading) return;
    _downloading = true;
    try {
      final region = CircleRegion(center, radiusKm).toDownloadable(
        minZoom: minZoom,
        maxZoom: maxZoom,
        options: TileLayer(
          urlTemplate: _urlTemplate,
          userAgentPackageName: _userAgent,
        ),
      );
      await for (final _ in _store.download.startForeground(
        region: region,
        skipExistingTiles: true,
      )) {
        // Progress events ignored — this is a silent background warm-up.
      }
      _lastUpdated = DateTime.now();
    } catch (e) {
      debugPrint('Pre-cache failed (non-fatal): $e');
    } finally {
      _downloading = false;
    }
  }

  /// {sizeMb, tileCount, lastUpdated} for a settings/storage screen.
  Future<Map<String, dynamic>> getCacheStats() async {
    if (!_ready) {
      return {'sizeMb': 0.0, 'tileCount': 0, 'lastUpdated': null};
    }
    try {
      final s = await _store.stats.all; // (hits, length, misses, size[KiB])
      return {
        'sizeMb': s.size / 1024.0,
        'tileCount': s.length,
        'lastUpdated': _lastUpdated?.toIso8601String(),
      };
    } catch (e) {
      debugPrint('getCacheStats failed: $e');
      return {'sizeMb': 0.0, 'tileCount': 0, 'lastUpdated': null};
    }
  }

  Future<void> clearCache() async {
    if (!_ready) return;
    try {
      await _store.manage.reset();
      _lastUpdated = null;
    } catch (e) {
      debugPrint('clearCache failed: $e');
    }
  }
}
