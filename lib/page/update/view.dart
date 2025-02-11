import 'package:cached_network_image/cached_network_image.dart';
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
    final logic = Get.put(UpdateLogic());
    return Scaffold(
        appBar: AppBar(
          title: const Text("应用更新"),
        ),
        body: Container(
          padding: const EdgeInsets.all(16),
          child: const SizedBox(),
        ));
  }
}
