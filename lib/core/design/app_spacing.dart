import 'package:flutter/widgets.dart';

/// App spacing constants
/// Follows 4px grid system for consistent spacing
class AppSpacing {
  AppSpacing._();

  // ========== Spacing Scale ==========
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double xxxl = 32.0;
  static const double huge = 40.0;
  static const double massive = 48.0;

  // ========== All Sides ==========
  static const EdgeInsets allXS = EdgeInsets.all(xs);
  static const EdgeInsets allSM = EdgeInsets.all(sm);
  static const EdgeInsets allMD = EdgeInsets.all(md);
  static const EdgeInsets allLG = EdgeInsets.all(lg);
  static const EdgeInsets allXL = EdgeInsets.all(xl);
  static const EdgeInsets allXXL = EdgeInsets.all(xxl);
  static const EdgeInsets allXXXL = EdgeInsets.all(xxxl);
  static const EdgeInsets allHuge = EdgeInsets.all(huge);
  static const EdgeInsets allMassive = EdgeInsets.all(massive);

  // ========== Horizontal Only ==========
  static const EdgeInsets onlyHorizontalXS = EdgeInsets.symmetric(horizontal: xs);
  static const EdgeInsets onlyHorizontalSM = EdgeInsets.symmetric(horizontal: sm);
  static const EdgeInsets onlyHorizontalMD = EdgeInsets.symmetric(horizontal: md);
  static const EdgeInsets onlyHorizontalLG = EdgeInsets.symmetric(horizontal: lg);
  static const EdgeInsets onlyHorizontalXL = EdgeInsets.symmetric(horizontal: xl);
  static const EdgeInsets onlyHorizontalXXL = EdgeInsets.symmetric(horizontal: xxl);
  static const EdgeInsets onlyHorizontalXXXL = EdgeInsets.symmetric(horizontal: xxxl);
  static const EdgeInsets onlyHorizontalHuge = EdgeInsets.symmetric(horizontal: huge);

  // ========== Vertical Only ==========
  static const EdgeInsets onlyVerticalXS = EdgeInsets.symmetric(vertical: xs);
  static const EdgeInsets onlyVerticalSM = EdgeInsets.symmetric(vertical: sm);
  static const EdgeInsets onlyVerticalMD = EdgeInsets.symmetric(vertical: md);
  static const EdgeInsets onlyVerticalLG = EdgeInsets.symmetric(vertical: lg);
  static const EdgeInsets onlyVerticalXL = EdgeInsets.symmetric(vertical: xl);
  static const EdgeInsets onlyVerticalXXL = EdgeInsets.symmetric(vertical: xxl);
  static const EdgeInsets onlyVerticalXXXL = EdgeInsets.symmetric(vertical: xxxl);
  static const EdgeInsets onlyVerticalHuge = EdgeInsets.symmetric(vertical: huge);

  // ========== Top Only ==========
  static const EdgeInsets onlyTopXS = EdgeInsets.only(top: xs);
  static const EdgeInsets onlyTopSM = EdgeInsets.only(top: sm);
  static const EdgeInsets onlyTopMD = EdgeInsets.only(top: md);
  static const EdgeInsets onlyTopLG = EdgeInsets.only(top: lg);
  static const EdgeInsets onlyTopXL = EdgeInsets.only(top: xl);
  static const EdgeInsets onlyTopXXL = EdgeInsets.only(top: xxl);
  static const EdgeInsets onlyTopXXXL = EdgeInsets.only(top: xxxl);

  // ========== Bottom Only ==========
  static const EdgeInsets onlyBottomXS = EdgeInsets.only(bottom: xs);
  static const EdgeInsets onlyBottomSM = EdgeInsets.only(bottom: sm);
  static const EdgeInsets onlyBottomMD = EdgeInsets.only(bottom: md);
  static const EdgeInsets onlyBottomLG = EdgeInsets.only(bottom: lg);
  static const EdgeInsets onlyBottomXL = EdgeInsets.only(bottom: xl);
  static const EdgeInsets onlyBottomXXL = EdgeInsets.only(bottom: xxl);
  static const EdgeInsets onlyBottomXXXL = EdgeInsets.only(bottom: xxxl);

