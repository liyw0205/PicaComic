import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/pair.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/search_language.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';

class _SearchPageComicList extends ComicsPage<BaseComic> {
  const _SearchPageComicList({
    super.key,
    required this.keyword,
    required this.languageIndex,
    required this.options,
    required this.header,
    required this.sourceKey,
  });

  final String keyword;

  final int languageIndex;

  final List<String> options;

  @override
  final String sourceKey;

  @override
  final Widget header;

  @override
  Future<Res<List<BaseComic>>> getComics(int i) async {
    final searchData = ComicSource.find(sourceKey)!.searchPageData!;
    final query = withDefaultSearchLanguage(keyword, languageIndex,
        enabled: searchData.enableLanguageFilter);
    return await searchData.loadPage!(query, i, options);
  }

  @override
  String? get tag =>
      "$sourceKey search page with ${withDefaultSearchLanguage(keyword, languageIndex, enabled: ComicSource.find(sourceKey)!.searchPageData!.enableLanguageFilter)}";

  @override
  String? get title => null;
}

class SearchResultPage extends StatefulWidget {
  const SearchResultPage({
    super.key,
    required this.keyword,
    this.options = const [],
    required this.sourceKey,
  });

  final String keyword;

  final List<String> options;

  final String sourceKey;

  static final Set<_SearchResultPageState> _activePages = {};

  static void updateDefaultLanguage(int languageIndex) {
    for (final page in _activePages.toList()) {
      page.updateDefaultLanguage(languageIndex);
    }
  }

  @override
  State<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends State<SearchResultPage> {
  var controller = TextEditingController();
  bool _showFab = true;
  late String keyword = widget.keyword;
  late int languageIndex = int.tryParse(appdata.settings[69]) ?? 0;

  OverlayEntry? get suggestionOverlay => suggestionsController.entry;
  late _SuggestionsController suggestionsController;
  late var sourceKey = widget.sourceKey;
  late var options = widget.options;

  @override
  void initState() {
    controller.text = keyword.trim();
    suggestionsController = _SuggestionsController(controller);
    SearchResultPage._activePages.add(this);
    super.initState();
  }

  @override
  void dispose() {
    if (suggestionOverlay != null) {
      suggestionsController.remove();
    }
    SearchResultPage._activePages.remove(this);
    controller.dispose();
    super.dispose();
  }

  void updateDefaultLanguage(int index) {
    if (!mounted || languageIndex == index) return;
    setState(() => languageIndex = index);
  }

  void onChanged(String s) {
    suggestionsController.findSuggestions();
    if (suggestionOverlay != null) {
      if (suggestionsController.suggestions.isEmpty) {
        suggestionsController.remove();
      } else {
        suggestionsController.updateWidget();
      }
    } else if (suggestionsController.suggestions.isNotEmpty) {
      suggestionsController.entry = OverlayEntry(
        builder: (context) {
          return Positioned(
            top: context.padding.top + 56 + 16,
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              child: _Suggestions(
                controller: suggestionsController,
              ),
            ),
          );
        },
      );
      Overlay.of(context).insert(suggestionOverlay!);
    }
  }

