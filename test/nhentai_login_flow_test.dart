import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/nhentai_network/login_flow.dart';

void main() {
  test('CSRF, refresh-only and empty values are not a login', () {
    for (final values in [
      {'csrftoken': 'dummy'},
      {'session_preference': 'dummy'},
      {'refresh_token': 'dummy'},
      {'access_token': ''},
      {'access_token': 'null'},
      {'access_token': 'undefined'},
      {'access_token': ' null '},
    ]) {
      expect(hasNhentaiSession(values), isFalse);
    }
    expect(hasNhentaiSession({'access_token': 'dummy'}), isTrue);
    expect(hasNhentaiSession({'sessionid': 'dummy'}), isTrue);
  });

  test('account marker sync preserves other source data', () {
    final data = <String, dynamic>{
      'account': null,
      'tagStack': ['artist:fixture'],
      'customPreference': 'kept',
    };

    expect(syncNhentaiAccountMarker(data, true), isTrue);
    expect(data, {
      'account': 'ok',
      'tagStack': ['artist:fixture'],
      'customPreference': 'kept',
    });
    expect(syncNhentaiAccountMarker(data, true), isFalse);
    expect(syncNhentaiAccountMarker(data, false), isTrue);
    expect(data['account'], isNull);
    expect(data['tagStack'], ['artist:fixture']);
    expect(data['customPreference'], 'kept');
  });

  test('account marker sync preserves persisted source settings', () async {
    final root = await Directory.systemTemp.createTemp('nhentai-source-');
    addTearDown(() => root.delete(recursive: true));
    App.dataPath = root.path;
    final sourceDirectory = Directory('${root.path}/comic_source');
    await sourceDirectory.create(recursive: true);
    await File('${sourceDirectory.path}/nhentai.data').writeAsString(
      jsonEncode({
        'account': null,
        'tagStack': ['artist:fixture'],
        'customPreference': 'kept',
      }),
    );
    final source = ComicSource.named(
      name: 'nhentai',
      key: 'nhentai',
      filePath: 'built-in',
    );

    await source.loadData();
    expect(syncNhentaiAccountMarker(source.data, true), isTrue);
    await source.saveData();

    expect(
      jsonDecode(
          await File('${sourceDirectory.path}/nhentai.data').readAsString()),
      {
        'account': 'ok',
        'tagStack': ['artist:fixture'],
        'customPreference': 'kept',
      },
    );
  });

  test('native and double-encoded JS strings decode safely', () {
    final payload = jsonEncode({'access_token': 'dummy', 'sessionid': null});
    expect(
        decodeNhentaiStorage(jsonEncode(payload)), {'access_token': 'dummy'});
    expect(decodeNhentaiStorage(payload), {'access_token': 'dummy'});
    expect(decodeNhentaiStorage('bad json'), isEmpty);
  });

  test('storage credentials are persisted with clearance and refresh',
      () async {
    final flow = NhentaiLoginFlow();
    Map<String, String>? saved;
    var closes = 0;
    await flow.probe(
      readCookies: () async => {'cf_clearance': 'dummy-clearance'},
      readStorage: () async => {
        'access_token': 'dummy-access',
        'refresh_token': 'dummy-refresh',
        'irrelevant': 'ignored',
      },
      readUserAgent: () async => 'test-agent',
      persist: (cookies, ua) {
        saved = cookies;
        expect(ua, 'test-agent');
      },
      close: () => closes++,
    );
    expect(await flow.result, isTrue);
    expect(saved, {
      'cf_clearance': 'dummy-clearance',
      'access_token': 'dummy-access',
      'refresh_token': 'dummy-refresh',
    });
    expect(closes, 1);
  });

  test('cancelling an async probe cannot persist or close', () async {
    final flow = NhentaiLoginFlow();
    final cookies = Completer<Map<String, String>>();
    final probe = flow.probe(
      readCookies: () => cookies.future,
      readStorage: () async => {},
      readUserAgent: () async => 'test-agent',
      persist: (_, __) => fail('persisted after cancellation'),
      close: () => fail('closed after cancellation'),
    );
    flow.cancel();
    expect(await flow.result, isFalse);
    cookies.complete({'access_token': 'dummy'});
    await probe;
  });

  test('concurrent probes save and close only once', () async {
    final flow = NhentaiLoginFlow();
    final cookies = Completer<Map<String, String>>();
    var saves = 0;
    var closes = 0;
    Future<void> probe() => flow.probe(
          readCookies: () => cookies.future,
          readStorage: () async => {'access_token': 'stale-storage'},
          readUserAgent: () async => 'test-agent',
          persist: (values, _) {
            saves++;
            expect(values['access_token'], 'native');
          },
          close: () => closes++,
        );
    final first = probe();
    await probe();
    cookies.complete({'access_token': 'native'});
    await first;
    await probe();
    flow.cancel();
    expect(await flow.result, isTrue);
    expect(saves, 1);
    expect(closes, 1);
  });

  test('a transient read failure allows the next probe to succeed', () async {
    final flow = NhentaiLoginFlow();
    await expectLater(
      flow.probe(
        readCookies: () async => throw StateError('not ready'),
        readStorage: () async => {},
        readUserAgent: () async => null,
        persist: (_, __) {},
        close: () {},
      ),
      throwsStateError,
    );
    await flow.probe(
      readCookies: () async => {'sessionid': 'dummy'},
      readStorage: () async => {},
      readUserAgent: () async => null,
      persist: (_, __) {},
      close: () {},
    );
    expect(await flow.result, isTrue);
  });

  test('native session succeeds when browser storage is unavailable', () async {
    final flow = NhentaiLoginFlow();
    var persisted = false;
    await flow.probe(
      readCookies: () async => {'sessionid': 'native-session'},
      readStorage: () async => throw StateError('storage unavailable'),
      readUserAgent: () async => null,
      persist: (_, __) => persisted = true,
      close: () {},
    );
    expect(persisted, isTrue);
    expect(await flow.result, isTrue);
  });
}
