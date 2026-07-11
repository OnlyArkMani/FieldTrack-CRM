import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';

/// Real connectivity, not just radio state.
///
/// WHY A PING, NOT JUST connectivity_plus: a phone can be "connected" to a
/// captive-portal WiFi or a dead hotspot and still have zero internet. The
/// only honest test is talking to OUR server, so we GET /health (cheap,
/// auth-free) with a 3s timeout and treat success as the truth.
///
/// Emissions: re-checks every 30s AND immediately on any connectivity change
/// (radio flip is the fastest signal that something changed). [isOnline] is a
/// broadcast stream of DISTINCT values; [current] holds the latest.
class ConnectivityService {
  ConnectivityService({Dio? pingClient})
      : _dio = pingClient ??
            Dio(BaseOptions(
              baseUrl: Env.apiBaseUrl,
              connectTimeout: const Duration(seconds: 3),
              receiveTimeout: const Duration(seconds: 3),
            ));

  final Dio _dio;
  final _controller = StreamController<bool>.broadcast();

  Timer? _poll;
  StreamSubscription<List<ConnectivityResult>>? _radioSub;
  bool _current = false;
  bool _started = false;

  Stream<bool> get isOnline => _controller.stream;
  bool get current => _current;

  void start() {
    if (_started) return;
    _started = true;
    // React to radio changes instantly. Wrapped in its own try-catch because
    // the connectivity_plus platform channel can throw DeadSystemException on
    // Android when the system process is killed under memory pressure — that
    // native JNI error bypasses Dart's normal exception handling and would
    // crash the app if not guarded here.
    _radioSub = Connectivity().onConnectivityChanged.listen(
      (_) => _check(),
      // cancelOnError: false is critical — without it, a single platform-channel
      // error (e.g. DeadSystemException on Android) cancels the subscription
      // permanently, so the engine never detects connectivity-restored again
      // for the rest of the session. The 30s poll is the only fallback once
      // the subscription dies, meaning sync can be delayed by up to 30s.
      // With cancelOnError: false the subscription stays alive after errors.
      cancelOnError: false,
      onError: (_) {/* platform error — subscription stays alive, poll covers us */},
    );
    // …and re-verify on a 30s heartbeat (catches captive portals that the
    // radio thinks are fine).
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _check());
    _check(); // prime immediately
  }

  Future<bool> checkNow() => _check();

  Future<bool> _check() async {
    bool online;
    try {
      // Isolated try-catch for the platform channel call — connectivity_plus
      // can throw android.os.DeadSystemException (a native JNI error) when
      // the Android system server is killed under memory pressure.  Without
      // this guard the exception bypasses Dart's catch and crashes the app.
      List<ConnectivityResult> radio;
      try {
        radio = await Connectivity().checkConnectivity();
      } catch (_) {
        // Native platform crash — treat as offline to avoid crashing the app.
        radio = const [ConnectivityResult.none];
      }

      if (radio.contains(ConnectivityResult.none)) {
        online = false;
      } else {
        final resp = await _dio.get('/health');
        online = resp.statusCode != null &&
            resp.statusCode! >= 200 &&
            resp.statusCode! < 300;
      }
    } catch (_) {
      online = false; // timeout / no route / server down => offline
    }

    if (online != _current) {
      _current = online;
      if (!_controller.isClosed) _controller.add(online);
    }
    return online;
  }

  void dispose() {
    _poll?.cancel();
    _radioSub?.cancel();
    _controller.close();
  }
}

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityService()..start();
  ref.onDispose(service.dispose);
  return service;
});

/// Convenience stream provider for widgets that just want the boolean.
final isOnlineProvider = StreamProvider<bool>((ref) {
  final service = ref.watch(connectivityServiceProvider);
  return service.isOnline;
});
