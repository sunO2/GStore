import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/groovy.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';

/// 代码预览/编辑支持的语言。
///
/// 只引入实际用到的语言，避免把 re_highlight 的全部语言打进包体。
/// 语言选择以文件扩展名/文件名为主，未知类型返回 null（纯文本、不高亮）。
class AppCodeLanguage {
  const AppCodeLanguage(this.name, this.mode);

  /// re_highlight 注册名（如 `dart` / `json`）。
  final String name;

  /// re_highlight 语言规则。
  final Mode mode;

  static final AppCodeLanguage dart = AppCodeLanguage('dart', langDart);
  static final AppCodeLanguage json = AppCodeLanguage('json', langJson);
  static final AppCodeLanguage yaml = AppCodeLanguage('yaml', langYaml);
  static final AppCodeLanguage xml = AppCodeLanguage('xml', langXml);
  static final AppCodeLanguage markdown =
      AppCodeLanguage('markdown', langMarkdown);
  static final AppCodeLanguage javascript =
      AppCodeLanguage('javascript', langJavascript);
  static final AppCodeLanguage typescript =
      AppCodeLanguage('typescript', langTypescript);
  static final AppCodeLanguage css = AppCodeLanguage('css', langCss);
  static final AppCodeLanguage java = AppCodeLanguage('java', langJava);
  static final AppCodeLanguage kotlin = AppCodeLanguage('kotlin', langKotlin);
  static final AppCodeLanguage python = AppCodeLanguage('python', langPython);
  static final AppCodeLanguage bash = AppCodeLanguage('bash', langBash);
  static final AppCodeLanguage sql = AppCodeLanguage('sql', langSql);
  static final AppCodeLanguage c = AppCodeLanguage('c', langC);
  static final AppCodeLanguage cpp = AppCodeLanguage('cpp', langCpp);
  static final AppCodeLanguage rust = AppCodeLanguage('rust', langRust);
  static final AppCodeLanguage go = AppCodeLanguage('go', langGo);
  static final AppCodeLanguage swift = AppCodeLanguage('swift', langSwift);
  static final AppCodeLanguage ruby = AppCodeLanguage('ruby', langRuby);
  static final AppCodeLanguage php = AppCodeLanguage('php', langPhp);
  static final AppCodeLanguage diff = AppCodeLanguage('diff', langDiff);
  static final AppCodeLanguage ini = AppCodeLanguage('ini', langIni);
  static final AppCodeLanguage dockerfile =
      AppCodeLanguage('dockerfile', langDockerfile);
  static final AppCodeLanguage makefile =
      AppCodeLanguage('makefile', langMakefile);
  static final AppCodeLanguage groovy = AppCodeLanguage('groovy', langGroovy);

  /// 按 markdown 代码围栏语言标识推断语言（如 ```dart）。
  ///
  /// 与 [forPath] 共用同一组语言规则；未知/plaintext 返回 null。
  static AppCodeLanguage? forName(String? name) {
    final value = name?.trim().toLowerCase();
    if (value == null || value.isEmpty) return null;
    return switch (value) {
      'dart' => dart,
      'json' || 'jsonc' || 'json5' => json,
      'yaml' || 'yml' => yaml,
      'xml' || 'html' || 'htm' || 'svg' => xml,
      'md' || 'markdown' => markdown,
      'js' || 'javascript' || 'mjs' || 'cjs' => javascript,
      'ts' || 'typescript' || 'tsx' => typescript,
      'css' || 'scss' || 'less' => css,
      'java' => java,
      'kotlin' || 'kt' || 'kts' => kotlin,
      'python' || 'py' || 'pyw' => python,
      'bash' || 'sh' || 'shell' || 'zsh' || 'console' => bash,
      'sql' => sql,
      'c' || 'h' => c,
      'cpp' || 'c++' || 'cc' || 'cxx' || 'hpp' => cpp,
      'rust' || 'rs' => rust,
      'go' || 'golang' => go,
      'swift' => swift,
      'ruby' || 'rb' => ruby,
      'php' => php,
      'diff' || 'patch' => diff,
      'ini' || 'toml' || 'properties' || 'conf' => ini,
      'dockerfile' || 'docker' => dockerfile,
      'makefile' || 'make' => makefile,
      'groovy' || 'gradle' => groovy,
      _ => null,
    };
  }

  /// 按文件路径推断语言；无法判断时返回 null。
  static AppCodeLanguage? forPath(String? path) {
    if (path == null || path.trim().isEmpty) return null;
    final file = path.replaceAll('\\', '/').split('/').last.toLowerCase();

    // 无扩展名/特殊文件名优先。
    if (file == 'dockerfile') return dockerfile;
    if (file == 'makefile') return makefile;
    if (file == '.gitignore' ||
        file == '.dockerignore' ||
        file == '.gitattributes' ||
        file == '.editorconfig') {
      return ini;
    }
    if (file == 'gradlew') return bash;

    final dot = file.lastIndexOf('.');
    if (dot < 0 || dot == file.length - 1) return null;
    final ext = file.substring(dot + 1);

    return switch (ext) {
      'dart' => dart,
      'json' => json,
      'yaml' || 'yml' => yaml,
      'xml' || 'html' || 'htm' || 'svg' => xml,
      'md' || 'markdown' => markdown,
      'js' || 'mjs' || 'cjs' => javascript,
      'ts' || 'tsx' => typescript,
      'css' || 'scss' || 'less' => css,
      'java' => java,
      'kt' || 'kts' => kotlin,
      'py' || 'pyw' => python,
      'sh' || 'bash' || 'zsh' => bash,
      'sql' => sql,
      'c' || 'h' => c,
      'cpp' || 'cc' || 'cxx' || 'hpp' || 'hh' => cpp,
      'rs' => rust,
      'go' => go,
      'swift' => swift,
      'rb' => ruby,
      'php' => php,
      'diff' || 'patch' => diff,
      'ini' || 'toml' || 'properties' || 'conf' => ini,
      'gradle' => groovy,
      'dockerfile' => dockerfile,
      'mk' => makefile,
      _ => null,
    };
  }
}
