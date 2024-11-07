import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:gstore/http/download/downloadService.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/http/download/downloadService.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Get.config(
      enableLog: true,
      defaultPopGesture: true,
      defaultTransition: Transition.cupertino);

  Get.lazyPut<GithubRestClient>(() {
    return GithubRestClient(DioClient().get());
  });
  Get.lazyPut<DownloadService>(() {
    return DownloadService(DioClient().get());
  });

  runApp(DynamicColorBuilder(builder: (light, dark) {
    return GetMaterialApp(
      onInit: () async {
        final SharedPreferencesAsync prefs = SharedPreferencesAsync();
        var token = await prefs.getString("github_token");
        log("token: $token");
        DioClient().setAuthorization(token);
      },
      // home: const MyHomePage(title: "GStore"),
      builder: (context, child) {
        return Material(
          child: SafeArea(
            child: child!,
          ),
        );
      },
      initialRoute: AppRoute.home,
      getPages: AppRoute.pages,
      themeMode: ThemeMode.system,
      theme: ThemeData(
          colorScheme: light, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(
          colorScheme: dark, useMaterial3: true, brightness: Brightness.dark),
    );
  }));
}
