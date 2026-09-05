import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';
import 'package:gstore/core/utils/logger.dart';
import 'package:gstore/compent/entrance_list.dart';
import 'package:gstore/compent/pressable_scale.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:jovial_svg/jovial_svg.dart';

import 'providers.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _searchController = TextEditingController();

  /// 路由 extra 参数（原 Get.arguments）解析结果。
  /// 需在首次 build 读取（initState 无路由 scope），_extraChecked 保证只解析一次。
  AppCategory? _category;
  bool _extraChecked = false;

  @override
  void initState() {
    super.initState();
    // 搜索入口的输入监听（分类场景无输入框，listener 不会触发）
    _searchController.addListener(_onSearchInput);
  }

  /// 解析路由 extra：分类浏览入口参数为 AppCategory（无参为搜索入口）。
  /// goRouterExtraOf 依赖路由 InheritedWidget，只能在 build 阶段调用。
  void _resolveRouteExtraIfNeeded() {
    if (_extraChecked) return;
    _extraChecked = true;
    final args = goRouterExtraOf(context);
    final category = args is AppCategory ? args : null;
    if (category != null) {
      _category = category;
      // 分类浏览为一次性加载（页面每次 build 仅此一次会命中）
      ref.read(searchProvider.notifier).loadCategory(category);
    }
  }

  void _onSearchInput() {
    ref
        .read(searchProvider.notifier)
        .onInputChanged(_searchController.text);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchInput);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _resolveRouteExtraIfNeeded();
    final results = ref.watch(searchProvider);
    final category = _category;

    return Scaffold(
      appBar: AppBar(
        title: category == null
            ? SizedBox(
                width: 240,
                child: TextField(
                  autofocus: true,
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: "搜索应用",
                    border: InputBorder.none,
                  ),
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(category.description),
                  const SizedBox(
                    width: 6,
                  ),
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: ScalableImageWidget(
                      scale: 0.2,
                      si: ScalableImage.fromSvgString(category.icon),
                    ),
                  ),
                ],
              ),
      ),
      body: Container(
          padding: AppSpacing.allLG,
          child: results.isEmpty
              ? const SizedBox()
              : EntranceList(
                  key: ValueKey(results.length),
                  itemBuilder: (context, index) {
                    var app = results[index];
                    log("app: $app");
                    // 外层 PressableScale 仅做按压反馈（点击由 ListTile 内层 onTap 承接）
                    return PressableScale(
                      child: ListTile(
                        onTap: () {
                          context.push(AppRoute.appDetail, extra: app);
                        },
                        leading: Hero(
                          tag: app.icon,
                          child: Image(
                            image: CachedNetworkImageProvider(
                              results[index].icon,
                            ),
                            width: 48,
                            height: 48,
                          ),
                        ),
                        title: Hero(
                          tag: app.name,
                          child: Text(
                            app.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        subtitle: Text(
                          app.des,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    );
                  },
                  itemCount: results.length,
                )),
    );
  }
}
