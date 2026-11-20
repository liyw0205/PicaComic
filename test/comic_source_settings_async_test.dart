import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/js_engine.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _SettingsData extends Appdata {
  @override
  Future<void> updateSettings([bool syncData = true]) async {}
}

class _SourceResponse {
  _SourceResponse(this.request);

  final HttpRequest request;
  final ready = Completer<String>();
  final done = Completer<void>();
  int statusCode = HttpStatus.ok;
}

String _script(String url, [String version = '1.0.0']) => '''
class SettingsFixture extends ComicSource {
  name = "Settings fixture"
  key = "settings_fixture"
  version = "$version"
  url = "$url"
  comic = {}
}
''';

Future<void> _pumpAsyncUntil(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 100 && !done(); attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  final previousData = appdata;
  final previousSources = ComicSource.sources;
  final previousProxy = proxyHttpOverrides;
  final previousCookieJar = SingleInstanceCookieJar.instance;
  late Directory directory;
  late HttpServer server;
  late StreamSubscription<HttpRequest> serving;
  late String url;
  late File sourceFile;
  late ComicSource source;
  late WidgetTester activeTester;
  final responses = <_SourceResponse>[];

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('source-settings-');
    App.dataPath = directory.path;
    await Directory('${directory.path}/comic_source').create();
    SingleInstanceCookieJar('${directory.path}/cookies.db');
    await JsEngine().init(throwOnError: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://${server.address.address}:${server.port}/source.js';
    serving = server.listen((request) async {
      final response = _SourceResponse(request);
      responses.add(response);
      try {
        final script = await response.ready.future;
        request.response.statusCode = response.statusCode;
        request.response.headers.contentType = ContentType.text;
        request.response.write(script);
        await request.response.close();
      } on HttpException {
        // Cancellation may close the connection before the fixture replies.
      } finally {
        response.done.complete();
      }
    });
  });

  setUp(() async {
    responses.clear();
    appdata = _SettingsData();
    appdata.settings[82] = '000000';
    appdata.settings[8] = '';
    appdata.settings[91] = '0';
    proxyHttpOverrides = null;
    ComicSource.sources = [];
    JsEngine().runCode('ComicSource.sources = {};');
    sourceFile = File('${directory.path}/comic_source/settings_fixture.js');
    await sourceFile.writeAsString(_script(url));
    source = await ComicSourceParser().parse(_script(url), sourceFile.path);
    ComicSource.sources.add(source);
  });

  tearDown(() async {
    await activeTester.runAsync(() async {
      for (final response in responses) {
        if (!response.ready.isCompleted) response.ready.complete(_script(url));
      }
      await Future.wait(responses.map((response) => response.done.future));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });

  tearDownAll(() async {
    await serving.cancel();
    await server.close(force: true);
    JsEngine().dispose();
    SingleInstanceCookieJar.instance?.dispose();
    SingleInstanceCookieJar.instance = previousCookieJar;
    appdata = previousData;
    ComicSource.sources = previousSources;
    proxyHttpOverrides = previousProxy;
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    activeTester = tester;
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const Scaffold(
        body: SingleChildScrollView(child: ComicSourceSettings()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> startUpdate(WidgetTester tester) async {
    final count = responses.length;
    await tester.runAsync(() => tester.tap(find.byTooltip('Update')));
    await tester.pump();
    await _pumpAsyncUntil(tester, () => responses.length > count);
    expect(responses, hasLength(count + 1));
  }

  testWidgets('source remains available while its update is downloading',
      (tester) async {
    await open(tester);
    await startUpdate(tester);

    expect(ComicSource.find(source.key), same(source));
    expect(await tester.runAsync(sourceFile.readAsString), _script(url));
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling an update immediately preserves the active source',
      (tester) async {
    await open(tester);
    await startUpdate(tester);
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    await tester.pump();

    expect(ComicSource.find(source.key), same(source));
    expect(find.text('Loading'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a cancelled update cannot resurrect a subsequently deleted source',
      (tester) async {
    await open(tester);
    await startUpdate(tester);
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.runAsync(() async {
      for (var attempt = 0;
          attempt < 100 && await sourceFile.exists();
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(await tester.runAsync(sourceFile.exists), isFalse);

    responses.single.ready.complete(_script(url, '2.0.0'));
    await tester.runAsync(() async {
      await responses.single.done.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(ComicSource.find(source.key), isNull);
    expect(await tester.runAsync(sourceFile.exists), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a successful update is persisted and loaded', (tester) async {
    await open(tester);
    await startUpdate(tester);
    responses.single.ready.complete(_script(url, '2.0.0'));
    await _pumpAsyncUntil(
        tester, () => ComicSource.find(source.key)?.version == '2.0.0');

    expect(ComicSource.find(source.key)?.version, '2.0.0');
    expect(
        await tester.runAsync(sourceFile.readAsString), _script(url, '2.0.0'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled request cannot overwrite a later successful update',
      (tester) async {
    await open(tester);
    await startUpdate(tester);
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await startUpdate(tester);
    responses.last.ready.complete(_script(url, '2.0.0'));
    await _pumpAsyncUntil(
        tester, () => ComicSource.find(source.key)?.version == '2.0.0');
    responses.first.ready.complete(_script(url, '9.0.0'));
    await tester.runAsync(() async {
      await responses.first.done.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(ComicSource.find(source.key)?.version, '2.0.0');
    expect(
        await tester.runAsync(sourceFile.readAsString), _script(url, '2.0.0'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate update actions start only one request',
      (tester) async {
    await open(tester);
    final button = tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.update));
    await tester.runAsync(() async {
      button.onPressed!();
      button.onPressed!();
    });
    await _pumpAsyncUntil(tester, () => responses.isNotEmpty);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(responses, hasLength(1));
    expect(ComicSource.find(source.key), same(source));
    await tester.runAsync(() => tester.tap(find.text('Cancel')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement source invalidates a pending update',
      (tester) async {
    await open(tester);
    await startUpdate(tester);
    late ComicSource replacement;
    await tester.runAsync(() async {
      ComicSource.sources.clear();
      await sourceFile.writeAsString(_script(url, '3.0.0'));
      replacement = await ComicSourceParser()
          .parse(_script(url, '3.0.0'), sourceFile.path);
      ComicSource.sources.add(replacement);
      responses.single.ready.complete(_script(url, '2.0.0'));
      await responses.single.done.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(ComicSource.find(source.key), same(replacement));
    expect(
        await tester.runAsync(sourceFile.readAsString), _script(url, '3.0.0'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the loading route discards the pending response',
      (tester) async {
    await open(tester);
    await startUpdate(tester);
    App.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    responses.single.ready.complete(_script(url, '2.0.0'));
    await tester.runAsync(() async {
      await responses.single.done.future;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(ComicSource.find(source.key), same(source));
    expect(await tester.runAsync(sourceFile.readAsString), _script(url));
    expect(tester.takeException(), isNull);
  });

  for (final failure in ['network', 'invalid script', 'changed key']) {
    testWidgets('$failure preserves the committed source and permits retry',
        (tester) async {
      await open(tester);
      await startUpdate(tester);
      responses.single.statusCode =
          failure == 'network' ? HttpStatus.badRequest : HttpStatus.ok;
      final invalid = failure == 'invalid script'
          ? 'invalid source fixture'
          : _script(url, '2.0.0')
              .replaceFirst('settings_fixture', 'different_fixture');
      responses.single.ready.complete(invalid);
      await _pumpAsyncUntil(
          tester, () => find.text('Loading').evaluate().isEmpty);
      await tester.pump(const Duration(seconds: 3));

      expect(ComicSource.find(source.key)?.version, '1.0.0');
      expect(ComicSource.find('different_fixture'), isNull);
      expect(await tester.runAsync(sourceFile.readAsString), _script(url));
      expect(JsEngine().runCode('ComicSource.sources.settings_fixture.version'),
          '1.0.0');
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      await startUpdate(tester);
      responses.last.ready.complete(_script(url, '2.0.0'));
      await _pumpAsyncUntil(
          tester, () => ComicSource.find(source.key)?.version == '2.0.0');

      expect(ComicSource.find(source.key)?.version, '2.0.0');
      expect(await tester.runAsync(sourceFile.readAsString),
          _script(url, '2.0.0'));
      expect(tester.takeException(), isNull);
    });
  }
}
