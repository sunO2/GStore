import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:gstore/db/db_manager.dart';
import 'package:gstore/http/download/downloadService.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';

import 'package:gstore/core/core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

registerService() async {
  Get.lazyPut<GithubRestClient>(() => GithubRestClient(DioClient().get()));
  Get.lazyPut<GithubAuthApi>(() => GithubAuthApi(DioClient().get()));
  await Get.putAsync<DbManager>(() async => await DbManager().init());
  Get.lazyPut<DownloadService>(() => DownloadService(DioClient().get()));
}

main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Get.config(
      enableLog: true,
      defaultPopGesture: true,
      defaultTransition: Transition.cupertino);
  await registerService();

  runApp(DynamicColorBuilder(builder: (light, dark) {
    return GetMaterialApp(
      onInit: () async {
        final SharedPreferencesAsync prefs = SharedPreferencesAsync();
        var token = await prefs.getString("github_token");
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
