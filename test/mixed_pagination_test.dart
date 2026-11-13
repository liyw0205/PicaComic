import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/res.dart';

class _PagingHarness extends StatefulWidget {
  const _PagingHarness({
    required this.totalPages,
    required this.requests,
    this.throwOnPageOnce,
  });

  final int? totalPages;
  final List<int> requests;
  final int? throwOnPageOnce;

  @override
  State<_PagingHarness> createState() => _PagingHarnessState();
}

class _PagingHarnessState extends MultiPageLoadingState<_PagingHarness, int> {
  @override
  Future<Res<List<int>>> loadData(int page) async {
    widget.requests.add(page);
    if (widget.throwOnPageOnce == page &&
        widget.requests
                .where((requestedPage) => requestedPage == page)
                .length ==
            1) {
      throw StateError('network failure');
    }
    if (widget.totalPages == null && page == 2) {
      return const Res([]);
    }
    return Res([page], subData: widget.totalPages);
  }

  @override
  Widget buildContent(BuildContext context, List<int> data) => Column(
        children: [
          Text(haveNextPage.toString(), key: const Key('has-next-page')),
          if (haveNextPage)
            TextButton(
              onPressed: nextPage,
              child: const Text('next'),
            ),
        ],
      );
}

void main() {
  testWidgets('unknown page count loads until the empty terminal page',
      (tester) async {
    final requests = <int>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: _PagingHarness(totalPages: null, requests: requests),
    ));
    await tester.pumpAndSettle();

    expect(requests, [1]);
    expect(find.text('true'), findsOneWidget);
    await tester.tap(find.text('next'));
    await tester.pumpAndSettle();

    expect(requests, [1, 2]);
    expect(find.text('false'), findsOneWidget);
    expect(find.text('next'), findsNothing);
  });

  testWidgets('known page count stops after its final non-empty page',
      (tester) async {
    final requests = <int>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: _PagingHarness(totalPages: 2, requests: requests),
    ));
    await tester.pumpAndSettle();

    expect(find.text('true'), findsOneWidget);
    await tester.tap(find.text('next'));
    await tester.pumpAndSettle();

    expect(requests, [1, 2]);
    expect(find.text('false'), findsOneWidget);
    expect(find.text('next'), findsNothing);
  });

  testWidgets('an initial exception can be retried', (tester) async {
    final requests = <int>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: _PagingHarness(
        totalPages: 1,
        requests: requests,
        throwOnPageOnce: 1,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Network Error'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(requests, [1, 1]);
  });

  testWidgets('a later-page exception releases loading for retry',
      (tester) async {
    final requests = <int>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: _PagingHarness(
        totalPages: 3,
        requests: requests,
        throwOnPageOnce: 2,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('next'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('next'), findsOneWidget);

    await tester.tap(find.text('next'));
    await tester.pumpAndSettle();
    expect(requests, [1, 2, 2]);
  });
}
