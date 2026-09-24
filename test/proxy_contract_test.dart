import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 假网关：受控返回信封响应 + 可推送原始事件；**不触碰 FFI**。
class _FakeGateway implements ProxyModuleGateway {
  _FakeGateway(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> methods = <String>[];

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    final response = responses[method];
    if (response == null) {
      throw StateError('no stub for $method');
    }
    return response;
  }

  @override
  Stream<ProxyRawEvent> get events => const Stream<ProxyRawEvent>.empty();
}

Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

Uint8List _errorEnvelope(int status, String code, String message) =>
    Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{
        'status': status,
        'code': code,
        'message': message,
      })),
    );

Uint8List _raw(String text) => Uint8List.fromList(utf8.encode(text));

String _rep(String unit, int count) => List<String>.filled(count, unit).join();

// ==================== 每个方法的响应 fixture ====================

const _importedProfileFixture = <String, dynamic>{
  'name': 'My Sub',
  'format': 'clash',
  'nodeCount': 1,
  'nodes': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'node-1',
      'type': 'ss',
      'server': '1.2.3.4',
      'port': 443,
      'cipher': 'aes-256-gcm',
      'password': 'redacted',
      'tls': true,
      'sni': 'example.com',
      'alpn': <String>['h2'],
      'reality': <String, dynamic>{'publicKey': 'k', 'shortId': 's'},
      'ws': <String, dynamic>{'path': '/ws', 'host': 'example.com'},
      'grpc': <String, dynamic>{'serviceName': 'svc'},
      'groups': <String>['PROXY'],
      'source': <String, dynamic>{'format': 'clash', 'origin': 'url', 'index': 0},
    },
  ],
  'groups': <Map<String, dynamic>>[
    <String, dynamic>{'name': 'PROXY', 'type': 'select', 'members': <String>['node-1']},
  ],
  'userinfo': <String, dynamic>{'upload': 1, 'download': 2, 'total': 100, 'expire': 1700000000},
  'source': <String, dynamic>{
    'origin': 'url',
    'url': 'https://example.com/sub',
    'finalUrl': 'https://example.com/sub',
    'filename': 'sub.yaml',
    'userAgent': 'clash.meta',
    'fetchedAtMs': 1,
    'bytes': 10,
    'contentType': 'text/yaml',
  },
  'warnings': <String>[],
};

const _storedProfileFixture = <String, dynamic>{
  'schemaVersion': 2,
  'id': 'p1',
  'revision': 1,
  'createdAtMs': 1,
  'updatedAtMs': 2,
  'refresh': <String, dynamic>{
    'state': 'done',
    'requestedAtMs': 1,
    'attempts': 1,
    'consecutiveFailures': 0,
    'intervalMs': 3600000,
    'lastUpdatedAtMs': 2,
    'nextRefreshAtMs': 3600002,
  },
  'appBackup': <String, dynamic>{'k': 'v'},
  'profile': _importedProfileFixture,
};

const _generatedConfigFixture = <String, dynamic>{
  'config': 'mode: rule\n',
  'format': 'clash',
  'template': 'gstore-controlled-v1',
  'profileId': 'p1',
  'profileName': 'Fixture',
  'hash': 'abc123',
  'generatedAtMs': 1,
  'counts': <String, dynamic>{'proxies': 2, 'groups': 1, 'rules': 1},
  'overlays': <String, dynamic>{'stack': 'gvisor', 'mtu': 1500},
  'warnings': <Map<String, dynamic>>[
    <String, dynamic>{
      'code': 'PROXY_CONFIG_NODE_UNSUPPORTED',
      'node': 'h1',
      'message': 'skip',
    },
  ],
};

const _rulesSnapshotFixture = <String, dynamic>{
  'rules': <Map<String, dynamic>>[
    <String, dynamic>{
      'index': 0,
      'lineNumber': 1,
      'line': 'DOMAIN-SUFFIX,example.com,PROXY',
      'type': 'DOMAIN-SUFFIX',
      'value': 'example.com',
      'target': 'PROXY',
      'source': 'config',
    },
  ],
  'final': 'DIRECT',
  'count': 1,
  'revision': 1,
  'groups': <String>['PROXY'],
  'providers': <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'cn',
      'type': 'inline',
      'behavior': 'domain',
      'status': 'loaded',
      'count': 1,
    },
  ],
  'geo': <String, dynamic>{
    'status': 'ready',
    'assets': <Map<String, dynamic>>[
      <String, dynamic>{
        'kind': 'geoip',
        'file': 'country.mmdb',
        'path': '/x',
        'status': 'ready',
        'verified': true,
        'sha256': 'a',
      },
    ],
  },
  'errors': <Map<String, dynamic>>[],
  'warnings': <String>[],
};

const _dnsConfigFixture = <String, dynamic>{
  'mode': 'fake-ip',
  'nameservers': <String>['1.1.1.1'],
  'fallback': <String>['8.8.8.8'],
  'doh': <String>['https://dns.example/dns-query'],
  'dot': <String>['tls://8.8.8.8:853'],
  'defaultNameservers': <String>['223.5.5.5'],
  'fakeIpRange': '198.18.0.0/16',
  'fakeIpFilter': <String>['*.lan'],
  'fakeIpFilterMode': 'blacklist',
  'useHosts': true,
  'ipv6': true,
  'hijack': true,
  'hosts': <String, dynamic>{'example.com': <String>['93.184.216.34']},
};

const _coreStatusFixture = <String, dynamic>{
  'state': 'running',
  'mode': 'vpn',
  'instanceId': 7,
  'spawned': true,
  'profileId': 'p1',
  'profileName': 'Fixture',
  'hash': 'abc',
  'template': 'gstore-controlled-v1',
  'proxies': 2,
  'groups': 1,
  'rules': 1,
  'overlays': <String, dynamic>{'stack': 'gvisor', 'mtu': 1500},
  'warnings': <Map<String, dynamic>>[],
};

/// `LAN` config fixture（`API.md` §2.12 `LanConfig`）。
const _lanConfigFixture = <String, dynamic>{
  'enabled': false,
  'port': 1087,
  'bindAddress': '0.0.0.0',
  'auth': null,
  'allowedIps': <String>[],
};

