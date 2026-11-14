import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/init.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/tools/legacy_data_migration.dart';
import 'package:sqlite3/open.dart';

class _ReadOnlyCookieJar extends CookieJarSql {
  _ReadOnlyCookieJar(super.path);

  @override
  void saveCookies(Iterable<Cookie> cookies, {String? defaultDomain}) {
    throw const FileSystemException('Read-only destination');
  }
}

void main() {
  late Directory root;
  late CookieJarSql destination;

  setUpAll(() {
    final prefix = Platform.environment['PREFIX'];
    if (Platform.isAndroid && prefix != null) {
      open.overrideFor(OperatingSystem.android,
          () => DynamicLibrary.open('$prefix/lib/libsqlite3.so'));
    }
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('legacy-cookie-test-');
    destination = CookieJarSql('${root.path}/cookies.db');
  });

  tearDown(() async {
    destination.dispose();
    await root.delete(recursive: true);
  });

  Future<Directory> fixture(String relative,
      {bool nested = true, bool corruptIndex = false}) async {
    final directory = Directory('${root.path}/$relative');
    final storage = nested ? Directory('${directory.path}/ie0_ps1') : directory;
    await storage.create(recursive: true);
    await File('${storage.path}/.index')
        .writeAsString(corruptIndex ? '{broken' : jsonEncode(['example.test']));
    await File('${storage.path}/example.test').writeAsString(jsonEncode({
      '/': {
        'root': 'root=host-only; HttpOnly;_crt=1700000000',
      },
      '/private': {
        'nested':
            'nested=scoped; Path=/private; Secure; HttpOnly; Expires=Wed, 01 Jan 2031 00:00:00 GMT;_crt=1700000000',
      },
    }));
    await File('${storage.path}/.domains').writeAsString(jsonEncode({
      'example.test': {
        '/gallery': {
          'shared':
              'shared=domain; Domain=.example.test; Path=/gallery; Secure;_crt=1700000000',
        },
      },
    }));
    return directory;
  }

  test('v4 migration preserves host-only scope and every cookie path',
      () async {
    await fixture('comic_source/cookies');
    expect(
        await migrateLegacyCookies(root.path, destination: destination), true);
    expect(
        destination
            .loadForRequest(Uri.parse('https://example.test/private'))
            .map((cookie) => cookie.name),
        containsAll(['root', 'nested']));
    expect(destination.loadForRequest(Uri.parse('https://sub.example.test/')),
        isEmpty);
    final cookie = destination
        .loadForRequest(Uri.parse('https://example.test/private'))
        .singleWhere((cookie) => cookie.name == 'nested');
    expect(cookie.secure, true);
    expect(cookie.httpOnly, true);
    expect(cookie.expires?.toUtc(), DateTime.utc(2031));
    expect(
        destination
            .loadForRequest(Uri.parse('https://sub.example.test/gallery'))
            .map((cookie) => cookie.name),
        ['shared']);
    expect(
        destination
            .loadForRequest(Uri.parse('http://example.test/private'))
            .map((cookie) => cookie.name),
        ['root']);
  });

  test('old direct layout is fully read and retained as a retry backup',
      () async {
    final source = await fixture('cookies', nested: false);
    expect(
        await migrateLegacyCookies(root.path, destination: destination), true);
    expect(
        destination
            .loadForRequest(Uri.parse('https://example.test/private'))
            .map((cookie) => cookie.name),
        containsAll(['root', 'nested']));
    expect(await Directory('${source.path}.legacy-v1-backup').exists(), true);
    expect(
        await migrateLegacyCookies(root.path, destination: destination), true);
    expect(destination.loadForRequest(Uri.parse('https://sub.example.test/')),
        isEmpty);
  });

  test('corrupt metadata is unchanged and no source is deleted', () async {
    final source = await fixture('cookies', corruptIndex: true);
    final index = File('${source.path}/ie0_ps1/.index');
    expect(
        await migrateLegacyCookies(root.path, destination: destination), false);
    expect(await index.readAsString(), '{broken');
    expect(destination.loadForRequest(Uri.parse('https://example.test/')),
        isEmpty);
  });

  test('incomplete index and missing host file retain every source', () async {
    final source = await fixture('cookies');
    final index = File('${source.path}/ie0_ps1/.index');
    await index.writeAsString(jsonEncode(['example.test', 'missing.test']));
    expect(
        await migrateLegacyCookies(root.path, destination: destination), false);
    expect(await index.readAsString(), contains('missing.test'));
    expect(await source.exists(), true);
    expect(destination.loadForRequest(Uri.parse('https://example.test/')),
        isEmpty);
  });

  test('destination failure retains the complete source', () async {
    final source = await fixture('eh_cookies');
    final readOnly = _ReadOnlyCookieJar('${root.path}/read-only.db');
    addTearDown(readOnly.dispose);
    expect(await migrateLegacyCookies(root.path, destination: readOnly), false);
    expect(await source.exists(), true);
    expect(await File('${source.path}/ie0_ps1/.index').exists(), true);
  });

  test('legitimate domain-only index needs no host file', () async {
    final source = await fixture('cookies');
    await File('${source.path}/ie0_ps1/example.test').delete();
    expect(
        await migrateLegacyCookies(root.path, destination: destination), true);
    expect(
        destination
            .loadForRequest(Uri.parse('https://sub.example.test/gallery'))
            .map((cookie) => cookie.name),
        ['shared']);
  });

  test('persisted max-age uses original creation time', () async {
    final source = await fixture('cookies');
    await File('${source.path}/ie0_ps1/example.test').writeAsString(jsonEncode({
      '/login': {
        'session': 'session=value; Max-Age=3600;_crt=1893456000',
      },
    }));
    expect(
        await migrateLegacyCookies(root.path, destination: destination), true);
    final cookies =
        destination.loadForRequest(Uri.parse('https://example.test/login'));
    expect(cookies.single.name, 'session');
    expect(cookies.single.expires?.toUtc(), DateTime.utc(2030, 1, 1, 1));
    expect(
        destination.loadForRequest(Uri.parse('https://sub.example.test/login')),
        isEmpty);
  });

  test('account destination and marker verify before source is removed',
      () async {
    final file = File('${root.path}/comic_source/jm.data');
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode({'setting': 'keep'}));
    var removed = false;
    final saved = await migrateLegacyAccount(
      dataPath: root.path,
      sourceKey: 'jmName',
      destinationKey: 'jm',
      sourceValues: const {'jmName': 'demo', 'jmPwd': 'password'},
      values: const {
        'account': ['demo', 'password'],
        'name': 'demo'
      },
      removeSource: () async {
        final actual = jsonDecode(await file.readAsString());
        expect(actual['account'], ['demo', 'password']);
        expect(
            await File(
                    '${root.path}/legacy_migration_v1/accounts/jmName.completed.json')
                .exists(),
            true);
        removed = true;
        return true;
      },
    );
    expect(removed, true);
    expect(saved['setting'], 'keep');
    final backup = jsonDecode(
        await File('${root.path}/legacy_migration_v1/accounts/jmName.json')
            .readAsString());
    expect(backup['sourceValues']['jmPwd'], 'password');
    expect(backup['destinationBefore'], {'setting': 'keep'});
  });

  test('account write failure keeps source and retry backup', () async {
    await Directory('${root.path}/comic_source/jm.data')
        .create(recursive: true);
    var removed = false;
    await expectLater(
        migrateLegacyAccount(
          dataPath: root.path,
          sourceKey: 'jmName',
          destinationKey: 'jm',
          sourceValues: const {'jmName': 'demo', 'jmPwd': 'password'},
          values: const {
            'account': ['demo', 'password']
          },
          removeSource: () async {
            removed = true;
            return true;
          },
        ),
        throwsA(isA<FileSystemException>()));
    expect(removed, false);
    expect(
        await File('${root.path}/legacy_migration_v1/accounts/jmName.json')
            .exists(),
        true);
    expect(
        await File(
                '${root.path}/legacy_migration_v1/accounts/jmName.completed.json')
            .exists(),
        false);
  });

  test('retry after preference failure preserves a later account update',
      () async {
    var shouldRemove = false;
    Future<Map<String, dynamic>> migrate() => migrateLegacyAccount(
          dataPath: root.path,
          sourceKey: 'jmName',
          destinationKey: 'jm',
          sourceValues: const {'jmName': 'demo', 'jmPwd': 'password'},
          values: const {
            'account': ['demo', 'password']
          },
          removeSource: () async => shouldRemove,
        );
    await expectLater(migrate(), throwsStateError);
    final file = File('${root.path}/comic_source/jm.data');
    await file.writeAsString(jsonEncode({
      'account': ['new', 'updated']
    }));
    shouldRemove = true;
    expect((await migrate())['account'], ['new', 'updated']);
    expect(
        (await Directory('${root.path}/legacy_migration_v1/accounts')
                .list()
                .toList())
            .length,
        2);
  });
}
