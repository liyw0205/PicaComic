import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/secret_store.dart';
import 'package:pica_comic/network/webdav.dart';
import 'package:pica_comic/network/sync_revision.dart';
import 'package:pica_comic/network/sync_transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnavailableSecretStore implements SecretStore {
  @override
  Future<String?> read(String key) =>
      Future<String?>.error(StateError('secure store unavailable'));

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

class _EmptySyncTransport implements SyncTransport {
  bool closed = false;

  @override
  Future<bool> compareAndSetPointer(SyncPointer previous, String text) async =>
      true;

  @override
  void close() {
    closed = true;
  }

  @override
  Future<void> download(String name, String destination) async {}

  @override
  Future<List<String>> list() async => <String>[];

  @override
  Future<SyncPointer> pointer() async => const SyncPointer(null);

  @override
  Future<void> upload(String source, String name) async {}

  @override
  Future<String> readText(String name) async => '';

  @override
  Future<void> writeText(String name, String text) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('webdav-secret-tests-');
    App.dataPath = root.path;
    App.cachePath = root.path;
  });

  tearDownAll(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('memory secret store supports replacement and deletion', () async {
    final store = MemorySecretStore();
    expect(await store.read('missing'), isNull);
    await store.write('key', 'first');
    await store.write('key', 'second');
    expect(await store.read('key'), 'second');
    await store.delete('key');
    expect(await store.read('key'), isNull);
  });

  test('export redaction removes WebDAV and URL credentials', () {
    final settings = List<String>.filled(91, '');
    settings[45] = 'https://dav.example;alice;secret;/pica';
    settings[8] = 'https://user:pass@example.test/path';
    settings[90] = 'https://example.test/without-credentials';

    final redacted = redactSettingsForExport(settings);

    expect(redacted[45], 'https://dav.example;;;/pica');
    expect(redacted[8], 'https://example.test/path');
    expect(redacted[90], settings[90]);
    expect(settings[45], 'https://dav.example;alice;secret;/pica');
  });

  test('legacy WebDAV credentials migrate without changing endpoint/path',
      () async {
    for (final entity in root.listSync()) {
      entity.deleteSync(recursive: true);
    }
    SharedPreferences.setMockInitialValues({});
    SecretStoreRegistry.configure(MemorySecretStore());
    final previous = appdata.settings[45];
    addTearDown(() {
      appdata.settings[45] = previous;
      SecretStoreRegistry.configure(MemorySecretStore());
    });
    appdata.settings[45] = 'https://dav.example;alice;secret;/pica';

    expect(await Webdav.migrateLegacyConfig(), isTrue);
    expect(appdata.settings[45], 'https://dav.example;;;/pica');
    expect(
        await SecretStoreRegistry.instance.read(webdavUsernameSecret), 'alice');
    expect(await SecretStoreRegistry.instance.read(webdavPasswordSecret),
        'secret');
  });

  test('legacy migration rolls back secrets when settings cannot be written',
      () async {
    for (final entity in root.listSync()) {
      entity.deleteSync(recursive: true);
    }
    final blockedDataPath = Directory('${root.path}/settings');
    await blockedDataPath.create();
    SharedPreferences.setMockInitialValues({});

    final store = MemorySecretStore();
    await store.write(webdavUsernameSecret, 'old-user');
    await store.write(webdavPasswordSecret, 'old-password');
    SecretStoreRegistry.configure(store);
    final previous = appdata.settings[45];
    addTearDown(() {
      appdata.settings[45] = previous;
      SecretStoreRegistry.configure(MemorySecretStore());
    });
    appdata.settings[45] = 'https://dav.example;new-user;new-password;/pica';

    expect(await Webdav.migrateLegacyConfig(), isFalse);
    expect(appdata.settings[45],
        'https://dav.example;new-user;new-password;/pica');
    expect(await store.read(webdavUsernameSecret), 'old-user');
    expect(await store.read(webdavPasswordSecret), 'old-password');
  });

  test('credential read failure never falls back to anonymous WebDAV',
      () async {
    final previousFactory = Webdav.transportFactory;
    final previousSetting = appdata.settings[45];
    var transportCreated = false;
    try {
      appdata.settings[45] = 'https://dav.example;;;/pica';
      SecretStoreRegistry.configure(_UnavailableSecretStore());
      Webdav.transportFactory = (_) {
        transportCreated = true;
        return _EmptySyncTransport();
      };

      expect(await Webdav.downloadData(), isFalse);
      expect(transportCreated, isFalse);
      expect(Webdav.lastResult.status, SyncStatus.failed);
    } finally {
      appdata.settings[45] = previousSetting;
      Webdav.transportFactory = previousFactory;
      SecretStoreRegistry.configure(MemorySecretStore());
    }
  });

  test('explicit anonymous config bypasses secret storage', () async {
    final previousFactory = Webdav.transportFactory;
    final previousSetting = appdata.settings[45];
    final transport = _EmptySyncTransport();
    try {
      appdata.settings[45] = '';
      SecretStoreRegistry.configure(_UnavailableSecretStore());
      Webdav.transportFactory = (_) => transport;

      expect(await Webdav.downloadData('https://dav.example;;;/pica'), isTrue);
      expect(transport.closed, isTrue);
    } finally {
      appdata.settings[45] = previousSetting;
      Webdav.transportFactory = previousFactory;
      SecretStoreRegistry.configure(MemorySecretStore());
    }
  });
}
