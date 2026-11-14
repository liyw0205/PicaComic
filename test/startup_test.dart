import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/startup.dart';
import 'package:pica_comic/pages/startup_recovery.dart';

void main() {
  test('core failure stops initialization and retry skips completed stages',
      () async {
    final calls = <String>[];
    var shouldFail = true;
    final startup = StartupCoordinator([
      StartupStep('paths', () async => calls.add('paths')),
      StartupStep('recovery', () async {
        calls.add('recovery');
        if (shouldFail) throw StateError('Incomplete restore');
      }),
      StartupStep('settings', () async => calls.add('settings')),
      StartupStep('database', () async => calls.add('database')),
    ]);
    final failed = await startup.run();
    expect(failed.ready, false);
    expect(failed.failure!.stage, 'recovery');
    expect(calls, ['paths', 'recovery']);
    expect(failed.timings.keys, ['paths', 'recovery']);
    shouldFail = false;
    final retried = await startup.run();
    expect(retried.ready, true);
    expect(calls, ['paths', 'recovery', 'recovery', 'settings', 'database']);
  });

  test('optional failure is observable and does not block core readiness',
      () async {
    var coreRan = false;
    final events = <String>[];
    final startup = StartupCoordinator([
      StartupStep('integration', () async => throw StateError('Unavailable'),
          essential: false),
      StartupStep('database', () async => coreRan = true),
    ], onStepFinished: (stage, elapsed, failure) {
      events.add('$stage:${failure != null}');
    });
    final result = await startup.run();
    expect(result.ready, true);
    expect(coreRan, true);
    expect(result.warnings.single.stage, 'integration');
    expect(events, ['integration:true', 'database:false']);
  });

  test('concurrent retry requests share one attempt', () async {
    final blocker = Completer<void>();
    var calls = 0;
    final startup = StartupCoordinator([
      StartupStep('database', () async {
        calls++;
        await blocker.future;
      }),
    ]);
    final first = startup.run();
    final second = startup.run();
    expect(identical(first, second), true);
    blocker.complete();
    expect((await first).ready, true);
    expect(calls, 1);
  });

  testWidgets('failed startup never builds application and retry can recover',
      (tester) async {
    final pending = Completer<StartupResult>();
    var appBuilds = 0;
    var retryCalls = 0;
    await tester.pumpWidget(StartupGate(
      initialResult: StartupResult(
          failure: StartupFailure(
              'data recovery', StateError('failed'), StackTrace.current)),
      retry: () {
        retryCalls++;
        return pending.future;
      },
      applicationBuilder: () {
        appBuilds++;
        return const MaterialApp(home: Text('Application ready'));
      },
    ));
    expect(appBuilds, 0);
    expect(find.textContaining('data recovery'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('startup-retry')));
    await tester.pump();
    expect(retryCalls, 1);
    expect(appBuilds, 0);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete(const StartupResult());
    await tester.pumpAndSettle();
    expect(appBuilds, 1);
    expect(find.text('Application ready'), findsOneWidget);
  });

  testWidgets('failed retry remains usable on a narrow viewport',
      (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final failure = StartupResult(
        failure: StartupFailure(
            'favorites', StateError('failed'), StackTrace.current));
    await tester.pumpWidget(StartupGate(
      initialResult: failure,
      retry: () async => failure,
      applicationBuilder: () => throw StateError('Must not build'),
    ));
    await tester.tap(find.byKey(const ValueKey('startup-retry')));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
}