  // ========== Left Only ==========
  static const EdgeInsets onlyLeftXS = EdgeInsets.only(left: xs);
  static const EdgeInsets onlyLeftSM = EdgeInsets.only(left: sm);
  static const EdgeInsets onlyLeftMD = EdgeInsets.only(left: md);
  static const EdgeInsets onlyLeftLG = EdgeInsets.only(left: lg);
  static const EdgeInsets onlyLeftXL = EdgeInsets.only(left: xl);
  static const EdgeInsets onlyLeftXXL = EdgeInsets.only(left: xxl);
  static const EdgeInsets onlyLeftXXXL = EdgeInsets.only(left: xxxl);

  // ========== Right Only ==========
  static const EdgeInsets onlyRightXS = EdgeInsets.only(right: xs);
  static const EdgeInsets onlyRightSM = EdgeInsets.only(right: sm);
  static const EdgeInsets onlyRightMD = EdgeInsets.only(right: md);
  static const EdgeInsets onlyRightLG = EdgeInsets.only(right: lg);
  static const EdgeInsets onlyRightXL = EdgeInsets.only(right: xl);
  static const EdgeInsets onlyRightXXL = EdgeInsets.only(right: xxl);
  static const EdgeInsets onlyRightXXXL = EdgeInsets.only(right: xxxl);

  // ========== Horizontal + Vertical ==========
  static const EdgeInsets horizontalXS_verticalSM = EdgeInsets.symmetric(horizontal: xs, vertical: sm);
  static const EdgeInsets horizontalXS_verticalMD = EdgeInsets.symmetric(horizontal: xs, vertical: md);
  static const EdgeInsets horizontalXS_verticalLG = EdgeInsets.symmetric(horizontal: xs, vertical: lg);
  static const EdgeInsets horizontalXS_verticalXL = EdgeInsets.symmetric(horizontal: xs, vertical: xl);

  static const EdgeInsets horizontalSM_verticalXS = EdgeInsets.symmetric(horizontal: sm, vertical: xs);
  static const EdgeInsets horizontalSM_verticalMD = EdgeInsets.symmetric(horizontal: sm, vertical: md);
  static const EdgeInsets horizontalSM_verticalLG = EdgeInsets.symmetric(horizontal: sm, vertical: lg);
  static const EdgeInsets horizontalSM_verticalXL = EdgeInsets.symmetric(horizontal: sm, vertical: xl);

  static const EdgeInsets horizontalMD_verticalXS = EdgeInsets.symmetric(horizontal: md, vertical: xs);
  static const EdgeInsets horizontalMD_verticalSM = EdgeInsets.symmetric(horizontal: md, vertical: sm);
  static const EdgeInsets horizontalMD_verticalLG = EdgeInsets.symmetric(horizontal: md, vertical: lg);
  static const EdgeInsets horizontalMD_verticalXL = EdgeInsets.symmetric(horizontal: md, vertical: xl);

  static const EdgeInsets horizontalLG_verticalXS = EdgeInsets.symmetric(horizontal: lg, vertical: xs);
  static const EdgeInsets horizontalLG_verticalSM = EdgeInsets.symmetric(horizontal: lg, vertical: sm);
  static const EdgeInsets horizontalLG_verticalMD = EdgeInsets.symmetric(horizontal: lg, vertical: xs);
  static const EdgeInsets horizontalLG_verticalXL = EdgeInsets.symmetric(horizontal: lg, vertical: xl);

  static const EdgeInsets horizontalXL_verticalXS = EdgeInsets.symmetric(horizontal: xl, vertical: xs);
  static const EdgeInsets horizontalXL_verticalSM = EdgeInsets.symmetric(horizontal: xl, vertical: sm);
  static const EdgeInsets horizontalXL_verticalMD = EdgeInsets.symmetric(horizontal: xl, vertical: md);
  static const EdgeInsets horizontalXL_verticalLG = EdgeInsets.symmetric(horizontal: xl, vertical: lg);

  static const EdgeInsets horizontalXXL_verticalXS = EdgeInsets.symmetric(horizontal: xxl, vertical: xs);
  static const EdgeInsets horizontalXXL_verticalSM = EdgeInsets.symmetric(horizontal: xxl, vertical: sm);
  static const EdgeInsets horizontalXXL_verticalMD = EdgeInsets.symmetric(horizontal: xxl, vertical: md);
  static const EdgeInsets horizontalXXL_verticalLG = EdgeInsets.symmetric(horizontal: xxl, vertical: lg);

