import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/search_language.dart';

void main() {
  test('defaults apply to initial, repeated and empty searches', () {
    for (final keyword in ['first', 'second', '']) {
      expect(withDefaultSearchLanguage(keyword, 1),
          '$keyword language:chinese'.trim());
    }
  });

  test('explicit language wins over the default, without duplicates', () {
    expect(withDefaultSearchLanguage('tag Language:japanese', 1),
        'tag Language:japanese');
    final query = withDefaultSearchLanguage('tag', 1);
    expect(withDefaultSearchLanguage(query, 1), query);
  });

  test('a query snapshot follows a changed default language', () {
    const keyword = 'artist:test';
    expect(withDefaultSearchLanguage(keyword, 0), keyword);
    expect(withDefaultSearchLanguage(keyword, 1), '$keyword language:chinese');
    expect(withDefaultSearchLanguage(keyword, 2), '$keyword language:english');
  });

  test('negative and ordinary language words do not disable the default', () {
    expect(withDefaultSearchLanguage('language_school -language:english', 1),
        'language_school -language:english language:chinese');
  });

  test('unsupported sources and invalid settings do not add a filter', () {
    expect(withDefaultSearchLanguage('tag', 1, enabled: false), 'tag');
    for (final index in [-1, 0, 4, 99]) {
      expect(withDefaultSearchLanguage('tag', index), 'tag');
    }
  });
}
