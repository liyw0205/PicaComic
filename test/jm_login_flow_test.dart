import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/built_in/jm.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/network/jm_network/domain_selection.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pointycastle/export.dart';

class _LoginNetwork extends JmNetwork {
  _LoginNetwork() : super.create();

  int? selected = 0;
  bool throwSelection = false;
  int posts = 0;
  int images = 0;
  int checkins = 0;
  bool? imageRelogin;
  bool? checkinRelogin;
  Future<Res<dynamic>>? pendingPost;
  final imageStarted = Completer<void>();
  final imageRelease = Completer<void>();
  final checkinFinished = Completer<void>();
  Res<dynamic> response = const Res.error('Incorrect credentials');

  @override
  Future<int?> selectDomain() async {
    if (throwSelection) throw StateError('selection failed');
    return selected;
  }

  @override
  Future<Res<dynamic>> post(String url, String data) async {
    posts++;
    return pendingPost == null ? response : await pendingPost!;
  }

  @override
  Future<void> updateImgUrl(int index, {bool allowReLogin = true}) async {
    images++;
    imageRelogin = allowReLogin;
    imageStarted.complete();
    await imageRelease.future;
  }

  @override
  Future<Res<bool>> dailyChk({bool allowReLogin = true}) async {
    checkins++;
    checkinRelogin = allowReLogin;
    checkinFinished.complete();
    return const Res.error('Optional check-in unavailable');
  }
}

class _ResponseNetwork extends JmNetwork {
  _ResponseNetwork(this.payload) : super.create();

  final Map<String, dynamic> payload;
  final requests = <Uri>[];

  @override
  Future<Res<dynamic>> get(String url,
      {Map<String, String>? header,
      CacheExpiredTime expiredTime = CacheExpiredTime.long,
      bool isRetry = false}) async {
    requests.add(Uri.parse(url));
    return Res(payload);
  }
}

class _ImageNetwork extends JmNetwork {
  _ImageNetwork() : super.create();

  final requests = <Uri>[];
  final responses = <Completer<Res<dynamic>>>[];

  @override
  Future<Res<dynamic>> get(String url,
      {Map<String, String>? header,
      CacheExpiredTime expiredTime = CacheExpiredTime.long,
      bool isRetry = false}) {
    requests.add(Uri.parse(url));
    final response = Completer<Res<dynamic>>();
    responses.add(response);
    return response.future;
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  bool closed = false;
  CancelToken? cancelToken;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    cancelToken = options.cancelToken;
    return await Future.any([
      Future.sync(() => respond(options)),
      if (cancelFuture != null)
        cancelFuture.then<ResponseBody>((_) => throw DioException(
            requestOptions: options, type: DioExceptionType.cancel)),
    ]);
  }

  @override
  void close({bool force = false}) => closed = true;
}

