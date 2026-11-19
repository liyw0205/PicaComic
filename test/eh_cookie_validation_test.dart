import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/built_in/ehentai.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late SingleInstanceCookieJar? previousCookieJar;
  late String? previousName;
  late Object? previousAccount;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('eh-cookie-validation-');
    previousCookieJar = SingleInstanceCookieJar.instance;
    previousName = ehentai.data['name'] as String?;
    previousAccount = ehentai.data['account'];
    ehentai.data['account'] = null;
    SingleInstanceCookieJar.instance = null;
    SingleInstanceCookieJar('${directory.path}/cookies.sqlite');
  });

  tearDown(() async {
    ehentai.data['name'] = previousName;
    ehentai.data['account'] = previousAccount;
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = previousCookieJar;
    await directory.delete(recursive: true);
  });

  test('HTTP 200 login page is not accepted as a login', () async {
    final network = EhNetwork.create(
      cachedNetworkFactory: () => _FixtureCachedNetwork(
        200,
        '<html><form action="index.php?act=Login"></form></html>',
      ),
    );

    expect(await network.validateCookies(), isFalse);
    expect(ehentai.data['name'], previousName);
  });

  test('authenticated user marker supplies the actual account name', () async {
    final network = EhNetwork.create(
      cachedNetworkFactory: () => _FixtureCachedNetwork(
        200,
        '<div id="userlinks"><p class="home"><b>'
        '<a href="/user/123">fixture-user</a>'
        '</b></p></div>',
      ),
    );

    expect(await network.validateCookies(), isTrue);
    expect(ehentai.data['name'], 'fixture-user');
  });

  test('non-200 response is rejected even when it contains a user marker',
      () async {
    final network = EhNetwork.create(
      cachedNetworkFactory: () => _FixtureCachedNetwork(
        503,
        '<div id="userlinks"><p class="home"><b>'
        '<a href="/user/123">fixture-user</a>'
        '</b></p></div>',
      ),
    );

    expect(await network.validateCookies(), isFalse);
    expect(ehentai.data['name'], previousName);
  });
}

class _FixtureCachedNetwork extends CachedNetwork {
  _FixtureCachedNetwork(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  Future<CachedNetworkRes<String>> get(
    String url,
    BaseOptions options, {
    CacheExpiredTime expiredTime = CacheExpiredTime.short,
    CookieJarSql? cookieJar,
    bool log = true,
    bool http2 = false,
    CancelToken? cancelToken,
  }) async {
    expect(url, 'https://e-hentai.org/home.php');
    expect(options.followRedirects, isFalse);
    return CachedNetworkRes(body, statusCode, url);
  }
}