  static const EdgeInsets onlyHorizontalXS_verticalLG = EdgeInsets.symmetric(horizontal: xs, vertical: lg);
  static const EdgeInsets onlyHorizontalSM_verticalLG = EdgeInsets.symmetric(horizontal: sm, vertical: lg);
  static const EdgeInsets onlyHorizontalMD_verticalLG = EdgeInsets.symmetric(horizontal: md, vertical: lg);
  static const EdgeInsets onlyHorizontalLG_verticalLG = EdgeInsets.symmetric(horizontal: lg, vertical: lg);

  static const EdgeInsets horizontalXS_verticalXS = EdgeInsets.symmetric(horizontal: xs, vertical: xs);

  // ========== Special Component Spacing ==========
  /// Card padding - standard internal padding for cards
  static const EdgeInsets cardPadding = EdgeInsets.all(lg);

  /// List item padding - padding for list items
  static const EdgeInsets listItemPadding = EdgeInsets.symmetric(horizontal: lg, vertical: xs);

  /// Dialog padding - padding for dialog content
  static const EdgeInsets dialogPadding = EdgeInsets.all(xxl);

  /// Bottom sheet padding - padding for bottom sheet content
  static const EdgeInsets bottomSheetPadding = EdgeInsets.symmetric(horizontal: lg, vertical: xl);

  /// Button padding - padding for buttons
  static const EdgeInsets buttonPadding = EdgeInsets.symmetric(horizontal: xl, vertical: md);

  /// Input field padding - padding for text input fields
  static const EdgeInsets inputFieldPadding = EdgeInsets.symmetric(horizontal: md, vertical: sm);

  /// Chip padding - padding for chips
  static const EdgeInsets chipPadding = EdgeInsets.symmetric(horizontal: md, vertical: xs);

  /// AppBar padding - padding for app bar content
  static const EdgeInsets appBarPadding = EdgeInsets.symmetric(horizontal: lg);

  /// Tab padding - padding for tab content
  static const EdgeInsets tabPadding = EdgeInsets.symmetric(horizontal: lg, vertical: md);

  /// Section padding - padding for content sections
  static const EdgeInsets sectionPadding = EdgeInsets.all(xxl);

  /// Section spacing - margin between sections
  static const EdgeInsets sectionSpacing = EdgeInsets.only(bottom: xxxl);

  /// Group spacing - margin between item groups
  static const EdgeInsets groupSpacing = EdgeInsets.only(bottom: xl);

  /// Item spacing - margin between items
  static const EdgeInsets itemSpacing = EdgeInsets.only(bottom: md);

  /// Safe area padding - additional padding for safe areas
  static const EdgeInsets safeAreaPadding = EdgeInsets.all(lg);

  /// Page padding - standard page content padding
  static const EdgeInsets pagePadding = EdgeInsets.all(lg);

  /// Page horizontal padding - horizontal padding for full-width pages
  static const EdgeInsets pageHorizontalPadding = EdgeInsets.symmetric(horizontal: lg);

  /// Page vertical padding - vertical padding for scrollable pages
  static const EdgeInsets pageVerticalPadding = EdgeInsets.symmetric(vertical: lg);

  /// Icon button padding - padding for icon buttons
  static const EdgeInsets iconButtonPadding = EdgeInsets.all(sm);

  /// Small card padding - compact card padding
  static const EdgeInsets smallCardPadding = EdgeInsets.all(md);

  /// Large card padding - spacious card padding
  static const EdgeInsets largeCardPadding = EdgeInsets.all(xxl);

  /// Modal padding - padding for modal bottom sheets
  static const EdgeInsets modalPadding = EdgeInsets.all(xxl);

  /// Slider padding - padding for sliders
  static const EdgeInsets sliderPadding = EdgeInsets.symmetric(horizontal: lg);

  /// Switch padding - padding for switches
  static const EdgeInsets switchPadding = EdgeInsets.symmetric(horizontal: sm);

  /// Checkbox padding - padding for checkboxes
  static const EdgeInsets checkboxPadding = EdgeInsets.symmetric(horizontal: sm);

  /// Radio padding - padding for radio buttons
  static const EdgeInsets radioPadding = EdgeInsets.symmetric(horizontal: sm);

  // ========== Sliver Padding ==========
  /// Sliver padding for app bar
  static const EdgeInsets sliverAppBarPadding = EdgeInsets.symmetric(horizontal: lg, vertical: md);

  /// Sliver padding for list headers
  static const EdgeInsets sliverHeaderPadding = EdgeInsets.symmetric(horizontal: lg, vertical: md);

