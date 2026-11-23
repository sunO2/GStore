import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/mcp/mcp_server_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('MCP 服务器增删改与持久化', () async {
    final store = await McpServerStore.load();
    final server = await store.add(
      name: 'Weather',
      url: 'https://mcp.example/mcp',
      headers: const {'Authorization': 'Bearer x'},
    );
    expect(store.all, hasLength(1));
    expect(store.enabled, hasLength(1));

    server.enabled = false;
    await store.update(server);
    expect(store.enabled, isEmpty);

    final reloaded = await McpServerStore.load();
    expect(reloaded.all.single.name, 'Weather');
    expect(reloaded.all.single.enabled, isFalse);

    await reloaded.remove(server.id);
    expect(reloaded.all, isEmpty);
  });
}
