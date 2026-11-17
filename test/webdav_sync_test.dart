import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/foundation/runtime_metrics.dart';
import 'package:pica_comic/foundation/secret_store.dart';
import 'package:pica_comic/network/sync_revision.dart';
import 'package:pica_comic/network/sync_transport.dart';
import 'package:pica_comic/network/webdav.dart';
import 'package:sqlite3/sqlite3.dart';

class _FakeSyncTransport implements SyncTransport {
  _FakeSyncTransport({
    this.failList = false,
    this.failDownloads = false,
    this.failClose = false,
    this.pointerValue = const SyncPointer(null),
  });

  final bool failList;
  final bool failDownloads;
  final bool failClose;
  final SyncPointer pointerValue;
  final List<String> names = <String>[];
  final Map<String, String> text = <String, String>{};
  final List<String> downloads = <String>[];
  final List<String> uploads = <String>[];
  final List<SyncPointer> pointerWrites = <SyncPointer>[];
  bool closed = false;

  @override
  Future<bool> compareAndSetPointer(SyncPointer previous, String value) async {
    pointerWrites.add(previous);
    text['sync-head.json'] = value;
    return true;
  }

  @override
  void close() {
    closed = true;
    if (failClose) throw StateError('injected close failure');
  }

  @override
  Future<void> download(String name, String destination) async {
    downloads.add(name);
    if (failDownloads) throw StateError('injected download failure');
    await File(destination).writeAsBytes(const <int>[]);
  }

  @override
  Future<List<String>> list() async {
    if (failList) throw StateError('injected list failure');
    return List<String>.from(names);
  }

  @override
  Future<SyncPointer> pointer() async => pointerValue;

  @override
  Future<void> upload(String source, String name) async {
    uploads.add(name);
  }

  @override
  Future<String> readText(String name) async => text[name]!;

  @override
  Future<void> writeText(String name, String value) async {
    text[name] = value;
  }
}

/// A shared remote store lets one test exercise two independent local state
/// files without depending on an external WebDAV server.
class _SharedSyncRemote {
  _SharedSyncRemote({required this.etags});

  final bool etags;
  final Map<String, List<int>> archives = <String, List<int>>{};
  final Map<String, String> metadata = <String, String>{};
  final List<bool> casResults = <bool>[];
  String? _etag;
  int _etagVersion = 0;
  int _pointerReads = 0;
  bool returnStalePointerOnSecondRead = false;
  void Function()? beforeCompareAndSet;

  List<String> get names => <String>[...archives.keys, ...metadata.keys];

  SyncPointer pointer() {
    _pointerReads++;
    if (returnStalePointerOnSecondRead && _pointerReads == 2) {
      return const SyncPointer('*');
    }
    if (!etags) return const SyncPointer(null);
    return SyncPointer(_etag == null ? '*' : '"$_etag"');
  }

  bool compareAndSet(SyncPointer previous, String value) {
    beforeCompareAndSet?.call();
    final expected = _etag == null ? '*' : '"$_etag"';
    final accepted = !etags || previous.etag == expected;
    casResults.add(accepted);
    if (!accepted) return false;
    metadata['sync-head.json'] = value;
    if (etags) _etag = '${++_etagVersion}';
    return true;
  }

  void publishExternalRevision(SyncRevision revision, List<int> bytes) {
    archives[revision.archiveName] = bytes;
    metadata[revision.descriptorName] = encodeSyncRevision(revision);
    metadata['sync-head.json'] = jsonEncode({
      'protocol': 2,
      'heads': [revision.id]
    });
    if (etags) _etag = '${++_etagVersion}';
  }

  void publishLegacyArchive(int version, List<int> bytes) {
    archives['$version.picadata'] = bytes;
  }
}

class _SharedSyncTransport implements SyncTransport {
  _SharedSyncTransport(this.remote);

  final _SharedSyncRemote remote;
  bool closed = false;

  @override
  Future<bool> compareAndSetPointer(SyncPointer previous, String value) async =>
      remote.compareAndSet(previous, value);

  @override
  void close() {
    closed = true;
  }

  @override
  Future<void> download(String name, String destination) async {
    final bytes = remote.archives[name];
    if (bytes == null) throw StateError('missing remote archive $name');
    await File(destination).writeAsBytes(bytes);
  }

  @override
  Future<List<String>> list() async => remote.names;

