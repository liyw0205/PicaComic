part of pica_settings;

class NhSettings extends StatefulWidget {
  const NhSettings(this.popUp, {super.key});

  final bool popUp;

  @override
  State<NhSettings> createState() => _NhSettingsState();
}

class _NhSettingsState extends State<NhSettings> {
  String baseUrl = "https://nhentai.net";

  Future<void> editDefaultExcludes() async {
    final initialValue = NhentaiTagSettings.defaultExcludes.toQuery();
    var value = initialValue;
    String? error;
    var saving = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('默认排除标签'.tl),
          content: TextFormField(
            initialValue: initialValue,
            onChanged: (text) => value = text,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            enabled: !saving,
            decoration: InputDecoration(
              hintText: '-tag:"yaoi" -artist:"name"',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context),
              child: Text('取消'.tl),
            ),
            TextButton(
              onPressed: saving
                  ? null
                  : () async {
                      final query = NhentaiTagQuery.parse(value.trim());
                      if (query.text.isNotEmpty) {
                        setDialogState(() => error = '标签格式无效'.tl);
                        return;
                      }
                      setDialogState(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await NhentaiTagSettings.setDefaultExcludes(
                            query.terms);
                        if (context.mounted) Navigator.pop(context);
                      } catch (_) {
                        if (context.mounted) {
                          setDialogState(() {
                            saving = false;
                            error = '保存失败'.tl;
                          });
                        }
                      }
                    },
              child: Text('确认'.tl),
            ),
          ],
        ),
      ),
    );
  }

  void deleteAllCookie() {
    final cookieJar = SingleInstanceCookieJar.instance!;
    var cookies = cookieJar.loadForRequest(Uri.parse(baseUrl));
    if (cookies.isEmpty) {
      showToast(message: "cookie 为空".tl);
      return;
    } else {
      var title = "${"确认删除".tl}?";
      var msg =
          "${"删除全部".tl}(${cookies.length}) nhentai cookie\n${"删除后需重新登录".tl}\n";
      showConfirmDialog(App.globalContext!, title, msg, () async {
        NhentaiNetwork().logged = false;
        cookieJar.deleteUri(Uri.parse(baseUrl));
        var source = ComicSource.find('nhentai')!;
        source.data["account"] = null;
        await source.saveData();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: Text("nhentai".tl),
        ),
        ValueListenableBuilder(
          valueListenable: NhentaiTagSettings.changes,
          builder: (context, _, __) => SwitchListTile(
            secondary: const Icon(Icons.layers_outlined),
            title: Text('点标签时叠加到当前标签'.tl),
            value: NhentaiTagSettings.stackEnabled,
            onChanged: NhentaiTagSettings.setStackEnabled,
          ),
        ),
        ValueListenableBuilder(
          valueListenable: NhentaiTagSettings.changes,
          builder: (context, _, __) => ListTile(
            leading: const Icon(Icons.filter_alt_off_outlined),
            title: Text('默认排除标签'.tl),
            subtitle: NhentaiTagSettings.defaultExcludes.isEmpty
                ? null
                : Text(NhentaiTagSettings.defaultExcludes.toQuery(),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.edit_outlined),
            onTap: editDefaultExcludes,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.delete_forever),
          title: Text("${"删除".tl} cookie"),
          onTap: () => deleteAllCookie(),
          trailing: const Icon(Icons.arrow_right),
        )
      ],
    );
  }
}
