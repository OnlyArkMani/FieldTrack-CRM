import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_colors.dart';
import 'app_text_styles.dart';

/// Design constants — single source for radii/spacing/shadows.
abstract final class AppDimens {
  static const cardRadius = 12.0;
  static const buttonRadius = 8.0;
  static const sheetRadius = 24.0;
  static const grid = 8.0; // 8px base spacing grid

  /// Soft shadow: 4px blur, 8% opacity. Never use Material elevation > 0.
  static List<BoxShadow> shadow(Brightness b) => [
        BoxShadow(
          color: b == Brightness.light
              ? AppPalette.shadowLight
              : AppPalette.shadowDark,
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ];
}

/// Colors that don't fit Material's ColorScheme slots, exposed as a
/// ThemeExtension so they theme-switch and lerp correctly.
@immutable
class AppColorsX extends ThemeExtension<AppColorsX> {
  const AppColorsX({
    required this.card,
    required this.textSecondary,
    required this.statusActive,
    required this.statusIdle,
    required this.statusOffline,
    required this.statusGpsDisabled,
    required this.statusLowBattery,
    required this.shadow,
  });

  final Color card;
  final Color textSecondary;
  final Color statusActive;
  final Color statusIdle;
  final Color statusOffline;
  final Color statusGpsDisabled;
  final Color statusLowBattery;
  final Color shadow;

  static const light = AppColorsX(
    card: AppPalette.lightCard,
    textSecondary: AppPalette.textSecondaryLight,
    statusActive: AppPalette.statusActive,
    statusIdle: AppPalette.statusIdle,
    statusOffline: AppPalette.statusOffline,
    statusGpsDisabled: AppPalette.statusGpsDisabled,
    statusLowBattery: AppPalette.statusLowBattery,
    shadow: AppPalette.shadowLight,
  );

  static const dark = AppColorsX(
    card: AppPalette.darkCard,
    textSecondary: AppPalette.textSecondaryDark,
    statusActive: AppPalette.statusActive,
    statusIdle: AppPalette.statusIdle,
    statusOffline: AppPalette.statusOffline,
    statusGpsDisabled: AppPalette.statusGpsDisabled,
    statusLowBattery: AppPalette.statusLowBattery,
    shadow: AppPalette.shadowDark,
  );

  @override
  AppColorsX copyWith({Color? card, Color? textSecondary}) => AppColorsX(
        card: card ?? this.card,
        textSecondary: textSecondary ?? this.textSecondary,
        statusActive: statusActive,
        statusIdle: statusIdle,
        statusOffline: statusOffline,
        statusGpsDisabled: statusGpsDisabled,
        statusLowBattery: statusLowBattery,
        shadow: shadow,
      );

  @override
  AppColorsX lerp(AppColorsX? other, double t) {
    if (other == null) return this;
    return AppColorsX(
      card: Color.lerp(card, other.card, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      statusActive: Color.lerp(statusActive, other.statusActive, t)!,
      statusIdle: Color.lerp(statusIdle, other.statusIdle, t)!,
      statusOffline: Color.lerp(statusOffline, other.statusOffline, t)!,
      statusGpsDisabled:
          Color.lerp(statusGpsDisabled, other.statusGpsDisabled, t)!,
      statusLowBattery:
          Color.lerp(statusLowBattery, other.statusLowBattery, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

/// Sugar: `context.appColors.statusActive`
extension AppColorsContext on BuildContext {
  AppColorsX get appColors => Theme.of(this).extension<AppColorsX>()!;
}

abstract final class AppTheme {
  static ThemeData get light => _build(
        brightness: Brightness.light,
        background: AppPalette.cream,
        surface: AppPalette.lightCard,
        textPrimary: AppPalette.textPrimaryLight,
        extension: AppColorsX.light,
      );

  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        background: AppPalette.darkBg,
        surface: AppPalette.darkSurface,
        textPrimary: AppPalette.textPrimaryDark,
        extension: AppColorsX.dark,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color textPrimary,
    required AppColorsX extension,
  }) {
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: AppPalette.amber,
      onPrimary: AppPalette.textPrimaryLight, // dark text on amber — contrast
      secondary: AppPalette.softPurple,
      onSecondary: AppPalette.lightCard,
      error: AppPalette.coral,
      onError: AppPalette.lightCard,
      surface: surface,
      onSurface: textPrimary,
    );

    final textTheme = TextTheme(
      displaySmall: AppTextStyles.display.copyWith(color: textPrimary),
      headlineSmall: AppTextStyles.heading.copyWith(color: textPrimary),
      titleMedium: AppTextStyles.bodyMedium.copyWith(color: textPrimary),
      bodyMedium: AppTextStyles.body.copyWith(color: textPrimary),
      bodySmall:
          AppTextStyles.caption.copyWith(color: extension.textSecondary),
      labelLarge: AppTextStyles.button.copyWith(color: textPrimary),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      textTheme: textTheme,
      extensions: [extension],
      splashFactory: InkRipple.splashFactory,

      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: AppTextStyles.heading.copyWith(color: textPrimary),
      ),

      cardTheme: CardThemeData(
        color: extension.card,
        elevation: 0, // shadows come from AppDimens.shadow via AppCard
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        ),
        margin: EdgeInsets.zero,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: extension.card,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppDimens.grid * 2,
          vertical: AppDimens.grid * 1.75,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
          borderSide: BorderSide(color: extension.textSecondary.withValues(alpha: 0.25)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
          borderSide: BorderSide(color: extension.textSecondary.withValues(alpha: 0.25)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
          borderSide: const BorderSide(color: AppPalette.amber, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
          borderSide: const BorderSide(color: AppPalette.coral),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
          borderSide: const BorderSide(color: AppPalette.coral, width: 1.5),
        ),
        hintStyle: AppTextStyles.body.copyWith(color: extension.textSecondary),
        errorStyle: AppTextStyles.caption.copyWith(color: AppPalette.coral),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: extension.card,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppDimens.sheetRadius)),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: extension.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.cardRadius),
        ),
        titleTextStyle: AppTextStyles.heading.copyWith(color: textPrimary),
        contentTextStyle: AppTextStyles.body.copyWith(color: textPrimary),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: extension.textSecondary,
        textColor: textPrimary,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppDimens.grid * 2),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppPalette.amber
              : extension.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppPalette.amber.withValues(alpha: 0.4)
              : extension.textSecondary.withValues(alpha: 0.25),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor:
            brightness == Brightness.light ? AppPalette.darkBg : extension.card,
        contentTextStyle:
            AppTextStyles.body.copyWith(color: AppPalette.textPrimaryDark),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDimens.buttonRadius),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: extension.textSecondary.withValues(alpha: 0.15),
        thickness: 1,
        space: 1,
      ),
    );
  }
}

// ── Theme mode state (Riverpod + persistence) ────────────────────────────

/// Overridden in main() with the real instance — keeps everything sync.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Override in main()'),
);

const _kThemeModeKey = 'theme_mode';

class ThemeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final stored = ref.read(sharedPreferencesProvider).getString(_kThemeModeKey);
    return switch (stored) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.light, // default: light (cream is the brand look)
    };
  }

  void toggle() => setMode(
      state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);

  void setMode(ThemeMode mode) {
    state = mode;
    ref
        .read(sharedPreferencesProvider)
        .setString(_kThemeModeKey, mode == ThemeMode.dark ? 'dark' : 'light');
  }
}

final themeModeProvider =
    NotifierProvider<ThemeNotifier, ThemeMode>(ThemeNotifier.new);
