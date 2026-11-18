part of comic_source;

class CategoryData {
  /// The title is displayed in the tab bar.
  final String title;

  /// 当使用中文语言时, 英文的分类标签将在构建页面时被翻译为中文
  final List<BaseCategoryPart> categories;

  final bool enableRankingPage;

  final String key;

  final List<CategoryButtonData> buttons;

  /// Data class for building category page.
  const CategoryData({
    required this.title,
    required this.categories,
    required this.enableRankingPage,
    required this.key,
    this.buttons = const [],
  });
}

class CategoryButtonData {
  final String label;

  final void Function() onTap;

  const CategoryButtonData({
    required this.label,
    required this.onTap,
  });
}

abstract class BaseCategoryPart {
  String get title;

  List<String> get categories;

  /// Rebuild the visible random sample and return its labels.
  ///
  /// Fixed category parts have no sample state, so their current labels are
  /// returned unchanged.
  List<String> refreshCategories() => categories;

  List<String>? get categoryParams => null;

  bool get enableRandom;

  String get categoryType;

  /// Data class for building a part of category page.
  const BaseCategoryPart();
}

class FixedCategoryPart extends BaseCategoryPart {
  @override
  final List<String> categories;

  @override
  bool get enableRandom => false;

  @override
  final String title;

  @override
  final String categoryType;

  @override
  final List<String>? categoryParams;

  /// A [BaseCategoryPart] that show fixed tags on category page.
  const FixedCategoryPart(this.title, this.categories, this.categoryType,
      [this.categoryParams]);
}

class RandomCategoryPart extends BaseCategoryPart {
  final List<String> tags;

  final int randomNumber;

  final math.Random? _random;

  @override
  final String title;

  @override
  bool get enableRandom => true;

  @override
  final String categoryType;

  @override
  List<String> get categories =>
      _randomCategories(tags, randomNumber, _random ?? math.Random());

  /// A [BaseCategoryPart] that show random tags on category page.
  const RandomCategoryPart(
      this.title, this.tags, this.randomNumber, this.categoryType,
      {math.Random? random})
      : _random = random;
}

List<String> _randomCategories(
    Iterable<String> values, int count, math.Random random) {
  if (count <= 0) return [];
  final tags = values.toList();
  if (count >= tags.length) return tags;
  final start = random.nextInt(tags.length - count + 1);
  return tags.sublist(start, start + count);
}

typedef CategoryParamBuilder = String Function(String tag);

class RandomCategoryPartWithRuntimeData extends BaseCategoryPart {
  final Iterable<String> Function() loadTags;

  final int randomNumber;

  final CategoryParamBuilder? buildParam;

  final math.Random? _random;

  @override
  final String title;

  @override
  bool get enableRandom => true;

  @override
  final String categoryType;

  static final random = math.Random();

  List<String>? _lastCategories;

  List<String> _sampleCategories() {
    _lastCategories = List.unmodifiable(
        _randomCategories(loadTags(), randomNumber, _random ?? random));
    return List.of(_lastCategories!);
  }

  @override
  List<String> get categories => _sampleCategories();

  @override
  List<String> refreshCategories() => _sampleCategories();

  @override
  List<String>? get categoryParams {
    final builder = buildParam;
    if (builder == null) return null;
    // Navigation must use the same sample as the most recently rendered labels.
    return (_lastCategories ?? _sampleCategories()).map(builder).toList();
  }

  /// A [BaseCategoryPart] that show random tags on category page.
  RandomCategoryPartWithRuntimeData(
      this.title, this.loadTags, this.randomNumber, this.categoryType,
      {this.buildParam, math.Random? random})
      : _random = random;
}

CategoryData getCategoryDataWithKey(String key) {
  for (var source in ComicSource.sources) {
    if (source.categoryData?.key == key) {
      return source.categoryData!;
    }
  }
  throw "Unknown category key $key";
}
