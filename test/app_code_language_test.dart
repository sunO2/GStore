import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/editor/app_code_language.dart';

void main() {
  group('AppCodeLanguage.forPath', () {
    test('按扩展名识别常见语言', () {
      expect(AppCodeLanguage.forPath('lib/main.dart')?.name, 'dart');
      expect(AppCodeLanguage.forPath('pubspec.yaml')?.name, 'yaml');
      expect(AppCodeLanguage.forPath('data.json')?.name, 'json');
      expect(AppCodeLanguage.forPath('README.md')?.name, 'markdown');
      expect(AppCodeLanguage.forPath('src/index.ts')?.name, 'typescript');
      expect(AppCodeLanguage.forPath('src/app.py')?.name, 'python');
      expect(AppCodeLanguage.forPath('script.sh')?.name, 'bash');
      expect(AppCodeLanguage.forPath('Dockerfile')?.name, 'dockerfile');
      expect(AppCodeLanguage.forPath('Makefile')?.name, 'makefile');
      expect(AppCodeLanguage.forPath('.gitignore')?.name, 'ini');
      expect(AppCodeLanguage.forPath('build.gradle')?.name, 'groovy');
    });

    test('未知扩展名/空路径返回 null', () {
      expect(AppCodeLanguage.forPath('notes.txt'), isNull);
      expect(AppCodeLanguage.forPath('archive.bin'), isNull);
      expect(AppCodeLanguage.forPath(''), isNull);
      expect(AppCodeLanguage.forPath(null), isNull);
    });

    test('Windows 路径也能识别', () {
      expect(
        AppCodeLanguage.forPath(r'C:\project\lib\main.dart')?.name,
        'dart',
      );
    });
  });

  group('AppCodeLanguage.forName（markdown 围栏）', () {
    test('常见围栏语言标识', () {
      expect(AppCodeLanguage.forName('dart')?.name, 'dart');
      expect(AppCodeLanguage.forName('js')?.name, 'javascript');
      expect(AppCodeLanguage.forName('shell')?.name, 'bash');
      expect(AppCodeLanguage.forName('c++')?.name, 'cpp');
      expect(AppCodeLanguage.forName('HTML')?.name, 'xml');
      expect(AppCodeLanguage.forName('yml')?.name, 'yaml');
    });

    test('plaintext/未知返回 null', () {
      expect(AppCodeLanguage.forName('text'), isNull);
      expect(AppCodeLanguage.forName('plaintext'), isNull);
      expect(AppCodeLanguage.forName('unknown-lang'), isNull);
      expect(AppCodeLanguage.forName(null), isNull);
    });
  });
}
