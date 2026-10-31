// Todo 18: theme call sites read/write the grouped `theme.*` keys through
// ConfigService, with Riverpod remaining the runtime authority.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_provider.dart';

import 'support/grouped_config_fake.dart';

Future<void> _settle() => Future<void>.delayed(
      const Duration(milliseconds: 20),
    );

/// Reads the current value, then deliberately delays the response: this models
/// a startup load that returns a stale snapshot after a newer write landed.
class _StaleReadConfigApiClient extends GroupedConfigApiClient {
  static const Duration _delay = Duration(milliseconds: 30);

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) async {
    final value = await super.get(module: module, key: key, masked: masked);
    await Future<void>.delayed(_delay);
    return value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ConfigService.instance;
  late GroupedConfigApiClient fake;

  setUp(() async {
    await service.resetForTest();
    fake = GroupedConfigApiClient();
    service.debugSetApi(ConfigRustApi(fake));
    await service.ensureReady();
  });

  tearDown(() async {
    await service.resetForTest();
    await fake.close();
  });

  group('theme grouped config', () {
    test('theme mode uses theme.mode wire key and survives reload', () async {
      expect(ConfigKeys.themeMode, 'theme.mode');
      expect(ConfigKeys.themeConfig, 'theme.config');

      final first = ProviderContainer();
      expect(first.read(themeProvider).mode, AppThemeMode.system);
      await _settle();

      await first.read(themeProvider.notifier).setThemeMode(AppThemeMode.dark);
      await _settle();

      expect(first.read(themeProvider).mode, AppThemeMode.dark);
      expect(await service.getRaw(ConfigKeys.themeMode), 2);
      expect(fake.raw(ConfigKeys.themeMode), 2);
      first.dispose();

      // Restart: a fresh container must load the persisted dark mode.
      final second = ProviderContainer();
      addTearDown(second.dispose);
      second.read(themeProvider);
      await _settle();
      expect(second.read(themeProvider).mode, AppThemeMode.dark);
    });

    test('external write immediately after build wins over stale startup load',
        () async {
      await service.resetForTest();
      final stale = _StaleReadConfigApiClient();
      service.debugSetApi(ConfigRustApi(stale));
      await service.ensureReady();
      addTearDown(stale.close);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(themeProvider); // starts the delayed startup load

      await service.set(
        ConfigKeys.themeMode,
        AppThemeMode.light.index,
        source: ConfigChangeSource.agent,
      );
      await service.set(
        ConfigKeys.themeConfig,
        <String, dynamic>{'fontStyle': AppFontStyle.large.index},
        source: ConfigChangeSource.agent,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final state = container.read(themeProvider);
      expect(state.mode, AppThemeMode.light);
      expect(state.config.fontStyle, AppFontStyle.large);
    });

    test('theme config JSON round-trips through ConfigService', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(themeProvider);
      await _settle();

      final notifier = container.read(themeProvider.notifier);
      await notifier.setFontStyle(AppFontStyle.large);
      await notifier.setRadiusStyle(AppRadiusStyle.circular);
      await notifier.toggleCustomColors();
      await _settle();

      final raw = await service.getRaw(ConfigKeys.themeConfig) as Map;
      expect(raw['fontStyle'], AppFontStyle.large.index);
      expect(raw['radiusStyle'], AppRadiusStyle.circular.index);
      expect(raw['useCustomColors'], isTrue);

      final reloaded = ProviderContainer();
      addTearDown(reloaded.dispose);
      reloaded.read(themeProvider);
      await _settle();
      final config = reloaded.read(themeProvider).config;
      expect(config.fontStyle, AppFontStyle.large);
      expect(config.radiusStyle, AppRadiusStyle.circular);
      expect(config.useCustomColors, isTrue);
    });

    test('malformed theme JSON keeps the previous state', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(themeProvider);
      await _settle();

      final notifier = container.read(themeProvider.notifier);
      await notifier.setFontStyle(AppFontStyle.large);
      await _settle();
      final before = container.read(themeProvider).config.fontStyle;
      expect(before, AppFontStyle.large);

      // Valid JSON shape but invalid enum index -> AppThemeConfig.fromJson throws.
      final result = await service.set(
        ConfigKeys.themeConfig,
        <String, dynamic>{'fontStyle': 99},
      );
      expect(result.success, isTrue);
      await _settle();

      expect(container.read(themeProvider).config.fontStyle, before);

      // Malformed JSON text is rejected before it can reach listeners.
      final rejected = await service.set(ConfigKeys.themeConfig, '{not-json');
      expect(rejected.success, isFalse);
      await _settle();
      expect(container.read(themeProvider).config.fontStyle, before);
    });
  });
}