/// `net.shaper.*` 单方向 fixture（`API.md` §2.15 `DirectionConfig`）。
const _shaperDirectionFixture = <String, dynamic>{
  'rateBps': 100000,
  'burstBytes': 32768,
  'delayMs': 25,
  'jitterMs': 5,
  'jitterDistribution': 'normal',
  'lossPct': 0.5,
  'lossModel': 'random',
  'lossGoodToBadPct': 0,
  'lossBadToGoodPct': 0,
  'duplicatePct': 0,
  'reorderPct': 0,
  'reorderGap': 0,
  'order': 'preserve',
};

/// `net.shaper.*` 配置 fixture（`API.md` §2.15 `ShaperConfig`）。
const _shaperConfigFixture = <String, dynamic>{
  'enabled': true,
  'seed': 7,
  'uplink': _shaperDirectionFixture,
  'downlink': _shaperDirectionFixture,
};

/// `net.shaper.get` / `net.shaper.set` **共用**的冻结响应 fixture。
const _shaperSnapshotFixture = <String, dynamic>{
  'config': _shaperConfigFixture,
  'effective': _shaperConfigFixture,
  'applied': true,
  'engineRunning': true,
  'counters': <String, dynamic>{
    'upFramesShaped': 1,
    'downFramesShaped': 2,
    'upBytesShaped': 3,
    'downBytesShaped': 4,
    'lossDropped': 5,
    'bufferDropped': 6,
    'duplicated': 7,
    'reordered': 8,
    'bufferedFrames': 9,
    'bufferedBytes': 10,
    'maxBufferedFrames': 11,
  },
};

/// `capture.config.get` / `capture.config.set` 共用的冻结响应 fixture
/// （`API.md` §2.16 `CaptureConfig`；字段值刻意偏离默认以证 round-trip 保真）。
const _captureConfigFixture = <String, dynamic>{
  'enabled': true,
  'tlsPorts': <int>[443, 8443],
  'domainAllowlist': <String>['a.example', '*.b.example'],
  'appAllowlist': <String>['com.a'],
  'captureBody': false,
  'captureWs': false,
  'captureH2': false,
  'maxBodyBytes': 524288,
};

/// `capture.ca.get` / `capture.ca.generate` 共用的冻结响应 fixture
/// （`API.md` §2.17 `CaptureCaInfo`；字段值刻意非空以证 round-trip 保真）。
const _captureCaInfoFixture = <String, dynamic>{
  'generated': true,
  'pem': '-----BEGIN CERTIFICATE-----\nMIIBKekq\n-----END CERTIFICATE-----\n',
  'derBase64': 'MIIBKekq',
  'fingerprintSha256': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
};

/// `capture.ca.reset` 冻结响应 fixture（`API.md` §2.17 `{ok, cleared}`）。
const _captureCaResetFixture = <String, dynamic>{
  'ok': true,
  'cleared': true,
};

/// 一条环内抓包记录 fixture（`API.md` §2.18 `CaptureRecord`）：含 base64 预览、
/// 一个 WS 帧与 IPv6 host/url（字段值刻意偏离默认以证 round-trip 保真）。
const _captureRecordFixture = <String, dynamic>{
  'recordId': 1,
  'requestRecordId': 0,
  'connId': 'c1',
  'host': '[2001:db8::1]',
  'method': 'GET',
  'scheme': 'https',
  'url': 'https://[2001:db8::1]:8443/p/1?q=1',
  'statusCode': 200,
  'protocol': 'h1',
  'reqHeaders': 'host: [2001:db8::1]\r\n',
  'respHeaders': 'content-type: text/plain\r\n',
  'reqBodyPreview': 'cmVx',
  'respBodyPreview': 'cmVzcA==',
  'reqBytes': 3,
  'respBytes': 4,
  'contentType': 'text/plain',
  'startedAtMs': 100,
  'finishedAtMs': 150,
  'durationMs': 50,
  'truncated': false,
  'mitmFailed': false,
  'wsFrames': <Map<String, dynamic>>[
    <String, dynamic>{
      'direction': 'clientToServer',
      'opcode': 'text',
      'payloadLen': 2,
      'preview': 'aGk=',
      'truncated': false,
      'atMs': 120,
    },
  ],
};

/// `captures.get` 冻结响应 fixture（`API.md` §2.18 `CapturePage`）。
const _capturePageFixture = <String, dynamic>{
  'records': <Map<String, dynamic>>[_captureRecordFixture],
  'nextCursor': 1,
  'firstCursor': 1,
  'retained': 1,
  'capacity': 256,
  'dropped': 0,
  'evicted': 0,
};

/// `captures.detail` 冻结响应 fixture（`API.md` §2.18 `CaptureDetail`）：环比字段
/// **加上**完整 body（base64）与完整 url/头。
final _captureDetailFixture = <String, dynamic>{
  ..._captureRecordFixture,
  'requestRecordId': 7,
  'url': 'https://[2001:db8::1]:8443/p/1?q=1&full=1',
  'reqHeaders': 'host: [2001:db8::1]\r\nx-full: 1\r\n',
  'reqBody': 'ZnVsbC1yZXE=',
  'respBody': 'ZnVsbC1yZXNw',
};

/// `captures.reset` 冻结响应 fixture（`API.md` §2.18 `{ok, cleared}`）。
const _capturesResetFixture = <String, dynamic>{'ok': true, 'cleared': 1};

