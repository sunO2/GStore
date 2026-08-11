/// 优化后的应用列表页面
/// 简化交互，添加快速搜索功能
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/service/metadata_submit_service.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/user_info/user_info.dart';
import 'package:gstore/page/web/browser.dart';

import 'logic.dart';
import 'state.dart';
import 'package:gstore/core/core.dart';

/// 快速搜索对话框
/// 简化应用搜索流程，一站式完成搜索和添加
class QuickSearchDialog extends StatefulWidget {
  const QuickSearchDialog({super.key});

  @override
  State<QuickSearchDialog> createState() => _QuickSearchDialogState();
}

class _QuickSearchDialogState extends State<QuickSearchDialog> {
  final TextEditingController _searchController = TextEditingController();
  ChannelType? _selectedChannel;
  ChannelType? _currentSearchChannel;
  final List<AppSummary> _searchResults = [];
  bool _isSearching = false;
  String? _errorMessage;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 执行搜索
  Future<void> _performSearch() async {
    if (_searchController.text.trim().isEmpty) {
      setState(() => _errorMessage = '请输入搜索关键词');
      return;
    }

    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _searchResults.clear();
    });

    try {
      final manager = ChannelManager.instance;

      // 确定搜索渠道
      final targetChannel = _selectedChannel ?? manager.defaultChannelType;
      final channel = manager.getChannel(targetChannel);

      if (channel == null) {
        setState(() {
          _errorMessage = '所选渠道不可用';
          _isSearching = false;
        });
        return;
      }

      // 记录当前搜索渠道（用于结果项展示渠道相关操作）
      _currentSearchChannel = targetChannel;

      // 执行搜索
      final result = await channel.searchApps(
        _searchController.text.trim(),
        forceRefresh: true,
      );

      if (result.success && result.data != null) {
        setState(() {
          _searchResults.addAll(result.data!);
          _isSearching = false;
        });
      } else {
        setState(() {
          _errorMessage = result.error ?? '搜索失败';
          _isSearching = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '搜索出错: $e';
        _isSearching = false;
      });
    }
  }

  /// 添加应用
  Future<void> _addApp(AppSummary app) async {
    try {
      final aggregator = AppAggregatorManager.instance;
      await aggregator.addApp(
        channel: _currentSearchChannel ?? ChannelType.localDb,
        appInfo: app,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已添加 ${app.name}'),
            duration: const Duration(seconds: 2),
            action: SnackBarAction(
              label: '查看',
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('添加失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 标题和关闭按钮
            Row(
              children: [
                const Icon(Icons.search, size: 24),
                const SizedBox(width: 8),
                const Text(
                  '快速搜索应用',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),

            const Divider(height: 24),

            // 搜索输入框
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '输入应用名称搜索...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchResults.clear();
                            _errorMessage = null;
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
              ),
              onSubmitted: (_) => _performSearch(),
            ),

            const SizedBox(height: 12),

            // 渠道选择器
            _buildChannelSelector(context),

            const SizedBox(height: 12),

            // 搜索按钮
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSearching ? null : _performSearch,
                icon: _isSearching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                label: Text(_isSearching ? '搜索中...' : '搜索'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // 错误提示
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_errorMessage!, style: TextStyle(color: Colors.red.shade700))),
                  ],
                ),
              ),

            const SizedBox(height: 8),

            // 搜索结果
            Expanded(
              child: _searchResults.isEmpty
                  ? Center(
                      child: Text(
                        _isSearching
                            ? '正在搜索...'
                            : '输入关键词并选择渠道开始搜索',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final app = _searchResults[index];
                        return _buildSearchResultItem(context, app);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 渠道选择器
  Widget _buildChannelSelector(BuildContext context) {
    final manager = ChannelManager.instance;
    final channels = manager.allChannelInfo;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // 全部渠道（使用默认渠道）
        FilterChip(
          label: const Text('默认渠道'),
          avatar: const Icon(Icons.apps, size: 16),
          selected: _selectedChannel == null,
          onSelected: (selected) {
            if (selected) {
              setState(() => _selectedChannel = null);
            }
          },
          selectedColor: Theme.of(context).colorScheme.primaryContainer,
          showCheckmark: false,
        ),
        // 各个渠道
        ...channels.map((info) {
          final isSelected = _selectedChannel == info.type;
          return FilterChip(
            label: Text(info.name),
            avatar: Icon(
              _getChannelIcon(info.type),
              size: 16,
            ),
            selected: isSelected,
            onSelected: (selected) {
              setState(() => _selectedChannel = info.type);
            },
            selectedColor: Theme.of(context).colorScheme.primaryContainer,
            showCheckmark: false,
          );
        }),
      ],
    );
  }

  /// 搜索结果项
  Widget _buildSearchResultItem(BuildContext context, AppSummary app) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: app.icon.isNotEmpty
              ? CachedNetworkImage(
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => const CupertinoActivityIndicator(radius: 14),
                  errorWidget: (context, url, error) => Container(
                    width: 48,
                    height: 48,
                    color: Colors.grey.shade200,
                    child: const Icon(Icons.error),
                  ),
                  imageUrl: app.icon,
                )
              : Container(
                  width: 48,
                  height: 48,
                  color: Colors.grey.shade200,
                  child: const Icon(Icons.apps),
                ),
        ),
        title: Text(app.name),
        subtitle: Text(app.des ?? '暂无描述'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // GitHub 渠道 / LocalDb 的 GitHub 仓库类型：完善应用信息
            if (_canSubmitAppMetadata(app))
              IconButton(
                icon: const Icon(Icons.manage_search),
                color: Theme.of(context).colorScheme.primary,
                tooltip: '完善应用信息',
                onPressed: () => _submitAppMetadata(app),
              ),
            IconButton(
              icon: const Icon(Icons.add_circle),
              color: Theme.of(context).colorScheme.primary,
              onPressed: () => _addApp(app),
            ),
          ],
        ),
        onTap: () => _addApp(app),
      ),
    );
  }

  /// 当前搜索结果是否可提交元数据（GitHub 渠道，或 LocalDb 的 GitHub 仓库类型）
  bool _canSubmitAppMetadata(AppSummary app) {
    if (_currentSearchChannel == ChannelType.github) return true;
    if (_currentSearchChannel == ChannelType.localDb) {
      return app.user.isNotEmpty && app.repositories.isNotEmpty;
    }
    return false;
  }

  /// 提交元数据提取请求（GitHub 渠道 / LocalDb 的 GitHub 仓库类型搜索结果）
  Future<void> _submitAppMetadata(AppSummary app) async {
    // GitHub 渠道：appId 为 owner/repo；LocalDb：使用 user + repositories
    final parts = app.appId.split('/');
    final String owner;
    final String repo;
    if (parts.length == 2) {
      owner = parts[0];
      repo = parts[1];
    } else if (app.user.isNotEmpty && app.repositories.isNotEmpty) {
      owner = app.user;
      repo = app.repositories;
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法解析仓库地址，请从详情页提交')),
      );
      return;
    }

    final userManager = Get.find<UserManager>();
    final loggedIn = await userManager.isLoggedIn();
    if (!loggedIn) {
      final goLogin = await AppDialogs.showDialog(
        title: '需要登录 GitHub',
        content: '提交完善应用信息需要登录 GitHub 账号，是否前往登录？',
        confirmText: '去登录',
        cancelText: '取消',
      );
      if (goLogin == true && mounted) {
        Get.toNamed(AppRoute.auth);
      }
      return;
    }

    if (!mounted) return;
    final confirmed = await AppDialogs.showDialog(
      title: '完善应用信息',
      content: '将向 GStore-Repositorys 提交 issue，'
          '由 Actions 自动提取 $owner/$repo 最新 release APK 的\n'
          '应用名 / 包名 / 图标 / 版本信息。',
      confirmText: '提交',
      cancelText: '取消',
    );
    if (confirmed != true) return;

    try {
      final url = await MetadataSubmitService.instance.submitAppMetadata(
        owner: owner,
        repo: repo,
      );
      if (!mounted) return;
      if (url == null) {
        AppDialogs.showError('未登录，无法提交');
        return;
      }
      AppDialogs.showSuccess(
        '已提交，仓库 Actions 将自动处理\n可在 issue 中查看进度',
        title: '提交成功',
      );
    } catch (e) {
      if (mounted) {
        AppDialogs.showError('提交失败: $e', title: '提交失败');
      }
    }
  }

  IconData _getChannelIcon(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return Icons.storage;
      case ChannelType.github:
        return Icons.code;
      case ChannelType.http:
        return Icons.cloud;
      case ChannelType.vivo:
        return Icons.phone_android;
      case ChannelType.fdroid:
        return Icons.android;
      default:
        return Icons.extension;
    }
  }
}