  void update() {
    if (controller.text != keyword) {
      setState(() {
        keyword = controller.text;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final comicSource =
        ComicSource.find(sourceKey) ?? (throw "source $sourceKey not found");
    final searchData = comicSource.searchPageData!;
    final effectiveOptions = searchData.searchOptions != null &&
            searchData.searchOptions!.length != options.length
        ? searchData.searchOptions!.map((e) => e.defaultValue).toList()
        : options;
    final query = withDefaultSearchLanguage(
      keyword,
      languageIndex,
      enabled: searchData.enableLanguageFilter,
    );
    if (searchData.overrideSearchResultBuilder != null) {
      return KeyedSubtree(
        key: ValueKey('$sourceKey:$query:${effectiveOptions.join(',')}'),
        child: searchData.overrideSearchResultBuilder!(query, effectiveOptions),
      );
    }

    Widget trailing;
    if (context.width < 400) {
      trailing = Button.icon(
        icon: const Icon(Icons.more_horiz),
        onPressed: more,
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            icon: const Icon(Icons.dataset_outlined),
            onPressed: changeSource,
          ),
          const SizedBox(
            width: 4,
          ),
          Button.icon(
            icon: const Icon(Icons.tune),
            onPressed: showSearchOptions,
          ),
        ],
      );
    }

    return Scaffold(
      floatingActionButton: _showFab
          ? FloatingActionButton(
              child: const Icon(Icons.search),
              onPressed: () {
                var s = controller.text;
                setState(() {
                  keyword = s;
                });
              },
            )
          : null,
      body: NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) {
          if (suggestionsController.entry != null) {
            suggestionsController.remove();
          }
          final ScrollDirection direction = notification.scrollDelta! < 0
              ? ScrollDirection.forward
              : ScrollDirection.reverse;
          var showFab = _showFab;
          if (direction == ScrollDirection.reverse) {
            _showFab = false;
          } else if (direction == ScrollDirection.forward) {
            _showFab = true;
          }
          if (_showFab == showFab) return true;
          setState(() {});
          return false;
        },
        child: _SearchPageComicList(
          keyword: keyword,
          languageIndex: languageIndex,
          sourceKey: sourceKey,
          key: Key(
            '$query${effectiveOptions.toString()}$sourceKey',
          ),
          header: SliverPersistentHeader(
            pinned: _showFab && SmoothScrollProvider.isMouseScroll,
            floating: !SmoothScrollProvider.isMouseScroll,
            delegate: _SliverAppBarDelegate(
              minHeight: 60,
              maxHeight: 60,
              child: FloatingSearchBar(
                onSearch: (s) {
                  suggestionsController.suggestions.clear();
                  suggestionsController.remove();
                  if (s == keyword) return;
                  setState(() {
                    keyword = s;
                  });
                },
                controller: controller,
                onChanged: onChanged,
                trailing: trailing,
              ),
            ),
          ),
          options: effectiveOptions,
        ),
      ),
    );
  }

  void more() {
    showMenu(
      context: context,
      elevation: 2,
      color: context.colorScheme.surface,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 48,
        56,
        0,
        0,
      ),
      items: [
        PopupMenuItem(
          value: 0,
          child: Text("切换源".tl),
        ),
        PopupMenuItem(
          value: 1,
          child: Text("搜索选项".tl),
        ),
      ],
    ).then((value) {
      if (value == 0) {
        changeSource();
      } else if (value == 1) {
        showSearchOptions();
      }
    });
  }

  void changeSource() {
    var sources = ComicSource.sources.where((e) => e.searchPageData != null);
    String? sourceKey = this.sourceKey;
    showDialog(
      useSafeArea: false,
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "切换源".tl,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var source in sources)
                  RadioListTile<String>(
                    title: Text(source.name),
                    value: source.key,
                    groupValue: sourceKey,
                    onChanged: (value) {
                      setState(() {
                        sourceKey = value;
                      });
                    },
                  )
              ],
            ),
            actions: [
              Button.filled(
                child: Text("确认".tl),
                onPressed: () {
                  if (sourceKey != null) {
                    context.pop();
                    var searchData =
                        ComicSource.find(sourceKey!)!.searchPageData!;
                    options = (searchData.searchOptions ?? [])
                        .map((e) => e.defaultValue)
                        .toList();
                    if (searchData.overrideSearchResultBuilder != null) {
                      this.context.off(() {
                        return SearchResultPage(
                          keyword: keyword,
                          options: options,
                          sourceKey: sourceKey!,
                        );
                      });
                    } else {
                      this.setState(() {
                        this.sourceKey = sourceKey!;
                      });
                    }
                  }
                },
              )
            ],
          );
        });
      },
    );
  }

  void showSearchOptions() {
    showDialog(
      context: context,
      useSafeArea: false,
      builder: (context) => _SearchOptions(
        current: options,
        sourceKey: sourceKey,
        onChanged: (options) {
          setState(() {
            this.options = options;
          });
        },
      ),
    );
  }
}

class _SliverAppBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverAppBarDelegate(
      {required this.child, required this.maxHeight, required this.minHeight});

  final double minHeight;
  final double maxHeight;
  final Widget child;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox.expand(
      child: child,
    );
  }

  @override
  double get maxExtent => minHeight;

  @override
  double get minExtent => max(maxHeight, minHeight);

  @override
  bool shouldRebuild(SliverPersistentHeaderDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxExtent ||
        minHeight != oldDelegate.minExtent;
  }
}

class _SuggestionsController {
  _SuggestionsState? _state;

  final TextEditingController controller;

  OverlayEntry? entry;

  void updateWidget() {
    _state?.update();
  }

  void remove() {
    entry?.remove();
    entry = null;
  }

  var suggestions = <Pair<String, TranslationType>>[];

  void findSuggestions() {
    var text = controller.text.split(" ").last;
    var suggestions = this.suggestions;

    suggestions.clear();

    bool check(String text, String key, String value) {
      if (text.removeAllBlank == "") {
        return false;
      }
      if (key.length >= text.length && key.substring(0, text.length) == text ||
          (key.contains(" ") &&
              key.split(" ").last.length >= text.length &&
              key.split(" ").last.substring(0, text.length) == text)) {
        return true;
      } else if (value.length >= text.length && value.contains(text)) {
        return true;
      }
      return false;
    }

    void find(Map<String, String> map, TranslationType type) {
      for (var element in map.entries) {
        if (suggestions.length > 200) {
          break;
        }
        if (check(text, element.key, element.value)) {
          suggestions.add(Pair(element.key, type));
        }
      }
    }

    find(TagsTranslation.femaleTags, TranslationType.female);
    find(TagsTranslation.maleTags, TranslationType.male);
    find(TagsTranslation.parodyTags, TranslationType.parody);
    find(TagsTranslation.characterTranslations, TranslationType.character);
    find(TagsTranslation.otherTags, TranslationType.other);
    find(TagsTranslation.mixedTags, TranslationType.mixed);
    find(TagsTranslation.languageTranslations, TranslationType.language);
    find(TagsTranslation.artistTags, TranslationType.artist);
    find(TagsTranslation.groupTags, TranslationType.group);
    find(TagsTranslation.cosplayerTags, TranslationType.cosplayer);
  }

