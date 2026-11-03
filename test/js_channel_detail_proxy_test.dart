import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/model/proxy/JsChannelDetailProxy.dart';

void main() {
  test('description 为 appId 时回退到 des', () {
    final proxy = JsChannelDetailProxy({
      'appId': 'com.pingan.app',
      'description': 'com.pingan.app',
      'des': '图文详情内容',
    });

    expect(proxy.description, '图文详情内容');
  });

  test('正常 description 不被 des 覆盖', () {
    final proxy = JsChannelDetailProxy({
      'appId': 'com.pingan.app',
      'description': '正常描述',
      'des': '其他内容',
    });

    expect(proxy.description, '正常描述');
  });
}
