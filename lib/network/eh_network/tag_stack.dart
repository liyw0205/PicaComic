/// Helpers for composing E-Hentai searches made from tag terms.
library;

const ehTagStackLimit = 5;

class EhTagTerm {
  const EhTagTerm(this.namespace, this.value,
      {this.exact = false, this.exclude = false});

  final String namespace;
  final String value;
  final bool exact;
  final bool exclude;

  bool sameTarget(EhTagTerm other) =>
      namespace == other.namespace &&
      value.toLowerCase() == other.value.toLowerCase();

  String toKeyword() {
    var text = '$value${exact ? r'$' : ''}';
    if (text.contains(' ')) text = '"$text"';
    return '${exclude ? '-' : ''}$namespace:$text';
  }

  @override
  String toString() => toKeyword();
}

final _term = RegExp(r'^(-)?([a-z]+):(?:"([^"]+)"|([^\s"]+))$');

const _languageFlags = {'translated', 'rewrite', 'speechless', 'text cleaned'};

bool isEhLanguage(EhTagTerm term) =>
    term.namespace == 'language' &&
    !_languageFlags.contains(term.value.trim().toLowerCase());

List<String> _splitTerms(String keyword) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < keyword.length; i++) {
    final char = keyword[i];
    if (char == '"') quoted = !quoted;
    if (char.trim().isEmpty && !quoted) {
      if (buffer.isNotEmpty) tokens.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty) tokens.add(buffer.toString());
  return tokens;
}

List<EhTagTerm>? ehTermsFromKeyword(String keyword) {
  final terms = <EhTagTerm>[];
  for (final token in _splitTerms(keyword.trim())) {
    final match = _term.firstMatch(token);
    if (match == null) return null;
    var value = (match[3] ?? match[4]!).trim();
    var exact = false;
    if (value.contains(' | ')) {
      value = value.split(' | ').first.trim();
      exact = true;
    }
    if (value.endsWith(r'$')) {
      value = value.substring(0, value.length - 1).trim();
      exact = true;
    }
    if (value.isEmpty) return null;
    terms.add(
        EhTagTerm(match[2]!, value, exact: exact, exclude: match[1] != null));
  }
  return terms.isEmpty ? null : terms;
}

String ehKeywordFromTerms(List<EhTagTerm> terms) =>
    terms.map((term) => term.toKeyword()).join(' ');

enum EhStackOutcome { added, duplicate, limit }

class EhStackResult {
  const EhStackResult(this.outcome, this.terms);

  final EhStackOutcome outcome;
  final List<EhTagTerm> terms;
}

EhStackResult ehStackAdd(
  List<EhTagTerm> base,
  EhTagTerm term, {
  int limit = ehTagStackLimit,
}) {
  if (base.any((item) => item.sameTarget(term))) {
    return EhStackResult(EhStackOutcome.duplicate, base);
  }
  final next = [
    for (final item in base)
      if (!(isEhLanguage(term) && isEhLanguage(item))) item,
    term,
  ];
  if (next.length > limit) {
    return EhStackResult(EhStackOutcome.limit, base);
  }
  return EhStackResult(EhStackOutcome.added, next);
}
