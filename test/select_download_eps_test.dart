import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/components/select_download_eps.dart';
import 'package:pica_comic/tools/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppTranslation.translations = const {};

  Finder button(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(FilledButton),
      );

  Future<void> open(WidgetTester tester, List<String> chapters,
      List<int> downloaded, void Function(List<int>) onSubmit) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: SelectDownloadChapter(chapters, onSubmit, downloaded),
      ),
    ));
  }

  testWidgets('download selection requires an available selected chapter',
      (tester) async {
    List<int>? selected;
    await open(tester, ['Chapter 1', 'Chapter 2'], [1],
        (chapters) => selected = chapters);

    expect(tester.widget<FilledButton>(button('下载选择')).onPressed, isNull);

    await tester.tap(find.text('Chapter 1'));
    await tester.pump();
    expect(tester.widget<FilledButton>(button('下载选择')).onPressed, isNotNull);

    await tester.tap(find.text('下载选择'));
    expect(selected, [0]);
  });

  testWidgets('deselecting the last chapter prevents an empty submission',
      (tester) async {
    final submissions = <List<int>>[];
    await open(tester, ['Chapter 1'], [], submissions.add);
    await tester.tap(find.text('Chapter 1'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button('下载选择')).onPressed, isNotNull);

    await tester.tap(find.text('Chapter 1'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button('下载选择')).onPressed, isNull);
    await tester.tap(find.text('下载选择'));
    expect(submissions, isEmpty);
  });

  testWidgets('downloaded chapters cannot be selected again', (tester) async {
    final submissions = <List<int>>[];
    await open(tester, ['Chapter 1', 'Chapter 2'], [1], submissions.add);

    await tester.tap(find.text('Chapter 2'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.download_done), findsOneWidget);
    expect(find.byIcon(Icons.done), findsNothing);
    expect(tester.widget<FilledButton>(button('下载选择')).onPressed, isNull);
    await tester.tap(find.text('下载选择'));
    expect(submissions, isEmpty);
  });

  testWidgets('download all submits only undownloaded chapters in order',
      (tester) async {
    final submissions = <List<int>>[];
    await open(tester, ['Chapter 1', 'Chapter 2', 'Chapter 3', 'Chapter 4'],
        [1, 3], submissions.add);
    await tester.tap(find.text('Chapter 3'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下载全部'));

    expect(submissions, [
      [0, 2]
    ]);
  });

  for (final empty in [false, true]) {
    testWidgets('no downloadable chapters disables both buttons (empty=$empty)',
        (tester) async {
      final submissions = <List<int>>[];
      await open(tester, empty ? [] : ['Chapter 1', 'Chapter 2'],
          empty ? [] : [0, 1], submissions.add);

      expect(tester.widget<FilledButton>(button('下载全部')).onPressed, isNull);
      expect(tester.widget<FilledButton>(button('下载选择')).onPressed, isNull);
      await tester.tap(find.text('下载全部'));
      await tester.tap(find.text('下载选择'));
      expect(submissions, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
