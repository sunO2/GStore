import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/page/detail/widgets.dart';

/// isDescriptionDuplicated 测试
///
/// 验证头部 description 与 readme 的重复判定：
/// - description.trim() == readme.trim() → true（相等）
/// - readme 为空/null → false
/// - description 为空 → false
/// - readme 以 description 开头（前缀）→ true
/// - 完全不同 → false
class _FakeDetailInfo implements IDetailInfo {
  String? readmeValue;

  @override
  String get packageName => 'com.example.app';
  @override
  String get appName => '测试应用';
  @override
  String get icon => '';
  @override
  String get description => '';
  @override
  String get appId => 'com.example.app';
  @override
  String get name => appName;
  @override
  bool get isValid => packageName.isNotEmpty && appName.isNotEmpty;
  @override
  String get channelId => 'github';
  @override
  ChannelType get channelType => ChannelType.github;
  @override
  String? get version => '1.0.0';
  @override
  String? get developer => null;
  @override
  String? get projectUrl => null;
  @override
  List<DownloadInfo> get downloads => const [];
  @override
  List<DetailSection> get sections => const [DetailSection.readme];
  @override
  Map<String, dynamic> get extra => const {};
  @override
  String? get readme => readmeValue;
  @override
  List<ScreenshotInfo>? get screenshots => null;
  @override
  String? get changelog => null;
  @override
  List<String>? get permissions => null;
  @override
  StatisticsInfo? get statistics => null;
  @override
  List<StatTag> buildStatTags() => const [];
}

void main() {
  group('isDescriptionDuplicated', () {
    test('description 与 readme 完全相等（含首尾空白差异）→ true', () {
      final info = _FakeDetailInfo()..readmeValue = ' 完整介绍文本 ';
      expect(isDescriptionDuplicated(info, '完整介绍文本'), isTrue);
    });

    test('readme 为空 → false', () {
      final info = _FakeDetailInfo(); // readmeValue = null
      expect(isDescriptionDuplicated(info, '完整介绍文本'), isFalse);

      final emptyReadme = _FakeDetailInfo()..readmeValue = '';
      expect(isDescriptionDuplicated(emptyReadme, '完整介绍文本'), isFalse);
    });

    test('info 为 null 或 description 为空 → false', () {
      expect(isDescriptionDuplicated(null, '完整介绍文本'), isFalse);
      final info = _FakeDetailInfo()..readmeValue = '完整介绍文本';
      expect(isDescriptionDuplicated(info, ''), isFalse);
      expect(isDescriptionDuplicated(info, '   '), isFalse);
    });

    test('readme 以 description 为前缀 → true', () {
      final info = _FakeDetailInfo()..readmeValue = '简介\n\n详细正文内容';
      expect(isDescriptionDuplicated(info, '简介'), isTrue);
    });

    test('完全不同 → false', () {
      final info = _FakeDetailInfo()..readmeValue = 'readme 正文';
      expect(isDescriptionDuplicated(info, '完全不同的描述'), isFalse);
    });
  });
}
