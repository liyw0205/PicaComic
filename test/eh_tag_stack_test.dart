import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/eh_network/tag_stack.dart';

void main() {
  List<String> keywords(List<EhTagTerm>? terms) =>
      [for (final term in terms ?? const <EhTagTerm>[]) term.toKeyword()];

  test('parses quoted, exact, and excluded terms', () {
    final terms = ehTermsFromKeyword(
        r'language:chinese female:glasses$ female:"big breasts$" -male:yaoi')!;
    expect(
        terms.map(
            (term) => (term.namespace, term.value, term.exact, term.exclude)),
        [
          ('language', 'chinese', false, false),
          ('female', 'glasses', true, false),
          ('female', 'big breasts', true, false),
          ('male', 'yaoi', false, true),
        ]);
    expect(ehKeywordFromTerms(terms),
        r'language:chinese female:glasses$ female:"big breasts$" -male:yaoi');
  });

  test('free text and malformed terms do not stack', () {
    expect(ehTermsFromKeyword(''), isNull);
    expect(ehTermsFromKeyword('touhou'), isNull);
    expect(ehTermsFromKeyword('female:glasses touhou'), isNull);
    expect(ehTermsFromKeyword('female:'), isNull);
    expect(ehTermsFromKeyword(r'female:$'), isNull);
  });

  test('duplicate and language terms are handled predictably', () {
    final base = ehTermsFromKeyword('language:chinese female:glasses')!;
    final duplicate = ehStackAdd(base, const EhTagTerm('female', 'Glasses'));
    expect(duplicate.outcome, EhStackOutcome.duplicate);
    expect(duplicate.terms, same(base));

    final replacement =
        ehStackAdd(base, const EhTagTerm('language', 'english'));
    expect(keywords(replacement.terms), ['female:glasses', 'language:english']);

    final flag = ehStackAdd(base, const EhTagTerm('language', 'translated'));
    expect(keywords(flag.terms),
        ['language:chinese', 'female:glasses', 'language:translated']);
  });

  test('enforces the stack limit without mutating the base list', () {
    var terms = <EhTagTerm>[];
    for (var i = 0; i < ehTagStackLimit; i++) {
      final result = ehStackAdd(terms, EhTagTerm('female', 'tag$i'));
      expect(result.outcome, EhStackOutcome.added);
      terms = result.terms;
    }
    final result = ehStackAdd(terms, const EhTagTerm('female', 'one more'));
    expect(result.outcome, EhStackOutcome.limit);
    expect(result.terms, same(terms));
  });
}
