import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One third-party package entry shown on the open-source licenses page.
class LicensePackage {
  const LicensePackage({
    required this.name,
    this.version,
    this.description,
    this.homepage,
    this.repository,
    this.license,
    this.isSdk = false,
  });

  final String name;
  final String? version;
  final String? description;
  final String? homepage;
  final String? repository;
  final String? license;
  final bool isSdk;
}

/// Decoded contents of `assets/licenses/oss_licenses.json.gz`.
class LicenseBundle {
  const LicenseBundle(this.packages);

  final List<LicensePackage> packages;

  static LicenseBundle decode(Uint8List gzipBytes) {
    final jsonBytes = GZipCodec().decode(gzipBytes);
    final root = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    final entries = (root['packages'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    return LicenseBundle(
      entries
          .map(
            (entry) => LicensePackage(
              name: entry['name'] as String,
              version: entry['version'] as String?,
              description: entry['description'] as String?,
              homepage: entry['homepage'] as String?,
              repository: entry['repository'] as String?,
              license: entry['license'] as String?,
              isSdk: entry['isSdk'] == true,
            ),
          )
          .toList(growable: false),
    );
  }
}
