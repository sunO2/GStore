/// Bundled Agent Skills backed by the standard `SKILL.md` format.
///
/// Genkit's Skills Middleware reads skills from a filesystem directory. Flutter
/// assets are not directly addressable by `dart:io`, so the bundled files are
/// copied into application support storage once per [AgentSkillStore] instance.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _assetPrefix = 'assets/skills/';
const _targetDirectoryName = 'agent_skills';
final _skillNamePattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// Extracts bundled skills and provides safe, read-only access to them.
class AgentSkillStore {
  AgentSkillStore({
    AssetBundle? bundle,
    Future<Directory> Function()? supportDirectory,
  })  : _bundle = bundle ?? rootBundle,
        _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final AssetBundle _bundle;
  final Future<Directory> Function() _supportDirectory;
  Directory? _directory;
  Future<Directory>? _extraction;

  /// The extracted skills directory. Null until [ensureExtracted] completes.
  Directory? get directory => _directory;

  /// Copies every bundled `SKILL.md` into application support storage.
  ///
  /// The destination is rebuilt on the first call so removed or renamed skills
  /// cannot linger across app updates. Subsequent calls reuse the same result.
  Future<Directory> ensureExtracted() async {
    if (_extraction != null) return _extraction!;
    try {
      return await (_extraction = _extract());
    } catch (_) {
      _extraction = null;
      rethrow;
    }
  }

  Future<Directory> _extract() async {
    final manifest = await AssetManifest.loadFromAssetBundle(_bundle);
    final assets = manifest.listAssets().where((asset) {
      return asset.startsWith(_assetPrefix) && asset.endsWith('/SKILL.md');
    }).toList()
      ..sort();

    if (assets.isEmpty) {
      throw StateError(
          'No bundled Agent Skills were found under $_assetPrefix');
    }

    final support = await _supportDirectory();
    final target = Directory(p.join(support.path, _targetDirectoryName));
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    await target.create(recursive: true);

    for (final asset in assets) {
      final relativePath = asset.substring(_assetPrefix.length);
      final file = File(p.join(target.path, relativePath));
      await file.parent.create(recursive: true);
      await file.writeAsString(await _bundle.loadString(asset), flush: true);
    }

    _directory = target;
    debugPrint(
        'AgentSkillStore: extracted ${assets.length} skills to ${target.path}');
    return target;
  }

  /// Reads one skill by its directory name.
  ///
  /// Only lowercase kebab-case names are accepted, preventing path traversal
  /// outside the extracted skills directory.
  Future<String> readSkill(String skillName) async {
    final name = skillName.trim();
    if (!_skillNamePattern.hasMatch(name)) {
      throw ArgumentError('Invalid skill name: $skillName');
    }

    final dir = await ensureExtracted();
    final file = File(p.join(dir.path, name, 'SKILL.md'));
    if (!await file.exists()) {
      throw StateError('Skill not found: $name');
    }
    return file.readAsString();
  }
}