  /// Sliver padding for list items
  static const EdgeInsets sliverListItemPadding = EdgeInsets.symmetric(horizontal: lg, vertical: sm);

  // ========== Edge Insets for Specific Sides ==========
  /// Left and right padding
  static const EdgeInsets leftRightXS = EdgeInsets.only(left: xs, right: xs);
  static const EdgeInsets leftRightSM = EdgeInsets.only(left: sm, right: sm);
  static const EdgeInsets leftRightMD = EdgeInsets.only(left: md, right: md);
  static const EdgeInsets leftRightLG = EdgeInsets.only(left: lg, right: lg);
  static const EdgeInsets leftRightXL = EdgeInsets.only(left: xl, right: xl);
  static const EdgeInsets leftRightXXL = EdgeInsets.only(left: xxl, right: xxl);

  /// Top and bottom padding
  static const EdgeInsets topBottomXS = EdgeInsets.only(top: xs, bottom: xs);
  static const EdgeInsets topBottomSM = EdgeInsets.only(top: sm, bottom: sm);
  static const EdgeInsets topBottomMD = EdgeInsets.only(top: md, bottom: md);
  static const EdgeInsets topBottomLG = EdgeInsets.only(top: lg, bottom: lg);
  static const EdgeInsets topBottomXL = EdgeInsets.only(top: xl, bottom: xl);
  static const EdgeInsets topBottomXXL = EdgeInsets.only(top: xxl, bottom: xxl);

  // ========== Three-sided Padding ==========
  /// Horizontal + top padding
  static const EdgeInsets horizontalLG_topXS = EdgeInsets.only(left: lg, right: lg, top: xs);
  static const EdgeInsets horizontalLG_topSM = EdgeInsets.only(left: lg, right: lg, top: sm);
  static const EdgeInsets horizontalLG_topMD = EdgeInsets.only(left: lg, right: lg, top: md);
  static const EdgeInsets horizontalLG_topLG = EdgeInsets.only(left: lg, right: lg, top: lg);

  /// Horizontal + bottom padding
  static const EdgeInsets horizontalLG_bottomXS = EdgeInsets.only(left: lg, right: lg, bottom: xs);
  static const EdgeInsets horizontalLG_bottomSM = EdgeInsets.only(left: lg, right: lg, bottom: sm);
  static const EdgeInsets horizontalLG_bottomMD = EdgeInsets.only(left: lg, right: lg, bottom: md);
  static const EdgeInsets horizontalLG_bottomLG = EdgeInsets.only(left: lg, right: lg, bottom: lg);

  /// Horizontal + vertical (different top and bottom)
  static const EdgeInsets horizontalLG_topXS_bottomXS = EdgeInsets.only(left: lg, right: lg, top: xs, bottom: xs);
  static const EdgeInsets horizontalLG_topXS_bottomSM = EdgeInsets.only(left: lg, right: lg, top: xs, bottom: sm);
  static const EdgeInsets horizontalLG_topXS_bottomMD = EdgeInsets.only(left: lg, right: lg, top: xs, bottom: md);
  static const EdgeInsets horizontalLG_topSM_bottomXS = EdgeInsets.only(left: lg, right: lg, top: sm, bottom: xs);
  static const EdgeInsets horizontalLG_topSM_bottomSM = EdgeInsets.only(left: lg, right: lg, top: sm, bottom: sm);
  static const EdgeInsets horizontalLG_topSM_bottomMD = EdgeInsets.only(left: lg, right: lg, top: sm, bottom: md);
  static const EdgeInsets horizontalLG_topMD_bottomXS = EdgeInsets.only(left: lg, right: lg, top: md, bottom: xs);
  static const EdgeInsets horizontalLG_topMD_bottomSM = EdgeInsets.only(left: lg, right: lg, top: md, bottom: sm);
  static const EdgeInsets horizontalLG_topMD_bottomMD = EdgeInsets.only(left: lg, right: lg, top: md, bottom: md);
  static const EdgeInsets horizontalLG_verticalSM_bottomXS = EdgeInsets.only(left: lg, right: lg, top: sm, bottom: xs);

  // ========== Gap Values ==========
  /// Gap value for SizedBox in columns/rows
  static const double gapXS = xs;
  static const double gapSM = sm;
  static const double gapMD = md;
  static const double gapLG = lg;
  static const double gapXL = xl;
  static const double gapXXL = xxl;
  static const double gapXXXL = xxxl;
  static const double gapHuge = huge;
  static const double gapMassive = massive;
}
