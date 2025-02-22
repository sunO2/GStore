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
    var colors = <String,Color>{
      "primary":colorScheme.primary,
      "primaryContainer":colorScheme.primaryContainer,
      "primaryFixed":colorScheme.primaryFixed,
      "primaryFixedDim":colorScheme.primaryFixedDim,
      "secondary":colorScheme.secondary,
      "secondaryContainer":colorScheme.secondaryContainer,
      "secondaryFixed":colorScheme.secondaryFixed,
      "secondaryFixedDim":colorScheme.secondaryFixedDim,
      "tertiary":colorScheme.tertiary,
      "tertiaryContainer":colorScheme.tertiaryContainer,
      "tertiaryFixed":colorScheme.tertiaryFixed,
      "tertiaryFixedDim":colorScheme.tertiaryFixedDim,
      "error":colorScheme.error,
      "errorContainer":colorScheme.errorContainer,
      "surface":colorScheme.surface,
      "surfaceBright":colorScheme.surfaceBright,
      "surfaceContainer":colorScheme.surfaceContainer,
      "surfaceContainerHigh":colorScheme.surfaceContainerHigh,
      "surfaceContainerHighest":colorScheme.surfaceContainerHighest,
      "surfaceContainerLow":colorScheme.surfaceContainerLow,
      "surfaceContainerLowest":colorScheme.surfaceContainerLowest,
      "surfaceDim":colorScheme.surfaceDim,
      "surfaceTint":colorScheme.surfaceTint,
    };

    final logic = Get.put(UpdateLogic());
    return Scaffold(
        appBar: AppBar(
          title: const Text("应用更新"),
        ),
        body: Container(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
            children: colors.keys.map((key){
                var color = colors[key];
                return colorWidget(context,key,color!);
            }).toList(),
          ),
          ),
        ));
  }

  Widget colorWidget(BuildContext context,String key,Color color){
    return Row(
      children: [
        Text(key),
        Expanded(child: Container(height: 20,color: color,margin: const EdgeInsets.only(left: 16,top: 8,bottom: 8),width: double.maxFinite,)),
      ],
    );
  }
}
