import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/core/theme/theme_utils.dart';
import 'package:gstore/core/transition/app_transition.dart';
import 'package:gstore/core/translations/app_translations.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:gstore/http/github/github_auth_api.dart';
import 'package:gstore/http/github/github_client.dart';

import 'package:gstore/core/core.dart';

registerService() async {
  Get.lazyPut<GithubRestClient>(() => GithubRestClient(DioClient().get()));
  await Get.putAsync<DbManager>(() async => await DbManager().init());

  Get.lazyPut<GithubAuthApi>(() => GithubAuthApi(DioClient().get()));
  Get.lazyPut<DownloadService>(() => DownloadService(DioClient().get()));
  Get.lazyPut<UserManager>(() => UserManager());
}

colorSchemeSeed(ColorScheme? color, Brightness brightness) {
  if (null == color) {
    if (brightness == Brightness.light) {
      return ColorScheme.dark(brightness: brightness);
    } else {
      return ColorScheme.light(brightness: brightness);
    }
  }
  return color;
}

main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Get.config(
    enableLog: true,
    defaultPopGesture: false,
    // defaultTransition: Transition.cupertino
  );
  await registerService();

  runApp(DynamicColorBuilder(builder: (light, dark) {
    return GetMaterialApp(
      onInit: () async {
        DioClient().authorization = await Get.find<UserManager>().token;
      },
      builder: (context, child) {
        configStatusBar();
        return Material(
          child: SafeArea(
            top: false,
            bottom: false,
            child: child!,
          ),
        );
      },
      locale: Get.deviceLocale,
      fallbackLocale: const Locale("en", "US"),
      translations: Messages(),
      initialRoute: AppRoute.home,
      getPages: AppRoute.pages,
      themeMode: ThemeMode.system,
      customTransition: AppTransition(),
      theme: ThemeData(
          colorScheme: colorSchemeSeed(light, Brightness.light),
          useMaterial3: true,
          brightness: Brightness.light),
      darkTheme: ThemeData(
          colorScheme: colorSchemeSeed(dark, Brightness.dark),
          useMaterial3: true,
          brightness: Brightness.dark),
    );
  }));
}
