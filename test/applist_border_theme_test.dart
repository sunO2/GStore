import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/service/badge_service.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/core/update/update_manager.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/page/home/tab/applist/view.dart';
import 'package:gstore/page/home/tab/applist/widgets/empty_state_widget.dart';
import 'package:gstore/page/home/tab/applist/widgets/horizontal_app_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页区卡片/头像边框响应主题 borderStyle（AppBorders）测试
///
/// 覆盖：
/// - HorizontalAppRow 卡片边框宽度随 cardTheme.shape.side（默认 1.0 / 自定义 1.5）
/// - EmptyStateWidget 快速添加卡片边框宽度随主题
/// - ApplistPage 头像边框非黑色（outlineVariant 系色），宽度随主题

AggregatedAppInfo _app(String id) => AggregatedAppInfo(
      addedAppInfo: AddedAppInfo(channelId: 'github', appId: id),
      appInfo: AppSummary(
        appId: id,
        packageName: 'com.example.$id',
        name: 'App $id',
        user: 'owner',
        repositories: 'owner/$id',
        icon: '',
        des: 'desc',
      ),
      channel: ChannelType.github,
    );

/// 横向卡片中带边框的 Container（唯一：角标/图标容器均无边框）
Container _borderedContainer(WidgetTester tester) {
  final containers = tester.widgetList<Container>(find.byType(Container));
  return containers.firstWhere(
    (c) =>
        c.decoration is BoxDecoration &&
        (c.decoration as BoxDecoration).border != null,
  );
}

Border _borderOf(Container container) =>
    ((container.decoration! as BoxDecoration).border! as Border);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HorizontalAppRow 卡片边框', () {
    Future<void> pumpRow(WidgetTester tester, {CardThemeData? cardTheme}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(cardTheme: cardTheme),
          home: Scaffold(
            body: HorizontalAppRow(
              apps: [_app('a')],
              onTap: (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('默认主题：边框宽度 1.0、颜色 outlineVariant', (tester) async {
      await pumpRow(tester);

      final border = _borderOf(_borderedContainer(tester));
      final scheme = Theme.of(tester.element(find.byType(HorizontalAppRow)))
          .colorScheme;

      expect(border.top.width, 1.0);
      expect(border.bottom.width, 1.0);
      expect(border.left.width, 1.0);
      expect(border.right.width, 1.0);
      expect(border.top.color, scheme.outlineVariant);
    });

    testWidgets('自定义 cardTheme width 1.5：边框宽度跟随 1.5、颜色仍 outlineVariant',
        (tester) async {
      await pumpRow(
        tester,
        cardTheme: const CardThemeData(
          shape: RoundedRectangleBorder(
            side: BorderSide(width: 1.5, color: Colors.red),
          ),
        ),
      );

      final border = _borderOf(_borderedContainer(tester));
      final scheme = Theme.of(tester.element(find.byType(HorizontalAppRow)))
          .colorScheme;

      expect(border.top.width, 1.5);
      expect(border.bottom.width, 1.5);
      expect(border.left.width, 1.5);
      expect(border.right.width, 1.5);
      // 颜色保留语义色 outlineVariant（不被主题 side 颜色覆盖）
      expect(border.top.color, scheme.outlineVariant);
    });
  });

  group('EmptyStateWidget 快速添加卡片边框', () {
    Future<void> pumpEmpty(WidgetTester tester,
        {CardThemeData? cardTheme}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(cardTheme: cardTheme),
          home: Scaffold(
            body: EmptyStateWidget(onImportSample: () {}),
          ),
        ),
      );
    }

    RoundedRectangleBorder cardShape(WidgetTester tester) =>
        tester.widget<Card>(find.byType(Card).first).shape!
            as RoundedRectangleBorder;

    testWidgets('默认主题：卡片边框宽度 1.0', (tester) async {
      await pumpEmpty(tester);

      expect(cardShape(tester).side.width, 1.0);
    });

    testWidgets('自定义 cardTheme width 1.5：卡片边框宽度跟随', (tester) async {
      await pumpEmpty(
        tester,
        cardTheme: const CardThemeData(
          shape: RoundedRectangleBorder(
            side: BorderSide(width: 1.5, color: Colors.red),
          ),
        ),
      );

      expect(cardShape(tester).side.width, 1.5);
    });
  });

  group('ApplistPage 头像边框', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Get.reset();
      // ApplistLogic(GithubRequestMix) 构造期依赖 + view 内 Get.find 依赖
      Get.put<GithubRestClient>(GithubRestClient(Dio()));
      Get.put(BadgeService());
      Get.put(UpdateManagerService());
      Get.put(UserManager.instance);
    });

    tearDown(() {
      Get.reset();
    });

    testWidgets('头像边框非黑色（outlineVariant 系色），宽度随主题', (tester) async {
      UserManager.instance.userInfo.value = const UserInfo(
        login: 'tester',
        name: 'tester',
        avatarUrl: 'https://example.com/avatar.png',
      );

      await tester.pumpWidget(const GetMaterialApp(home: ApplistPage()));
      // 固定 pump：头像 placeholder（AppLoading）为无限动画，pumpAndSettle 会超时
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final avatarContainer = tester.widget<Container>(
        find
            .ancestor(
              of: find.byType(CachedNetworkImage),
              matching: find.byType(Container),
            )
            .first,
      );
      final border = _borderOf(avatarContainer);
      final scheme =
          Theme.of(tester.element(find.byType(ApplistPage))).colorScheme;

      // 修复前 Border.all(width: 1.5) 无颜色 = 默认黑色（C 类硬编码）
      expect(border.top.color, isNot(Colors.black));
      expect(border.top.color, scheme.outlineVariant);
      expect(border.top.width, 1.0);
      expect(tester.takeException(), isNull);
    });
  });
}