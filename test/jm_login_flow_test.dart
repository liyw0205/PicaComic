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