final Map<String, Map<String, dynamic>> _methodFixtures =
    <String, Map<String, dynamic>>{
  ProxyMethods.ping: <String, dynamic>{
    'pong': true,
    'module': 'proxy',
    'moduleVersion': '0.1.0',
    'apiVersion': 1,
    'minHostAbi': 3,
    'hostAbi': 3,
    'instanceId': 7,
    'state': 'stopped',
    'mode': 'off',
    'protectFdPresent': true,
    'protectInstalled': false,
  },
  ProxyMethods.version: <String, dynamic>{
    'module': 'proxy',
    'moduleVersion': '0.1.0',
    'apiVersion': 1,
    'minHostAbi': 3,
    'hostAbi': 3,
    'meowRev': 'abc123',
    'targetArch': 'aarch64',
  },
  ProxyMethods.tunSetFd: <String, dynamic>{
    'fd': 7,
    'nonblocking': true,
    'replacedRunning': false,
  },
  ProxyMethods.coreStart: _coreStatusFixture,
  ProxyMethods.coreStop: <String, dynamic>{'state': 'stopped'},
  ProxyMethods.coreRestart: _coreStatusFixture,
  ProxyMethods.coreGetMode: <String, dynamic>{
    'mode': 'off',
    'state': 'stopped',
    'sinceMs': 0,
  },
  ProxyMethods.coreSetMode: <String, dynamic>{
    'ok': true,
    'mode': 'vpn',
    'previous': 'off',
  },
  ProxyMethods.routingGetMode: <String, dynamic>{
    'mode': 'rule',
    'engineRunning': true,
  },
  ProxyMethods.routingSetMode: <String, dynamic>{
    'mode': 'global',
    'applied': true,
    'engineRunning': true,
  },
  ProxyMethods.dnsGet: <String, dynamic>{
    'mode': 'fake-ip',
    'config': _dnsConfigFixture,
    'stats': <String, dynamic>{
      'queries': 3,
      'failures': 1,
      'cacheEntries': 2,
      'fakeIpActive': true,
      'fakeIpRange': '198.18.0.0/16',
    },
    'mappings': <Map<String, dynamic>>[
      <String, dynamic>{
        'domain': 'example.com',
        'ip': '198.18.0.4',
        'fake': true,
        'tsMs': 1,
        'domainKnown': true,
      },
    ],
    'recentQueries': <Map<String, dynamic>>[
      <String, dynamic>{
        'tsMs': 1,
        'domain': 'example.com',
        'qtype': 'A',
        'rcode': 'NoError',
        'answers': <String>['198.18.0.4'],
        'resolver': 'fake-ip',
        'latencyMs': 2,
        'ok': true,
        'mode': 'fake-ip',
        'note': 'fake-ip',
      },
    ],
  },
  ProxyMethods.dnsSet: <String, dynamic>{
    'ok': true,
    'config': _dnsConfigFixture,
  },
  ProxyMethods.dnsClearCache: <String, dynamic>{'ok': true, 'flushed': 3},
  ProxyMethods.dnsFlushCache: <String, dynamic>{'ok': true, 'flushed': 3},
  ProxyMethods.logGet: <String, dynamic>{
    'records': <Map<String, dynamic>>[
      <String, dynamic>{
        'cursor': 1,
        'tsMs': 1,
        'level': 'info',
        'kind': 'message',
        'message': 'proxy: core.start',
      },
      <String, dynamic>{
        'cursor': 2,
        'tsMs': 2,
        'level': 'info',
        'kind': 'connection',
        'connection': <String, dynamic>{
          'id': 'c1',
          'direction': 'in',
          'domain': 'a.com',
          'outbound': 'proxy-a',
          'rule': 'MATCH',
          'rulePayload': '',
          'network': 'tcp',
          'src': '10.10.0.2:1',
          'dst': '1.2.3.4:443',
          'uploadBytes': 1,
          'downloadBytes': 2,
          'bytes': 3,
          'durationMs': 4,
        },
      },
      <String, dynamic>{
        'cursor': 3,
        'tsMs': 3,
        'level': 'debug',
        'kind': 'dns',
        'dns': <String, dynamic>{
          'tsMs': 3,
          'domain': 'a.com',
          'qtype': 'A',
          'rcode': 'NoError',
          'answers': <String>['1.2.3.4'],
          'resolver': 'fake-ip',
          'latencyMs': 1,
          'ok': true,
          'mode': 'fake-ip',
        },
      },
    ],
    'cursor': 4,
    'nextCursor': 3,
    'firstCursor': 1,
    'retained': 3,
    'capacity': 1000,
    'dropped': 0,
    'sinkDropped': 0,
    'level': 'info',
  },
  ProxyMethods.logSetLevel: <String, dynamic>{'ok': true, 'level': 'debug'},
  ProxyMethods.logClear: <String, dynamic>{'ok': true},
  ProxyMethods.rulesGet: _rulesSnapshotFixture,
  ProxyMethods.rulesReload: _rulesSnapshotFixture,
  ProxyMethods.configGenerate: _generatedConfigFixture,
  ProxyMethods.configApply: <String, dynamic>{
    ..._generatedConfigFixture,
    'applied': true,
    'rules': 1,
  },
  ProxyMethods.profileExportClash: _generatedConfigFixture,
  ProxyMethods.profileImportUrl: _importedProfileFixture,
  ProxyMethods.profileImportText: _importedProfileFixture,
  ProxyMethods.profileImportLink: _importedProfileFixture,
  ProxyMethods.profileList: <String, dynamic>{
    'schemaVersion': 2,
    'revision': 3,
    'count': 1,
    'profiles': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'p1',
        'name': 'Fixture',
        'format': 'clash',
        'nodeCount': 1,
        'groupCount': 1,
        'createdAtMs': 1,
        'updatedAtMs': 2,
        'revision': 1,
        'sourceOrigin': 'url',
        'sourceUrl': 'https://example.com/sub',
        'userinfo': <String, dynamic>{'upload': 1, 'download': 2},
        'refresh': <String, dynamic>{'state': 'done', 'attempts': 1},
      },
    ],
    'warnings': <Map<String, dynamic>>[
      <String, dynamic>{
        'code': 'PROXY_PROFILE_CORRUPT',
        'id': 'p2',
        'file': 'p2.json',
        'message': 'bad',
      },
    ],
  },
  ProxyMethods.profileGet: _storedProfileFixture,
  ProxyMethods.profileCreate: _storedProfileFixture,
  ProxyMethods.profileUpdate: _storedProfileFixture,
  ProxyMethods.profileDelete: <String, dynamic>{
    'ok': true,
    'id': 'p1',
    'deleted': true,
  },
  ProxyMethods.profileRefresh: <String, dynamic>{
    'profileId': 'p1',
    'state': 'failed',
    'attempts': 2,
    'nodeCount': 1,
    'userinfo': <String, dynamic>{'upload': 1, 'download': 2},
    'nextRefreshAtMs': 100,
    'retryAfterMs': 50,
    'error': <String, dynamic>{
      'code': 'PROXY_SUB_FETCH_FAILED',
      'message': 'connect refused',
    },
    'profile': _storedProfileFixture,
  },
  ProxyMethods.profileRefreshAll: <String, dynamic>{
    'force': false,
    'limit': 8,
    'attempted': 1,
    'count': 1,
    'failedCount': 0,
    'refreshed': <Map<String, dynamic>>[],
    'skipped': <Map<String, dynamic>>[
      <String, dynamic>{'profileId': 'p2', 'reason': 'backoff', 'nextRefreshAtMs': 5},
    ],
  },
  ProxyMethods.profileSetSchedule: _storedProfileFixture,
  ProxyMethods.nodeSelect: <String, dynamic>{
    'ok': true,
    'group': 'G',
    'node': 'A',
    'active': 'A',
  },
  ProxyMethods.nodeDelayTest: <String, dynamic>{
    'results': <Map<String, dynamic>>[
      <String, dynamic>{'node': 'A', 'delayMs': 0, 'alive': false, 'error': 'timeout'},
    ],
    'url': 'https://www.gstatic.com/generate_204',
    'timeoutMs': 5000,
    'group': 'G',
  },
  ProxyMethods.nodeList: <String, dynamic>{
    'engineRunning': true,
    'groups': <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'G',
        'type': 'select',
        'now': 'A',
        'members': <String>['A', 'B'],
        'selectable': true,
      },
    ],
    'current': <String, dynamic>{'group': 'G', 'now': 'A', 'node': null},
  },
  ProxyMethods.connList: <String, dynamic>{
    'connections': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'c1',
        'src': '10.10.0.2:40000',
        'dst': '1.2.3.4:443',
        'domain': 'example.com',
        'network': 'tcp',
        'rule': 'DOMAIN-SUFFIX',
        'rulePayload': 'example.com',
        'outbound': 'proxy-a',
        'uploadBytes': 0,
        'downloadBytes': 0,
        'startedAtMs': 0,
      },
    ],
    'count': 1,
    'returned': 1,
    'total': 1,
    'offset': 0,
    'limit': 256,
    'hasMore': false,
    'capacity': 1024,
  },
  ProxyMethods.connClose: <String, dynamic>{
    'ok': true,
    'id': 'c1',
    'closed': true,
    'alreadyClosed': false,
  },
  ProxyMethods.connCloseAll: <String, dynamic>{'ok': true, 'closed': 2},
  ProxyMethods.statsDomainGet: <String, dynamic>{
    'domains': <Map<String, dynamic>>[
      <String, dynamic>{
        'domain': 'example.com',
        'domainKnown': true,
        'connections': 3,
        'uploadBytes': 1,
        'downloadBytes': 2,
        'lastSeenMs': 5,
        'rule': 'DOMAIN-SUFFIX',
        'rulePayload': 'example.com',
        'outbound': 'proxy-a',
      },
    ],
    'count': 1,
    'returned': 1,
    'capacity': 2048,
    'domainCap': 2048,
    'evicted': 0,
    'rangeMs': 0,
    'sort': 'bytes',
  },
  ProxyMethods.statsDomainReset: <String, dynamic>{'ok': true, 'cleared': 4},
  ProxyMethods.statsTrafficGet: <String, dynamic>{
    'uploadBytes': 1,
    'downloadBytes': 2,
    'activeConns': 1,
    'upBps': 3,
    'downBps': 4,
    'domainCount': 1,
    'capacity': 2048,
    'evicted': 0,
    'topDomains': <Map<String, dynamic>>[
      <String, dynamic>{'domain': 'example.com', 'domainKnown': true},
    ],
  },
  ProxyMethods.statsGet: <String, dynamic>{
    'domains': <Map<String, dynamic>>[],
    'count': 0,
    'returned': 0,
    'capacity': 2048,
    'domainCap': 2048,
    'evicted': 0,
    'rangeMs': 0,
    'sort': 'bytes',
  },
  ProxyMethods.statsReset: <String, dynamic>{'ok': true, 'cleared': 0},
  ProxyMethods.requestsGet: <String, dynamic>{
    'records': <Map<String, dynamic>>[
      <String, dynamic>{
        'recordId': 1,
        'connId': 'c1',
        'openTsMs': 100,
        'closeTsMs': 200,
        'durationMs': 100,
        'domain': 'example.com',
        'domainKnown': true,
        'dstIp': '1.2.3.4',
        'dstPort': 443,
        'src': '10.10.0.2:5555',
        'network': 'tcp',
        'uid': 10123,
        'packages': <String>['com.example.app'],
        'uidState': 'known',
        'rule': 'MATCH',
        'rulePayload': '',
        'outbound': 'DIRECT',
        'uploadBytes': 1,
        'downloadBytes': 2,
        'closeReason': 'closed',
      },
    ],
    'nextCursor': 1,
    'firstCursor': 1,
    'retained': 1,
    'capacity': 4096,
    'dropped': 0,
    'evicted': 0,
    'windowStartMs': 100,
  },
  ProxyMethods.requestsReset: <String, dynamic>{'ok': true, 'cleared': 1},
  ProxyMethods.requestsExport: <String, dynamic>{
    'csvPath': '/data/proxy_requests_export_1.csv',
    'jsonPath': '/data/proxy_requests_export_1.json',
    'rows': 1,
    'bytes': 123,
    'generatedAtMs': 1000,
  },
  ProxyMethods.clashApiStart: <String, dynamic>{
    'enabled': true,
    'bound': true,
    'address': '127.0.0.1:9090',
    'loopbackOnly': true,
    'port': 9090,
  },
  ProxyMethods.clashApiStop: <String, dynamic>{
    'enabled': false,
    'wasRunning': true,
  },
  ProxyMethods.clashApiStatus: <String, dynamic>{
    'enabled': false,
    'bound': false,
    'loopbackOnly': true,
  },
  ProxyMethods.lanGet: <String, dynamic>{
    'config': _lanConfigFixture,
    'warning': null,
  },
  ProxyMethods.lanStatus: <String, dynamic>{
    'enabled': false,
    'bound': false,
    'listening': false,
    'addresses': <String>[],
    'activeConns': 0,
    'port': 1087,
    'bindAddress': '0.0.0.0',
    'engineOnly': false,
    'warning': null,
    'config': _lanConfigFixture,
  },
  // `lan.set` 的 status **嵌套**在 `status` 之下（lib.rs `lan_set_arm`）。
  ProxyMethods.lanSet: <String, dynamic>{
    'config': <String, dynamic>{..._lanConfigFixture, 'enabled': true},
    'status': <String, dynamic>{
      'enabled': true,
      'bound': true,
      'listening': true,
      'addresses': <String>['192.168.1.5:1087'],
      'activeConns': 0,
      'port': 1087,
      'bindAddress': '0.0.0.0',
      'engineOnly': false,
      'warning': null,
      'config': <String, dynamic>{..._lanConfigFixture, 'enabled': true},
    },
    'warning': null,
  },
  // `net.shaper.get` 与 `net.shaper.set` 共用同一冻结形状 fixture。
  ProxyMethods.netShaperGet: _shaperSnapshotFixture,
  ProxyMethods.netShaperSet: _shaperSnapshotFixture,
  // `capture.config.get` 与 `capture.config.set` 共用同一冻结形状 fixture。
  ProxyMethods.captureConfigGet: _captureConfigFixture,
  ProxyMethods.captureConfigSet: _captureConfigFixture,
  // `capture.ca.get` 与 `capture.ca.generate` 共用同一冻结形状 fixture。
  ProxyMethods.captureCaGet: _captureCaInfoFixture,
  ProxyMethods.captureCaGenerate: _captureCaInfoFixture,
  ProxyMethods.captureCaReset: _captureCaResetFixture,
  // `captures.*` 抓包时间线（API.md §2.18）。
  ProxyMethods.capturesGet: _capturePageFixture,
  ProxyMethods.capturesDetail: _captureDetailFixture,
  ProxyMethods.capturesReset: _capturesResetFixture,
};

