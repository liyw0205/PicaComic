import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/nhentai_network/tag_query.dart';
import 'package:pica_comic/tools/tags_translation.dart';
import 'package:pica_comic/tools/translations.dart';

/// Carries only explicit tag filters through a listing's comic tiles.
class NhentaiTagScope extends InheritedWidget {
  const NhentaiTagScope({
    super.key,
    required this.terms,
    required super.child,
  });

  final List<NhentaiTagTerm> terms;

  static List<NhentaiTagTerm> termsOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NhentaiTagScope>()?.terms ??
      const [];

  @override
  bool updateShouldNotify(NhentaiTagScope oldWidget) =>
      oldWidget.terms != terms;
}

class NhentaiTagStackBar extends StatelessWidget {
  const NhentaiTagStackBar({
    super.key,
    required this.terms,
    required this.onRemove,
  });

  final List<NhentaiTagTerm> terms;
  final ValueChanged<NhentaiTagTerm> onRemove;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final term in terms)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Center(
                  child: Tooltip(
                    message: term.toQuery(),
                    child: InputChip(
                      label: Text(
                          '${term.exclude ? '-' : ''}${App.locale.languageCode == 'zh' ? term.value.translateTagsToCN : term.value}'),
                      visualDensity: VisualDensity.compact,
                      onDeleted: () => onRemove(term),
                      deleteButtonTooltipMessage: '移除'.tl,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}
