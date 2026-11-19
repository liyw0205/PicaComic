import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/pages/settings/settings_page.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  AppTranslation.translations = const {};

  for (final label in ['可用测试', '质量测试']) {
    testWidgets('$label aborts when dialog is disposed while loading config',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final config = Completer<AppProxyConfig?>();
      var loads = 0;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: ProxySettingDialog(configLoader: () {
          loads++;
          return config.future;
        }),
      ));

      await tester.tap(find.text(label), warnIfMissed: true);
      await tester.pump();
      expect(loads, 1);
      expect(config.isCompleted, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(find.byType(ProxySettingDialog), findsNothing);

      config.complete(AppProxyConfig(
        scheme: 'http',
        host: '127.0.0.1',
        port: 8080,
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(loads, 1);
    });
  }
}
