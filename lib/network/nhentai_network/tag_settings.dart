import 'package:flutter/foundation.dart';
import 'package:pica_comic/comic_source/comic_source.dart';

import 'tag_query.dart';
import 'tag_stack.dart';

class NhentaiTagSettings {
  NhentaiTagSettings._();

  static const _stackEnabledKey = 'tagStackEnabled';
  static const _defaultExcludesKey = 'multiTagDefaultExcludes';

  @visibleForTesting
  static Map<String, dynamic>? Function() dataProvider =
      () => ComicSource.find('nhentai')?.data;

  @visibleForTesting
  static Future<void> Function() saver =
      () async => await ComicSource.find('nhentai')?.saveData();

  static final changes = ValueNotifier<int>(0);

  static bool get stackEnabled => dataProvider()?[_stackEnabledKey] != false;

  static Future<void> setStackEnabled(bool value) async {
    final data = dataProvider();
    if (data == null) return;
    data[_stackEnabledKey] = value;
    await _save();
  }

  static NhentaiTagQuery get defaultExcludes {
    final raw = dataProvider()?[_defaultExcludesKey];
    if (raw is! String) return NhentaiTagQuery.empty;
    return _exclusions(NhentaiTagQuery.parse(raw).terms);
  }

  static Future<void> setDefaultExcludes(List<NhentaiTagTerm> terms) async {
    final data = dataProvider();
    if (data == null) return;
    final query = _exclusions(terms);
    if (query.isEmpty) {
      data.remove(_defaultExcludesKey);
    } else {
      data[_defaultExcludesKey] = query.toQuery();
    }
    await _save();
  }

  /// An explicit include or exclude takes precedence over the same default.
  static String applyDefaultExcludes(String keyword) {
    if (RegExp(r'^\s*\d+\s*$').hasMatch(keyword)) return keyword;
    final missing =
        NhentaiTagQuery.parse(keyword).missingTermsFrom(defaultExcludes);
    if (missing.isEmpty) return keyword;
    return [
      if (keyword.trim().isNotEmpty) keyword.trim(),
      for (final term in missing) term.toQuery(),
    ].join(' ');
  }

  static String searchQuery(String keyword, int languageIndex) =>
      applyDefaultExcludes(withNhentaiSearchLanguage(keyword, languageIndex));

  static NhentaiTagQuery _exclusions(List<NhentaiTagTerm> terms) {
    var query = NhentaiTagQuery.empty;
    for (final term in terms) {
      if (term.isValid) query = query.add(term.copyWith(exclude: true));
    }
    return query;
  }

  static Future<void> _save() async {
    await saver();
    changes.value++;
  }
}
