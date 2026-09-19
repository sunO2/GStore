import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ModuleBootstrap.dart 不导入任何 Flutter UI 库', () {
    final file = File('lib/core/rust/ModuleBootstrap.dart');
    expect(file.existsSync(), isTrue, reason: 'ModuleBootstrap.dart 必须存在');

    final source = file.readAsStringSync();
    final importLines = source
        .split('\n')
        .where((line) => line.trimLeft().startsWith('import '))
        .toList();
    expect(importLines, isNotEmpty, reason: '至少应有 import 行');

    const forbidden = <String>[
      'package:flutter/material.dart',
      'package:flutter/widgets.dart',
      'package:flutter/cupertino.dart',
    ];

    for (final line in importLines) {
      for (final lib in forbidden) {
        expect(
          line.contains(lib),
          isFalse,
          reason: 'ModuleBootstrap 不得导入 UI 库（命中 $lib）：$line',
        );
      }
    }
  });
}
