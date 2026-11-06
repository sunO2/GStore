import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/licenses/license_bundle.dart';

void main() {
  test('decode reads compressed package entries', () {
    final payload = jsonEncode({
      'packages': [
        {
          'name': 'alpha',
          'version': '1.0.0',
          'description': 'A',
          'homepage': 'https://example.com/a',
          'repository': null,
          'license': 'MIT',
          'isSdk': false,
        },
        {
          'name': 'beta',
          'version': null,
          'description': 'B',
          'homepage': null,
          'repository': null,
          'license': null,
          'isSdk': true,
        },
      ],
    });
    final gz = Uint8List.fromList(GZipCodec().encode(utf8.encode(payload)));

    final bundle = LicenseBundle.decode(gz);

    expect(bundle.packages, hasLength(2));
    expect(bundle.packages[0].name, 'alpha');
    expect(bundle.packages[0].license, 'MIT');
    expect(bundle.packages[1].isSdk, isTrue);
    expect(bundle.packages[1].version, isNull);
  });

  test('bundled license asset decodes', () {
    final bytes = File('assets/licenses/oss_licenses.json.gz').readAsBytesSync();

    final bundle = LicenseBundle.decode(bytes);

    expect(bundle.packages, isNotEmpty);
    expect(bundle.packages.any((pkg) => pkg.name == 'flutter'), isTrue);
  });
}
