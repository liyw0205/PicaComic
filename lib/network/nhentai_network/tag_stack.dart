/// Tag stacking and category routes shared by nhentai lists and galleries.
library;

import 'tag_query.dart';
import '../search_language.dart';

const nhentaiTagStackLimit = 5;

const _languageFlags = {'translated', 'rewrite', 'speechless', 'text cleaned'};

bool isNhentaiLanguage(NhentaiTagTerm term) =>
    term.namespace.trim().toLowerCase() == 'language' &&
    !_languageFlags.contains(
        term.value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase());

String withNhentaiSearchLanguage(String keyword, int index) {
  keyword = keyword.trim();
  if (index < 1 ||
      index > searchLanguages.length ||
      RegExp(r'^\d+$').hasMatch(keyword) ||
      NhentaiTagQuery.parse(keyword)
          .terms
          .any((term) => !term.exclude && isNhentaiLanguage(term))) {
    return keyword;
  }
  return '$keyword language:${searchLanguages[index - 1]}'.trim();
}

List<NhentaiTagTerm>? nhentaiTermsFromKeyword(String keyword) {
  final query = NhentaiTagQuery.parse(keyword);
  if (query.text.isNotEmpty ||
      query.terms.isEmpty ||
      query.terms.length > nhentaiTagStackLimit) {
    return null;
  }
  return query.terms;
}

enum NhentaiStackOutcome { added, duplicate, limit }

class NhentaiStackResult {
  const NhentaiStackResult(this.outcome, this.terms);

  final NhentaiStackOutcome outcome;
  final List<NhentaiTagTerm> terms;
}

NhentaiStackResult nhentaiStackAdd(
  List<NhentaiTagTerm> base,
  NhentaiTagTerm term, {
  int limit = nhentaiTagStackLimit,
}) {
  if (base.any((current) => current.sameTarget(term))) {
    return NhentaiStackResult(NhentaiStackOutcome.duplicate, base);
  }
  final replaceLanguage = !term.exclude && isNhentaiLanguage(term);
  final next = [
    for (final current in base)
      if (!(replaceLanguage && !current.exclude && isNhentaiLanguage(current)))
        current,
    term,
  ];
  if (next.length > limit) {
    return NhentaiStackResult(NhentaiStackOutcome.limit, base);
  }
  return NhentaiStackResult(NhentaiStackOutcome.added, next);
}

String nhentaiStackParam(List<NhentaiTagTerm> terms) {
  if (terms.isEmpty ||
      terms.length > nhentaiTagStackLimit ||
      terms.any((term) => !term.isValid)) {
    throw ArgumentError.value(terms, 'terms', 'Invalid nhentai tag stack');
  }
  if (terms.length == 1) {
    final term = terms.single;
    final value =
        term.value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    // A hyphen in a real tag cannot round trip through a space-based slug.
    if (!term.exclude &&
        RegExp(r'^[a-z0-9]+(?: [a-z0-9]+)*$').hasMatch(value)) {
      return '/${term.namespace.trim().toLowerCase()}/${value.replaceAll(' ', '-')}';
    }
  }
  return '/combo/${Uri.encodeComponent(NhentaiTagQuery(terms: terms).toQuery())}';
}

List<NhentaiTagTerm>? nhentaiTermsFromParam(String? param) {
  if (param == null) return null;
  final parts = param.split('/');
  if (parts.length != 3 || parts.first.isNotEmpty || parts.last.isEmpty) {
    return null;
  }
  String value;
  try {
    value = Uri.decodeComponent(parts.last);
  } on ArgumentError {
    return null;
  }
  if (parts[1] == 'combo') {
    return nhentaiTermsFromKeyword(value);
  }
  if (!nhentaiTagNamespaces.contains(parts[1])) return null;
  final term = NhentaiTagTerm(parts[1], value.replaceAll('-', ' '));
  return term.isValid ? [term] : null;
}
