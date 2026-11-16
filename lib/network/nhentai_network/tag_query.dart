/// Parsing and composing the tag part of an nhentai search query.
library;

const nhentaiTagNamespaces = <String>[
  'tag',
  'artist',
  'parody',
  'character',
  'group',
  'language',
  'category',
];

String? nhentaiNamespaceOfField(String field) => switch (field) {
      'Tags' || 'Tag' => 'tag',
      'Artists' || 'Artist' => 'artist',
      'Parodies' || 'Parody' => 'parody',
      'Characters' || 'Character' => 'character',
      'Groups' || 'Group' => 'group',
      'Languages' || 'Language' => 'language',
      'Categories' || 'Category' => 'category',
      _ => null,
    };

String _normalize(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

String _escape(String value) =>
    value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

class NhentaiTagTerm {
  const NhentaiTagTerm(this.namespace, this.value, {this.exclude = false});

  final String namespace;
  final String value;
  final bool exclude;

  bool get isValid =>
      nhentaiTagNamespaces.contains(_normalize(namespace)) &&
      _normalize(value).isNotEmpty;

  String get target => '${_normalize(namespace)}:${_normalize(value)}';

  bool sameTarget(NhentaiTagTerm other) => target == other.target;

  NhentaiTagTerm copyWith({bool? exclude}) =>
      NhentaiTagTerm(namespace, value, exclude: exclude ?? this.exclude);

  String toQuery() {
    final ns = _normalize(namespace);
    final v = _normalize(value);
    final body = ns == 'language' && RegExp(r'^\w+$').hasMatch(v)
        ? '$ns:$v'
        : '$ns:"${_escape(v)}"';
    return '${exclude ? '-' : ''}$body';
  }

  @override
  bool operator ==(Object other) =>
      other is NhentaiTagTerm && sameTarget(other) && exclude == other.exclude;

  @override
  int get hashCode => Object.hash(target, exclude);

  @override
  String toString() => toQuery();
}

class NhentaiTagQuery {
  const NhentaiTagQuery({this.terms = const [], this.text = ''});

  static const empty = NhentaiTagQuery();

  final List<NhentaiTagTerm> terms;

  /// Unrecognised tokens, including numeric filters, retained as typed.
  final String text;

  bool get isEmpty => terms.isEmpty && text.trim().isEmpty;

  bool get isNotEmpty => !isEmpty;

  NhentaiTagTerm? find(NhentaiTagTerm term) {
    for (final current in terms) {
      if (current.sameTarget(term)) return current;
    }
    return null;
  }

  NhentaiTagQuery add(NhentaiTagTerm term) {
    final next = List<NhentaiTagTerm>.from(terms);
    final index = next.indexWhere((current) => current.sameTarget(term));
    if (index < 0) {
      next.add(term);
    } else {
      next[index] = term;
    }
    return NhentaiTagQuery(terms: next, text: text);
  }

  NhentaiTagQuery remove(NhentaiTagTerm term) => NhentaiTagQuery(
        terms: terms.where((current) => !current.sameTarget(term)).toList(),
        text: text,
      );

  List<NhentaiTagTerm> missingTermsFrom(NhentaiTagQuery other) =>
      other.terms.where((term) => find(term) == null).toList(growable: false);

  String toQuery() => [
        if (text.trim().isNotEmpty) text.trim(),
        for (final term in terms) term.toQuery(),
      ].join(' ');

  @override
  String toString() => toQuery();

  static final _termPattern =
      RegExp(r'^(-?)([a-z]+):(.+)$', caseSensitive: false, dotAll: true);

  static NhentaiTagQuery parse(String query) {
    var parsed = empty;
    final text = <String>[];
    for (final token in _tokenize(query)) {
      final match = _termPattern.firstMatch(token);
      final namespace = match?[2]?.toLowerCase();
      final value = match == null ? null : _unquote(match[3]!);
      if (namespace == null ||
          !nhentaiTagNamespaces.contains(namespace) ||
          value == null ||
          value.trim().isEmpty) {
        text.add(token);
        continue;
      }
      parsed = parsed
          .add(NhentaiTagTerm(namespace, value, exclude: match![1] == '-'));
    }
    return NhentaiTagQuery(terms: parsed.terms, text: text.join(' '));
  }

  static List<String> _tokenize(String query) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    for (var i = 0; i < query.length; i++) {
      final c = query[i];
      if (quoted && c == '\\' && i + 1 < query.length) {
        buffer
          ..write(c)
          ..write(query[++i]);
      } else if (c == '"') {
        quoted = !quoted;
        buffer.write(c);
      } else if (!quoted && c.trim().isEmpty) {
        if (buffer.isNotEmpty) tokens.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(c);
      }
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }

  static String? _unquote(String raw) {
    if (!raw.startsWith('"')) return raw.contains('"') ? null : raw;
    if (raw.length < 2 || !raw.endsWith('"')) return null;
    final value = StringBuffer();
    for (var i = 1; i < raw.length - 1; i++) {
      final c = raw[i];
      if (c == '"') return null;
      if (c == '\\') {
        if (++i >= raw.length - 1) return null;
        value.write(raw[i]);
      } else {
        value.write(c);
      }
    }
    return value.toString();
  }
}
