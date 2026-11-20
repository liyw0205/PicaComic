const searchLanguages = ['chinese', 'english', 'japanese'];

bool shouldHideSourceLanguageOption({
  required String label,
  required bool enableLanguageFilter,
  required int languageIndex,
}) =>
    enableLanguageFilter &&
    label == '语言' &&
    languageIndex >= 1 &&
    languageIndex <= searchLanguages.length;

String withDefaultSearchLanguage(String keyword, int index,
    {bool enabled = true}) {
  keyword = keyword.trim();
  if (!enabled || index < 1 || index > searchLanguages.length) return keyword;
  if (RegExp(r'(?:^|\s)language\s*:\s*\S+', caseSensitive: false)
      .hasMatch(keyword)) {
    return keyword;
  }
  return '$keyword language:${searchLanguages[index - 1]}'.trim();
}
