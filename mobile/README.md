# FieldTrack Mobile

Flutter app for Employees and Supervisors. Android-first, **min SDK 21**,
built for low-end devices. Admin uses the web dashboard only.

## lib/ structure

```
lib/
├── main.dart                 # bootstrap: dotenv, prefs, Firebase, ProviderScope
├── app.dart                  # MaterialApp.router wired to theme + router
├── core/                     # everything feature-agnostic
│   ├── config/
│   │   └── env.dart          # typed access to .env values (no raw dotenv calls in features)
│   ├── theme/
│   │   ├── app_colors.dart   # THE palette. Only file in the app allowed to contain hex.
│   │   ├── app_text_styles.dart  # Inter styles: display/heading/body/caption/button
│   │   └── app_theme.dart    # light+dark ThemeData, AppColorsX ThemeExtension,
│   │                         # ThemeNotifier (Riverpod) + SharedPreferences persistence
│   ├── router/
│   │   ├── transitions.dart  # WaterPage: fade+slide, easeInOutCubic, 350ms
│   │   └── app_router.dart   # go_router: guards, role routing, shell with 4 tabs
│   ├── network/
│   │   ├── api_exceptions.dart  # typed errors mapped from {detail, code} bodies
│   │   └── api_client.dart   # Dio + connectivity/auth/refresh/error interceptors
│   ├── storage/
│   │   └── token_storage.dart   # access/refresh token persistence
│   ├── location/             # (next phase) GPS service isolating background_locator_2
│   └── widgets/              # the 7 shared components — features compose these,
│                             # never re-style raw Material widgets
├── features/                 # one folder per domain: screens/ providers/ data/ models/
│   ├── auth/
│   │   ├── models/user.dart
│   │   ├── data/auth_repository.dart   # talks to /auth/* endpoints
│   │   ├── providers/auth_provider.dart # AuthState machine the router listens to
│   │   └── screens/login_screen.dart
│   ├── home/
│   │   └── screens/home_shell.dart     # bottom nav shell (animated indicator)
│   ├── dashboard/            # role-aware: supervisor=team view, employee=personal
│   ├── attendance/           # START/BREAK/RESUME/END (next phase)
│   ├── map/                  # flutter_map + offline tiles (next phase)
│   ├── profile/
│   │   └── screens/profile_screen.dart
│   └── employees/
│       └── screens/employee_detail_screen.dart  # supervisor-only
└── (tests in test/)
```

**Layering rule:** `features → core`. Features never import each other's
internals; cross-feature data flows through providers. `core` never imports
`features` (one exception: the router imports screens to declare routes).

## Screen rules (every screen, no exceptions)

These exist because the first build of this app shipped overflow bugs,
dead buttons, and jank. Each rule kills one class of those bugs.

1. Root wrapped in `SafeArea`.
2. Every `Text` sets `overflow: TextOverflow.ellipsis` and `maxLines`.
3. Every scrollable: `physics: ClampingScrollPhysics()` (cheaper on low-end
   devices than bouncing, and consistent on Android).
4. Never `Column` inside `SingleChildScrollView` for dynamic content — use
   `ListView`/`CustomScrollView` so children build lazily.
5. Every button has disabled + loading states (`AppButton.isLoading`).
6. No hardcoded colors — `Theme.of(context)` / `context.appColors` only.
   The single allowed hex location is `core/theme/app_colors.dart`.
7. Animations: page transitions via `WaterPage`, press feedback via
   `AppButton` scale, state changes via `AnimatedContainer`, list entrances
   staggered 50ms, loading via `ShimmerCard` (never a bare spinner).

## Setup

```bash
cp .env.example .env       # point API_BASE_URL at your backend
flutter pub get
flutter run
```

Android: `minSdkVersion 21` in `android/app/build.gradle`. Firebase needs
`google-services.json` in `android/app/` (FCM phase).
