import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/app_shortcuts.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/cache_manager.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
import 'package:pica_comic/tools/translations.dart';

class _DelayedSettings extends Appdata {
  var release = Completer<void>();
  Future<void>? pending;
  int saves = 0;
  bool fail = false;

  Future<void> seed() => super.updateSettings(false);

  @override
  Future<void> writeData([bool sync = true]) => updateSettings(false);

  @override
  Future<void> updateSettings([bool syncData = true]) {
    saves++;
    return pending = _persist();
  }

  Future<void> _persist() async {
    await release.future;
    if (fail) throw const FileSystemException('fixture failure');
    await super.updateSettings(false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};
  late Directory directory;
  late Appdata previousData;
  late _DelayedSettings data;
  late CacheManager cache;
  late WidgetTester activeTester;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pica-cache-limit-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    cache = CacheManager();
    await cache.findCache('initialize');
  });

  setUp(() async {
    previousData = appdata;
    appdata = data = _DelayedSettings();
    appdata.appSettings.cacheLimit = 500;
    cache.setLimitSize(500);
    await data.seed();
  });

  tearDown(() async {
    await activeTester.runAsync(() async {
      if (!data.release.isCompleted) data.release.complete();
      try {
        await data.pending;
      } catch (_) {}
      await DataMaintenance.waitForIdle();
    });
    appdata = previousData;
  });

  tearDownAll(() async {
    await cache.clear();
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    activeTester = tester;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.navigatorKey,
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      builder: (_, child) => AppShortcuts(child: child!),
      home: const Scaffold(
        body: TextButton(onPressed: setCacheLimit, child: Text('Open')),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.runAsync(() => tester.tap(find.text('确认')));
    await tester.pump();
  }

  Future<void> finishSave(WidgetTester tester) async {
    await tester.runAsync(() async {
      data.release.complete();
      await data.pending;
      await DataMaintenance.waitForIdle();
    });
    await tester.pumpAndSettle();
  }

  Future<int> storedLimit(WidgetTester tester) async {
    final settings = await tester
        .runAsync(() => File('${directory.path}/settings').readAsString());
    return int.parse((jsonDecode(settings!) as List)[35] as String);
  }

  testWidgets('invalid input never silently saves a default limit',
      (tester) async {
    await open(tester);
    for (final input in ['', 'abc', '15', '-1', '16.5']) {
      await tester.enterText(find.byType(TextField), input);
      await confirm(tester);
      expect(find.text('设置缓存限制'), findsOneWidget, reason: input);
      expect(data.saves, 0, reason: input);
      expect(appdata.appSettings.cacheLimit, 500, reason: input);
      expect(cache.limitSize, 500 * 1024 * 1024, reason: input);
      expect(await storedLimit(tester), 500, reason: input);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final keyboard in [false, true]) {
    testWidgets('${keyboard ? 'keyboard' : 'button'} saves the minimum once',
        (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '16');
      final submitAgain = keyboard
          ? () => tester
              .widget<TextField>(find.byType(TextField))
              .onSubmitted!('16')
          : tester.widget<Button>(find.byType(Button)).onPressed;
      if (keyboard) {
        await tester.runAsync(
            () => tester.testTextInput.receiveAction(TextInputAction.done));
        await tester.pump();
      } else {
        await confirm(tester);
      }
      expect(data.saves, 1);
      expect(find.text('设置缓存限制'), findsOneWidget);
      expect(cache.limitSize, 500 * 1024 * 1024);
      expect(await storedLimit(tester), 500);
      await tester.runAsync(() async => submitAgain());
      await tester.pump();
      expect(data.saves, 1);

      await finishSave(tester);
      expect(find.text('设置缓存限制'), findsNothing);
      expect(appdata.appSettings.cacheLimit, 16);
      expect(cache.limitSize, 16 * 1024 * 1024);
      expect(await storedLimit(tester), 16);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed settings write preserves the input and permits retry',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '96');
    await confirm(tester);
    expect(find.text('设置缓存限制'), findsOneWidget);
    data.fail = true;
    await tester.runAsync(() async {
      data.release.complete();
      try {
        await data.pending;
      } catch (_) {}
      data.pending = null;
    });
    await tester.pumpAndSettle();
    expect(find.text('保存失败'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '96');
    expect(appdata.appSettings.cacheLimit, 500);
    expect(cache.limitSize, 500 * 1024 * 1024);
    expect(await storedLimit(tester), 500);

    data.release = Completer<void>();
    data.fail = false;
    await confirm(tester);
    expect(data.saves, 2);
    await finishSave(tester);
    expect(find.text('设置缓存限制'), findsNothing);
    expect(cache.limitSize, 96 * 1024 * 1024);
    expect(await storedLimit(tester), 96);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending save blocks dismissal and only closes its own route',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '64');
    await confirm(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('设置缓存限制'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('设置缓存限制'), findsOneWidget);

    showDialog<void>(
      context: App.navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('New dialog')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await finishSave(tester);
    expect(find.text('New dialog'), findsOneWidget);
    expect(find.text('设置缓存限制'), findsNothing);
    expect(cache.limitSize, 64 * 1024 * 1024);
    expect(await storedLimit(tester), 64);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('forced disposal ignores the late save UI result',
      (tester) async {
    await open(tester);
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    await tester.enterText(find.byType(TextField), '80');
    await confirm(tester);
    expect(data.saves, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(() => controller.addListener(() {}), throwsFlutterError);
    await finishSave(tester);
    expect(cache.limitSize, 80 * 1024 * 1024);
    expect(await storedLimit(tester), 80);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing an unsaved dialog disposes input without writing',
      (tester) async {
    await open(tester);
    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    await tester.enterText(find.byType(TextField), '32');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('设置缓存限制'), findsNothing);
    expect(data.saves, 0);
    expect(appdata.appSettings.cacheLimit, 500);
    expect(cache.limitSize, 500 * 1024 * 1024);
    expect(await storedLimit(tester), 500);
    expect(() => controller.addListener(() {}), throwsFlutterError);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save after forced disposal restores the previous limit',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '32');
    await confirm(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    data.fail = true;
    await tester.runAsync(() async {
      data.release.complete();
      try {
        await data.pending;
      } catch (_) {}
      data.pending = null;
    });
    await tester.pump();
    expect(appdata.appSettings.cacheLimit, 500);
    expect(cache.limitSize, 500 * 1024 * 1024);
    expect(await storedLimit(tester), 500);
    expect(tester.takeException(), isNull);
  });
}
