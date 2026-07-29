import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/theme/app_theme.dart';
import 'services/location/location_service.dart';
import 'services/location/location_sync_service.dart';
import 'services/map/tile_cache_service.dart';
import 'services/notification/fcm_service.dart';

Future<void> main() async {
  // No global handler previously existed: any exception that escaped a
  // try/catch anywhere in the app (sync or async) was fatal to the isolate
  // instead of being logged. This is a safety net, not a fix for any specific
  // bug — it turns "app silently closes" into a logged, recoverable error.
  runZonedGuarded(_bootstrap, (error, stack) {
    debugPrint('Uncaught zone error: $error\n$stack');
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('PlatformDispatcher uncaught error: $error\n$stack');
    return true;
  };

  // Env + prefs BEFORE runApp: theme mode and API base URL must be ready on
  // first frame (no flash of wrong theme, no late env crashes).
  await dotenv.load(fileName: '.env');
  final prefs = await SharedPreferences.getInstance();

  // Mirror the API base URL into prefs: the background-locator isolate can't
  // load dotenv assets, so the sync service reads it from here.
  await prefs.setString(LocationSyncService.kApiBaseUrlPref, Env.apiBaseUrl);

  // Background GPS plumbing (idempotent; must happen before any register).
  await LocationService.instance.initialize();

  // Offline map tile cache (best-effort: map falls back to network tiles if
  // this fails). Initialised here so a pre-cache on attendance START works even
  // before the map tab is first opened.
  await TileCacheService.instance.initializeCache();

  // Drain any offline backlog from previous runs — fire and forget.
  // ignore: unawaited_futures
  LocationSyncService.flushPendingLocations();

  // Firebase + FCM (guarded so the app still boots without google-services.json
  // during early development). The background message handler MUST be
  // registered before runApp and points at a top-level entry-point function.
  // App-level token registration + tap routing live in FcmController, which
  // HomeShell watches for the authenticated session.
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    // Create the local-notification channel early so the first foreground push
    // has somewhere to land.
    await FcmService.instance.initialize();
  } catch (e) {
    debugPrint('Firebase init skipped (FCM disabled this run): $e');
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const SamarthSathiApp(),
    ),
  );
}