  _SuggestionsController(this.controller);
}

class _Suggestions extends StatefulWidget {
  const _Suggestions({required this.controller});

  final _SuggestionsController controller;

  @override
  State<_Suggestions> createState() => _SuggestionsState();
}

class _SuggestionsState extends State<_Suggestions> {
  void update() {
    setState(() {});
  }

  @override
  void initState() {
    widget.controller._state = this;
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _Suggestions oldWidget) {
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._state = null;
      widget.controller._state = this;
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return buildSuggestions(context);
  }

  Widget buildSuggestions(BuildContext context) {
    bool showMethod = MediaQuery.of(context).size.width < 600;
    bool showTranslation = App.locale.languageCode == "zh";

    Widget buildItem(Pair<String, TranslationType> value) {
      var subTitle = TagsTranslation.translationTagWithNamespace(
          value.left, value.right.name);
      return ListTile(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Text(
                value.left,
                maxLines: 2,
              ),
            ),
            if (!showMethod)
              const SizedBox(
                width: 12,
              ),
            if (!showMethod && showTranslation)
              Text(
                subTitle,
                style: TextStyle(
                    fontSize: 14, color: Theme.of(context).colorScheme.outline),
              )
          ],
        ),
        subtitle: (showMethod && showTranslation) ? Text(subTitle) : null,
        trailing: Text(
          value.right.name,
          style: const TextStyle(fontSize: 13),
        ),
        onTap: () => onSelected(value.left, value.right),
      );
    }

    return Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              const SizedBox(
                width: 32,
              ),
              Text("建议".tl),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  widget.controller.suggestions.clear();
                  widget.controller.remove();
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(
                width: 36,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: widget.controller.suggestions.length,
            itemBuilder: (context, index) =>
                buildItem(widget.controller.suggestions[index]),
          ),
        )
      ],
    );
  }

  bool check(String text, String key, String value) {
    if (text.removeAllBlank == "") {
      return false;
    }
    if (key.length >= text.length && key.substring(0, text.length) == text ||
        (key.contains(" ") &&
            key.split(" ").last.length >= text.length &&
            key.split(" ").last.substring(0, text.length) == text)) {
      return true;
    } else if (value.length >= text.length && value.contains(text)) {
      return true;
    }
    return false;
  }

  void onSelected(String text, TranslationType? type) {
    var controller = widget.controller.controller;
    var words = controller.text.split(" ");
    if (words.length >= 2 &&
        check("${words[words.length - 2]} ${words[words.length - 1]}", text,
            text.translateTagsToCN)) {
      controller.text = controller.text.replaceLast(
          "${words[words.length - 2]} ${words[words.length - 1]}", "");
    } else {
      controller.text =
          controller.text.replaceLast(words[words.length - 1], "");
    }
    if (type != null) {
      controller.text += "${type.name}:$text ";
    } else {
      controller.text += "$text ";
    }
    widget.controller.suggestions.clear();
    widget.controller.remove();
  }
}

class _SearchOptions extends StatefulWidget {
  const _SearchOptions({
    required this.current,
    required this.sourceKey,
    required this.onChanged,
  });

  final List<String> current;

  final String sourceKey;

  final void Function(List<String>) onChanged;

  @override
  State<_SearchOptions> createState() => _SearchOptionsState();
}

class _SearchOptionsState extends State<_SearchOptions> {
  late SearchPageData data;

  var options = <String>[];

  @override
  void initState() {
    data = ComicSource.find(widget.sourceKey)!.searchPageData!;
    options = widget.current;
    if (data.searchOptions != null &&
        options.length != data.searchOptions!.length) {
      options = data.searchOptions!.map((e) => e.defaultValue).toList();
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "搜索选项".tl,
      content: buildSearchOptions(context),
      actions: [
        Button.filled(
          child: Text("确认".tl),
          onPressed: () {
            context.pop();
            widget.onChanged(options);
          },
        )
      ],
    );
  }

  Widget buildSearchOptions(BuildContext context) {
    var children = <Widget>[];
    if (data.customOptionsBuilder != null) {
      children.add(
        data.customOptionsBuilder!(context, options, (options) {
          this.options = options;
        }),
      );
    } else {
      final searchOptions = data.searchOptions ?? <SearchOptions>[];
      for (int i = 0; i < searchOptions.length; i++) {
        final option = searchOptions[i];
        children.add(ListTile(
          title: Text(option.label),
        ));
        children.add(Wrap(
          runSpacing: 8,
          spacing: 8,
          children: option.options.entries.map((e) {
            return InkWell(
              onTap: () {
                setState(() {
                  options[i] = e.key;
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                decoration: BoxDecoration(
                  color: options[i] == e.key
                      ? context.colorScheme.primaryContainer
                      : context.colorScheme.primaryContainer.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(e.value.tl),
                ),
              ),
            );
          }).toList(),
        ).paddingHorizontal(16));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ).paddingBottom(12);
  }
}