String _encryptResponse(Map<String, dynamic> body, String time) {
  final bytes = utf8.encode(jsonEncode(body));
  final padding = 16 - bytes.length % 16;
  final input =
      Uint8List.fromList([...bytes, ...List.filled(padding, padding)]);
  final key = utf8.encode(
      md5.convert(utf8.encode('$time${JmNetwork.kJmSecret}')).toString());
  final cipher = ECBBlockCipher(AESEngine())
    ..init(true, KeyParameter(Uint8List.fromList(key)));
  final encrypted = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += 16) {
    cipher.processBlock(input, offset, encrypted, offset);
  }
  return base64Encode(encrypted);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<String> settings;
  late List<String> apiDomains;
  late Map<String, dynamic> data;
  late List<ComicSource> sources;
  late JmNetwork previousNetwork;
  late HttpOverrides? previousHttpOverrides;
  late ProxyHttpOverrides? previousProxy;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-jm-login-');
    App.dataPath = root.path;
  });
  tearDownAll(() async {
    await root.delete(recursive: true);
  });
  setUp(() {
    settings = List.from(appdata.settings);
    apiDomains = List.from(appdata.appSettings.jmApiDomains);
    data = Map.from(jm.data);
    sources = List.from(ComicSource.sources);
    previousNetwork = jmNetwork;
    previousHttpOverrides = HttpOverrides.current;
    previousProxy = proxyHttpOverrides;
    appdata.settings[8] = '';
    appdata.settings[15] = '1';
    appdata.settings[17] = '0';
    appdata.settings[58] = '0';
    appdata.settings[88] = '0';
    appdata.settings[91] = '0';
    appdata.appSettings.jmApiDomains = ['one.example', 'two.example'];
    jm.data.clear();
  });
  tearDown(() {
    appdata.settings = settings;
    appdata.appSettings.jmApiDomains = apiDomains;
    jm.data = data;
    ComicSource.sources = sources;
    jmNetwork = previousNetwork;
    HttpOverrides.global = previousHttpOverrides;
    proxyHttpOverrides = previousProxy;
  });

  test('empty and fully failed line races finish with no winner', () async {
    expect(await selectJmDomain([], (_) async => true), isNull);
    expect(await selectJmDomain(['a', 'b'], (_) async => false), isNull);
    expect(await selectJmDomain(['a', 'b'], (_) => throw StateError('offline')),
        isNull);
  });

  testWidgets('stalled probes time out and ignore late success',
      (tester) async {
    final stalled = Completer<bool>();
    var done = false;
    int? result;
    selectJmDomain(['a'], (_) => stalled.future,
            timeout: const Duration(seconds: 2))
        .then((value) {
      done = true;
      result = value;
    });
    await tester.pump(const Duration(seconds: 2));
    expect(done, isTrue);
    expect(result, isNull);
    stalled.complete(true);
    await tester.pump();
    expect(result, isNull);
  });

  test('first available line wins even when another probe fails later',
      () async {
    final slow = Completer<bool>();
    expect(
        await selectJmDomain(['slow', 'fast'],
            (host) => host == 'slow' ? slow.future : Future.value(true)),
        1);
    slow.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
  });

  test('line selection rejects proxy HTML and closes outstanding probes',
      () async {
    final adapter = _Adapter((options) {
      expect(options.data, '&');
      expect(options.followRedirects, isFalse);
      expect(options.sendTimeout, isNotNull);
      expect(options.receiveTimeout, isNotNull);
      return ResponseBody.fromString(
          options.uri.host == 'one.example'
              ? '<html>Proxy</html>'
              : '{"errorMsg":"Missing username"}',
          401);
    });
    final network = JmNetwork.create(
        dioFactory: (options) => Dio(options)..httpClientAdapter = adapter);
    expect(await network.selectDomain(), 1);
    expect(adapter.closed, isTrue);
    expect(adapter.cancelToken?.isCancelled, isTrue);
  });

  test('comic details accept numeric counters from JSON', () async {
    final network = _ResponseNetwork({
      'name': 'Fixture comic',
      'author': ['Fixture author'],
      'description': 'Description',
      'likes': 12,
      'total_views': 345,
      'comment_total': 6,
      'series': [],
      'tags': ['fixture'],
      'works': [],
      'actors': [],
      'related_list': [],
      'liked': false,
      'is_favorite': false,
    });

    final result = await network.getComicInfo('42');
    expect(result.success, isTrue);
    expect(result.data.likes, 12);
    expect(result.data.views, 345);
    expect(result.data.comments, 6);
  });

  test('newer image stream selection wins over a late response', () async {
    final network = _ImageNetwork();
    appdata.settings[37] = '0';
    appdata.settings[86] = 'original.example';
    final first = network.updateImgUrl(1);
    appdata.settings[37] = '1';
    final second = network.updateImgUrl(2);
    expect(network.requests.map((uri) => uri.queryParameters['app_img_shunt']),
        ['1', '2']);

    network.responses[1].complete(const Res({'img_host': 'new.example'}));
    await second;
    await appdata.waitForSettingsWrites();
    expect(appdata.settings[86], 'new.example');
    network.responses[0].complete(const Res({'img_host': 'old.example'}));
    await first;
    await appdata.waitForSettingsWrites();
    expect(appdata.settings[86], 'new.example');
    final stored =
        jsonDecode(await File('${root.path}/settings').readAsString()) as List;
    expect(stored[37], '1');
    expect(stored[86], 'new.example');
  });

  test('logout invalidates an unfinished image stream update', () async {
    final network = _ImageNetwork();
    appdata.settings[37] = '0';
    appdata.settings[86] = 'original.example';
    final pending = network.updateImgUrl(1);
    await network.logout();
    network.responses.single.complete(const Res({'img_host': 'late.example'}));
    await pending;
    await appdata.waitForSettingsWrites();
    expect(appdata.settings[86], 'original.example');
  });

  test('changing the selected stream invalidates an unfinished update',
      () async {
    final network = _ImageNetwork();
    appdata.settings[37] = '0';
    appdata.settings[86] = 'original.example';
    final pending = network.updateImgUrl(1);
    appdata.settings[37] = '1';
    network.responses.single.complete(const Res({'img_host': 'late.example'}));
    await pending;
    expect(appdata.settings[86], 'original.example');
  });

  test('replacing settings invalidates an unfinished image stream update',
      () async {
    final network = _ImageNetwork();
    final original = appdata;
    original.settings[37] = '0';
    final pending = network.updateImgUrl(1);
    try {
      appdata = Appdata();
      appdata.settings[37] = '0';
      appdata.settings[86] = 'imported.example';
      network.responses.single
          .complete(const Res({'img_host': 'late.example'}));
      await pending;
      expect(appdata.settings[86], 'imported.example');
    } finally {
      appdata = original;
    }
  });

  test('failed image stream retry cannot revive an older response', () async {
    final network = _ImageNetwork();
    appdata.settings[37] = '0';
    appdata.settings[86] = 'original.example';
    final first = network.updateImgUrl(1);
    final second = network.updateImgUrl(1);
    network.responses[1].complete(const Res.error('Offline'));
    await second;
    network.responses[0].complete(const Res({'img_host': 'stale.example'}));
    await first;
    expect(appdata.settings[86], 'original.example');

    final retry = network.updateImgUrl(1);
    network.responses[2].complete(const Res({'img_host': 'retry.example'}));
    await retry;
    expect(appdata.settings[86], 'retry.example');
    final stored =
        jsonDecode(await File('${root.path}/settings').readAsString()) as List;
    expect(stored[86], 'retry.example');
  });

  Map<String, dynamic> listPayload(Object? total, {bool empty = false}) {
    final comics = empty
        ? <Map<String, dynamic>>[]
        : [
            for (final id in ['42', '43'])
              {
                'id': id,
                'author': 'Author',
                'name': 'Comic $id',
                'category': <String, dynamic>{},
                'category_sub': <String, dynamic>{},
              }
          ];
    return {'total': total, 'content': comics, 'list': comics};
  }

  Future<Map<String, Res<dynamic>>> loadLists(_ResponseNetwork network) async =>
      {
        'promote': await network.getPromoteList('promote'),
        'search': await network.searchNew('query', 2, ComicsOrder.latest),
        'category':
            await network.getCategoryComics('category', ComicsOrder.update, 3),
        'favorites': await network.getFolderComicsPage('folder', 2),
      };

  for (final total in <Object>['23', 23, 23.0]) {
    test('JM lists accept ${total.runtimeType} total without losing pagination',
        () async {
      final network = _ResponseNetwork(listPayload(total));
      final results = await loadLists(network);
      expect(results.map((key, value) => MapEntry(key, value.success)), {
        'promote': true,
        'search': true,
        'category': true,
        'favorites': true,
      });
      final promoted = results['promote']!.data;
      expect(promoted.total, 23);
      expect(promoted.loaded, 2);
      expect(promoted.page, 1);
      expect(promoted.comics.map((comic) => comic.id), ['42', '43']);
      for (final endpoint in ['search', 'category', 'favorites']) {
        expect(results[endpoint]!.subData, 12, reason: endpoint);
        expect((results[endpoint]!.data as List).map((comic) => comic.id),
            ['42', '43'],
            reason: endpoint);
      }
      expect(network.requests.map((uri) => uri.path), [
        '/promote_list',
        '/search',
        '/categories/filter',
        '/favorite',
      ]);
      expect(network.requests[1].queryParameters['page'], '2');
      expect(network.requests[2].queryParameters['page'], '3');
      expect(network.requests.last.queryParameters['folder_id'], 'folder');
    });
  }

  for (final total in <Object>[0, '0']) {
    test(
        'JM empty lists retain their page conventions with ${total.runtimeType} total',
        () async {
      final results =
          await loadLists(_ResponseNetwork(listPayload(total, empty: true)));
      expect(results.values.every((result) => result.success), isTrue);
      expect(results['promote']!.data.total, 0);
      expect(results['promote']!.data.loaded, 0);
      expect(results['search']!.subData, 0);
      expect(results['favorites']!.subData, 0);
      expect(results['category']!.subData, 1);
    });
  }

  for (final total in [null, 'invalid']) {
    test('JM malformed total=$total remains a parsing error', () async {
      final results = await loadLists(_ResponseNetwork(listPayload(total)));
      expect(results.map((key, value) => MapEntry(key, value.error)), {
        'promote': true,
        'search': true,
        'category': true,
        'favorites': true,
      });
    });
  }

  test('JM non-integer, negative, and non-numeric totals remain errors',
      () async {
    for (final total in <Object>[-1, 23.5, double.nan, double.infinity, true]) {
      final results = await loadLists(_ResponseNetwork(listPayload(total)));
      expect(results.values.every((result) => result.error), isTrue,
          reason: 'total=$total');
    }
  });

  test('unavailable lines never receive credentials', () async {
    final network = _LoginNetwork()..selected = null;
    expect((await network.login('sample', 'dummy')).error, isTrue);
    expect(network.posts, 0);
    expect(network.images, 0);
    expect(network.checkins, 0);
  });

  test('selection exceptions release the login lock', () async {
    final network = _LoginNetwork()..throwSelection = true;
    expect((await network.login('sample', 'dummy')).error, isTrue);
    network.throwSelection = false;
    await network.login('sample', 'dummy');
    expect(network.posts, 1);
  });

  test('failed login skips optional requests and releases the lock', () async {
    final network = _LoginNetwork();
    appdata.settings[88] = '1';
    expect((await network.login('sample', 'dummy')).error, isTrue);
    expect((await network.login('sample', 'dummy')).error, isTrue);
    expect(network.posts, 2);
    expect(network.images, 0);
    expect(network.checkins, 0);
  });

  test('authentication finishes before optional work without re-entering login',
      () async {
    final network = _LoginNetwork()
      ..response = const Res({'username': 'sample', 'uid': '42'});
    appdata.settings[88] = '1';
    try {
      expect((await network.login('sample', 'dummy')).success, isTrue);
      await network.imageStarted.future.timeout(const Duration(seconds: 5));
      expect(network.images, 1);
      expect(network.imageRelogin, isFalse);
      expect(network.checkins, 0);
    } finally {
      network.imageRelease.complete();
    }
    await network.checkinFinished.future.timeout(const Duration(seconds: 5));
    expect(network.checkinRelogin, isFalse);
  });

  test('parallel login cannot send a second set of credentials', () async {
    final pending = Completer<Res<dynamic>>();
    final network = _LoginNetwork()..pendingPost = pending.future;
    final first = network.login('one', 'dummy');
    await Future<void>.delayed(Duration.zero);
    expect((await network.login('two', 'dummy')).error, isTrue);
    expect(network.posts, 1);
    pending.complete(const Res.error('Offline'));
    expect((await first).error, isTrue);
  });

  test('malformed success does not create an account', () async {
    final network = _LoginNetwork()
      ..response = const Res({'message': 'unexpected'});
    expect((await network.login('sample', 'dummy')).error, isTrue);
    expect(jm.data['name'], isNull);
    expect(network.images, 0);
  });

  test('logout rejects a late login response and its cookies', () async {
    final pending = Completer<Res<dynamic>>();
    final network = _LoginNetwork()..pendingPost = pending.future;
    final result = network.login('sample', 'dummy');
    await Future<void>.delayed(Duration.zero);
    await network.logout();
    await network.cookieJar.saveFromResponse(
        Uri.parse('https://one.example/'), [Cookie('AVS', 'late-session')]);
    pending.complete(const Res({'username': 'sample', 'uid': '42'}));
    expect((await result).error, isTrue);
    expect(jm.data['name'], isNull);
    expect(network.images, 0);
    expect(
        await network.cookieJar
            .loadForRequest(Uri.parse('https://one.example/')),
        isEmpty);
  });

  test('failed credentials cannot overwrite the stored account', () async {
    jm.data['account'] = ['existing', 'stored-dummy'];
    jmNetwork = _LoginNetwork();
    ComicSource.sources = [jm];
    expect((await jm.account!.login!('new', 'wrong-dummy')).error, isTrue);
    expect(jm.data['account'], ['existing', 'stored-dummy']);
  });

  for (final inPayload in [true, false]) {
    test('login preserves AVS from ${inPayload ? 'payload' : 'envelope'}',
        () async {
      final adapter = _Adapter((options) {
        final time = (options.headers['tokenparam'] as String).split(',').first;
        return ResponseBody.fromString(
            jsonEncode({
              'data': _encryptResponse({
                'username': 'sample',
                'uid': '42',
                if (inPayload) 's': 'synthetic-session',
              }, time),
              if (!inPayload) 's': 'synthetic-session',
            }),
            200);
      });
      final network = JmNetwork.create(
          dioFactory: (options) => Dio(options)..httpClientAdapter = adapter);
      final result = await network.post(
          'https://one.example/login', 'username=sample&password=dummy');
      expect(result.success, isTrue);
      final cookies = await network.cookieJar
          .loadForRequest(Uri.parse('https://one.example/favorite'));
      expect(cookies.singleWhere((cookie) => cookie.name == 'AVS').value,
          'synthetic-session');
      expect(adapter.closed, isTrue);
    });
  }

  test('server rejection returns the error without a session', () async {
    final adapter = _Adapter((_) =>
        ResponseBody.fromString('{"errorMsg":"Incorrect credentials"}', 401));
    final network = JmNetwork.create(
        dioFactory: (options) => Dio(options)..httpClientAdapter = adapter);
    final result = await network.post(
        'https://one.example/login', 'username=sample&password=dummy');
    expect(result.errorMessage, 'Incorrect credentials');
    expect(
        await network.cookieJar
            .loadForRequest(Uri.parse('https://one.example/')),
        isEmpty);
    expect(adapter.closed, isTrue);
  });

  testWidgets('stalled login is cancelled and its client is closed',
      (tester) async {
    final stalled = Completer<ResponseBody>();
    final adapter = _Adapter((_) => stalled.future);
    final network = JmNetwork.create(
        dioFactory: (options) => Dio(options)..httpClientAdapter = adapter);
    Res<dynamic>? result;
    network
        .post('https://one.example/login', 'username=sample&password=dummy')
        .then((value) => result = value);
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    expect(result?.errorMessage, contains('超时'));
    expect(adapter.cancelToken?.isCancelled, isTrue);
    expect(adapter.closed, isTrue);
    stalled.complete(ResponseBody.fromString('late response', 200));
    await tester.pump();
  });
}
