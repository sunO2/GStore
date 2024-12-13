import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:sprintf/sprintf.dart';

class AliIcon {
  static const String _aLiFontIcon = "AliIconFont";
  static const IconData downloadSuccess =
      IconData(0xe615, fontFamily: _aLiFontIcon);
  static const IconData appStore = IconData(0xe603, fontFamily: _aLiFontIcon);
  static const IconData appStoreActive =
      IconData(0xe664, fontFamily: _aLiFontIcon);
  static const IconData appDownloadCenter =
      IconData(0xe613, fontFamily: _aLiFontIcon);
  static const IconData appUpdateCenter =
      IconData(0xe614, fontFamily: _aLiFontIcon);
  static const IconData browser = IconData(0xe60d, fontFamily: _aLiFontIcon);
  static const IconData history = IconData(0xe665, fontFamily: _aLiFontIcon);
}

class SvgIcon {
  static const _history =
      '''<svg t="1731635168793" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="1050" width="128" height="128"><path d="M644.8 944c-144 0-260.8-116.8-260.8-260.8s116.8-260.8 260.8-260.8 260.8 116.8 260.8 260.8c1.6 144-116.8 260.8-260.8 260.8z" fill="#%x" p-id="1051"></path><path d="M680 702.4c-3.2 0-8-1.6-11.2-3.2l-201.6-120c-6.4-4.8-11.2-11.2-11.2-19.2V256c0-12.8 9.6-22.4 22.4-22.4s22.4 9.6 22.4 22.4v291.2l190.4 113.6c11.2 6.4 14.4 20.8 8 30.4-4.8 8-11.2 11.2-19.2 11.2zM230.4 592c-8 0-16-4.8-19.2-11.2-14.4-25.6-44.8-94.4-22.4-179.2 8-32 24-62.4 44.8-88 8-9.6 22.4-11.2 32-3.2 9.6 8 11.2 22.4 3.2 32-17.6 20.8-30.4 44.8-36.8 72-17.6 68.8 6.4 124.8 19.2 145.6 6.4 11.2 1.6 24-8 30.4-6.4 0-9.6 1.6-12.8 1.6z" fill="#%x" p-id="1052"></path><path d="M304 272m-32 0a32 32 0 1 0 64 0 32 32 0 1 0-64 0Z" fill="#%x" p-id="1053"></path><path d="M491.2 904c-224 0-406.4-182.4-406.4-406.4 0-224 182.4-406.4 406.4-406.4 224 0 406.4 182.4 406.4 406.4 0 224-182.4 406.4-406.4 406.4z m0-768C292.8 136 129.6 299.2 129.6 497.6s161.6 361.6 361.6 361.6 361.6-161.6 361.6-361.6S691.2 136 491.2 136z" fill="#%x" p-id="1054"></path></svg>''';
  static const _browser =
      '''<svg t="1731640502428" class="icon" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" p-id="2140" width="128" height="128"><path d="M692.8 960c-144 0-260.8-116.8-260.8-260.8s116.8-260.8 260.8-260.8 260.8 116.8 260.8 260.8c1.6 144-116.8 260.8-260.8 260.8z" fill="#%x" p-id="2141"></path><path d="M292.8 219.2c-8 0-14.4-3.2-19.2-9.6-8-11.2-4.8-25.6 4.8-33.6 14.4-9.6 44.8-25.6 60.8-33.6 11.2-6.4 25.6-1.6 32 11.2 6.4 11.2 1.6 25.6-11.2 32-25.6 12.8-46.4 24-54.4 30.4-3.2 1.6-8 3.2-12.8 3.2z" fill="#%x" p-id="2142"></path><path d="M515.2 916.8c-224 0-408-182.4-408-408 0-100.8 36.8-198.4 105.6-273.6 8-9.6 24-11.2 33.6-1.6 9.6 8 11.2 24 1.6 33.6-59.2 65.6-92.8 152-92.8 241.6 0 198.4 161.6 360 360 360s360-161.6 360-360S713.6 148.8 515.2 148.8c-32 0-62.4 4.8-92.8 12.8-12.8 3.2-25.6-4.8-28.8-16s4.8-25.6 16-28.8c33.6-9.6 68.8-14.4 105.6-14.4 224 0 408 182.4 408 408 0 222.4-182.4 406.4-408 406.4z" fill="#%x" p-id="2143"></path><path d="M372.8 672c-4.8 0-11.2-1.6-14.4-6.4-4.8-4.8-8-12.8-4.8-20.8L411.2 416c1.6-8 8-12.8 16-16L656 342.4c8-1.6 14.4 0 20.8 4.8 4.8 4.8 8 12.8 4.8 20.8L624 596.8c-1.6 8-8 12.8-16 16L377.6 672h-4.8z m73.6-232l-44.8 182.4 182.4-44.8 44.8-182.4-182.4 44.8z" fill="#%x" p-id="2144"></path></svg>''';
  static browser(BuildContext context, {Color? full, Color? dot}) {
    var fullColor =
        (full ?? Theme.of(context).textTheme.bodyLarge?.color ?? Colors.red)
            .value;
    var dotColor = Theme.of(context).colorScheme.primary.value;
    return ScalableImage.fromSvgString(
        sprintf(_browser, [dotColor, fullColor, fullColor, fullColor]));
  }

  static history(BuildContext context, {Color? full, Color? dot}) {
    var fullColor =
        (full ?? Theme.of(context).textTheme.bodyLarge?.color ?? Colors.red)
            .value;
    var dotColor = Theme.of(context).colorScheme.primary.value;
    return ScalableImage.fromSvgString(sprintf(
        _history, [dotColor, fullColor, fullColor, fullColor, fullColor]));
  }
}
