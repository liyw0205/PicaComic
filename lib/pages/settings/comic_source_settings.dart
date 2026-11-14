part of pica_settings;

class ComicSourceSettings extends StatefulWidget {
  const ComicSourceSettings({super.key});

  @override
  State<ComicSourceSettings> createState() => _ComicSourceSettingsState();

  // static void checkCustomComicSourceUpdate([bool showLoading = false]) async {
  //   if (ComicSource.sources.isEmpty) {
  //     return;
  //   }
  //   var controller = showLoading ? showLoadingDialog(App.globalContext!) : null;
  //   var dio = logDio();
  //   var res = await dio.get<String>(
  //       "https://raw.githubusercontent.com/user/repo/master/index.json");
  //   if (res.statusCode != 200) {
  //     showToast(message: "网络错误".tl);
  //     return;
  //   }
  //   var list = jsonDecode(res.data!) as List;
  //   var versions = <String, String>{};
  //   for (var source in list) {
  //     versions[source['key']] = source['version'];
  //   }
  //   var shouldUpdate = <String>[];
  //   for (var source in ComicSource.sources) {
  //     if (versions.containsKey(source.key) &&
  //         versions[source.key] != source.version) {
  //       shouldUpdate.add(source.key);
  //     }
  //   }
  //   controller?.close();
  //   if (shouldUpdate.isEmpty) {
  //     return;
  //   }
  //   var msg = "";
  //   for (var key in shouldUpdate) {
  //     msg += "${ComicSource.find(key)?.name}: v${versions[key]}\n";
  //   }
  //   msg = msg.trim();
  //   showConfirmDialog(App.globalContext!, "有可用更新".tl, msg, () {
  //     for (var key in shouldUpdate) {
  //       var source = ComicSource.find(key);
  //       _ComicSourceSettingsState.update(source!);
  //     }
  //   });
  // }
}

extension _WidgetExt on Widget {
  Widget withDivider() {
    return Column(
      children: [
        this,
        const Divider(),
      ],
    );
  }
}

