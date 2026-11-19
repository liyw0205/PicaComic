import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/window_frame.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  late List<Completer<bool>> queries;

  setUp(() {
    queries = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'isMaximized');
      final query = Completer<bool>();
      queries.add(query);
      return query.future;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    expect(windowManager.listeners, isEmpty);
  });

  Future<void> open(WidgetTester tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const Scaffold(body: Align(child: WindowButtons())),
    ));
    expect(queries, hasLength(1));
  }

  Future<void> event(WidgetTester tester, String name) async {
    final reply =
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec
          .encodeMethodCall(MethodCall('onEvent', {'eventName': name})),
      null,
    );
    channel.codec.decodeEnvelope(reply!);
    await tester.pump();
  }

  Future<void> resolve(
      WidgetTester tester, Completer<bool> query, bool value) async {
    query.complete(value);
    await tester.pumpAndSettle();
  }

  for (final maximized in [false, true]) {
    testWidgets('initial query displays maximized=$maximized', (tester) async {
      await open(tester);
      await resolve(tester, queries.single, maximized);

      expect(
          find.byType(RestoreIcon), maximized ? findsOneWidget : findsNothing);
      expect(
          find.byType(MaximizeIcon), maximized ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a late startup query does not overwrite an unmaximize event',
      (tester) async {
    await open(tester);
    await event(tester, 'maximize');
    expect(find.byType(RestoreIcon), findsOneWidget);
    await event(tester, 'unmaximize');
    expect(find.byType(MaximizeIcon), findsOneWidget);

    await resolve(tester, queries.single, true);

    expect(find.byType(MaximizeIcon), findsOneWidget);
    expect(find.byType(RestoreIcon), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final maximized in [false, true]) {
    testWidgets('leaving full screen resyncs maximized=$maximized',
        (tester) async {
      await open(tester);
      await resolve(tester, queries.single, !maximized);
      await event(tester, 'enter-full-screen');
      await event(tester, 'leave-full-screen');
      expect(queries, hasLength(2));
      await resolve(tester, queries.last, maximized);

      expect(
          find.byType(RestoreIcon), maximized ? findsOneWidget : findsNothing);
      expect(
          find.byType(MaximizeIcon), maximized ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'a late full screen query does not overwrite a newer window event',
      (tester) async {
    await open(tester);
    await resolve(tester, queries.single, false);
    await event(tester, 'leave-full-screen');
    expect(queries, hasLength(2));
    await event(tester, 'maximize');
    await resolve(tester, queries.last, false);

    expect(find.byType(RestoreIcon), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('window state query failure keeps the last known state',
      (tester) async {
    await open(tester);
    await resolve(tester, queries.single, true);
    await event(tester, 'leave-full-screen');
    expect(queries, hasLength(2));
    queries.last.completeError(PlatformException(code: 'unavailable'));
    await tester.pump();

    expect(find.byType(RestoreIcon), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only the latest full screen query can publish its result',
      (tester) async {
    await open(tester);
    await resolve(tester, queries.single, false);
    for (var i = 0; i < 2; i++) {
      await event(tester, 'enter-full-screen');
      await event(tester, 'leave-full-screen');
    }
    expect(queries, hasLength(3));
    await resolve(tester, queries.last, false);
    await resolve(tester, queries[1], true);

    expect(find.byType(MaximizeIcon), findsOneWidget);
    expect(find.byType(RestoreIcon), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a query completing after disposal does not update the widget',
      (tester) async {
    await open(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await resolve(tester, queries.single, true);

    expect(tester.takeException(), isNull);
  });
}
