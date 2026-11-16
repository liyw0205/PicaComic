import "package:flutter/material.dart";
import "package:pica_comic/comic_source/comic_source.dart";
import 'package:pica_comic/components/components.dart';
import "package:pica_comic/foundation/app.dart";
import 'package:pica_comic/network/base_comic.dart';
import "package:pica_comic/network/res.dart";
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/network/nhentai_network/tag_settings.dart';
import 'package:pica_comic/network/nhentai_network/tag_stack.dart';
import 'package:pica_comic/pages/nhentai/tag_stack_bar.dart';
import "package:pica_comic/tools/translations.dart";

class CategoryComicsPage extends StatefulWidget {
  const CategoryComicsPage({
    required this.category,
    this.param,
    required this.categoryKey,
    super.key,
  });

  final String category;

  final String? param;

  final String categoryKey;

  @override
  State<CategoryComicsPage> createState() => _CategoryComicsPageState();
}

class _CategoryComicsPageState extends State<CategoryComicsPage> {
  late final CategoryComicsData data;
  late final List<CategoryComicsOptions> options;
  late List<String> optionsValue;
  late final String sourceKey;
  late String? param = widget.param;

  List<NhentaiTagTerm> get nhentaiTerms =>
      sourceKey == 'nhentai' && NhentaiTagSettings.stackEnabled
          ? nhentaiTermsFromParam(param) ?? const []
          : const [];

  void findData() {
    for (final source in ComicSource.sources) {
      if (source.categoryData?.key == widget.categoryKey) {
        sourceKey = source.key;
        data = source.categoryComicsData!;
        options = data.options.where((element) {
          if (element.notShowWhen.contains(widget.category)) {
            return false;
          } else if (element.showWhen != null) {
            return element.showWhen!.contains(widget.category);
          }
          return true;
        }).toList();
        optionsValue = options.map((e) => e.options.keys.first).toList();
        return;
      }
    }
    throw "${widget.categoryKey} Not found";
  }

  @override
  void initState() {
    findData();
    if (sourceKey == 'nhentai') {
      NhentaiTagSettings.changes.addListener(_refreshTagSettings);
    }
    super.initState();
  }

  void _refreshTagSettings() => setState(() {});

  @override
  void dispose() {
    if (sourceKey == 'nhentai') {
      NhentaiTagSettings.changes.removeListener(_refreshTagSettings);
    }
    super.dispose();
  }

  void removeNhentaiTerm(NhentaiTagTerm term) {
    final rest = [
      for (final current in nhentaiTerms)
        if (!current.sameTarget(term)) current,
    ];
    if (rest.isEmpty) return;
    setState(() => param = nhentaiStackParam(rest));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text(widget.category),
      ),
      body: NhentaiTagScope(
        terms: nhentaiTerms,
        child: Column(
          children: [
            Expanded(
              child: _CategoryComicsList(
                key: ValueKey(
                    "${widget.category} with $param and $optionsValue ${sourceKey == 'nhentai' ? NhentaiTagSettings.changes.value : ''}"),
                loader: data.load,
                category: widget.category,
                options: optionsValue,
                param: param,
                header: buildOptions(),
                sourceKey: sourceKey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildOptionItem(
      String text, String value, int group, BuildContext context) {
    return OptionChip(
      text: text,
      isSelected: value == optionsValue[group],
      onTap: () {
        if (value == optionsValue[group]) return;
        setState(() {
          optionsValue[group] = value;
        });
      },
    );
  }

  Widget buildOptions() {
    List<Widget> children = [];
    for (var optionList in options) {
      children.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var option in optionList.options.entries)
            buildOptionItem(
              option.value.tl,
              option.key,
              options.indexOf(optionList),
              context,
            )
        ],
      ));
      if (options.last != optionList) {
        children.add(const SizedBox(height: 8));
      }
    }
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (nhentaiTerms.length > 1)
            NhentaiTagStackBar(
                terms: nhentaiTerms, onRemove: removeNhentaiTerm),
          ...children,
          const Divider(),
        ],
      ).paddingLeft(8).paddingRight(8),
    );
  }
}

class _CategoryComicsList extends ComicsPage<BaseComic> {
  const _CategoryComicsList({
    super.key,
    required this.loader,
    required this.category,
    required this.options,
    this.param,
    required this.header,
    required this.sourceKey,
  });

  final CategoryComicsLoader loader;

  final String category;

  final List<String> options;

  final String? param;

  @override
  final String sourceKey;

  @override
  final Widget header;

  @override
  Future<Res<List<BaseComic>>> getComics(int i) async {
    return await loader(category, param, options, i);
  }

  @override
  String? get tag => "$category with $param and $options";

  @override
  String? get title => null;
}
