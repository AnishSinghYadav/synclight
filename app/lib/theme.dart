import 'package:flutter/material.dart';

/// SyncLight look: near-black like ChatGPT's dark mode, white primary actions, RGB accents.
class SL {
  static const bg = Color(0xFF0D0D0D);
  static const surface = Color(0xFF171717);
  static const card = Color(0xFF1C1C1C);
  static const cardHigh = Color(0xFF262626);
  static const border = Color(0xFF2B2B2B);
  static const text = Color(0xFFECECEC);
  static const muted = Color(0xFF9B9B9B);
  static const faint = Color(0xFF5C5C5C);
  static const good = Color(0xFF2EE59D);
  static const bad = Color(0xFFFF5A5F);
  static const warn = Color(0xFFFFB13B);

  /// The RGB accent used for glows, rings and the logo.
  static const rgb = <Color>[
    Color(0xFFFF2D6F),
    Color(0xFFFFB13B),
    Color(0xFF2EE59D),
    Color(0xFF2FC2FF),
    Color(0xFF7B5CFF),
    Color(0xFFFF2D6F),
  ];

  static const radius = 20.0;
}

ThemeData buildTheme() {
  final scheme = const ColorScheme.dark(
    primary: Colors.white,
    onPrimary: Colors.black,
    secondary: SL.text,
    onSecondary: Colors.black,
    surface: SL.surface,
    onSurface: SL.text,
    error: SL.bad,
    onError: Colors.black,
    errorContainer: Color(0xFF3A1416),
    onErrorContainer: Color(0xFFFFB4B6),
    primaryContainer: SL.cardHigh,
    onPrimaryContainer: SL.text,
    surfaceContainerHighest: SL.cardHigh,
    outline: SL.border,
    outlineVariant: SL.border,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: SL.bg,
    canvasColor: SL.bg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: SL.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: SL.text, fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.2),
      iconTheme: IconThemeData(color: SL.text),
    ),
    cardTheme: CardThemeData(
      color: SL.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SL.radius),
        side: const BorderSide(color: SL.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        disabledBackgroundColor: SL.cardHigh,
        minimumSize: const Size.fromHeight(52),
        shape: shape,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: SL.text,
        side: const BorderSide(color: SL.border),
        minimumSize: const Size.fromHeight(52),
        shape: shape,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: SL.muted, shape: shape),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: Colors.white,
      inactiveTrackColor: Color(0xFF333333),
      thumbColor: Colors.white,
      overlayColor: Color(0x22FFFFFF),
      trackHeight: 6,
      valueIndicatorColor: Colors.white,
      valueIndicatorTextStyle: TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.black : SL.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : SL.cardHigh),
      trackOutlineColor: WidgetStateProperty.all(SL.border),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: SL.card,
      selectedColor: Colors.white,
      labelStyle: const TextStyle(color: SL.text),
      secondaryLabelStyle: const TextStyle(color: Colors.black),
      side: const BorderSide(color: SL.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      checkmarkColor: Colors.black,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: SL.card,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: SL.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: SL.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.white)),
      hintStyle: const TextStyle(color: SL.faint),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: SL.cardHigh,
      contentTextStyle: const TextStyle(color: SL.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: SL.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(SL.radius)),
    ),
    dividerTheme: const DividerThemeData(color: SL.border),
    expansionTileTheme: const ExpansionTileThemeData(
      iconColor: SL.muted,
      collapsedIconColor: SL.muted,
      textColor: SL.text,
      collapsedTextColor: SL.text,
      shape: Border(),
      collapsedShape: Border(),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Colors.white, linearTrackColor: SL.cardHigh),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: ZoomPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
