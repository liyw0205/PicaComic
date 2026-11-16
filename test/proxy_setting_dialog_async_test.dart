import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  AppTranslation.translations = const {};

  testWidgets('proxy test aborts when dialog is disposed while loading config',
      (tester) async {
    final config = Completer<AppProxyConfig?>();
    await tester.pumpWidget(MaterialApp(
      home: ProxySettingDialog(configLoader: () => config.future),
    ));

    await tester.tap(find.text('可用测试'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    config.complete(AppProxyConfig(
      scheme: 'http',
      host: '127.0.0.1',
      port: 8080,
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'download folder failure restores the setting after dialog disposal',
      (tester) async {
    final directory =
        await Directory.systemTemp.createTemp('pica-download-dialog-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final oldPath = appdata.settings[22];
    final result = Completer<String>();
    final started = Completer<void>();
    appdata.settings[22] = oldPath;
    addTearDown(() => appdata.settings[22] = oldPath);

    await tester.pumpWidget(MaterialApp(
      home: SetDownloadFolderDialog(
        haveManageFilesPermission: true,
        updatePath: (path, transform) {
          started.complete();
          return result.future;
        },
      ),
    ));
    await tester.enterText(find.byType(TextField), directory.path);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.ensureVisible(find.text('提交'));
    await tester.tap(find.text('提交'));
    await tester.pump(const Duration(milliseconds: 250));
    await started.future;

    await tester.pumpWidget(const SizedBox.shrink());
    result.complete('migration failed');
    await tester.pump();

    expect(appdata.settings[22], oldPath);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download folder success ignores a disposed dialog',
      (tester) async {
    final directory =
        await Directory.systemTemp.createTemp('pica-download-dialog-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final oldPath = appdata.settings[22];
    final result = Completer<String>();
    final started = Completer<void>();
    appdata.settings[22] = oldPath;
    try {
      App.dataPath;
    } catch (_) {
      App.dataPath = directory.path;
    }
    addTearDown(() => appdata.settings[22] = oldPath);

    await tester.pumpWidget(MaterialApp(
      home: SetDownloadFolderDialog(
        haveManageFilesPermission: true,
        updatePath: (path, transform) {
          started.complete();
          return result.future;
        },
      ),
    ));
    await tester.enterText(find.byType(TextField), directory.path);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.ensureVisible(find.text('提交'));
    await tester.tap(find.text('提交'));
    await tester.pump(const Duration(milliseconds: 250));
    await started.future;

    await tester.pumpWidget(const SizedBox.shrink());
    result.complete('ok');
    await tester.pumpAndSettle();

    expect(appdata.settings[22], directory.path);
    expect(tester.takeException(), isNull);
  });
}
