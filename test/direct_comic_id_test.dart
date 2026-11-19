import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/comic_source/built_in/jm.dart' as jm_source;
import 'package:pica_comic/comic_source/built_in/nhentai.dart'
    as nhentai_source;
import 'package:pica_comic/pages/jm/jm_comic_page.dart';
import 'package:pica_comic/pages/nhentai/comic_page.dart';

void main() {
  testWidgets('JM direct-ID builder strips its accepted prefix',
      (tester) async {
    for (final input in ['jm123', '123']) {
      Widget? destination;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          destination = jm_source.jm.comicPageBuilder!(context, input, null);
          return const SizedBox.shrink();
        }),
      ));

      expect((destination as JmComicPage).id, '123');
    }
  });

  testWidgets('NH direct-ID builder strips accepted prefixes', (tester) async {
    for (final input in ['nh123', 'nhentai123', '123']) {
      Widget? destination;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          destination =
              nhentai_source.nhentai.comicPageBuilder!(context, input, null);
          return const SizedBox.shrink();
        }),
      ));

      expect(
          (destination as NhentaiComicPage).url, 'https://nhentai.net/g/123/');
    }
  });
}
