import 'package:get/get.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/db/apps/AppInfo.dart';

class ChannelTestState {
  /// 当前选中的渠道
  final selectedChannel = ChannelType.localDb.obs;

  /// 查询结果
  final queryResult = Rx<ChannelResult<dynamic>?>(null);

  /// 查询状态
  final isQuerying = false.obs;

  /// 应用列表
  final apps = <AppInfo>[].obs;

  /// 错误信息
  final errorMessage = ''.obs;

  /// 当前操作类型
  final operationType = 'getAllApps'.obs;

  /// 搜索关键词
  final searchKeyword = ''.obs;

  /// 分类 ID
  final categoryId = 'Tools'.obs;

  /// 应用 ID
  final appId = 'com.example.app'.obs;

  ChannelTestState() {
    // 初始化
  }
}
