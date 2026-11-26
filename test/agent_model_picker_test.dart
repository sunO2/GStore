import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/page/agent/model_picker_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _initMemoryConfig() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AgentModelStore.resetForTest();
    await _initMemoryConfig();
  });

  testWidgets('/model 弹层列出当前模型并可直接切换', (tester) async {
    final store = await AgentModelStore.load();
    await store.add(AgentModel(
      id: 'model-a',
      name: '模型 A',
      provider: AgentLlmProvider.openai,
      apiKey: 'sk-a',
      model: 'gpt-4o-mini',
    ));
    await store.add(AgentModel(
      id: 'model-b',
      name: '模型 B',
      provider: AgentLlmProvider.google,
      apiKey: 'sk-b',
      model: 'gemini-2.0-flash',
    ));
    await store.select('model-a');

    AgentModel? selected;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                selected = await showAgentModelPicker(context);
              },
              child: const Text('选择模型'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('选择模型'));
    await tester.pumpAndSettle();

    expect(find.text('切换模型'), findsOneWidget);
    expect(find.text('模型 A'), findsOneWidget);
    expect(find.text('模型 B'), findsOneWidget);
    expect(find.text('使用中'), findsOneWidget);

    await tester.tap(find.text('模型 B'));
    await tester.pumpAndSettle();

    expect(selected?.id, 'model-b');
    expect(store.selectedId, 'model-b');
    expect(find.text('切换模型'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
