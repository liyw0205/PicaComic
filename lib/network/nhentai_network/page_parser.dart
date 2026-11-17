import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart';

dynamic nhentaiFetchedPayload(Element script) {
  dynamic wrapper;
  try {
    wrapper = jsonDecode(script.text);
  } on FormatException {
    wrapper = jsonDecode(parseFragment(script.text).text ?? '');
  }
  if (wrapper is! Map || wrapper['body'] is! String) return null;
  return jsonDecode(wrapper['body'] as String);
}

Map<String, Set<String>> nhentaiTagIdsFromFetchedData(Document document) {
  final result = <String, Set<String>>{};
  for (final script
      in document.querySelectorAll('script[data-sveltekit-fetched]')) {
    try {
      final payload = nhentaiFetchedPayload(script);
      final dynamic galleries = payload is List
          ? payload
          : payload is Map && payload['result'] is List
              ? payload['result']
              : payload is Map && payload['id'] != null
                  ? [payload]
                  : null;
      if (galleries is! List) continue;
      for (final gallery in galleries) {
        if (gallery is! Map || gallery['tag_ids'] is! List) continue;
        final id = _numericId(gallery['id']);
        if (id == null) continue;
        final tags = result.putIfAbsent(id, () => <String>{});
        for (final value in gallery['tag_ids'] as List) {
          final tag = _numericId(value);
          if (tag != null) tags.add(tag);
        }
      }
    } catch (_) {
      // Ignore unrelated or malformed SvelteKit payloads.
    }
  }
  return result;
}

Set<String> nhentaiCardTagIds(Element card, Iterable<String> fetchedTags) {
  final result = <String>{...fetchedTags};
  for (final value
      in (card.attributes['data-tags'] ?? '').split(RegExp(r'\s+'))) {
    final id = _numericId(value);
    if (id != null) result.add(id);
  }
  return result;
}

String nhentaiLanguage(Set<String> tags) {
  if (tags.contains('12227')) return 'English';
  if (tags.contains('6346')) return '日本語';
  if (tags.contains('29963')) return '中文';
  return 'Unknown';
}

String? _numericId(dynamic value) {
  if (value is! int && value is! String) return null;
  final id = value.toString().trim();
  return RegExp(r'^\d+$').hasMatch(id) ? id : null;
}
