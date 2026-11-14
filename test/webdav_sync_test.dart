import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/secret_store.dart';
import 'package:pica_comic/network/sync_revision.dart';
import 'package:pica_comic/network/sync_transport.dart';
import 'package:pica_comic/network/webdav.dart';

class _FakeSyncTransport implements SyncTransport {
  _FakeSyncTransport({
    this.failList = false,
    this.failDownloads = false,
    this.pointerValue = const SyncPointer(null),
  });

  final bool failList;
  final bool failDownloads;
  final SyncPointer pointerValue;
  final List<String> names = <String>[];
  final Map<String, String> text = <String, String>{};
  final List<String> downloads = <String>[];
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
  Future<void> upload(String source, String name) async {}

  @override
  Future<String> readText(String name) async => text[name]!;

  @override
  Future<void> writeText(String name, String value) async {
    text[name] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-webdav-sync-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    SecretStoreRegistry.configure(MemorySecretStore());
  });

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
    } finally {
      appdata.settings[45] = previousSetting;
      Webdav.transportFactory = previousFactory;
    }
  });

  test('transport normalizes legacy Windows directory separators', () {
    final transport =
        WebdavSyncTransport(['https://dav.example', '', '', r'\pica\backups']);
    addTearDown(transport.close);

    expect(transport.directory, '/pica/backups/');
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
