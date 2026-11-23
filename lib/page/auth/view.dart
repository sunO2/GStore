import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/core.dart';
import 'logic.dart';
import 'state.dart';

/// GitHub 登录页——纯 Flutter 登录说明页（验证码/复制/重新获取/去 GitHub/轮询进度）。
class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  /// 页面逻辑（build 时从 ref 取）。
  AuthPageNotifier get logic => ref.read(authPageProvider.notifier);

  /// 页面状态（ref.watch，状态变化触发 build 重建）。
  AuthPageState get state => ref.watch(authPageProvider);

  /// 有效期显示刷新定时器（每 5 秒重建一次，让剩余秒数滚动）。
  Timer? _expiryTicker;

  /// 应用生命周期监听（回到前台时恢复轮询）。
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // 进入登录说明页：取消残留轮询/通知，重置状态（避免显示上一次的验证码）
    logic.reset();
    // 进入登录说明页即请求设备码（UserManager.deviceId 会同步写入剪贴板）
    logic.getDeviceCode();
    _expiryTicker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
    // 应用回到前台（如从 GitHub 浏览器返回）：恢复轮询
    _lifecycleListener = AppLifecycleListener(
      onResume: () => logic.onAppResumed(),
    );
    WidgetsBinding.instance.addObserver(_lifecycleListener);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleListener);
    _expiryTicker?.cancel();
    super.dispose();
  }

  /// 设备码获取中：复制/重新获取等操作禁用。
  bool get _fetching => state.status == AuthStatus.requestUserCode;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text("GitHub 登录",
            style: TextStyle(fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: const Icon(TablerIcons.x),
          onPressed: () {
            logic.cancelLogin();
            Navigator.of(context).pop(
                state.status == AuthStatus.success ? AuthStatus.success : null);
          },
        ),
      ),
      body: Column(
        children: [
          // 描述内容——整个说明页不能滑动，滚动区域调整为描述内容
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _description(context),
              ),
            ),
          ),
          // 底部验证码登录区域——圆角边框与上方描述区分
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppRadius.radiusSheet)),
              // 只画上/左/右三边，底部与屏幕边缘衔接
              border: Border(
                top: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant),
                left: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant),
                right: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant),
              ),
            ),
            child: _buildBottom(context, state),
          ),
        ],
      ),
    );
  }

  List<Widget> _description(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return [
      // 主标题
      Text(
        '登录 GitHub 账户',
        style: textTheme.headlineSmall
            ?.copyWith(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 16),
      // 为什么需要登录 GitHub 账户？
      Text(
        '为什么需要登录 GitHub 账户？',
        style: textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        'GitHub 是全球最大的代码托管平台，为开发者提供丰富的工具与服务。登录 GitHub 账户后，您可以：',
        style: textTheme.bodyMedium,
      ),
      const SizedBox(height: 8),
      _bullet(scheme, textTheme,
          '突破 GitHub API 未登录访问的频率限制（每小时约 60 次），畅享更速访问。'),
      _bullet(scheme, textTheme,
          '安全访问您在 GitHub 上的私有仓库，进行代码管理与协作。'),
      _bullet(scheme, textTheme,
          '获得个性化服务，例如根据您的 GitHub 信息推荐可能感兴趣的内容。'),
      const SizedBox(height: 16),
      // 登录方式与用户信息
      Text(
        '登录方式：GitHub 设备认证',
        style: textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        '无需在应用中输入密码。登录成功后获取您的 GitHub 用户信息（如头像、用户名、公开仓库等），您可以在 GitHub 设置中随时撤销授权。',
        style: textTheme.bodyMedium,
      ),
      const SizedBox(height: 16),
      // 提示
      Text(
        '提示：整个认证过程完全在 GitHub 官方页面完成，密码绝不会在本应用中输入或存储。',
        style: textTheme.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    ];
  }

  Widget _bullet(ColorScheme scheme, TextTheme textTheme, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(TablerIcons.circle_check, size: 14, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }

  Widget _buildBottom(BuildContext context, AuthPageState state) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasCode = state.verificationCode.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
          left: 16,
          right: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 验证码 + 剩余有效时间（副标题） + 复制/重新获取（垂直居中于两者）
          Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 有验证码显示验证码；无验证码显示占位（避免一片空白）
                    hasCode
                        ? Text(
                            '验证码：${state.verificationCode}',
                            style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: scheme.primary),
                          )
                        : Text(
                            '（验证码将在获取成功后显示……）',
                            style: textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                    // 剩余有效时间——紧贴验证码作为副标题（小字，次要色）
                    if (state.codeExpiresAt != null)
                      Text(
                        _expirySubtitle(state),
                        style: textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 复制图标——点击复制验证码
              IconButton(
                onPressed: hasCode ? logic.copyVerificationCode : null,
                icon: const Icon(TablerIcons.copy),
                tooltip: '复制验证码',
              ),
              // 重新获取图标（无文字）
              IconButton(
                onPressed: _fetching ? null : logic.reFetchDeviceCode,
                icon: const Icon(TablerIcons.refresh),
                tooltip: '重新获取',
              ),
            ],
          ),
          // 轮询进度——图标 + 文本的紧凑可点击行，自适应宽度并靠左
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: logic.togglePollLogs,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        state.showPollLogs
                            ? TablerIcons.chevron_up
                            : TablerIcons.chevron_down,
                        size: 16,
                        color: scheme.primary),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      state.showPollLogs ? '收起轮询日志' : '查看轮询进度',
                      style: textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                          fontWeight: AppTypography.weightMedium),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 轮询日志（默认展开，固定高度，最新一条在底部）
          if (state.showPollLogs)
            Container(
              height: 160,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: state.pollingLogs.length,
                itemBuilder: (context, i) {
                  final logs = state.pollingLogs;
                  return Text(
                    logs[logs.length - 1 - i],
                    style: textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  );
                },
              ),
            ),
          // 提示：授权成功后可直接关闭本页面
          if (state.status == AuthStatus.verifying)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Row(
                children: [
                  Icon(TablerIcons.info_circle,
                      size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      '在 GitHub 完成授权后，即可关闭本页面（登录结果会自动同步）',
                      style: textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          // 状态文字 + 等待中的 app 统一 loading
          _hintWidget(context, state),
          const SizedBox(height: 16),
          // 去 GitHub 登录
          FilledButton(
            onPressed: _fetching ? null : logic.openGitHubDevicePage,
            child: const Text('去 GitHub 登录'),
          ),
        ],
      ),
    );
  }

  /// 验证码剩余有效时间（副标题文本）。
  String _expirySubtitle(AuthPageState state) {
    final expiresAt = state.codeExpiresAt;
    if (expiresAt == null) return '';
    final remaining = expiresAt.difference(DateTime.now()).inSeconds;
    if (remaining <= 0) return '已过期';
    if (remaining >= 120) return '剩余约 ${remaining ~/ 60} 分钟';
    return '剩余 $remaining 秒';
  }

  Widget _hintWidget(BuildContext context, AuthPageState state) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final text = Text(
      _hintText(state),
      style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
    );
    // 轮试失败（initial）——显示失败提示 + 「再次轮试」按钮
    if (state.status == AuthStatus.initial) {
      return Row(
        children: [
          text,
          const SizedBox(width: 8),
          IconButton(
            onPressed: logic.retryPolling,
            icon: const Icon(TablerIcons.player_play, size: 16),
            tooltip: '再次轮询',
          ),
        ],
      );
    }
    if (state.status != AuthStatus.verifying) return text;
    // 等待 GitHub 授权中——在文字后增加 app 统一的 loading
    return Row(
      children: [
        text,
        const SizedBox(width: 8),
        const AppLoading(size: AppLoadingSize.small),
      ],
    );
  }

  String _hintText(AuthPageState state) {
    switch (state.status) {
      case AuthStatus.requestUserCode:
        return '正在获取验证码…';
      case AuthStatus.verifying:
        return '等待 GitHub 授权中…';
      case AuthStatus.initial:
        return '登录失败，请重试';
      case AuthStatus.empty:
        return state.verificationCode.isEmpty
            ? '点击「去 GitHub 登录」开始登录'
            : '在 GitHub 设备页输入验证码';
      case AuthStatus.success:
        return '登录成功，即将返回';
    }
  }
}
