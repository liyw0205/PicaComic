import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:pica_comic/network/nhentai_network/tag_stack.dart';

void main() {
  group('nhentai tag queries', () {
    test('quotes, escapes, excludes and normalizes tag targets', () {
      const query = NhentaiTagQuery(terms: [
        NhentaiTagTerm('tag', 'Big  Breasts'),
        NhentaiTagTerm('tag', 'yaoi', exclude: true),
        NhentaiTagTerm('parody', r'a "b" \ c'),
        NhentaiTagTerm('language', 'Chinese'),
      ]);
      expect(query.toQuery(),
          r'tag:"big breasts" -tag:"yaoi" parody:"a \"b\" \\ c" language:chinese');
      expect(NhentaiTagQuery.parse(query.toQuery()).terms, query.terms);
      expect(
          const NhentaiTagTerm(' TAG ', 'Big  Breasts').sameTarget(
              const NhentaiTagTerm('tag', 'big breasts', exclude: true)),
          isTrue);
    });

    test('parses namespaced terms and preserves free text and filters', () {
      final query = NhentaiTagQuery.parse(
          '"exact title" TAG:"big breasts" -artist:someone pages:>20 -foo language:chinese');
      expect(query.terms, const [
        NhentaiTagTerm('tag', 'big breasts'),
        NhentaiTagTerm('artist', 'someone', exclude: true),
        NhentaiTagTerm('language', 'chinese'),
      ]);
      expect(query.text, '"exact title" pages:>20 -foo');
      expect(NhentaiTagQuery.parse(query.toQuery()).toQuery(), query.toQuery());
    });

    test('malformed quoting and empty terms stay text', () {
      for (final input in [
        'tag:""',
        'tag:',
        'tag:"open',
        'tag:"a"suffix',
        'tag:a"b"',
        r'tag:"escaped closing\"',
        'female:glasses',
        '-',
      ]) {
        final query = NhentaiTagQuery.parse(input);
        expect(query.terms, isEmpty, reason: input);
        expect(query.text, input);
      }
    });

    test('later duplicate wins in place and namespaces remain distinct', () {
      final query =
          NhentaiTagQuery.parse('tag:"Glasses" artist:glasses -tag:"glasses"');
      expect(query.terms, const [
        NhentaiTagTerm('tag', 'glasses', exclude: true),
        NhentaiTagTerm('artist', 'glasses'),
      ]);
      expect(query.remove(const NhentaiTagTerm('TAG', 'Glasses')).terms,
          const [NhentaiTagTerm('artist', 'glasses')]);
      expect(
          query.find(const NhentaiTagTerm('tag', 'glasses'))!.exclude, isTrue);
    });

    test('maps detail fields without treating page metadata as tags', () {
      expect(nhentaiNamespaceOfField('Tags'), 'tag');
      expect(nhentaiNamespaceOfField('Character'), 'character');
      expect(nhentaiNamespaceOfField('Characters'), 'character');
      expect(nhentaiNamespaceOfField('Parodies'), 'parody');
      expect(nhentaiNamespaceOfField('Languages'), 'language');
      expect(nhentaiNamespaceOfField('Pages'), isNull);
      expect(NhentaiTagQuery.empty.isEmpty, isTrue);
    });
  });

  group('nhentai tag stacks', () {
    const chinese = NhentaiTagTerm('language', 'chinese');
    const glasses = NhentaiTagTerm('tag', 'glasses');

    test('language flags and exclusions do not replace the default language',
        () {
      for (final flag in [
        'translated',
        'rewrite',
        'speechless',
        'text cleaned'
      ]) {
        final query = 'language:"$flag" -language:japanese';
        expect(withNhentaiSearchLanguage(query, 1), '$query language:chinese');
      }
      expect(withNhentaiSearchLanguage('language:english tag:glasses', 1),
          'language:english tag:glasses');
      expect(withNhentaiSearchLanguage('12345', 1), '12345');
      expect(withNhentaiSearchLanguage('tag:glasses', 0), 'tag:glasses');
      expect(withNhentaiSearchLanguage('tag:glasses', 9), 'tag:glasses');
      expect(nhentaiTermsFromKeyword('title tag:glasses'), isNull);
      expect(nhentaiTermsFromKeyword('tag:glasses')!.single, glasses);
    });

    test('starts and extends a stack without mutating its base', () {
      final first = nhentaiStackAdd(const [], chinese);
      final next = nhentaiStackAdd(first.terms, glasses);
      expect(next.outcome, NhentaiStackOutcome.added);
      expect(next.terms, const [chinese, glasses]);
      expect(first.terms, const [chinese]);
      final duplicate =
          nhentaiStackAdd(next.terms, const NhentaiTagTerm('TAG', ' Glasses '));
      expect(duplicate.outcome, NhentaiStackOutcome.duplicate);
      expect(duplicate.terms, same(next.terms));
    });

    test('replaces only positive languages and preserves flags', () {
      const flags = [
        NhentaiTagTerm('language', 'translated'),
        NhentaiTagTerm('language', 'rewrite'),
        NhentaiTagTerm('language', 'text  cleaned'),
      ];
      final result = nhentaiStackAdd(const [chinese, ...flags],
          const NhentaiTagTerm('language', 'english'));
      expect(result.terms,
          const [...flags, NhentaiTagTerm('language', 'english')]);
      const excluded = NhentaiTagTerm('language', 'japanese', exclude: true);
      expect(nhentaiStackAdd(const [chinese], excluded).terms,
          const [chinese, excluded]);
      expect(
          nhentaiStackAdd(const [chinese, excluded],
                  const NhentaiTagTerm('language', 'english'))
              .terms,
          const [excluded, NhentaiTagTerm('language', 'english')]);
    });

    test('limits stacks to five and allows a language replacement at limit',
        () {
      final full = [
        chinese,
        for (var i = 0; i < nhentaiTagStackLimit - 1; i++)
          NhentaiTagTerm('tag', 't$i'),
      ];
      final overflow = nhentaiStackAdd(full, glasses);
      expect(overflow.outcome, NhentaiStackOutcome.limit);
      expect(overflow.terms, same(full));
      final replacement =
          nhentaiStackAdd(full, const NhentaiTagTerm('language', 'english'));
      expect(replacement.outcome, NhentaiStackOutcome.added);
      expect(replacement.terms, hasLength(nhentaiTagStackLimit));
    });

    test('uses classic routes only for lossless positive single tags', () {
      expect(nhentaiStackParam(const [chinese]), '/language/chinese');
      expect(nhentaiStackParam(const [NhentaiTagTerm('tag', 'Big  Breasts')]),
          '/tag/big-breasts');
      expect(nhentaiTermsFromParam('/tag/full-color'),
          const [NhentaiTagTerm('tag', 'full color')]);
      for (final term in const [
        NhentaiTagTerm('tag', 'x-ray'),
        NhentaiTagTerm('tag', 'guro', exclude: true),
        NhentaiTagTerm('artist', 'a/b'),
        NhentaiTagTerm('artist', r'a "b" \ c'),
        NhentaiTagTerm('artist', '100%'),
        NhentaiTagTerm('artist', '\u4e2d\u6587'),
      ]) {
        final param = nhentaiStackParam([term]);
        expect(param, startsWith('/combo/'));
        expect(param.split('/'), hasLength(3));
        expect(nhentaiTermsFromParam(param), [term]);
      }
    });

    test('combo routes round trip and reject partial or invalid queries', () {
      const terms = [chinese, glasses, NhentaiTagTerm('artist', 'a/b')];
      expect(nhentaiTermsFromParam(nhentaiStackParam(terms)), terms);
      for (final param in [
        null,
        '/search/x',
        '/tag/',
        'tag/x',
        '/combo/%E0%A4%A',
        '/combo/foo',
        '/combo/${Uri.encodeComponent('tag:glasses free text')}',
        '/combo/${Uri.encodeComponent('tag:"open')}',
        '/combo/${Uri.encodeComponent(List.generate(6, (i) => 'tag:t$i').join(' '))}',
      ]) {
        expect(nhentaiTermsFromParam(param), isNull, reason: '$param');
      }
      expect(() => nhentaiStackParam(const []), throwsArgumentError);
    });
  });

  group('nhentai tag settings', () {
    final originalProvider = NhentaiTagSettings.dataProvider;
    final originalSaver = NhentaiTagSettings.saver;
    late Map<String, dynamic> data;
    late int saves;

    setUp(() {
      data = {};
      saves = 0;
      NhentaiTagSettings.dataProvider = () => data;
      NhentaiTagSettings.saver = () async => saves++;
    });

    tearDown(() {
      NhentaiTagSettings.dataProvider = originalProvider;
      NhentaiTagSettings.saver = originalSaver;
    });

    test('defaults stacking on and persists changes with notification',
        () async {
      expect(NhentaiTagSettings.stackEnabled, isTrue);
      final revision = NhentaiTagSettings.changes.value;
      await NhentaiTagSettings.setStackEnabled(false);
      expect(NhentaiTagSettings.stackEnabled, isFalse);
      expect(data['tagStackEnabled'], isFalse);
      expect(saves, 1);
      expect(NhentaiTagSettings.changes.value, revision + 1);
    });

    test('persists canonical deduplicated exclusions and clears empty rules',
        () async {
      await NhentaiTagSettings.setDefaultExcludes(const [
        NhentaiTagTerm('tag', 'yaoi'),
        NhentaiTagTerm('tag', 'YAOI', exclude: true),
        NhentaiTagTerm('tag', 'guro'),
        NhentaiTagTerm('invalid', 'ignored'),
      ]);
      expect(data['multiTagDefaultExcludes'], '-tag:"yaoi" -tag:"guro"');
      expect(NhentaiTagSettings.defaultExcludes.toQuery(),
          '-tag:"yaoi" -tag:"guro"');
      await NhentaiTagSettings.setDefaultExcludes(const []);
      expect(data.containsKey('multiTagDefaultExcludes'), isFalse);
      expect(saves, 2);
    });

    test(
        'explicit targets override defaults and repeated application is stable',
        () async {
      await NhentaiTagSettings.setDefaultExcludes(const [
        NhentaiTagTerm('tag', 'yaoi'),
        NhentaiTagTerm('tag', 'guro'),
      ]);
      final query = NhentaiTagSettings.applyDefaultExcludes('TAG:"Yaoi" foo');
      expect(query, 'TAG:"Yaoi" foo -tag:"guro"');
      expect(NhentaiTagSettings.applyDefaultExcludes(query), query);
      expect(NhentaiTagSettings.applyDefaultExcludes('-tag:yaoi'),
          '-tag:yaoi -tag:"guro"');
      expect(NhentaiTagSettings.applyDefaultExcludes(' 177013 '), ' 177013 ');
      expect(NhentaiTagSettings.applyDefaultExcludes(''),
          '-tag:"yaoi" -tag:"guro"');
    });

    test('reads only valid tags from stored data and handles missing sources',
        () async {
      data['multiTagDefaultExcludes'] =
          'tag:yaoi nonsense -tag:yaoi artist:someone pages:>20';
      expect(NhentaiTagSettings.defaultExcludes.toQuery(),
          '-tag:"yaoi" -artist:"someone"');
      data['multiTagDefaultExcludes'] = 42;
      expect(NhentaiTagSettings.defaultExcludes.isEmpty, isTrue);
      NhentaiTagSettings.dataProvider = () => null;
      await NhentaiTagSettings.setStackEnabled(false);
      await NhentaiTagSettings.setDefaultExcludes(
          const [NhentaiTagTerm('tag', 'yaoi')]);
      expect(saves, 0);
    });
  });
}
