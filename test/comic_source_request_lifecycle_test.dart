import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/res.dart';

void main() {
  late List<ComicSource> previousSources;

  setUp(() {
    previousSources = List.of(ComicSource.sources);
    ComicSource.sources = [];
  });

  tearDown(() {
    ComicSource.sources = previousSources;
  });

  test('removed source does not relogin after an in-flight request expires',
      () async {
    var loginCalls = 0;
    var requestCalls = 0;
    final request = Completer<Res<bool>>();
    final source = _source('removed_fixture', () async {
      loginCalls++;
      return const Res(true);
    });
    source.data['account'] = ['user', 'password'];
    ComicSource.sources = [source];

    final resultFuture = source.runWithLoginRetry(() {
      requestCalls++;
      return request.future;
    });
    ComicSource.sources = [];
    request.complete(const Res.error('Login expired'));

    final result = await resultFuture;
    expect(result.errorMessage, 'Comic Source Not Found');
    expect(loginCalls, 0);
    expect(requestCalls, 1);
  });

  test('same-key replacement is not used for a stale source retry', () async {
    var oldLoginCalls = 0;
    var replacementLoginCalls = 0;
    var requestCalls = 0;
    final request = Completer<Res<bool>>();
    final oldSource = _source('replace_fixture', () async {
      oldLoginCalls++;
      return const Res(true);
    });
    final replacement = _source('replace_fixture', () async {
      replacementLoginCalls++;
      return const Res(true);
    });
    oldSource.data['account'] = ['old-user', 'password'];
    replacement.data['account'] = ['new-user', 'password'];
    ComicSource.sources = [oldSource];

    final resultFuture = oldSource.runWithLoginRetry(() {
      requestCalls++;
      return request.future;
    });
    ComicSource.sources = [replacement];
    request.complete(const Res.error('Login expired'));

    final result = await resultFuture;
    expect(result.errorMessage, 'Comic Source Not Found');
    expect(oldLoginCalls, 0);
    expect(replacementLoginCalls, 0);
    expect(requestCalls, 1);
  });

  test('replacement during relogin prevents retrying the new source', () async {
    final loginStarted = Completer<void>();
    final finishLogin = Completer<Res<bool>>();
    var requestCalls = 0;
    var replacementLoginCalls = 0;
    final replacement = _source('late_replace_fixture', () async {
      replacementLoginCalls++;
      return const Res(true);
    });
    final source = _source('late_replace_fixture', () {
      loginStarted.complete();
      return finishLogin.future;
    });
    source.data['account'] = ['old-user', 'password'];
    replacement.data['account'] = ['new-user', 'password'];
    ComicSource.sources = [source];

    final resultFuture = source.runWithLoginRetry(() async {
      requestCalls++;
      return const Res.error('Login expired');
    });
    await loginStarted.future;
    ComicSource.sources = [replacement];
    finishLogin.complete(const Res(true));

    final result = await resultFuture;
    expect(result.errorMessage, 'Comic Source Not Found');
    expect(replacementLoginCalls, 0);
    expect(requestCalls, 1);
  });

  test('replacement also discards a successful result from the old source',
      () async {
    final request = Completer<Res<bool>>();
    final source = _source('success_replace_fixture', () async {
      fail('a successful request must not trigger relogin');
    });
    final replacement = _source('success_replace_fixture', () async {
      fail('the replacement source must not be used');
    });
    source.data['account'] = ['user', 'password'];
    ComicSource.sources = [source];

    final resultFuture = source.runWithLoginRetry(() => request.future);
    ComicSource.sources = [replacement];
    request.complete(const Res(true));

    expect((await resultFuture).errorMessage, 'Comic Source Not Found');
  });

  test('favorite-style requests still require login', () async {
    var requestCalls = 0;
    final source = _source('login_required_fixture', () async {
      return const Res(true);
    });
    ComicSource.sources = [source];

    final result = await source.runWithLoginRetry(() async {
      requestCalls++;
      return const Res(true);
    });

    expect(result.errorMessage, 'Not login');
    expect(requestCalls, 0);
  });

  test('comment-style requests can preserve anonymous access', () async {
    var requestCalls = 0;
    final source = _source('anonymous_fixture', () async {
      return const Res(true);
    });
    ComicSource.sources = [source];

    final result = await source.runWithLoginRetry(
      () async {
        requestCalls++;
        return const Res(true);
      },
      requireLogin: false,
    );

    expect(result.success, isTrue);
    expect(requestCalls, 1);
  });

  test('current source retries once after successful relogin', () async {
    var loginCalls = 0;
    var requestCalls = 0;
    final source = _source('retry_fixture', () async {
      loginCalls++;
      return const Res(true);
    });
    source.data['account'] = ['user', 'password'];
    ComicSource.sources = [source];

    final result = await source.runWithLoginRetry(() async {
      requestCalls++;
      return requestCalls == 1
          ? const Res.error('Login expired')
          : const Res(true);
    });

    expect(result.success, isTrue);
    expect(loginCalls, 1);
    expect(requestCalls, 2);
  });
}

ComicSource _source(
  String key,
  Future<Res<bool>> Function() login,
) =>
    ComicSource.named(
      name: key,
      key: key,
      filePath: 'fixture/$key.js',
      account: AccountConfig.named(
        login: (_, __) => login(),
        logout: () {},
      ),
    );
