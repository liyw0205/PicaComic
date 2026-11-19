import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _SettingsData extends Appdata {
  int saves = 0;
  bool fail = false;

  Future<void> seed() => super.updateSettings(false);

  @override
  Future<void> updateSettings([bool syncData = true]) {
    saves++;
    if (fail) return Future.error(const FileSystemException('fixture failure'));
    return super.updateSettings(false);
  }
}

class _SettingsNetwork extends JmNetwork {
  _SettingsNetwork() : super.create();

  final domains = ['new-one.example', 'new-two.example', 'new-three.example'];
  Future<Res<dynamic>>? pendingDomains;
  Res<dynamic> version = const Res.error('Version endpoint unavailable');
  int discoveries = 0;
  int versions = 0;
  int logins = 0;
  bool throwDiscovery = false;
  final loginStarted = Completer<void>();

  @override
  Future<Res<dynamic>> getApiDomains() async {
    discoveries++;
    if (throwDiscovery) throw StateError('Discovery unavailable');
    return pendingDomains == null ? Res(domains) : await pendingDomains!;
  }

  @override
  Future<Res<dynamic>> getAppVersionCode() async {
    versions++;
    return version;
  }

  @override
  Future<Res<bool>> loginFromAppdata() async {
    logins++;
    if (!loginStarted.isCompleted) loginStarted.complete();
    return const Res.error('Not logged in');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late Appdata previousData;
  late JmNetwork? previousNetwork;
  late _SettingsData data;
  late _SettingsNetwork network;
  late WidgetTester activeTester;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-jm-settings-');
    App.dataPath = directory.path;
  });

  setUp(() async {
    previousData = appdata;
    previousNetwork = JmNetwork.cache;
    appdata = data = _SettingsData();
    appdata.settings[15] = '0';
    appdata.settings[17] = '1';
    appdata.appSettings.jmApiDomains = ['old-one.example', 'old-two.example'];
    JmNetwork.cache = network = _SettingsNetwork();
    await data.seed();
  });

  tearDown(() async {
    await activeTester.runAsync(() => DataMaintenance.waitForIdle());
    appdata = previousData;
    JmNetwork.cache = previousNetwork;
  });

  tearDownAll(() => directory.delete(recursive: true));

  Future<Route<void>> open(WidgetTester tester) async {
    activeTester = tester;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const Scaffold(body: Text('Home')),
    ));
    final route = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(
        body: SingleChildScrollView(child: JmSettings(false)),
      ),
    );
    App.navigatorKey.currentState!.push(route);
    await tester.pumpAndSettle();
    return route;
  }

  Future<void> confirmUpdate(WidgetTester tester,
      {bool waitForLogin = true}) async {
    await tester.runAsync(() => tester.tap(find.text('更新API域名')));
    await tester.pumpAndSettle();
    expect(find.text('更新成功'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('确认'));
      if (waitForLogin) {
        await network.loginStarted.future.timeout(const Duration(seconds: 3));
      }
      await data.waitForSettingsWrites();
      await DataMaintenance.waitForIdle();
    });
    await tester.pumpAndSettle();
  }

  Future<List<dynamic>> storedSettings(WidgetTester tester) async {
    final value = await tester
        .runAsync(() => File('${directory.path}/settings').readAsString());
    return jsonDecode(value!) as List;
  }

  testWidgets('confirmed domains persist when the version endpoint fails',
      (tester) async {
    await open(tester);
    await confirmUpdate(tester);
    expect(appdata.appSettings.jmApiDomains, network.domains);
    expect((await storedSettings(tester))[85], network.domains.join(','));
    expect(data.saves, greaterThan(0));
    expect(network.versions, 1);
    expect(network.logins, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('confirmed domain changes rebuild the visible API selector',
      (tester) async {
    network.version = const Res('2.0.99');
    network.domains
      ..clear()
      ..add('new-only.example');
    await open(tester);
    await confirmUpdate(tester);
    final selector = tester.widget<Select>(find.descendant(
      of: find.widgetWithText(ListTile, 'API域名'),
      matching: find.byType(Select),
    ));
    expect(selector.values, ['分流1']);
    expect(selector.initialValue, 0);
    final stored = await storedSettings(tester);
    expect(stored[85], 'new-only.example');
    expect(stored[17], '0');
    expect(stored[89], '2.0.99');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('closing settings during discovery ignores the late response',
      (tester) async {
    final pending = Completer<Res<dynamic>>();
    network.pendingDomains = pending.future;
    final route = await open(tester);
    await tester.tap(find.text('更新API域名'));
    await tester.pump();
    App.navigatorKey.currentState!.removeRoute(route);
    await tester.pump();
    pending.complete(Res(network.domains));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('更新成功'), findsNothing);
    expect(data.saves, 0);
    expect(network.versions, 0);
    expect(network.logins, 0);
    expect(appdata.appSettings.jmApiDomains,
        ['old-one.example', 'old-two.example']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelling the confirmation preserves saved domains',
      (tester) async {
    await open(tester);
    await tester.runAsync(() => tester.tap(find.text('更新API域名')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(data.saves, 0);
    expect(
        (await storedSettings(tester))[85], 'old-one.example,old-two.example');
    expect(network.versions, 0);
    expect(network.logins, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'duplicate discovery is ignored and loading cancellation is final',
      (tester) async {
    final pending = Completer<Res<dynamic>>();
    network.pendingDomains = pending.future;
    await open(tester);
    final action = tester
        .widget<ListTile>(find.widgetWithText(ListTile, '更新API域名'))
        .onTap!;
    await tester.runAsync(() async {
      action();
      action();
    });
    await tester.pump();
    expect(network.discoveries, 1);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    pending.complete(Res(network.domains));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(data.saves, 0);
    expect(network.versions, 0);
    expect(network.logins, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final throws in [false, true]) {
    testWidgets(
        'discovery ${throws ? 'exception' : 'error'} offers saved fallback',
        (tester) async {
      network.throwDiscovery = throws;
      network.pendingDomains = Future.value(const Res.error('Offline'));
      await open(tester);
      await tester.runAsync(() => tester.tap(find.text('更新API域名')));
      await tester.pumpAndSettle();
      expect(find.text('更新失败'), findsOneWidget);
      expect(find.textContaining(JmNetwork.builtInApiDomains.last),
          findsOneWidget);
      expect(data.saves, 0);
      await tester.runAsync(() async {
        await tester.tap(find.text('确认'));
        await network.loginStarted.future.timeout(const Duration(seconds: 3));
        await data.waitForSettingsWrites();
        await DataMaintenance.waitForIdle();
      });
      await tester.pumpAndSettle();
      expect(appdata.appSettings.jmApiDomains, JmNetwork.builtInApiDomains);
      expect((await storedSettings(tester))[85],
          JmNetwork.builtInApiDomains.join(','));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('failed persistence restores domains and skips optional requests',
      (tester) async {
    data.fail = true;
    await open(tester);
    await confirmUpdate(tester, waitForLogin: false);
    expect(find.text('保存失败'), findsOneWidget);
    expect(appdata.appSettings.jmApiDomains,
        ['old-one.example', 'old-two.example']);
    expect(appdata.settings[17], '1');
    expect(
        (await storedSettings(tester))[85], 'old-one.example,old-two.example');
    expect(network.versions, 0);
    expect(network.logins, 0);
    await tester.tap(find.text('了解'));
    await tester.pumpAndSettle();
    data.fail = false;
    await confirmUpdate(tester);
    expect(appdata.appSettings.jmApiDomains, network.domains);
    expect((await storedSettings(tester))[85], network.domains.join(','));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
