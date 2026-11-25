import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_skills.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support =
        await Directory.systemTemp.createTemp('gstore_agent_skills_test_');
  });

  tearDown(() async {
    if (await support.exists()) {
      await support.delete(recursive: true);
    }
  });

  AgentSkillStore createStore() => AgentSkillStore(
        supportDirectory: () async => support,
      );

  group('AgentSkillStore', () {
    test('extracts all 14 bundled SKILL.md files and removes stale skills',
        () async {
      final stale =
          File(p.join(support.path, 'agent_skills', 'stale', 'SKILL.md'));
      await stale.parent.create(recursive: true);
      await stale.writeAsString('stale');

      final store = createStore();
      final dir = await store.ensureExtracted();
      final skillFiles = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => p.basename(file.path) == 'SKILL.md')
          .toList();

      expect(skillFiles, hasLength(14));
      expect(await stale.exists(), isFalse);
      expect(store.directory?.path, dir.path);
    });

    test('every skill has valid frontmatter and a matching directory name',
        () async {
      final dir = await createStore().ensureExtracted();
      final frontmatter = RegExp(r'^---\n([\s\S]*?)\n---');
      final namePattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

      for (final entity in dir.listSync()) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        final file = File(p.join(entity.path, 'SKILL.md'));
        expect(await file.exists(), isTrue, reason: name);
        expect(namePattern.hasMatch(name), isTrue, reason: name);

        final content = await file.readAsString();
        final match = frontmatter.firstMatch(content);
        expect(match, isNotNull, reason: name);
        final yaml = match!.group(1)!;
        expect(yaml, contains(RegExp('^name:\\s*$name\\s*\$', multiLine: true)),
            reason: name);
        expect(
            yaml, contains(RegExp(r'^description:\s*\S.*$', multiLine: true)),
            reason: name);
        expect(content, contains('# '), reason: name);
      }
    });

    test('reads a skill by directory name', () async {
      final content = await createStore().readSkill('app-recommendation');
      expect(content, contains('name: app-recommendation'));
      expect(content, contains('# 推荐应用'));
      expect(content, contains('searchApp'));
    });

    test('rejects unknown and traversal skill names', () async {
      final store = createStore();
      await expectLater(store.readSkill('missing-skill'), throwsStateError);
      await expectLater(
          store.readSkill('../app-recommendation'), throwsArgumentError);
    });
  });
}
