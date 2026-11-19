import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/foundation/ui_mode.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/components/components.dart';
import '../../foundation/app.dart';
import '../../foundation/local_favorites.dart';
import 'local_favorites.dart';

class LocalSearchPage extends StatefulWidget {
  /// Search page for local favorites
  const LocalSearchPage({super.key});

  @override
  State<LocalSearchPage> createState() => _LocalSearchPageState();
}

class _LocalSearchPageState extends StateWithController<LocalSearchPage> {
  var comics = <FavoriteItemWithFolderInfo>[];

  String keyword = "";

  final controller = TextEditingController();

  final _focusNode = FocusNode();

  void search() {
    if (keyword.isEmpty) {
      comics = [];
    } else {
      comics = LocalFavoritesManager().search(keyword);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void createFolder() {
    final manager = LocalFavoritesManager();
    final results = comics
        .map((item) => FavoriteItem.fromJson(item.comic.toJson()))
        .toList();
    unawaited(showDialog<void>(
      context: context,
      builder: (_) => _SearchFolderDialog(
        onCreate: () => manager.createFolderAndSave('search result',
            comics: results, renameWhenInvalidName: true),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    search();
    return Material(
      child: Column(
        children: [
          SizedBox(
            height:
                UiMode.m1(context) ? MediaQuery.of(context).padding.top : null,
          ),
          Container(
            height: 56,
            width: double.infinity,
            decoration: BoxDecoration(
                border: Border(
                    bottom: BorderSide(
                        color: Theme.of(context).colorScheme.outline,
                        width: 0.8))),
            child: Row(
              children: [
                Tooltip(
                  message: "Back",
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_sharp),
                    onPressed: () {
                      App.back(context);
                    },
                  ),
                ),
                Expanded(
                  child: TextField(
                    autofocus: true,
                    focusNode: _focusNode,
                    controller: controller,
                    decoration: const InputDecoration(
                        border: InputBorder.none, hintText: "Search"),
                    onSubmitted: (s) => search(),
                    onChanged: (s) => setState(() {
                      keyword = s;
                    }),
                  ),
                ),
                if (keyword.isNotEmpty)
                  Tooltip(
                    message: "clear",
                    child: IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        controller.clear();
                        setState(() {
                          keyword = "";
                        });
                      },
                    ),
                  ),
                if (comics.isNotEmpty)
                  Tooltip(
                    message: "create folder",
                    child: IconButton(
                      icon: const Icon(Icons.create_new_folder_outlined),
                      onPressed: createFolder,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              primary: false,
              gridDelegate: SliverGridDelegateWithComics(),
              itemCount: comics.length,
              padding: EdgeInsets.zero,
              itemBuilder: (BuildContext context, int index) {
                return LocalFavoriteTile(
                  comics[index].comic,
                  comics[index].folder,
                  () => setState(() {}),
                  true,
                  showFolderInfo: true,
                );
              },
            ),
          )
        ],
      ),
    );
  }

  @override
  Object? get tag => "local_search_page";
}

class _SearchFolderDialog extends StatefulWidget {
  const _SearchFolderDialog({required this.onCreate});

  final Future<String> Function() onCreate;

  @override
  State<_SearchFolderDialog> createState() => _SearchFolderDialogState();
}

class _SearchFolderDialogState extends State<_SearchFolderDialog> {
  bool _saving = false;
  bool _failed = false;

  Future<void> _submit() async {
    if (_saving) return;
    final route = ModalRoute.of(context)!;
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.onCreate();
    } catch (error, stack) {
      log('Failed to save favorite search results.\n${safeNetworkError(error)}\n$stack',
          'Favorite', LogLevel.error);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failed = true;
      });
      return;
    }
    if (!mounted) return;
    if (route.isCurrent) {
      navigator.pop();
    } else if (route.isActive) {
      navigator.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('创建收藏夹'.tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('从当前的搜索结果创建新的收藏夹'.tl),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('操作失败'.tl,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: _saving ? null : () => unawaited(_submit()),
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('确认'.tl),
          ),
        ],
      ),
    );
  }
}
