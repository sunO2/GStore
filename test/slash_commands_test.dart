import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/slash_commands.dart';

void main() {
  test('空查询返回全部命令', () {
    expect(filterSlashCommands('').length, kAgentSlashCommands.length);
  });

  test('/work 联想 /workspace', () {
    final result = filterSlashCommands('work');
    expect(result.first.command, '/workspace');
  });

  test('/pho 联想 /photo', () {
    final result = filterSlashCommands('pho');
    expect(result.first.command, '/photo');
  });

  test('包含斜杠/空格也能过滤', () {
    expect(filterSlashCommands('/work').first.command, '/workspace');
    expect(filterSlashCommands(' work ').first.command, '/workspace');
  });

  test('无匹配返回空', () {
    expect(filterSlashCommands('not-a-command'), isEmpty);
  });
}