/// 原有的 ApplistPage 保持不变，只添加快速搜索入口
class ApplistPage extends StatefulWidget {
  const ApplistPage({super.key});

  @override
  State<StatefulWidget> createState() => AppListState();
}

class AppListState extends State<ApplistPage>
    with AutomaticKeepAliveClientMixin {
  @override
  Widget build(BuildContext context) {
    super.build(context);
    final logic = Get.put(ApplistLogic());
    final state = Get.find<ApplistLogic>().state;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => _showQuickSearch(context),
          child: Tooltip(
            message: "快速搜索",
            child: Container(
              decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(40)),
                  color: Theme.of(context).primaryColor.withAlpha(30)),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: const Row(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Icon(
                      Icons.search,
                      size: 24,
                    ),
                  ),
                  SizedBox(
                    width: 16,
                  ),
                  Text("快速搜索应用",
                      style:
                          TextStyle(fontWeight: FontWeight.w400, fontSize: 18))
                ],
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: "应用更新",
            icon: const Icon(
              AliIcon.appUpdateCenter,
            ),
            onPressed: () => Get.toNamed(AppRoute.updateCenter),
          ),
          IconButton(
            tooltip: "下载中心",
            icon: const Icon(AliIcon.appDownloadCenter),
            onPressed: () => Get.toNamed(AppRoute.downloadCenter),
          ),
          Obx(() {
            var user = Get.find<UserManager>().userInfo.value;

            icon(UserInfo fuser) {
              if (fuser.avatarUrl?.isNotEmpty ?? false) {
                return Container(
                  width: Theme.of(context).appBarTheme.iconTheme?.size ?? 24,
                  height: Theme.of(context).appBarTheme.iconTheme?.size ?? 24,
                  decoration: BoxDecoration(
                      border: Border.all(width: 1.5),
                      borderRadius: BorderRadius.all(
                        Radius.circular(
                            Theme.of(context).appBarTheme.iconTheme?.size ??
                                24),
                      )),
                  child: ClipOval(
                    child: CachedNetworkImage(
                      width:
                          Theme.of(context).appBarTheme.iconTheme?.size ?? 24,
                      height:
                          Theme.of(context).appBarTheme.iconTheme?.size ?? 24,
                      placeholder: (context, url) =>
                          const CupertinoActivityIndicator(
                        radius: 8,
                      ),
                      errorWidget: (context, url, error) => const Icon(
                        Icons.account_circle_outlined,
                      ),
                      imageUrl: fuser.avatarUrl ?? "",
                    ),
                  ),
                );
              } else {
                return const Icon(
                  Icons.account_circle_outlined,
                );
              }
            }

            onPressed() {
              if (user.avatarUrl?.isEmpty ?? true) {
                Get.toNamed(AppRoute.auth);
              } else {
                GStoreInAppBrowser inAppBrowser = GStoreInAppBrowser();
                final settings = ChromeSafariBrowserSettings(
                  shareState: CustomTabsShareState.SHARE_STATE_ON,
                  barCollapsingEnabled: true,
                );
                inAppBrowser.open(
                    url: WebUri(user.htmlUrl ?? ""), settings: settings);
              }
            }

            return IconButton(
              tooltip: user.name ?? "登陆",
              icon: icon(user),
              onPressed: onPressed,
            );
          }),
        ],
      ),
      body: Obx(() => _buildBody(context, logic, state)),
    );
  }

  /// 显示快速搜索对话框
  void _showQuickSearch(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => const QuickSearchDialog(),
    );

    if (result == true) {
      // 用户点击了"查看"，刷新列表
      final logic = Get.find<ApplistLogic>();
      logic.loadAggregatedApps();
    }
  }

  Widget _buildBody(BuildContext context, ApplistLogic logic, ApplistState state) {
    // 加载状态
    if (state.isLoading.value) {
      return const Center(child: CircularProgressIndicator());
    }

    // 错误状态
    if (state.errorMessage.value.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(state.errorMessage.value),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: logic.loadAggregatedApps,
              child: const Text('重试'),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => _showQuickSearch(context),
              child: const Text('快速搜索添加应用'),
            ),
          ],
        ),
      );
    }

    // 空状态 - 优化引导
    if (state.apps.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.apps_outlined,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              '还没有添加任何应用',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '点击上方搜索栏快速添加应用',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _showQuickSearch(context),
              icon: const Icon(Icons.search),
              label: const Text('快速搜索'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                // 切换到发现Tab
                final homeLogic = Get.find<HomeLogic>();
                homeLogic.jumpToPage(1); // 发现页的索引
              },
              icon: const Icon(Icons.explore),
              label: const Text('浏览发现页'),
            ),
          ],
        ),
      );
    }

    // 应用列表
    return RefreshIndicator(
      onRefresh: logic.loadAggregatedApps,
      child: CustomScrollView(
        slivers: [
          // Banner
          SliverToBoxAdapter(
            child: FutureBuilder(
                future: logic.getBanner(),
                builder: (contest, snap) {
                  var data = snap.data;
                  if (null == data) {
                    return const SizedBox();
                  }
                  var length = data.length;
                  return SizedBox(
                    height: 180,
                    child: PageView.builder(
                      controller: PageController(
                          viewportFraction: 0.8, initialPage: 5000),
                      itemCount: 10000,
                      itemBuilder: (context, item) {
                        var index = item % length;
                        return GestureDetector(
                          onTap: () {
                            // Banner 点击暂不处理，因为 banner 数据结构可能变化
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(
                                left: 8, right: 8, top: 16, bottom: 16),
                            child: ClipRRect(
                              borderRadius:
                                  const BorderRadius.all(Radius.circular(16)),
                              child: CachedNetworkImage(
                                height: 180,
                                fit: BoxFit.fill,
                                imageUrl: data[index]["banner"],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                }),
          ),

          // 应用列表
          SliverPadding(
            padding: const EdgeInsets.all(0),
            sliver: SliverGrid.builder(
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
              ),
              itemBuilder: (context, index) {
                var app = state.apps[index];
                return _buildAggregatedAppItem(
                  context,
                  app,
                  logic,
                );
              },
              itemCount: state.apps.length,
            ),
          ),
        ],
      ),
    );
  }

  /// 聚合应用卡片
  Widget _buildAggregatedAppItem(
    BuildContext context,
    AggregatedAppInfo app,
    ApplistLogic logic,
  ) {
    final channelColor = _getChannelColor(app.channel);
    final channelShortName = _getChannelShortName(app.channel);

    return GestureDetector(
      onTap: () => logic.appDetail(app),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: Stack(
                children: [
                  // 图标
                  Positioned.fill(
                    child: Hero(
                      tag: app.appInfo.icon ?? "",
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: app.appInfo.icon != null
                              ? CachedNetworkImage(
                                  fit: BoxFit.fill,
                                  placeholder: (context, url) {
                                    return const CupertinoActivityIndicator(
                                      radius: 8,
                                    );
                                  },
                                  errorWidget: (context, url, error) {
                                    return const Icon(Icons.error);
                                  },
                                  imageUrl: app.appInfo.icon!,
                                  width: 56,
                                  height: 56,
                                )
                              : const SizedBox(),
                        ),
                      ),
                    ),
                  ),
                  // 渠道标识 - 优化显示
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 3, vertical: 1),
                      decoration: BoxDecoration(
                        color: channelColor.withOpacity(0.9),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(0),
                          topLeft: Radius.circular(4),
                          bottomLeft: Radius.circular(4),
                          bottomRight: Radius.circular(16),
                        ),
                      ),
                      child: Tooltip(
                        message: _getChannelFullName(app.channel),
                        child: Text(
                          channelShortName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 7,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Hero(
            tag: app.appInfo.name ?? "",
            child: Text(
              app.appInfo.name ?? "",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 获取渠道颜色
  Color _getChannelColor(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return Colors.blue;
      case ChannelType.github:
        return Colors.purple;
      case ChannelType.http:
        return Colors.orange;
      case ChannelType.vivo:
        return const Color(0xFF4155D0);
      case ChannelType.fdroid:
        return const Color(0xFF1976D2);
      default:
        return Colors.grey;
    }
  }

  /// 获取渠道短名称
  String _getChannelShortName(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return 'DB';
      case ChannelType.github:
        return 'GH';
      case ChannelType.http:
        return 'API';
      case ChannelType.vivo:
        return 'vivo';
      case ChannelType.fdroid:
        return 'FD';
      default:
        return 'APP';
    }
  }

  /// 获取渠道完整名称
  String _getChannelFullName(ChannelType type) {
    switch (type) {
      case ChannelType.localDb:
        return '本地数据库';
      case ChannelType.github:
        return 'GitHub';
      case ChannelType.http:
        return 'HTTP API';
      case ChannelType.vivo:
        return 'vivo 应用商店';
      case ChannelType.fdroid:
        return 'F-Droid';
      default:
        return '未知渠道';
    }
  }

  @override
  bool get wantKeepAlive => true;
}
