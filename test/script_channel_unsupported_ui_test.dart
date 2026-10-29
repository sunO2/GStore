/// Todo 6: a JS (script-pack) channel has no category model, so
/// `ChannelApi.getAllCategories` / `searchByCategory` now report a typed
/// `unsupported` instead of an empty `Ok(vec![])`.
///
/// The Dart callers must degrade on the typed CODE (`ChannelApiException.code ==
/// 'unsupported'`, never a message match) so the category UI keeps rendering the
/// same "no categories" state as before — the change stays invisible.
///
/// `ChannelManager.getAllCategories` is the UI-facing category read; no page
/// currently calls it (discovery loads app lists, the search page reads the
/// catalog), so the render assertion drives a minimal consumer widget that
/// mirrors the UI contract: list / "no categories" / error.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/db/apps/AppInfo.dart' as db;

import 'support/discovery_facade_seams.dart';

/// Channels-domain facade backend whose category methods raise the typed
/// `unsupported` gap a JS pack reports. Every other method is unused and fails
/// loudly.
class _UnsupportedCategoryBackend implements ChannelApiBackend {
  int getAllCategoriesCalls = 0;
  int searchByCategoryCalls = 0;

  @override
  Future<List<rust.ChannelCategoryInfo>> getAllCategories({
    required String key,
    required bool forceRefresh,
  }) async {
    getAllCategoriesCalls++;
    throw const ChannelApiException(
      'unsupported',
      'channel does not support get_all_categories',
    );
  }

  @override
  Future<List<rust.ChannelAppInfo>> searchByCategory({
    required String key,
    required String categoryId,
    required bool forceRefresh,
  }) async {
    searchByCategoryCalls++;
    throw const ChannelApiException(
      'unsupported',
      'channel does not support search_by_category',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused facade method: ${invocation.memberName}');
}

/// The category UI contract: categories when present, "no categories" when the
/// list is empty, an error line only on a real failure.
class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.future});

  final Future<ChannelResult<List<db.AppCategory>>> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ChannelResult<List<db.AppCategory>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Text('loading');
        }
        final result = snapshot.data!;
        if (!result.success) {
          return Text('error: ${result.error}');
        }
        final categories = result.data ?? const <db.AppCategory>[];
        if (categories.isEmpty) {
          return const Text('暂无可用的分类');
        }
        return Column(
          children: [
            for (final category in categories) Text(category.description),
          ],
        );
      },
    );
  }
}

Future<void> _enableChannels() async {
  CoreFlags.installBackend(
    FakeFlagsBackend(const CoreFlagsSnapshot(channels: true)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.channels, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _UnsupportedCategoryBackend backend;

  setUp(() async {
    await ChannelManager.instance.disposeAll();
    backend = _UnsupportedCategoryBackend();
    RustChannelFacade.installBackend(backend);
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    RustChannelFacade.resetBackend();
    await ChannelManager.instance.disposeAll();
  });

  test('facade getAllCategories degrades typed unsupported to an empty list',
      () async {
    await _enableChannels();

    final categories = await RustChannelFacade.instance
        .getAllCategories(key: 'custom', forceRefresh: false);

    expect(categories, isEmpty);
    expect(backend.getAllCategoriesCalls, 1,
        reason: 'the facade must still have consulted the channel');
  });

  test('ChannelManager.getAllCategories degrades unsupported to empty success',
      () async {
    await _enableChannels();

    final result = await ChannelManager.instance
        .getAllCategories(from: ChannelType.custom, forceRefresh: false);

    expect(result.success, isTrue,
        reason: 'unsupported must render as "no categories", not a failure');
    expect(result.data, isEmpty);
    expect(result.error, isNull);
  });

  test('ChannelManager.searchByCategory degrades unsupported to empty success',
      () async {
    await _enableChannels();

    final result = await ChannelManager.instance
        .searchByCategory('tools', from: ChannelType.custom, forceRefresh: false);

    expect(result.success, isTrue,
        reason: 'unsupported must render as "no categories", not a failure');
    expect(result.data, isEmpty);
    expect(result.error, isNull);
    expect(backend.searchByCategoryCalls, 1);
  });

  testWidgets(
      'category UI renders "no categories" (no error) for a JS channel whose '
      'getAllCategories returns unsupported', (tester) async {
    late ChannelResult<List<db.AppCategory>> result;
    await tester.runAsync(() async {
      await _enableChannels();
      result = await ChannelManager.instance
          .getAllCategories(from: ChannelType.custom, forceRefresh: false);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _CategoryList(future: Future.value(result)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无可用的分类'), findsOneWidget);
    expect(find.textContaining('error:'), findsNothing);
  });
}