  @override
  Future<SyncPointer> pointer() async => remote.pointer();

  @override
  Future<String> readText(String name) async {
    final value = remote.metadata[name];
    if (value == null) throw StateError('missing remote metadata $name');
    return value;
  }

  @override
  Future<void> upload(String source, String name) async {
    remote.archives[name] = await File(source).readAsBytes();
  }

  @override
  Future<void> writeText(String name, String value) async {
    remote.metadata[name] = value;
  }
}

Future<T> _withHttpServer<T>(FutureOr<void> Function(HttpRequest) handler,
    Future<T> Function(String baseUrl) action) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = server.listen(handler);
  final baseUrl = 'http://${server.address.address}:${server.port}';
  try {
    return await action(baseUrl);
  } finally {
    await requests.cancel();
    await server.close(force: true);
  }
}

void main() {
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-webdav-sync-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    SecretStoreRegistry.configure(MemorySecretStore());
    await LocalFavoritesManager().init(importLegacy: false);
    await HistoryManager().init(importLegacy: false);
    final cookies = sqlite3.open('${root.path}/cookies.db');
    cookies.execute('CREATE TABLE cookies (id TEXT);');
    cookies.dispose();
  });

  setUp(RuntimeMetrics.reset);

  tearDown(() async {
    await DataMaintenance.waitForIdle();
    SecretStoreRegistry.configure(MemorySecretStore());
  });

  tearDownAll(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('conflict resolution applies selected settings revision last', () async {
    final previousFactory = Webdav.transportFactory;
    final previousSetting = appdata.settings[45];
    final transport = _FakeSyncTransport(failDownloads: true);
    final first = SyncRevision(
        id: 'a', device: 'device-a', parents: const [], sha256: '0' * 64);
    final second = SyncRevision(
        id: 'b', device: 'device-b', parents: const [], sha256: '1' * 64);
    transport.names.addAll([
      first.archiveName,
      first.descriptorName,
      second.archiveName,
      second.descriptorName,
    ]);
    transport.text[first.descriptorName] = encodeSyncRevision(first);
    transport.text[second.descriptorName] = encodeSyncRevision(second);
    try {
      appdata.settings[45] = 'https://dav.example;;;/pica';
      Webdav.transportFactory = (_) => transport;

      expect(await Webdav.resolveConflict(settingsRevision: first.id), isFalse);
      expect(transport.downloads, [second.archiveName]);
      expect(transport.closed, isTrue);
      expect(Webdav.lastResult.status, SyncStatus.failed);
      final metric = RuntimeMetrics.snapshot()['sync.resolve']!;
      expect(metric.failure, 1);
      expect(metric.active, 0);
    } finally {
      appdata.settings[45] = previousSetting;
      Webdav.transportFactory = previousFactory;
    }
  });

  test(
      'upload failure before export still closes transport and reports failure',
      () async {
    final previousFactory = Webdav.transportFactory;
    final transport = _FakeSyncTransport(failList: true);
    final stateFilesBefore = root
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('sync-'))
        .length;
    try {
      Webdav.transportFactory = (_) => transport;

      expect(await Webdav.uploadData('https://dav.example;;;/upload'), isFalse);
      expect(transport.closed, isTrue);
      expect(Webdav.lastResult.status, SyncStatus.failed);
      // The identity is durable even though the first remote listing failed;
      // a retry must remain attributable to this device.
      expect(
          root
              .listSync()
              .whereType<File>()
              .where((file) => file.path.contains('sync-'))
              .length,
          greaterThan(stateFilesBefore));
    } finally {
      Webdav.transportFactory = previousFactory;
    }
  });

  test('malformed explicit upload config fails instead of becoming a no-op',
      () async {
    final previousFactory = Webdav.transportFactory;
    var transportCreated = false;
    try {
      Webdav.transportFactory = (_) {
        transportCreated = true;
        return _FakeSyncTransport();
      };

      expect(await Webdav.uploadData('not-a-webdav-config'), isFalse);
      expect(transportCreated, isFalse);
      expect(Webdav.lastResult.status, SyncStatus.failed);
    } finally {
      Webdav.transportFactory = previousFactory;
    }
  });

  test('malformed explicit download config fails instead of skipping sync',
      () async {
    final previousFactory = Webdav.transportFactory;
    var transportCreated = false;
    try {
      Webdav.transportFactory = (_) {
        transportCreated = true;
        return _FakeSyncTransport();
      };

      expect(await Webdav.downloadData('https://dav.example;broken'), isFalse);
      expect(transportCreated, isFalse);
      expect(Webdav.lastResult.status, SyncStatus.failed);
    } finally {
      Webdav.transportFactory = previousFactory;
    }
  });

  test('transport close failure does not replace the sync result', () async {
    final previousFactory = Webdav.transportFactory;
    final transport = _FakeSyncTransport(failClose: true);
    try {
      Webdav.transportFactory = (_) => transport;

      expect(await Webdav.downloadData('https://dav.example;;;close-failure'),
          isTrue);
      expect(Webdav.lastResult.status, SyncStatus.unchanged);
      expect(transport.closed, isTrue);
    } finally {
      Webdav.transportFactory = previousFactory;
    }
  });

  test('stale local parent is rejected before publishing an orphan revision',
      () async {
    final previousFactory = Webdav.transportFactory;
    const config = 'https://dav.example;;;/stale-parent';
    final values = config.split(';');
    final stateKey = sha256
        .convert(utf8.encode('${values[0]};${values[1]};${values[3]}'))
        .toString();
    final stateFile = File('${root.path}/sync-$stateKey.json')
      ..writeAsStringSync(jsonEncode({
        'device': 'device-local',
        'heads': ['missing-parent']
      }));
    final transport = _FakeSyncTransport();
    try {
      Webdav.transportFactory = (_) => transport;

      expect(await Webdav.uploadData(config), isFalse);
      expect(Webdav.lastResult.status, SyncStatus.failed);
      expect(transport.uploads, isEmpty);
      expect(
          await stateFile.readAsString(),
          jsonEncode({
            'device': 'device-local',
            'heads': ['missing-parent']
          }));
    } finally {
      Webdav.transportFactory = previousFactory;
    }
  });

  test('download exposes concurrent remote heads without choosing one',
      () async {
    final previousFactory = Webdav.transportFactory;
    final previousSetting = appdata.settings[45];
    final transport = _FakeSyncTransport(
        pointerValue: const SyncPointer('"head-before"', known: true));
    final first = SyncRevision(
        id: 'head-a', device: 'device-a', parents: const [], sha256: '0' * 64);
    final second = SyncRevision(
        id: 'head-b', device: 'device-b', parents: const [], sha256: '1' * 64);
    transport.names.addAll([
      first.archiveName,
      first.descriptorName,
      second.archiveName,
      second.descriptorName,
    ]);
    transport.text[first.descriptorName] = encodeSyncRevision(first);
    transport.text[second.descriptorName] = encodeSyncRevision(second);
    try {
      appdata.settings[45] = 'https://dav.example;;;/branches';
      Webdav.transportFactory = (_) => transport;

      expect(await Webdav.downloadData(), isFalse);
      expect(Webdav.lastResult.status, SyncStatus.conflict);
      expect(Webdav.lastResult.heads.map((head) => head.id),
          containsAll(<String>[first.id, second.id]));
      expect(transport.downloads, isEmpty);
      expect(transport.closed, isTrue);
      final metric = RuntimeMetrics.snapshot()['sync.download']!;
      expect(metric.failure, 1);
      expect(metric.active, 0);
    } finally {
      appdata.settings[45] = previousSetting;
      Webdav.transportFactory = previousFactory;
    }
  });

  test('stale ETag CAS keeps both client branches observable', () async {
    final previousFactory = Webdav.transportFactory;
    final previousVersion = appdata.settings[46];
    final remote = _SharedSyncRemote(etags: true)
      ..returnStalePointerOnSecondRead = true;
    try {
      Webdav.transportFactory = (_) => _SharedSyncTransport(remote);

      expect(await Webdav.uploadData('https://dav.example;;;etag-client-a'),
          isTrue);
      expect(Webdav.lastResult.status, SyncStatus.success);

      // The second client publishes its immutable descriptor, but its stale
      // pointer cannot replace the first client's head. The graph still
      // exposes both roots instead of silently selecting one by clock time.
      expect(await Webdav.uploadData('https://dav.example;;;etag-client-b'),
          isTrue);
      expect(Webdav.lastResult.status, SyncStatus.conflict);
      expect(remote.archives, hasLength(2));
      expect(remote.casResults, [true, false]);
    } finally {
      appdata.settings[46] = previousVersion;
      Webdav.transportFactory = previousFactory;
    }
  });

  for (final etags in [true, false]) {
    test(
        'remote client publishing after snapshot remains visible '
        '${etags ? 'with' : 'without'} ETag', () async {
      final previousFactory = Webdav.transportFactory;
      final previousVersion = appdata.settings[46];
      final remote = _SharedSyncRemote(etags: etags);
      final externalBytes = utf8.encode('client-b-snapshot');
      final external = SyncRevision(
        id: 'client-b-race',
        device: 'device-b',
        parents: const [],
        sha256: sha256.convert(externalBytes).toString(),
      );
      remote.beforeCompareAndSet = () {
        remote.beforeCompareAndSet = null;
        remote.publishExternalRevision(external, externalBytes);
      };
      try {
        Webdav.transportFactory = (_) => _SharedSyncTransport(remote);
        final config = etags
            ? 'https://dav.example;;;interleaved-etag-a'
            : 'https://dav.example;;;interleaved-no-etag-a';

        expect(await Webdav.uploadData(config), isTrue);
        expect(Webdav.lastResult.status, SyncStatus.conflict);
        final visibleHeads =
            Webdav.lastResult.heads.map((head) => head.id).toSet();
        expect(visibleHeads, hasLength(2));
        expect(visibleHeads, contains(external.id));
        expect(remote.archives, hasLength(2));
        expect(
            remote.metadata.keys
                .where((name) =>
                    name.startsWith('revision-') && name.endsWith('.json'))
                .length,
            2);
        expect(remote.casResults, [!etags]);
        final pointerHeads =
            (jsonDecode(remote.metadata['sync-head.json']!)['heads'] as List)
                .cast<String>();
        expect(pointerHeads, hasLength(1));
        expect(visibleHeads, contains(pointerHeads.single));
      } finally {
        appdata.settings[46] = previousVersion;
        Webdav.transportFactory = previousFactory;
      }
    });
  }

  test('legacy client archive racing a v2 upload remains a visible head',
      () async {
    final previousFactory = Webdav.transportFactory;
    final previousVersion = appdata.settings[46];
    final remote = _SharedSyncRemote(etags: false);
    const legacyVersion = 1700000000;
    remote.beforeCompareAndSet = () {
      remote.beforeCompareAndSet = null;
      remote.publishLegacyArchive(
          legacyVersion, utf8.encode('legacy-client-snapshot'));
    };
    try {
      Webdav.transportFactory = (_) => _SharedSyncTransport(remote);

      expect(
          await Webdav.uploadData(
              'https://dav.example;;;interleaved-legacy-client'),
          isTrue);
      expect(Webdav.lastResult.status, SyncStatus.conflict);
      final visibleHeads =
          Webdav.lastResult.heads.map((head) => head.id).toSet();
      expect(visibleHeads, hasLength(2));
      expect(visibleHeads, contains('legacy-$legacyVersion'));
      expect(remote.archives, hasLength(2));
      expect(remote.archives, contains('$legacyVersion.picadata'));
    } finally {
      appdata.settings[46] = previousVersion;
      Webdav.transportFactory = previousFactory;
    }
  });

  test('without ETag, graph reread still reports concurrent client branches',
      () async {
    final previousFactory = Webdav.transportFactory;
    final previousVersion = appdata.settings[46];
    final remote = _SharedSyncRemote(etags: false);
    try {
      Webdav.transportFactory = (_) => _SharedSyncTransport(remote);

      expect(await Webdav.uploadData('https://dav.example;;;no-etag-client-a'),
          isTrue);
      expect(await Webdav.uploadData('https://dav.example;;;no-etag-client-b'),
          isTrue);
      expect(Webdav.lastResult.status, SyncStatus.conflict);
      expect(remote.archives, hasLength(2));
      expect(remote.casResults, [true, true]);
    } finally {
      appdata.settings[46] = previousVersion;
      Webdav.transportFactory = previousFactory;
    }
  });

  test('state write failure rolls back the persisted settings revision',
      () async {
    final previousFactory = Webdav.transportFactory;
    final previousVersion = appdata.settings[46];
    const config = 'https://dav.example;;;state-write-failure';
    final values = config.split(';');
    final stateKey = sha256
        .convert(utf8.encode('${values[0]};${values[1]};${values[3]}'))
        .toString();
    final statePath = '${root.path}/sync-$stateKey.json';
    final remote = _SharedSyncRemote(etags: false);
    remote.beforeCompareAndSet = () {
      final state = File(statePath);
      if (state.existsSync()) state.deleteSync();
      Directory(statePath).createSync();
    };
    try {
      Webdav.transportFactory = (_) => _SharedSyncTransport(remote);

      expect(await Webdav.uploadData(config), isFalse);
      expect(Webdav.lastResult.status, SyncStatus.failed);
      final persisted =
          jsonDecode(await File('${root.path}/settings').readAsString())
              as List<dynamic>;
      expect(persisted[46], previousVersion);
      expect(remote.archives, hasLength(1));
    } finally {
      Webdav.transportFactory = previousFactory;
      appdata.settings[46] = previousVersion;
      await appdata.updateSettings(false);
    }
  });

  test('upload requested while maintenance is busy waits for its turn',
      () async {
    final previousFactory = Webdav.transportFactory;
    final previousVersion = appdata.settings[46];
    final remote = _SharedSyncRemote(etags: false);
    final entered = Completer<void>();
    final release = Completer<void>();
    try {
      Webdav.transportFactory = (_) => _SharedSyncTransport(remote);
      final maintenance = DataMaintenance.run(() async {
        entered.complete();
        await release.future;
      }, suppressSync: true);
      await entered.future;

      final upload = Webdav.uploadData('https://dav.example;;;busy-upload');
      await Future<void>.delayed(Duration.zero);
      expect(remote.archives, isEmpty);

      release.complete();
      expect(await upload, isTrue);
      await maintenance;
      expect(remote.archives, hasLength(1));
    } finally {
      if (!release.isCompleted) release.complete();
      await DataMaintenance.waitForIdle();
      appdata.settings[46] = previousVersion;
      Webdav.transportFactory = previousFactory;
    }
  });

  test('transport normalizes legacy Windows directory separators', () {
    final transport =
        WebdavSyncTransport(['https://dav.example', '', '', r'\pica\backups']);
    addTearDown(transport.close);

    expect(transport.directory, '/pica/backups/');
  });

  test('unsupported pointer methods fall back to graph-based detection',
      () async {
    await _withHttpServer((request) async {
      request.response.statusCode = request.method == 'GET'
          ? HttpStatus.methodNotAllowed
          : HttpStatus.notImplemented;
      await request.response.close();
    }, (baseUrl) async {
      final transport = WebdavSyncTransport([baseUrl, '', '', '/pica']);
      try {
        final pointer = await transport.pointer();
        expect(pointer.known, isTrue);
        expect(pointer.etag, isNull);
        expect(await transport.compareAndSetPointer(pointer, '{}'), isTrue);
      } finally {
        transport.close();
      }
    });
  });

  test('pointer CAS distinguishes conditional 409 from path conflict',
      () async {
    await _withHttpServer((request) async {
      expect(request.method, 'PUT');
      final ifMatch = request.headers.value('if-match');
      if (ifMatch != null) expect(ifMatch, '"stale"');
      request.response.statusCode = HttpStatus.conflict;
      await request.response.close();
    }, (baseUrl) async {
      final transport = WebdavSyncTransport([baseUrl, '', '', '/pica']);
      try {
        expect(
            await transport.compareAndSetPointer(
                const SyncPointer('"stale"'), '{}'),
            isFalse);
        await expectLater(
          transport.compareAndSetPointer(const SyncPointer(null), '{}'),
          throwsA(isA<StateError>()),
        );
      } finally {
        transport.close();
      }
    });
  });

  test('revision graph rejects an orphan parent', () {
    final child = SyncRevision(
        id: 'child',
        device: 'device-a',
        parents: const ['missing-parent'],
        sha256: '0' * 64);

    expect(() => revisionHeads([child]), throwsA(isA<FormatException>()));
  });

  test('revision graph rejects duplicate parent edges', () {
    final parent = SyncRevision(
        id: 'parent', device: 'device-a', parents: const [], sha256: '0' * 64);
    final child = SyncRevision(
        id: 'child',
        device: 'device-a',
        parents: const ['parent', 'parent'],
        sha256: '1' * 64);

    expect(
        () => revisionHeads([parent, child]), throwsA(isA<FormatException>()));
  });
}
