// Regenerates assets/licenses/oss_licenses.json.gz from the generated
// lib/oss_licenses.dart produced by:
//
//   dart run dart_pubspec_licenses:generate
//   dart run tool/dump_licenses.dart
//
// The app loads the compressed asset lazily, so the 895 KB const list is no
// longer compiled into libapp.so.

import 'dart:convert';
import 'dart:io';

import 'package:gstore/oss_licenses.dart' as oss;

void main() {
  final packages = oss.allDependencies
      .map(
        (pkg) => <String, Object?>{
          'name': pkg.name,
          'version': pkg.version,
          'description': pkg.description,
          'homepage': pkg.homepage,
          'repository': pkg.repository,
          'license': pkg.license,
          'isSdk': pkg.isSdk,
        },
      )
      .toList(growable: false);

  final json = jsonEncode({'packages': packages});
  final gz = GZipCodec(level: 9).encode(utf8.encode(json));
  final out = File('assets/licenses/oss_licenses.json.gz')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(gz);
  stdout.writeln(
    'wrote ${out.path}: ${gz.length} bytes, ${packages.length} packages',
  );
}
