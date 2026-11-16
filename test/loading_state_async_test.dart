import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/res.dart';

class _LoadingHarness extends StatefulWidget {
  const _LoadingHarness(this.loader);

  final Future<Res<int>> Function() loader;

  @override
  State<_LoadingHarness> createState() => _LoadingHarnessState();
}

class _LoadingHarnessState extends LoadingState<_LoadingHarness, int> {
  @override
  Future<Res<int>> loadData() => widget.loader();

  @override
  Widget buildContent(BuildContext context, int data) => Text('$data');
}

void main() {
  test('close is safe before the navigator callback is installed', () async {
    final controller = LoadingDialogController();
    var calls = 0;

    controller.close();
    controller.closeDialog = () => calls++;
    await Future<void>.delayed(Duration.zero);

    expect(controller.closed, isTrue);
    expect(calls, 1);
  });

  test('close invokes the navigator callback only once', () {
    final controller = LoadingDialogController();
    var calls = 0;
    controller.closeDialog = () => calls++;

    controller.close();
    controller.close();

    expect(calls, 1);
  });

  testWidgets('late loading result is ignored after disposal', (tester) async {
    final response = Completer<Res<int>>();
    await tester.pumpWidget(MaterialApp(
      home: _LoadingHarness(() => response.future),
    ));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    response.complete(const Res(1));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
