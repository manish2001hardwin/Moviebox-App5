import 'package:flutter/material.dart';

/// Visual identity: near-black background, red accent (Netflix-like),
/// soft grey secondary text, rounded 6px posters.
class C {
  static const bg = Color(0xFF0B0B0F);
  static const surface = Color(0xFF16161D);
  static const surface2 = Color(0xFF23232C);
  static const accent = Color(0xFFE50914);
  static const text2 = Color(0xFFB3B3B3);
}

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: C.bg,
    colorScheme: const ColorScheme.dark(
      primary: C.accent,
      secondary: C.accent,
      surface: C.surface,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0B0B0F),
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected) ? Colors.white : C.text2,
          )),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? Colors.white : C.text2,
          )),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: C.surface2,
      selectedColor: C.accent,
      checkmarkColor: Colors.white,
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.surface2,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: C.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    ),
    dividerTheme: const DividerThemeData(color: Color(0x14FFFFFF)),
  );
}
