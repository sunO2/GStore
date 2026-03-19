import 'package:flutter/material.dart';

/// App typography system
/// Provides consistent font sizes, weights, line heights, and predefined text styles
class AppTypography {
  AppTypography._();

  // ========== Font Sizes ==========
  static const double sizeXXXS = 10.0;
  static const double sizeXXS = 11.0;
  static const double sizeXS = 12.0;
  static const double sizeSM = 14.0;
  static const double sizeMD = 16.0;
  static const double sizeLG = 18.0;
  static const double sizeXL = 20.0;
  static const double sizeXXL = 24.0;
  static const double sizeXXXL = 32.0;
  static const double sizeHuge = 40.0;
  static const double sizeMassive = 48.0;

  // ========== Font Weights ==========
  static const FontWeight weightThin = FontWeight.w100;
  static const FontWeight weightExtraLight = FontWeight.w200;
  static const FontWeight weightLight = FontWeight.w300;
  static const FontWeight weightRegular = FontWeight.w400;
  static const FontWeight weightMedium = FontWeight.w500;
  static const FontWeight weightSemiBold = FontWeight.w600;
  static const FontWeight weightBold = FontWeight.w700;
  static const FontWeight weightExtraBold = FontWeight.w800;
  static const FontWeight weightBlack = FontWeight.w900;

  // ========== Line Heights ==========
  static const double heightTight = 1.2;
  static const double heightSnug = 1.3;
  static const double heightNormal = 1.5;
  static const double heightRelaxed = 1.7;
  static const double heightLoose = 2.0;

  // ========== Letter Spacing ==========
  static const double spacingTight = -0.5;
  static const double spacingNormal = 0.0;
  static const double spacingWide = 0.5;
  static const double spacingWider = 1.0;
  static const double spacingWidest = 1.5;

  // ========== Icon Sizes ==========
  static const double iconXXS = 10.0;
  static const double iconXS = 12.0;
  static const double iconSM = 15.0;
  static const double iconMD = 18.0;
  static const double iconLG = 20.0;
  static const double iconXL = 24.0;
  static const double iconXXL = 32.0;
  static const double iconXXXL = 48.0;
  static const double iconHuge = 56.0;
  static const double iconMassive = 64.0;
  static const double iconGiant = 80.0;

  // ========== Headline Styles ==========

  /// Display Large - Largest heading, hero text
  static const TextStyle displayLarge = TextStyle(
    fontSize: sizeHuge,
    fontWeight: weightBold,
    height: heightTight,
    letterSpacing: spacingTight,
  );

  /// Display Medium - Large heading
  static const TextStyle displayMedium = TextStyle(
    fontSize: sizeXXXL,
    fontWeight: weightBold,
    height: heightTight,
    letterSpacing: spacingNormal,
  );

  /// Display Small - Medium heading
  static const TextStyle displaySmall = TextStyle(
    fontSize: sizeXXL,
    fontWeight: weightSemiBold,
    height: heightSnug,
    letterSpacing: spacingNormal,
  );

  /// Headline Large - Page title
  static const TextStyle headlineLarge = TextStyle(
    fontSize: sizeXL,
    fontWeight: weightSemiBold,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Headline Medium - Section title
  static const TextStyle headlineMedium = TextStyle(
    fontSize: sizeLG,
    fontWeight: weightSemiBold,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Headline Small - Subsection title
  static const TextStyle headlineSmall = TextStyle(
    fontSize: sizeMD,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Title Large - Card title, large item title
  static const TextStyle titleLarge = TextStyle(
    fontSize: sizeMD,
    fontWeight: weightSemiBold,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Title Medium - List item title, card title
  static const TextStyle titleMedium = TextStyle(
    fontSize: sizeMD,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Title Small - Small item title
  static const TextStyle titleSmall = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingWide,
  );

  // ========== Body Styles ==========

  /// Body Large - Primary body text, readable paragraphs
  static const TextStyle bodyLarge = TextStyle(
    fontSize: sizeMD,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Body Medium - Standard body text
  static const TextStyle bodyMedium = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Body Small - Secondary body text, captions
  static const TextStyle bodySmall = TextStyle(
    fontSize: sizeXS,
    fontWeight: weightRegular,
    height: heightRelaxed,
    letterSpacing: spacingWide,
  );

  // ========== Label Styles ==========

  /// Label Large - Large button label, tab label
  static const TextStyle labelLarge = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingWide,
  );

  /// Label Medium - Button label, chip label
  static const TextStyle labelMedium = TextStyle(
    fontSize: sizeXS,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingWide,
  );

  /// Label Small - Small label, tag
  static const TextStyle labelSmall = TextStyle(
    fontSize: sizeXXS,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingWider,
  );

  // ========== Specialized Styles ==========

  /// Code text - Monospace for code snippets
  static const TextStyle code = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
    fontFamily: 'monospace',
  );

  /// Caption - Image captions, timestamps
  static const TextStyle caption = TextStyle(
    fontSize: sizeXS,
    fontWeight: weightRegular,
    height: heightRelaxed,
    letterSpacing: spacingWide,
  );

  /// Overline - Decorative text above content
  static const TextStyle overline = TextStyle(
    fontSize: sizeXS,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingWidest,
  );

  /// Button - Button text
  static const TextStyle button = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingWide,
  );

  /// Subtitle - Supporting text below titles
  static const TextStyle subtitle = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Price - Special style for prices
  static const TextStyle price = TextStyle(
    fontSize: sizeXL,
    fontWeight: weightSemiBold,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Price small - Small price text
  static const TextStyle priceSmall = TextStyle(
    fontSize: sizeMD,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Number - Number display, counters
  static const TextStyle number = TextStyle(
    fontSize: sizeLG,
    fontWeight: weightSemiBold,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Timestamp - Date/time display
  static const TextStyle timestamp = TextStyle(
    fontSize: sizeXS,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Link - Clickable text
  static const TextStyle link = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingNormal,
    decoration: TextDecoration.underline,
  );

  /// Error text - Error messages
  static const TextStyle error = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Warning text - Warning messages
  static const TextStyle warning = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Success text - Success messages
  static const TextStyle success = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Info text - Informational messages
  static const TextStyle info = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightRegular,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  // ========== Semantic Weight Variants ==========

  /// Bold body text
  static const TextStyle bodyLargeBold = TextStyle(
    fontSize: sizeMD,
    fontWeight: weightSemiBold,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Medium body text
  static const TextStyle bodyMediumMedium = TextStyle(
    fontSize: sizeSM,
    fontWeight: weightMedium,
    height: heightNormal,
    letterSpacing: spacingNormal,
  );

  /// Bold small text
  static const TextStyle bodySmallBold = TextStyle(
    fontSize: sizeXS,
    fontWeight: weightSemiBold,
    height: heightRelaxed,
    letterSpacing: spacingWide,
  );
}
