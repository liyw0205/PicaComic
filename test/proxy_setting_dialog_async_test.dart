import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
