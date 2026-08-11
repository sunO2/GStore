import 'package:get/get.dart';
import 'package:gstore/core/channel/channel.dart';
import 'package:gstore/core/model/AppSummary.dart';

class ChannelTestState {
  /// 当前选中的渠道
  final selectedChannel = ChannelType.localDb.obs;

  /// 查询结果
  final queryResult = Rx<ChannelResult<dynamic>?>(null);

  /// 查询状态
  final isQuerying = false.obs;

  /// 应用列表
  final apps = <AppSummary>[].obs;

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

  /// 当前执行的操作（用于高亮显示）
  final currentOperation = ''.obs;

  /// 开发者模式开关
  final developerMode = false.obs;

  /// 结果显示（纯文本格式）
  final result = ''.obs;

  ChannelTestState() {
    // 初始化
  }
}
