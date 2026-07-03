# FieldTrack — ProGuard/R8 rules for release builds.
#
# minifyEnabled + shrinkResources (enabled in build.gradle.kts) remove unused
# code and rename classes to save space. Plugins that use reflection or JNI
# need explicit "keep" rules or R8 strips classes they load by name at
# runtime, causing crashes that only show up in release builds (never in
# debug). Each section below is a plugin used by this app.

# ── Flutter engine ──────────────────────────────────────────────────────
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# ── Dio (HTTP client) ────────────────────────────────────────────────────
# Dio uses dart:ffi / okhttp under the hood on some platforms; keep okhttp
# and its annotation classes so request/response interceptors don't break.
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ── Firebase Cloud Messaging ─────────────────────────────────────────────
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# ── sqflite (local SQLite database) ──────────────────────────────────────
-keep class com.tekartik.sqflite.** { *; }

# ── geolocator / background location ─────────────────────────────────────
-keep class com.baseflow.geolocator.** { *; }
-keep class com.lyokone.location.** { *; }

# ── background_locator_2 (CRITICAL) ──────────────────────────────────────
# The foreground-service callback dispatcher (IsolateHolderService + the Dart
# @pragma('vm:entry-point') entrypoint registrar) is invoked by NAME from the
# native side. If R8 renames/strips these classes the background GPS isolate
# never starts — and it fails ONLY in release builds, silently. The plugin's
# Android package is `yukams.app.background_locator_2`.
-keep class yukams.app.background_locator_2.** { *; }
-keep class yukams.app.** { *; }
# Keep any class/members annotated as a VM entry-point (Flutter background
# isolates / plugin callback registrants).
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <methods>;
}
-keep @androidx.annotation.Keep class * { *; }
#
# CRASH FIX — Gson "Missing type parameter" on IsolateHolderService start.
#
# background_locator_2 stores its callback handle in SharedPreferences using
# Gson with an anonymous TypeToken subclass (PreferencesManager.getDataCallback).
# Gson 2.10+ changed how it resolves generic type parameters on anonymous
# subclasses: it now calls TypeToken.getSuperclassTypeParam() which walks the
# class hierarchy via reflection and throws RuntimeException("Missing type
# parameter") when R8 has stripped the generic Signature attribute from the
# anonymous class.
#
# Two rules are required:
#   1. Keep the TypeToken class itself and all subclasses (including anonymous
#      ones generated inside background_locator_2) with full member detail.
#   2. Preserve generic Signature attributes on those subclasses so Gson's
#      reflection can recover the type parameter at runtime.
#
# The root -keepattributes Signature line lower in this file covers the whole
# app, but R8 can still strip the class members that carry the signature;  
# the explicit -keep below prevents that.
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken { *; }
-keepattributes Signature

# ── flutter_local_notifications ──────────────────────────────────────────
-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**

# ── Play Core (Flutter deferred components) ──────────────────────────────
# Flutter's embedding references com.google.android.play.core.* for deferred
# component / split-install support. This app does NOT use deferred components
# and doesn't ship the Play Core library, so R8 reports these as missing
# classes and fails. Keep the referencing Flutter classes and silence the
# warnings for the absent Play Core APIs.
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }
-keep class io.flutter.embedding.android.FlutterPlayStoreSplitApplication { *; }

# ── General Dart/Kotlin reflection safety ────────────────────────────────
-keepattributes Signature, *Annotation*, EnclosingMethod, InnerClasses
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
