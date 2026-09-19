import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';

class _OfflineReleaseClient extends ModuleManifestClient {
  _OfflineReleaseClient({required this.manifest})
      : super(
          releasesUrl: Uri.parse('http://127.0.0.1:1/releases/latest'),
          downloadsBaseUrl: 'https://example.test/latest/download',
        );

  final ModuleManifestV2 manifest;

  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async => manifest;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Release 资产表不可用时回退稳定直链', () async {
    final sha = 'a' * 64;
    final manifest = ModuleManifestV2.fromJson(<String, dynamic>{
      'version': 2,
      'modules': <String, dynamic>{
        'qr': <String, dynamic>{
          'version': '0.1.0',
          'abi': <String, dynamic>{
            'arm64-v8a': <String, dynamic>{
              'asset': 'libgstore_mod_qr_0.1.0-arm64-v8a.so',
              'sha256': sha,
              'size': 10,
            },
          },
        },
      },
    });
    final client = _OfflineReleaseClient(manifest: manifest);

    final loc = await client.locateModuleAsset('qr');
    expect(loc, isNotNull);
    expect(
      loc!.url,
      'https://example.test/latest/download/'
      'libgstore_mod_qr_0.1.0-arm64-v8a.so',
    );
    expect(loc.asset, 'libgstore_mod_qr_0.1.0-arm64-v8a.so');
    expect(loc.sha256, sha);
    expect(loc.version, '0.1.0');
    expect(loc.abi, 'arm64-v8a');
  });
}
