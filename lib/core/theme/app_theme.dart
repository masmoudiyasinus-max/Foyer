import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Architectural Material 3 Palette
  static const Color layer1Surface = Color(0xFF0A0C10); // Noir profond
  static const Color layer2Container = Color(0xFF141820); // Anthracite doux
  static const Color layer3Border = Color(0xFF222834); // Bordures nettes 1px
  static const Color layer4Active = Color(0xFFFFFFFF); // Blanc net
  static const Color nordicSlate = Color(0xFF3B82F6); // Bleu Ardoise Nordique
  static const Color nordicSlateLight = Color(0xFF60A5FA); // Bleu Ardoise Nordique Clair
  static const Color alertRed = Color(0xFFEF4444); // Rouge Alerte strict
  static const Color textPrimary = layer4Active; // Alias for active primary text
  static const Color textMuted = Color(0xFF94A3B8); // Gris bleuté clair (WCAG AAA)

  // Common hairline structural border
  static const BorderSide hairlineBorder = BorderSide(
    color: layer3Border,
    width: 1.0,
  );

  static ThemeData get darkTheme {
    final TextTheme baseTextTheme = Typography.material2021().white;

    // Display & Title font: Red Rose (weights 400 & 500 only)
    // Body & Button font: Instrument Sans (weights 400 & 500 only)
    final TextTheme customTextTheme = baseTextTheme.copyWith(
      displayLarge: GoogleFonts.redRose(
        fontSize: 32,
        fontWeight: FontWeight.w500,
        color: layer4Active,
        letterSpacing: -0.5,
      ),
      displayMedium: GoogleFonts.redRose(
        fontSize: 28,
        fontWeight: FontWeight.w400,
        color: layer4Active,
      ),
      displaySmall: GoogleFonts.redRose(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        color: layer4Active,
      ),
      headlineLarge: GoogleFonts.redRose(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: layer4Active,
      ),
      headlineMedium: GoogleFonts.redRose(
        fontSize: 20,
        fontWeight: FontWeight.w400,
        color: layer4Active,
      ),
      headlineSmall: GoogleFonts.redRose(
        fontSize: 18,
        fontWeight: FontWeight.w400,
        color: layer4Active,
      ),
      titleLarge: GoogleFonts.redRose(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: layer4Active,
      ),
      titleMedium: GoogleFonts.redRose(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: layer4Active,
      ),
      titleSmall: GoogleFonts.redRose(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: layer4Active,
      ),
      bodyLarge: GoogleFonts.instrumentSans(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: layer4Active,
      ),
      bodyMedium: GoogleFonts.instrumentSans(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: layer4Active,
      ),
      bodySmall: GoogleFonts.instrumentSans(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: textMuted,
      ),
      labelLarge: GoogleFonts.instrumentSans(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: layer4Active,
      ),
      labelMedium: GoogleFonts.instrumentSans(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: layer4Active,
      ),
      labelSmall: GoogleFonts.instrumentSans(
        fontSize: 10,
        fontWeight: FontWeight.w400,
        color: textMuted,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: layer1Surface,
      canvasColor: layer1Surface,
      cardColor: layer2Container,
      dividerColor: layer3Border,

      colorScheme: const ColorScheme(
        brightness: Brightness.dark,
        primary: nordicSlate,
        onPrimary: layer4Active,
        secondary: nordicSlate,
        onSecondary: layer4Active,
        surface: layer1Surface,
        onSurface: layer4Active,
        surfaceContainer: layer2Container,
        surfaceContainerHigh: layer2Container,
        outline: layer3Border,
        outlineVariant: layer3Border,
        error: alertRed,
        onError: layer4Active,
      ),

      textTheme: customTextTheme,

      // Zero elevation across all components
      appBarTheme: AppBarTheme(
        backgroundColor: layer1Surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: layer4Active),
        titleTextStyle: GoogleFonts.redRose(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: layer4Active,
        ),
        shape: const Border(
          bottom: BorderSide(color: layer3Border, width: 1),
        ),
      ),

      cardTheme: CardThemeData(
        color: layer2Container,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          side: hairlineBorder,
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: layer2Container,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: hairlineBorder,
          borderRadius: BorderRadius.circular(16),
        ),
        titleTextStyle: GoogleFonts.redRose(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: layer4Active,
        ),
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: layer2Container,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: hairlineBorder,
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: layer2Container,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: hairlineBorder,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: hairlineBorder,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: layer4Active, width: 1),
        ),
        hintStyle: GoogleFonts.instrumentSans(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: textMuted,
        ),
        labelStyle: GoogleFonts.instrumentSans(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: layer4Active,
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: layer4Active,
          foregroundColor: layer1Surface,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          textStyle: GoogleFonts.instrumentSans(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: layer4Active,
          backgroundColor: layer2Container,
          elevation: 0,
          side: hairlineBorder,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          textStyle: GoogleFonts.instrumentSans(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: layer4Active,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: GoogleFonts.instrumentSans(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.selected)) {
            return nordicSlate;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(layer4Active),
        side: hairlineBorder,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(3),
        ),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.selected)) {
            return layer4Active;
          }
          return textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.selected)) {
            return nordicSlate;
          }
          return layer2Container;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith<Color>((states) {
          return layer3Border;
        }),
      ),

      datePickerTheme: DatePickerThemeData(
        backgroundColor: layer2Container,
        surfaceTintColor: Colors.transparent,
        dividerColor: layer3Border,
        headerBackgroundColor: layer1Surface,
        headerForegroundColor: layer4Active,
        headerHeadlineStyle: GoogleFonts.redRose(
          fontSize: 20,
          fontWeight: FontWeight.w500,
          color: layer4Active,
        ),
        headerHelpStyle: GoogleFonts.instrumentSans(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: textMuted,
        ),
        dayStyle: GoogleFonts.instrumentSans(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: layer4Active,
        ),
        dayForegroundColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.selected)) {
            return layer4Active;
          }
          if (states.contains(WidgetState.disabled)) {
            return textMuted.withValues(alpha: 0.4);
          }
          return layer4Active;
        }),
        dayBackgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.selected)) {
            return nordicSlate;
          }
          return Colors.transparent;
        }),
        todayForegroundColor: WidgetStateProperty.all(nordicSlateLight),
        todayBorder: const BorderSide(color: nordicSlate, width: 1),
        shape: RoundedRectangleBorder(
          side: hairlineBorder,
          borderRadius: BorderRadius.circular(8),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: layer1Surface,
        elevation: 0,
        height: 64,
        indicatorColor: layer2Container,
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: layer4Active, size: 22);
          }
          return const IconThemeData(color: textMuted, size: 22);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.instrumentSans(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: layer4Active,
            );
          }
          return GoogleFonts.instrumentSans(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: textMuted,
          );
        }),
      ),

      tabBarTheme: TabBarThemeData(
        indicatorColor: layer4Active,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: layer3Border,
        labelColor: layer4Active,
        unselectedLabelColor: textMuted,
        labelStyle: GoogleFonts.instrumentSans(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: GoogleFonts.instrumentSans(
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}
