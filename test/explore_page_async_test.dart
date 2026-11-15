import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/explore_page.dart';

void main() {
  testWidgets('refresh ignores stale multipart results', (tester) async {
    final requests = <Completer<Res<List<ExplorePagePart>>>>[];
    var calls = 0;
    final source = ComicSource.named(
      name: 'test',
      key: 'explore-async-test',
      filePath: 'test',
      explorePages: [
        ExplorePageData.named(
          title: 'Async Explore',
          type: ExplorePageType.singlePageWithMultiPart,
          loadMultiPart: () {
            calls++;
            final request = Completer<Res<List<ExplorePagePart>>>();
            requests.add(request);
            return request.future;
          },
        ),
      ],
    );
    final oldSources = ComicSource.sources;
    final oldPages = List<String>.from(appdata.appSettings.explorePages);
    ComicSource.sources = [source];
    appdata.appSettings.explorePages = ['Async Explore'];
    addTearDown(() {
      ComicSource.sources = oldSources;
      appdata.appSettings.explorePages = oldPages;
    });

    await tester.pumpWidget(const MaterialApp(home: ExplorePage()));
    await tester.pump();
    expect(calls, 1);

    await tester.tap(find.byKey(const Key('FAB')));
    await tester.pump();
    expect(calls, 2);

    requests[0].complete(const Res([
      ExplorePagePart('stale', [], null),
    ]));
    await tester.pump();
    expect(find.text('stale'), findsNothing);

    requests[1].complete(const Res([
      ExplorePagePart('fresh', [], null),
    ]));
    await tester.pump();
    expect(find.text('fresh'), findsOneWidget);
  });
}