final Map<String, Map<String, dynamic>> _eventFixtures =
    <String, Map<String, dynamic>>{
  ProxyEvents.state: <String, dynamic>{
    'state': 'running',
    'mode': 'vpn',
    'reason': 'user',
  },
  ProxyEvents.mode: <String, dynamic>{'mode': 'vpn', 'previous': 'off'},
  ProxyEvents.nodeDelay: <String, dynamic>{
    'group': 'G',
    'node': 'A',
    'delayMs': 12,
  },
  ProxyEvents.stats: <String, dynamic>{
    'uploadBytes': 1,
    'downloadBytes': 2,
    'activeConns': 1,
    'upBps': 3,
    'downBps': 4,
    'domainCount': 1,
    'capacity': 2048,
    'topDomains': <Map<String, dynamic>>[
      <String, dynamic>{'domain': 'a.com', 'domainKnown': true},
    ],
  },
  ProxyEvents.request: <String, dynamic>{
    'seq': 1,
    'count': 2,
    'tsMs': 1000,
  },
  ProxyEvents.subscriptionUpdated: <String, dynamic>{
    'profileId': 'p1',
    'nodeCount': 1,
    'traffic': <String, dynamic>{
      'uploadBytes': 1,
      'downloadBytes': 2,
      'totalBytes': 3,
      'usedBytes': 3,
    },
    'expireAtMs': 1,
  },
  ProxyEvents.subscriptionProgress: <String, dynamic>{
    'profileId': 'p1',
    'phase': 'fetch',
    'state': 'started',
    'attempts': 1,
  },
  ProxyEvents.subscriptionFailed: <String, dynamic>{
    'profileId': 'p1',
    'attempts': 1,
    'consecutiveFailures': 1,
    'lastAttemptMs': 1,
    'nextRefreshAtMs': 2,
    'error': <String, dynamic>{'code': 'x', 'message': 'y'},
  },
  ProxyEvents.subscriptionAdded: <String, dynamic>{
    'profileId': 'p1',
    'name': 'sub',
  },
  ProxyEvents.subscriptionRemoved: <String, dynamic>{'profileId': 'p1'},
  ProxyEvents.conn: <String, dynamic>{
    'action': 'close_all',
    'closed': 2,
  },
  ProxyEvents.dns: <String, dynamic>{
    'tsMs': 1,
    'domain': 'a.com',
    'qtype': 'A',
    'rcode': 'NoError',
    'answers': <String>['1.2.3.4'],
    'resolver': 'fake-ip',
    'latencyMs': 1,
    'ok': true,
    'mode': 'fake-ip',
  },
  ProxyEvents.tunReleased: <String, dynamic>{'fd': 9},
  ProxyEvents.configApplied: <String, dynamic>{
    'profileId': 'p1',
    'hash': 'abc',
    'template': 'gstore-controlled-v1',
  },
};

