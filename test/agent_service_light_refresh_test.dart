import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  test('无模型时设置页返回只做轻量同步，不重复初始化', () async {
    final agent = AgentService();
    addTearDown(agent.dispose);
    await agent.initialize(); // 未配置模型也会创建会话

    final sessionStore = agent.sessionStore;
    final sessionCount = sessionStore!.sessions.length;
    final currentId = sessionStore.current?.id;

    expect(await agent.ensureCurrentModelReady(), isFalse);

    // 没有重新执行 initialize：会话 store 仍是同一实例，也没有新增会话。
    expect(identical(agent.sessionStore, sessionStore), isTrue);
    expect(agent.sessionStore!.sessions.length, sessionCount);
    expect(agent.sessionStore!.current?.id, currentId);
    expect(agent.isInitialized, isFalse);
  });
}
