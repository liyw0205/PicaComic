part of pica_settings;

class SetJmComicsOrderController extends StateController {
  int settingsOrder;
  SetJmComicsOrderController(this.settingsOrder);
  late String value = appdata.settings[settingsOrder];

  void set(String v) {
    value = v;
    appdata.settings[settingsOrder] = v;
    appdata.writeData();
    App.globalBack();
  }
}

class JmSettings extends StatefulWidget {
  const JmSettings(this.popUp, {Key? key}) : super(key: key);
  final bool popUp;

  @override
  State<JmSettings> createState() => _JmSettingsState();

  static Future<void> daily([bool showLoading = false]) async {
    if (!jm.isLogin && showLoading) {
      showToast(message: "未登录".tl);
      return;
    }
    final context = App.globalContext;
    if (showLoading && (context == null || !context.mounted)) return;
    var controller = showLoading ? showLoadingDialog(context!) : null;
    final Res<bool> res;
    try {
      res = await JmNetwork().dailyChk();
    } finally {
      controller?.close();
    }
    var title = res.success ? "签到成功".tl : "签到失败".tl;
    var msg = res.success ? "${res.subData}".tl : res.errorMessage;
    if (showLoading && context != null && context.mounted) {
      showDialogMessage(context, title, msg!);
    }
  }

  static Future<void> updateAppVersionCode() async {
    var res = await JmNetwork().getAppVersionCode();
    if (!res.error) {
      appdata.settings[89] = res.data;
      await appdata.updateSettings();
    }
  }
}

class _JmSettingsState extends State<JmSettings> {
  bool autoSelectStream = appdata.settings[15] == "1";
  bool autoCheckIn = appdata.settings[88] == "1";
  bool _updatingDomains = false;

  Future<void> _updateApiDomains() async {
    if (_updatingDomains) return;
    setState(() => _updatingDomains = true);
    final network = JmNetwork();
    final ownerRoute = ModalRoute.of(context);
    final controller = showLoadingDialog(context);
    var dismissed = false;
    try {
      Res<dynamic> res;
      try {
        res = await network.getApiDomains();
      } catch (error, stack) {
        Log.error(
            'JM',
            'Failed to discover API domains: '
                '${safeNetworkError(error)}\n$stack');
        res = const Res.error('Failed to get JM api domains');
      } finally {
        dismissed = controller.closed;
        controller.close();
      }
      if (!mounted || ownerRoute?.isActive == false || dismissed) return;
      final domains = List<String>.of(res.error
          ? JmNetwork.builtInApiDomains
          : List<String>.from(res.data));
      final message = [
        if (res.error) "使用内置域名:".tl,
        for (var i = 0; i < domains.length; i++)
          '${"域名".tl}${i + 1}: ${domains[i]}',
      ].join('\n');
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(res.error ? "更新失败".tl : "更新成功".tl),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text("取消".tl),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text("确认".tl),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || ownerRoute?.isActive == false) {
        return;
      }
      final oldDomains = appdata.settings[85];
      final oldIndex = appdata.settings[17];
      appdata.appSettings.jmApiDomains = domains;
      final index = int.tryParse(oldIndex) ?? 0;
      if (index < 0 || index >= domains.length) appdata.settings[17] = "0";
      try {
        await appdata.updateSettings();
      } catch (error, stack) {
        appdata.settings[85] = oldDomains;
        appdata.settings[17] = oldIndex;
        Log.error(
            'JM',
            'Failed to save API domains: '
                '${safeNetworkError(error)}\n$stack');
        if (mounted && ownerRoute?.isActive != false) {
          showDialogMessage(context, "保存失败".tl, "操作失败".tl);
        }
        return;
      }
      if (mounted) setState(() {});
      try {
        await JmSettings.updateAppVersionCode();
        await network.loginFromAppdata();
      } catch (error, stack) {
        Log.error(
            'JM',
            'Failed to refresh JM after saving API domains: '
                '${safeNetworkError(error)}\n$stack');
      }
    } finally {
      if (mounted) setState(() => _updatingDomains = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    var apiDomains = appdata.appSettings.jmApiDomains;
    if (apiDomains.isEmpty) {
      apiDomains = JmNetwork.builtInApiDomains;
    }
    var apiDomainIndex = int.tryParse(appdata.settings[17]) ?? 0;
    if (apiDomainIndex < 0 || apiDomainIndex >= apiDomains.length) {
      apiDomainIndex = 0;
    }

    return Column(
      children: [
        ListTile(
          title: Text("禁漫天堂".tl),
        ),
        ListTile(
          leading: const Icon(Icons.track_changes),
          title: Text("自动选择域名".tl),
          subtitle: Text("登录时自动选择API域名".tl),
          trailing: Switch(
            value: autoSelectStream,
            onChanged: (b) {
              b ? appdata.settings[15] = "1" : appdata.settings[15] = "0";
              setState(() {
                autoSelectStream = b;
              });
              appdata.updateSettings();
              if (autoSelectStream) JmNetwork().loginFromAppdata();
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.dns),
          title: Text("API域名".tl),
          trailing: IgnorePointer(
            ignoring: autoSelectStream,
            child: Opacity(
              opacity: !autoSelectStream ? 1.0 : 0.5,
              child: Select(
                initialValue: apiDomainIndex,
                values: List.generate(
                  apiDomains.length,
                  (i) => "${"分流".tl}${i + 1}",
                ),
                onChange: (i) {
                  appdata.settings[17] = i.toString();
                  appdata.updateSettings();
                  JmNetwork().loginFromAppdata();
                },
              ),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text("图片分流".tl),
          trailing: Select(
            initialValue: int.parse(appdata.appSettings.jmImgUrlIndex),
            values: List.generate(
              JmNetwork.builtInImgUrls.length,
              (i) => "${"分流".tl}${i + 1}",
            ),
            onChange: (i) {
              appdata.settings[37] = i.toString();
              appdata.updateSettings();
              if (jm.isLogin) JmNetwork().updateImgUrl(i + 1);
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.favorite_border),
          title: Text("收藏夹漫画排序模式".tl),
          trailing: Select(
            initialValue: int.parse(appdata.settings[42]),
            width: App.locale.languageCode == "en" ? 130 : 120,
            values: ["最新收藏".tl, "最新更新".tl],
            onChange: (i) {
              appdata.settings[42] = i.toString();
              appdata.updateSettings();
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.update_outlined),
          title: Text("更新API域名".tl),
          onTap: _updatingDomains ? null : () => unawaited(_updateApiDomains()),
          trailing: const Icon(Icons.arrow_right),
        ),
        ListTile(
          leading: const Icon(Icons.today),
          title: Text("自动签到".tl),
          subtitle: Text("勾选启用, 点击测试".tl),
          onTap: () => unawaited(JmSettings.daily(true)),
          trailing: Switch(
            value: autoCheckIn,
            onChanged: (b) {
              b ? appdata.settings[88] = "1" : appdata.settings[88] = "0";
              setState(() {
                autoCheckIn = b;
              });
              appdata.updateSettings();
              if (autoCheckIn && jm.isLogin) {
                unawaited(JmSettings.daily(false));
              }
            },
          ),
        ),
      ],
    );
  }
}