// ==================== API.md 解析 ====================

String _section(String text, String startMarker, String endMarker) {
  final start = text.indexOf(startMarker);
  final end = text.indexOf(endMarker, start + startMarker.length);
  return text.substring(start, end);
}

Set<String> _documentedMethods(String apiMd) {
  final section = _section(apiMd, '## 2. Methods', '## 3. Events');
  final tableRow =
      RegExp(r'^\| `([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)`', multiLine: true);
  final heading =
      RegExp(r'^### 2\.\d+(?:\.\d+)? `([a-z][a-z0-9_]+)`', multiLine: true);
  return <String>{
    for (final m in tableRow.allMatches(section)) m.group(1)!,
    for (final m in heading.allMatches(section)) m.group(1)!,
  };
}

Set<String> _documentedEvents(String apiMd) {
  final section = _section(apiMd, '## 3. Events', '## 4. Host');
  final row = RegExp(r'^\| `(proxy\.[a-z0-9_.]+)`', multiLine: true);
  return <String>{for (final m in row.allMatches(section)) m.group(1)!};
}

/// `lan.*` 现已注册进冻结契约 [ProxyMethods]/[proxyResponseDecoders]
/// （`API.md` §2.12），文档↔代码差集为空。
const _documentedButNotInDartRegistry = <String>{};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('文档 ↔ 代码完整性（machine-checkable）', () {
    test('API.md 方法与 Dart 注册表一致（仅允许冻结契约外的 lan.*）', () {
      final apiMd = File('rust/gstore_mod_proxy/API.md').readAsStringSync();
      final documented = _documentedMethods(apiMd);
      final dartMethods = ProxyMethods.all.toSet();

      expect(
        dartMethods.difference(documented),
        isEmpty,
        reason: 'Dart 注册了 API.md 未文档化的方法',
      );
      expect(
        documented.difference(dartMethods),
        _documentedButNotInDartRegistry,
        reason: 'API.md 有既非 Dart 注册、又非 lan.* 的方法',
      );
    });

    test('API.md 事件与 Dart 事件注册表逐一相等', () {
      final apiMd = File('rust/gstore_mod_proxy/API.md').readAsStringSync();
      expect(_documentedEvents(apiMd), ProxyEvents.all.toSet());
    });

    test('每个方法都有唯一解码器', () {
      expect(ProxyMethods.all.toSet().length, ProxyMethods.all.length);
      expect(
        proxyResponseDecoders.keys.toSet(),
        ProxyMethods.all.toSet(),
        reason: '方法 → 解码器必须一一对应',
      );
    });

    test('请求编码器仅覆盖请求型方法（方法集合的子集）', () {
      final methodSet = ProxyMethods.all.toSet();
      expect(
        methodSet.containsAll(proxyRequestEncoders.keys),
        isTrue,
        reason: '编码器键必须全部是已注册方法（encoders ⊆ methods）',
      );
      expect(
        proxyRequestEncoders.keys.toSet(),
        isNot(methodSet),
        reason: '部分方法无请求体，编码器不应等于方法全集',
      );
    });

    test('运行日志 UI 已移除，但 log.* 冻结契约能力必须保留', () {
      // 运行日志查看器页与展示门面已删除；`log.*` 是模块级能力（日志环经宿主
      // `log` 回调桥接到 LogManager），不随 UI 移除而删除。此断言按名锁定能力。
      for (final method in const <String>[
        ProxyMethods.logGet,
        ProxyMethods.logSetLevel,
        ProxyMethods.logClear,
      ]) {
        expect(
          ProxyMethods.all,
          contains(method),
          reason: '$method 必须保留在冻结契约方法表中',
        );
        expect(
          proxyResponseDecoders.containsKey(method),
          isTrue,
          reason: '$method 必须保留解码器（能力完整）',
        );
        expect(
          _methodFixtures.containsKey(method),
          isTrue,
          reason: '$method 必须保留响应 fixture（round-trip 覆盖）',
        );
      }
    });
  });

  group('happy QA：每个方法都有 fixture → 类型化 Dart 模型', () {
    test('全部方法经假网关 round-trip 解码为非 Map 类型', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        for (final entry in _methodFixtures.entries)
          entry.key: _okEnvelope(entry.value),
      });
      final facade = ProxyModule(gateway: gateway);

      for (final method in ProxyMethods.all) {
        final decode = proxyResponseDecoders[method]!;
        final result = await facade.invoke(method, decode);
        expect(
          result is! Map,
          isTrue,
          reason: '$method 必须解码为类型化模型，实际 ${result.runtimeType}',
        );
      }
      expect(gateway.methods, ProxyMethods.all);
    });

    test('每个方法对空对象 {} 宽容解码，绝不抛错', () {
      for (final method in ProxyMethods.all) {
        final decode = proxyResponseDecoders[method]!;
        expect(
          () => decode(const <String, dynamic>{}),
          returnsNormally,
          reason: '$method 必须容忍缺失字段',
        );
      }
    });

    test('lan.set 解码嵌套 status（bound/addresses），锁定旧 bug 修复', () async {
      final fixture = _methodFixtures[ProxyMethods.lanSet]!;
      final gateway = _FakeGateway(<String, Uint8List>{
        ProxyMethods.lanSet: _okEnvelope(fixture),
      });
      final facade = ProxyModule(gateway: gateway);

      final status = await facade.invoke(
        ProxyMethods.lanSet,
        proxyResponseDecoders[ProxyMethods.lanSet]!,
      ) as ProxyLanStatus;
      expect(status.bound, isTrue);
      expect(status.addresses, isNotEmpty);

      // 类型化门面同样解包 `status`（而非顶层，否则 bound=false）。
      final typed = await facade.lanSet(const ProxyLanConfig());
      expect(typed.bound, isTrue);
      expect(typed.addresses, isNotEmpty);
    });

    test('capture.config fixture round-trip 保留真实字段值', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        ProxyMethods.captureConfigGet: _okEnvelope(_captureConfigFixture),
      });
      final facade = ProxyModule(gateway: gateway);

      final cfg = await facade.invoke(
        ProxyMethods.captureConfigGet,
        proxyResponseDecoders[ProxyMethods.captureConfigGet]!,
      ) as CaptureConfig;
      expect(cfg.enabled, isTrue);
      expect(cfg.tlsPorts, <int>[443, 8443]);
      expect(cfg.domainAllowlist, <String>['a.example', '*.b.example']);
      expect(cfg.appAllowlist, <String>['com.a']);
      expect(cfg.captureBody, isFalse);
      expect(cfg.captureWs, isFalse);
      expect(cfg.captureH2, isFalse);
      expect(cfg.maxBodyBytes, 524288);

      // get 形状 → toJson → fromJson 必须无损。
      final decoded = CaptureConfig.fromJson(cfg.toJson());
      expect(decoded.enabled, cfg.enabled);
      expect(decoded.tlsPorts, cfg.tlsPorts);
      expect(decoded.domainAllowlist, cfg.domainAllowlist);
      expect(decoded.appAllowlist, cfg.appAllowlist);
      expect(decoded.captureBody, cfg.captureBody);
      expect(decoded.captureH2, cfg.captureH2);
      expect(decoded.maxBodyBytes, cfg.maxBodyBytes);
    });

    test('capture.ca fixture round-trip 保留真实字段值', () async {
      // `get` 与 `generate` 共用同一 `CaptureCaInfo` 解码器。
      final gateway = _FakeGateway(<String, Uint8List>{
        ProxyMethods.captureCaGet: _okEnvelope(_captureCaInfoFixture),
        ProxyMethods.captureCaGenerate: _okEnvelope(_captureCaInfoFixture),
        ProxyMethods.captureCaReset: _okEnvelope(_captureCaResetFixture),
      });
      final facade = ProxyModule(gateway: gateway);

      final info = await facade.invoke(
        ProxyMethods.captureCaGet,
        proxyResponseDecoders[ProxyMethods.captureCaGet]!,
      ) as CaptureCaInfo;
      expect(info.generated, isTrue);
      expect(info.pem, contains('BEGIN CERTIFICATE'));
      expect(info.derBase64, 'MIIBKekq');
      expect(info.fingerprintSha256.length, 64);

      final generated = await facade.invoke(
        ProxyMethods.captureCaGenerate,
        proxyResponseDecoders[ProxyMethods.captureCaGenerate]!,
      ) as CaptureCaInfo;
      expect(generated.fingerprintSha256, info.fingerprintSha256);

      final reset = await facade.invoke(
        ProxyMethods.captureCaReset,
        proxyResponseDecoders[ProxyMethods.captureCaReset]!,
      ) as CaptureCaResetResult;
      expect(reset.ok, isTrue);
      expect(reset.cleared, isTrue);

      // 未生成形状（generated:false + 空字段）宽容解码，绝不抛错。
      final absent = CaptureCaInfo.fromJson(const <String, dynamic>{});
      expect(absent.generated, isFalse);
      expect(absent.pem, isEmpty);
      expect(absent.derBase64, isEmpty);
      expect(absent.fingerprintSha256, isEmpty);
    });

    test(
        'captures fixture round-trip 保留真实字段值（含 IPv6 / base64 / wsFrames / path）',
        () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        ProxyMethods.capturesGet: _okEnvelope(_capturePageFixture),
        ProxyMethods.capturesDetail: _okEnvelope(_captureDetailFixture),
        ProxyMethods.capturesReset: _okEnvelope(_capturesResetFixture),
      });
      final facade = ProxyModule(gateway: gateway);

      final page = await facade.invoke(
        ProxyMethods.capturesGet,
        proxyResponseDecoders[ProxyMethods.capturesGet]!,
      ) as CapturePage;
      expect(page.records, hasLength(1));
      expect(page.nextCursor, 1);
      expect(page.capacity, 256);
      final rec = page.records.single;
      expect(rec.recordId, 1);
      expect(rec.requestRecordId, 0, reason: '孤儿 capture 的关联键为 0 且仍返回');
      expect(rec.host, '[2001:db8::1]');
      expect(rec.url, 'https://[2001:db8::1]:8443/p/1?q=1');
      expect(rec.path, '/p/1', reason: 'path 由 url 派生，IPv6 host 不干扰');
      expect(rec.reqBodyPreview, utf8.encode('req'));
      expect(rec.respBodyPreview, utf8.encode('resp'));
      expect(rec.wsFrames, hasLength(1));
      expect(rec.wsFrames.single.direction, 'clientToServer');
      expect(rec.wsFrames.single.preview, utf8.encode('hi'));

      final detail = await facade.invoke(
        ProxyMethods.capturesDetail,
        proxyResponseDecoders[ProxyMethods.capturesDetail]!,
      ) as CaptureDetail;
      expect(detail.requestRecordId, 7);
      expect(detail.reqBody, utf8.encode('full-req'));
      expect(detail.respBody, utf8.encode('full-resp'));
      expect(detail.url, contains('full=1'));
      expect(detail.path, '/p/1');

      final reset = await facade.invoke(
        ProxyMethods.capturesReset,
        proxyResponseDecoders[ProxyMethods.capturesReset]!,
      ) as CapturesResetResult;
      expect(reset.ok, isTrue);
      expect(reset.cleared, 1);

      final empty = CaptureRecord.fromJson(const <String, dynamic>{});
      expect(empty.recordId, 0);
      expect(empty.wsFrames, isEmpty);
      expect(empty.reqBodyPreview, isEmpty);
    });

    test('CaptureRecord 最坏序列化 ≤ 4096（CAPTURE_RECORD_MAX_BYTES）', () {
      final worst = CaptureRecord(
        recordId: 0x7FFFFFFFFFFFFFFF,
        requestRecordId: 0x7FFFFFFFFFFFFFFF,
        connId: _rep('c', 64),
        host: _rep('h', 253),
        method: _rep('M', 16),
        scheme: 'https',
        url: _rep('u', 1024),
        statusCode: 65535,
        protocol: 'ws',
        reqHeaders: _rep('r', 512),
        respHeaders: _rep('s', 512),
        reqBodyPreview: Uint8List.fromList(List<int>.filled(256, 0xFF)),
        respBodyPreview: Uint8List.fromList(List<int>.filled(256, 0xFF)),
        reqBytes: 0x7FFFFFFFFFFFFFFF,
        respBytes: 0x7FFFFFFFFFFFFFFF,
        contentType: _rep('t', 128),
        startedAtMs: 0x7FFFFFFFFFFFFFFF,
        finishedAtMs: 0x7FFFFFFFFFFFFFFF,
        durationMs: 0x7FFFFFFFFFFFFFFF,
        truncated: true,
        mitmFailed: true,
      );
      final bytes = utf8.encode(jsonEncode(worst.toJson()));
      expect(bytes.length, lessThanOrEqualTo(4096),
          reason: 'CAPTURE_RECORD_MAX_BYTES = 4096');
      expect(bytes.length, greaterThan(3000), reason: '确实是接近上限的最坏用例');
    });

    test('每个事件 fixture 解码为对应类型化事件', () {
      for (final entry in _eventFixtures.entries) {
        final event = ProxyEvent.decode(ProxyRawEvent(
          eventType: entry.key,
          data: _raw(jsonEncode(entry.value)),
        ));
        expect(event, isNotNull, reason: '${entry.key} 未解码');
        expect(event!.eventType, entry.key);
      }
    });

    test('新增事件映射到正确的子类', () {
      final dns = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.dns',
        data: _raw(jsonEncode(_eventFixtures['proxy.dns'])),
      ));
      expect(dns, isA<ProxyDnsEvent>());
      expect((dns! as ProxyDnsEvent).domain, 'a.com');

      final released = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.tun.released',
        data: _raw(jsonEncode(<String, dynamic>{'fd': 3})),
      ));
      expect(released, isA<ProxyTunReleasedEvent>());
      expect((released! as ProxyTunReleasedEvent).fd, 3);

      final applied = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.config.applied',
        data: _raw(jsonEncode(_eventFixtures['proxy.config.applied'])),
      ));
      expect(applied, isA<ProxyConfigAppliedEvent>());
      expect((applied! as ProxyConfigAppliedEvent).template, 'gstore-controlled-v1');
    });

    test('proxy.request 解码为 ProxyRequestEvent（无载荷脏信号）', () {
      final event = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.request',
        data: _raw(jsonEncode(_eventFixtures['proxy.request'])),
      ));
      expect(event, isA<ProxyRequestEvent>());
      final request = event! as ProxyRequestEvent;
      expect(request.seq, 1);
      expect(request.count, 2);
      expect(request.tsMs, 1000);

      // 截断/畸形载荷静默忽略（不抛错），与其它事件一致。
      final truncated = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.request',
        data: _raw('{"seq":'),
      ));
      expect(truncated, isNull);
    });

    test('proxy.stats / proxy.conn 新字段解码', () {
      final stats = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.stats',
        data: _raw(jsonEncode(_eventFixtures['proxy.stats'])),
      ))! as ProxyStatsEvent;
      expect(stats.domainCount, 1);
      expect(stats.capacity, 2048);
      expect(stats.topDomains, hasLength(1));
      expect(stats.topDomains.first.domain, 'a.com');

      final conn = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.conn',
        data: _raw(jsonEncode(<String, dynamic>{'action': 'close_all', 'closed': 5})),
      ))! as ProxyConnEvent;
      expect(conn.closed, 5);
    });

    test('每个请求模型 toJson 可被 jsonEncode 编码', () {
      for (final entry in proxyRequestEncoders.entries) {
        expect(ProxyMethods.all, contains(entry.key));
        final json = entry.value();
        expect(() => jsonEncode(json), returnsNormally);
      }
    });

    test('node.delay_test：targets 非空时编码、空时省略键', () {
      final encoded =
          const NodeDelayTestRequest(targets: <String>['A', 'B']).toJson();
      expect(encoded['targets'], <String>['A', 'B']);
      // 空 targets 不产生键（保持旧请求形状 / 不触发后端 422）。
      expect(const NodeDelayTestRequest().toJson().containsKey('targets'),
          isFalse);
      // 显式 targets 与 group/node 互斥语义不冲突（均由后端处理）。
      expect(
        const NodeDelayTestRequest(targets: <String>['A']).toJson()['group'],
        isNull,
      );
    });
  });

  group('failure QA：结构化错误、无崩溃', () {
    test('未知方法 → 结构化 METHOD_NOT_FOUND（405）', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        'core.no_such_method': _errorEnvelope(
          405,
          'METHOD_NOT_FOUND',
          'method not found: core.no_such_method',
        ),
      });
      final facade = ProxyModule(gateway: gateway);

      await expectLater(
        facade.invoke('core.no_such_method', OkResult.fromJson),
        throwsA(
          isA<ProxyModuleException>()
              .having((e) => e.code, 'code', 'METHOD_NOT_FOUND')
              .having((e) => e.status, 'status', 405),
        ),
      );
    });

    test('BAD_REQUEST 信封 → 结构化 400', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        'ping': _errorEnvelope(400, 'BAD_REQUEST', 'envelope decode failed'),
      });
      final facade = ProxyModule(gateway: gateway);

      await expectLater(
        facade.invoke('ping', ProxyPingResult.fromJson),
        throwsA(
          isA<ProxyModuleException>()
              .having((e) => e.code, 'code', 'BAD_REQUEST')
              .having((e) => e.status, 'status', 400),
        ),
      );
    });

    test('截断 JSON 载荷 → PAYLOAD_DECODE_FAILED（400），不崩溃', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        'ping': _raw('{"ok":true,"data":{"pong":'),
      });
      final facade = ProxyModule(gateway: gateway);

      await expectLater(
        facade.invoke('ping', ProxyPingResult.fromJson),
        throwsA(
          isA<ProxyModuleException>()
              .having((e) => e.code, 'code', 'PAYLOAD_DECODE_FAILED')
              .having((e) => e.status, 'status', 400),
        ),
      );
    });

    test('非对象 JSON 载荷 → PAYLOAD_DECODE_FAILED，不崩溃', () async {
      final gateway = _FakeGateway(<String, Uint8List>{'ping': _raw('[]')});
      final facade = ProxyModule(gateway: gateway);

      await expectLater(
        facade.invoke('ping', ProxyPingResult.fromJson),
        throwsA(isA<ProxyModuleException>().having(
          (e) => e.code,
          'code',
          'PAYLOAD_DECODE_FAILED',
        )),
      );
    });

    test('事件载荷截断 → 静默忽略（不抛错）', () {
      final event = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.state',
        data: _raw('{"state":'),
      ));
      expect(event, isNull);
    });
  });

  group('GeoAsset：错误原因透传（Rust error: Option<String>）', () {
    test('fromJson 解析非空 error', () {
      final asset = GeoAsset.fromJson(const <String, dynamic>{
        'kind': 'mmdb',
        'file': 'country.mmdb',
        'path': '/tmp/country.mmdb',
        'status': 'failed',
        'verified': false,
        'sha256': '',
        'error': 'checksum mismatch: country.mmdb',
      });
      expect(asset.file, 'country.mmdb');
      expect(asset.status, 'failed');
      expect(asset.error, 'checksum mismatch: country.mmdb');
    });

    test('空串 error 归一化为 null', () {
      final asset = GeoAsset.fromJson(const <String, dynamic>{
        'kind': 'dat',
        'file': 'geosite.dat',
        'status': 'ready',
        'verified': true,
        'sha256': 'abc',
        'error': '',
      });
      expect(asset.error, isNull);
    });

    test('缺失 error 宽容解码为 null，不抛错', () {
      final asset = GeoAsset.fromJson(const <String, dynamic>{
        'kind': 'dat',
        'file': 'geosite.dat',
      });
      expect(asset.error, isNull);
    });
  });
}
