import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/page/home/logic.dart';
import 'package:gstore/page/home/state.dart';

/// 三 tab（功能 / 首页 / 设置）纯增量索引模型单元测试。
///
/// todo 4 只引入模型/常量，不接入 `jumpToPage`/`PageView`，因此这里仅锁定
/// 模型的稳定语义（顺序、下标、文案、越界回退、数量），作为 todo 5 的契约。
void main() {
  group('HomeTab3 三 tab 索引模型（纯增量）', () {
    test('values 顺序 = 功能 / 首页 / 设置', () {
      expect(HomeTab3.values, const [
        HomeTab3.features,
        HomeTab3.home,
        HomeTab3.settings,
      ]);
    });

    test('tabIndex 为 0 / 1 / 2', () {
      expect(HomeTab3.features.tabIndex, 0);
      expect(HomeTab3.home.tabIndex, 1);
      expect(HomeTab3.settings.tabIndex, 2);
    });

    test('label 文案为 功能 / 首页 / 设置', () {
      expect(HomeTab3.features.label, '功能');
      expect(HomeTab3.home.label, '首页');
      expect(HomeTab3.settings.label, '设置');
    });

    test('count == 3 且与 values.length 一致', () {
      expect(HomeTab3.count, 3);
      expect(HomeTab3.count, HomeTab3.values.length);
    });

    test('fromIndex 往返一致', () {
      for (final tab in HomeTab3.values) {
        expect(HomeTab3.fromIndex(tab.tabIndex), tab);
      }
    });

    test('fromIndex 越界回退到 features', () {
      expect(HomeTab3.fromIndex(-1), HomeTab3.features);
      expect(HomeTab3.fromIndex(3), HomeTab3.features);
    });

    test('homeTab3Order 与 values 同序且长度为 3', () {
      expect(homeTab3Order.length, HomeTab3.count);
      expect(homeTab3Order, HomeTab3.values);
    });
  });
}
