import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/accounts_page.dart';
import 'package:pica_comic/tools/translations.dart';

ComicSource accountSource(LoginFunction? login) => ComicSource.named(
      name: 'Test account',
      key: 'account-test',
      filePath: 'built-in',
      account: AccountConfig.named(login: login, logout: () {}),
    )..data['account'] = ['user', 'password'];

Future<void> showAccounts(WidgetTester tester, ComicSource source) async {
  ComicSource.sources = [source];
  await tester
      .pumpWidget(const MaterialApp(home: OverlayWidget(AccountsPage())));
  await tester.pumpAndSettle();
}

Future<void> clearAccounts(WidgetTester tester) async {
  hideAllMessages();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
  expect(tester.takeException(), isNull);
}

void main() {
  AppTranslation.translations = const {};
  late List<ComicSource> previousSources;
  setUp(() => previousSources = ComicSource.sources);
  tearDown(() => ComicSource.sources = previousSources);

  for (final asynchronous in [false, true]) {
    testWidgets(
        'relogin recovers from a ${asynchronous ? 'future' : 'sync'} error',
        (tester) async {
      var calls = 0;
      await showAccounts(tester, accountSource((username, password) {
        expect([username, password], ['user', 'password']);
        calls++;
        if (calls > 1) return Future.value(const Res(true));
        if (asynchronous) return Future.error(StateError('login failed'));
        throw StateError('login failed');
      }));

      await tester.tap(find.text('重新登录'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('网络错误'), findsOneWidget);
      await tester.tap(find.text('重新登录'));
      await tester.pump();
      expect(calls, 2);
      expect(find.text('重新登录成功'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await clearAccounts(tester);
    });
  }

  testWidgets(
      'relogin ignores duplicate taps and resets after a rejected result',
      (tester) async {
    final pending = Completer<Res<bool>>();
    var calls = 0;
    await showAccounts(tester, accountSource((_, __) {
      calls++;
      return calls == 1 ? pending.future : Future.value(const Res(true));
    }));
    await tester.tap(find.text('重新登录'));
    await tester.tap(find.text('重新登录'));
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending.complete(const Res.error('Rejected'));
    await tester.pump();
    expect(find.text('Rejected'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('重新登录'));
    await tester.pump();
    expect(calls, 2);
    await clearAccounts(tester);
  });

  for (final throws in [false, true]) {
    testWidgets(
        'late relogin ${throws ? 'error' : 'success'} ignores a new page',
        (tester) async {
      final pending = Completer<Res<bool>>();
      await showAccounts(tester, accountSource((_, __) => pending.future));
      await tester.tap(find.text('重新登录'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());

      final current = Completer<Res<bool>>();
      await showAccounts(tester, accountSource((_, __) => current.future));
      await tester.tap(find.text('重新登录'));
      await tester.pump();
      if (throws) {
        pending.completeError(StateError('old request'));
      } else {
        pending.complete(const Res(true));
      }
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('重新登录成功'), findsNothing);
      expect(find.text('网络错误'), findsNothing);
      expect(tester.takeException(), isNull);

      current.complete(const Res(true));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('重新登录成功'), findsOneWidget);
      await clearAccounts(tester);
    });
  }

  testWidgets(
      'relogin rejects malformed saved credentials without calling login',
      (tester) async {
    var calls = 0;
    final source = accountSource((_, __) async {
      calls++;
      return const Res(true);
    })
      ..data['account'] = ['user'];
    await showAccounts(tester, source);
    await tester.tap(find.text('重新登录'));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('无数据'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await clearAccounts(tester);
  });

  testWidgets('web-only accounts have no relogin action', (tester) async {
    await showAccounts(tester, accountSource(null));
    expect(find.text('重新登录'), findsNothing);
    expect(find.text('退出登录'), findsOneWidget);
    await clearAccounts(tester);
  });
}