class _ComicSourceSettingsState extends State<ComicSourceSettings> {
  var url = "";

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        buildCard(context),
        const _BuiltInSources(),
        if (appdata.appSettings.isComicSourceEnabled("picacg"))
          const PicacgSettings(false).withDivider(),
        if (appdata.appSettings.isComicSourceEnabled("ehentai"))
          const EhSettings(false).withDivider(),
        if (appdata.appSettings.isComicSourceEnabled("nhentai"))
          const NhSettings(false).withDivider(),
        if (appdata.appSettings.isComicSourceEnabled("jm"))
          const JmSettings(false).withDivider(),
        if (appdata.appSettings.isComicSourceEnabled("hitomi"))
          const HitomiSettings(false).withDivider(),
        if (appdata.appSettings.isComicSourceEnabled("htmanga"))
          // const HtSettings(false).withDivider(),
          const HtSettings(false),
        // buildCustomSettings(),
        for (var source in ComicSource.sources.where((e) => !e.isBuiltIn))
          buildCustom(context, source),
        Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom))
      ],
    );
  }

  // Widget buildCustomSettings() {
  //   return Column(
  //     children: [
  //       ListTile(
  //         title: Text("自定义漫画源".tl),
  //       ),
  //       ListTile(
  //         leading: const Icon(Icons.update_outlined),
  //         title: Text("检查更新".tl),
  //         onTap: () => ComicSourceSettings.checkCustomComicSourceUpdate(true),
  //         trailing: const Icon(Icons.arrow_right),
  //       ),
  //       SwitchSetting(
  //         title: "启动时检查更新".tl,
  //         icon: const Icon(Icons.security_update),
  //         settingsIndex: 80,
  //       )
  //     ],
  //   );
  // }

  Widget buildCustom(BuildContext context, ComicSource source) {
    return Column(
      children: [
        const Divider(),
        ListTile(
          title: Text(source.name),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (App.isDesktop)
                Tooltip(
                  message: "Edit",
                  child: IconButton(
                      onPressed: () {
                        unawaited(edit(source));
                      },
                      icon: const Icon(Icons.edit_note)),
                ),
              Tooltip(
                message: "Update",
                child: IconButton(
                    onPressed: () {
                      unawaited(update(source));
                    },
                    icon: const Icon(Icons.update)),
              ),
              Tooltip(
                message: "Delete",
                child: IconButton(
                    onPressed: () {
                      unawaited(delete(source));
                    },
                    icon: const Icon(Icons.delete)),
              ),
            ],
          ),
        ),
        ListTile(
          title: const Text("Version"),
          subtitle: Text(source.version),
        )
      ],
    );
  }

  Future<void> delete(ComicSource source) {
    showConfirmDialog(App.globalContext!, "删除".tl, "要删除此漫画源吗?".tl, () {
      unawaited(() async {
        try {
          final file = File(source.filePath);
          if (await file.exists()) {
            await file.delete();
          }
          ComicSource.sources.remove(source);
          await _validatePages();
          MyApp.updater?.call();
        } catch (e) {
          showToast(message: e.toString());
        }
      }());
    });
    return Future.value();
  }

  Future<void> edit(ComicSource source) async {
    try {
      await Process.run("code", [source.filePath], runInShell: true);
      await showDialog(
          context: App.globalContext!,
          builder: (context) => AlertDialog(
                title: const Text("Reload Configs"),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("cancel")),
                  TextButton(
                      onPressed: () {
                        unawaited(_reloadAfterEdit(context));
                      },
                      child: const Text("continue")),
                ],
              ));
    } catch (e) {
      showToast(message: "Failed to launch vscode");
    }
  }

  Future<void> _reloadAfterEdit(BuildContext dialogContext) async {
    try {
      await ComicSource.reload();
      MyApp.updater?.call();
      if (dialogContext.mounted) Navigator.pop(dialogContext);
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  static Future<void> update(ComicSource source) async {
    if (!source.url.isURL) {
      showToast(message: "Invalid url config");
      return;
    }
    final sourceIndex = ComicSource.sources.indexOf(source);
    ComicSource.sources.remove(source);
    bool cancel = false;
    var updated = false;
    var parseStarted = false;
    var controller = showLoadingDialog(App.globalContext!,
        onCancel: () => cancel = true, barrierDismissible: false);
    try {
      var res = await logDio().get<String>(source.url,
          options: Options(responseType: ResponseType.plain));
      final data = res.data;
      if (cancel) {
        // The finally block restores the source in the in-memory list.
      } else if (data == null) {
        throw StateError("Comic source response is empty");
      } else {
        parseStarted = true;
        await ComicSourceParser().parse(data, source.filePath);
        await writeTextFileAtomically(File(source.filePath), data);
        updated = true;
      }
    } catch (e) {
      if (!cancel) showToast(message: e.toString());
    } finally {
      controller.close();
    }
    if (!updated || cancel) {
      if (parseStarted) {
        try {
          // Parsing installs a temporary JS source before the file replacement;
          // reload to discard it when validation or persistence fails.
          await ComicSource.reload();
          MyApp.updater?.call();
          return;
        } catch (e) {
          showToast(message: e.toString());
        }
      }
      if (!ComicSource.sources.contains(source)) {
        final index =
            sourceIndex < 0 || sourceIndex > ComicSource.sources.length
                ? ComicSource.sources.length
                : sourceIndex;
        ComicSource.sources.insert(index, source);
      }
      return;
    }
    try {
      await ComicSource.reload();
      MyApp.updater?.call();
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  Widget buildCard(BuildContext context) {
    return Card.outlined(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Row(children: [
                Text("添加漫画源".tl),
                const SizedBox(
                  width: 2,
                ),
                InkWell(
                  borderRadius: const BorderRadius.all(Radius.circular(18)),
                  onTap: () => showDialogMessage(
                      context, "警告".tl, "${"此功能已不再受支持".tl}\n${"请勿反馈相关问题".tl}"),
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.red,
                    size: 18,
                  ),
                )
              ]),
              leading: const Icon(Icons.dashboard_customize),
            ),
            TextField(
                decoration: InputDecoration(
                    hintText: "URL",
                    border: const UnderlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    suffix: IconButton(
                        onPressed: () {
                          unawaited(handleAddSource(url));
                        },
                        icon: const Icon(Icons.check))),
                onChanged: (value) {
                  url = value;
                },
                onSubmitted: (value) {
                  unawaited(handleAddSource(value));
                }).paddingHorizontal(16).paddingBottom(32),
            Row(
              children: [
                const Spacer(),
                TextButton(
                        onPressed: () {
                          unawaited(chooseFile());
                        },
                        child: Text("选择文件".tl))
                    .paddingLeft(8),
                const Spacer(),
                TextButton(
                    onPressed: () {
                      showPopUpWidget(
                          context, _ComicSourceList(handleAddSource));
                    },
                    child: Text("浏览列表".tl)),
                const Spacer(),
                // TextButton(onPressed: help, child: Text("查看帮助".tl))
                //     .paddingRight(8),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ).paddingHorizontal(12);
  }

  Future<void> chooseFile() async {
    const XTypeGroup typeGroup = XTypeGroup(
      extensions: <String>['js'],
    );
    final XFile? file =
        await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file == null) return;
    try {
      var fileName = file.name;
      // file.readAsString 会导致中文乱码
      var bytes = await file.readAsBytes();
      var content = utf8.decode(bytes);
      await addSource(content, fileName);
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  // void help() {
  //   launchUrlString(
  //       "https://github.com/user/repo/blob/master/help.md");
  // }

  Future<void> handleAddSource(String url) async {
    if (url.isEmpty) {
      return;
    }
    var splits = url.split("/");
    splits.removeWhere((element) => element == "");
    var fileName = splits.last;
    bool cancel = false;
    var controller = showLoadingDialog(App.globalContext!,
        onCancel: () => cancel = true, barrierDismissible: false);
    try {
      var res = await logDio()
          .get<String>(url, options: Options(responseType: ResponseType.plain));
      if (cancel) return;
      final data = res.data;
      if (data == null) {
        throw StateError("Comic source response is empty");
      }
      await addSource(data, fileName);
    } catch (e) {
      if (cancel) return;
      showToast(message: e.toString());
    } finally {
      controller.close();
    }
  }

  Future<void> addSource(String js, String fileName) async {
    var comicSource = await ComicSourceParser().createAndParse(js, fileName);
    ComicSource.sources.add(comicSource);
    await _addAllPagesWithComicSource(comicSource);
    await appdata.updateSettings();
    MyApp.updater?.call();
  }
}

class _ComicSourceList extends StatefulWidget {
  const _ComicSourceList(this.onAdd);

  final Future<void> Function(String) onAdd;

  @override
  State<_ComicSourceList> createState() => _ComicSourceListState();
}

class _ComicSourceListState extends State<_ComicSourceList> {
  bool loading = true;
  List? json;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      var dio = logDio();
      var res = await dio.get<String>(
          "https://raw.githubusercontent.com/wgh136/pica_configs/master/index.json");
      if (res.statusCode != 200 || res.data == null) {
        throw StateError("Network error");
      }
      if (!mounted) return;
      setState(() {
        json = jsonDecode(res.data!);
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("漫画源".tl),
        actions: const [
          IconButton(onPressed: App.globalBack, icon: Icon(Icons.close)),
        ],
      ),
      body: buildBody(),
    );
  }

  Widget buildBody() {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return Center(child: Text(error!));
    } else {
      var currentKey = ComicSource.sources.map((e) => e.key).toList();
      return ListView.builder(
        itemCount: json!.length,
        itemBuilder: (context, index) {
          var key = json![index]["key"];
          var action = currentKey.contains(key)
              ? const Icon(Icons.check)
              : Tooltip(
                  message: "Add",
                  child: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      unawaited(_addSource(index));
                    },
                  ),
                );

          return ListTile(
            title: Text(json![index]["name"]),
            subtitle: Text(json![index]["version"]),
            trailing: action,
          );
        },
      );
    }
  }

  Future<void> _addSource(int index) async {
    try {
      await widget.onAdd(
          "https://raw.githubusercontent.com/wgh136/pica_configs/master/${json![index]["fileName"]}");
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showToast(message: e.toString());
    }
  }
}

class _BuiltInSources extends StatefulWidget {
  const _BuiltInSources();

  @override
  State<_BuiltInSources> createState() => _BuiltInSourcesState();
}

class _BuiltInSourcesState extends State<_BuiltInSources> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Divider(),
        ListTile(
          title: Text("内置漫画源".tl),
        ),
        for (int index = 0; index < builtInSources.length; index++)
          buildTile(index),
        const Divider(),
      ],
    );
  }

  bool isLoading = false;

  Widget buildTile(int index) {
    var key = builtInSources[index];
    return ListTile(
      title: Text(ComicSource.builtIn.firstWhere((e) => e.key == key).name.tl),
      trailing: Switch(
        value: appdata.appSettings.isComicSourceEnabled(key),
        onChanged: (v) {
          unawaited(_setSourceEnabled(key, v));
        },
      ),
    );
  }

  Future<void> _setSourceEnabled(String key, bool enabled) async {
    if (isLoading) return;
    isLoading = true;
    try {
      appdata.appSettings.setComicSourceEnabled(key, enabled);
      await appdata.updateSettings();
      if (!enabled) {
        ComicSource.sources.removeWhere((e) => e.key == key);
        await _validatePages();
      } else {
        var source = ComicSource.builtIn.firstWhere((e) => e.key == key);
        ComicSource.sources.add(source);
        await source.loadData();
        await _addAllPagesWithComicSource(source);
      }
      if (mounted) {
        setState(() {});
        context
            .findAncestorStateOfType<_ComicSourceSettingsState>()
            ?.setState(() {});
      }
    } catch (e) {
      if (mounted) showToast(message: e.toString());
    } finally {
      isLoading = false;
    }
  }
}

Future<void> _validatePages() async {
  var explorePages = appdata.appSettings.explorePages;
  var categoryPages = appdata.appSettings.categoryPages;
  var networkFavorites = appdata.appSettings.networkFavorites;

  var totalExplorePages = ComicSource.sources
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.sources
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.sources
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.appSettings.explorePages = explorePages;
  appdata.appSettings.categoryPages = categoryPages;
  appdata.appSettings.networkFavorites = networkFavorites;

  await appdata.updateSettings();
}

Future<void> _addAllPagesWithComicSource(ComicSource source) async {
  var explorePages = appdata.appSettings.explorePages;
  var categoryPages = appdata.appSettings.categoryPages;
  var networkFavorites = appdata.appSettings.networkFavorites;

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }

  appdata.appSettings.explorePages = explorePages.toSet().toList();
  appdata.appSettings.categoryPages = categoryPages.toSet().toList();
  appdata.appSettings.networkFavorites = networkFavorites.toSet().toList();

  await appdata.updateSettings();
}
