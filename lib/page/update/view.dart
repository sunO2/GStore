import 'package:cached_network_image/cached_network_image.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/utils/logger.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'logic.dart';

class UpdateManager extends StatelessWidget {
  const UpdateManager({super.key});

  @override
  Widget build(BuildContext context) {
    var colorScheme = Theme.of(context).colorScheme;
    var schemeColors = <String, Color>{
      "primary": colorScheme.primary,
      "primaryContainer": colorScheme.primaryContainer,
      "primaryFixed": colorScheme.primaryFixed,
      "primaryFixedDim": colorScheme.primaryFixedDim,
      "secondary": colorScheme.secondary,
      "secondaryContainer": colorScheme.secondaryContainer,
      "secondaryFixed": colorScheme.secondaryFixed,
      "secondaryFixedDim": colorScheme.secondaryFixedDim,
      "tertiary": colorScheme.tertiary,
      "tertiaryContainer": colorScheme.tertiaryContainer,
      "tertiaryFixed": colorScheme.tertiaryFixed,
      "tertiaryFixedDim": colorScheme.tertiaryFixedDim,
      "error": colorScheme.error,
      "errorContainer": colorScheme.errorContainer,
      "surface": colorScheme.surface,
      "surfaceBright": colorScheme.surfaceBright,
      "surfaceContainer": colorScheme.surfaceContainer,
      "surfaceContainerHigh": colorScheme.surfaceContainerHigh,
      "surfaceContainerHighest": colorScheme.surfaceContainerHighest,
      "surfaceContainerLow": colorScheme.surfaceContainerLow,
      "surfaceContainerLowest": colorScheme.surfaceContainerLowest,
      "surfaceDim": colorScheme.surfaceDim,
      "surfaceTint": colorScheme.surfaceTint,
    };

    var themeColors = <String, Color>{
      "primaryColor": Theme.of(context).primaryColor,
      "primaryColorDark": Theme.of(context).primaryColorDark,
      "primaryColorLight": Theme.of(context).primaryColorLight
    };

    final logic = Get.put(UpdateLogic());
    return Scaffold(
        appBar: AppBar(
          title: Text("updata_tip".tr),
        ),
        body: Container(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              children: [
                Text(
                  "Theme: ",
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                ...themeColors.keys.map((key) {
                  var color = themeColors[key];
                  return colorWidget(context, key, color!);
                }),
                Text(
                  "Scheme: ",
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                ...schemeColors.keys.map((key) {
                  var color = schemeColors[key];
                  return colorWidget(context, key, color!);
                })
              ],
            ),
          ),
        ));
  }

  Widget colorWidget(BuildContext context, String key, Color color) {
    return Container(
      color: color,
      padding: EdgeInsets.all(4),
      margin: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
      width: double.maxFinite,
      child: Text(key),
    );
  }
}
