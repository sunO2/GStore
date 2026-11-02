import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';

import 'support/library_api_seam.dart';

class _RecordingTokenBackend extends FakeChannelApiBackend
    implements GithubTokenSyncBackend {
  _RecordingTokenBackend() : super(FakeLibraryApi());

  String? token;
  int calls = 0;

  @override
  Future<void> setGithubToken({String? token}) async {
    this.token = token;
    calls++;
  }
}

void main() {
  test('facade forwards GitHub token set and clear to capable backend', () async {
    final backend = _RecordingTokenBackend();
    final facade = RustChannelFacade(backend: backend);

    await facade.setGithubToken(token: 'token-abc');
    expect(backend.token, 'token-abc');
    expect(backend.calls, 1);

    await facade.setGithubToken(token: null);
    expect(backend.token, isNull);
    expect(backend.calls, 2);
  });

  test('facade skips backends without the token capability', () async {
    final facade = RustChannelFacade(backend: FakeChannelApiBackend(FakeLibraryApi()));

    await facade.setGithubToken(token: 'token-abc');
  });
}
