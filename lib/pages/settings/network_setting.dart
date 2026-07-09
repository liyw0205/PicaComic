part of pica_settings;

class NetworkSettings extends StatefulWidget {
  const NetworkSettings({super.key});

  @override
  State<NetworkSettings> createState() => _NetworkSettingsState();
}

class _NetworkSettingsState extends State<NetworkSettings> {
  String _formatProxyConfig(AppProxyConfig config) =>
      "${config.isSocks5 ? "SOCKS5" : "HTTP"} ${config.hostPort}";

  String _rememberedProxyText() {
    var config =
        AppProxyConfig.tryParse(appdata.settings[rememberedProxySettingIndex]);
    return config == null ? "" : " · ${"已记住".tl} ${_formatProxyConfig(config)}";
  }

  String _proxySubtitle() {
    var currentProxy = appdata.settings[networkProxySettingIndex].trim();
    if (currentProxy == "0") return "${"使用系统代理".tl}${_rememberedProxyText()}";
    if (currentProxy.isEmpty) return "${"禁用".tl}${_rememberedProxyText()}";
    var config = AppProxyConfig.tryParse(currentProxy);
    if (config == null) return currentProxy;
    return _formatProxyConfig(config);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text("网络代理".tl),
        ),
        ListTile(
          leading: const Icon(Icons.network_ping),
          title: Text("设置代理".tl),
          subtitle: Text(_proxySubtitle()),
          trailing: const Icon(
            Icons.arrow_right,
          ),
          onTap: () {
            setProxy(context).then((_) {
              if (mounted) setState(() {});
            });
          },
        ),
        ListTile(
          leading: const Icon(Icons.vpn_key),
          title: Text("VPN自动切换".tl),
          subtitle: Text("检测到 VPN 时自动关闭代理，断开后恢复".tl),
          trailing: Switch(
            value: appdata.settings[vpnAutoSwitchSettingIndex] == "1",
            onChanged: (value) {
              setState(() {
                appdata.settings[vpnAutoSwitchSettingIndex] = value ? "1" : "0";
              });
              appdata.updateSettings();
              setNetworkProxy();
            },
          ),
        ),
        ListTile(
          title: Row(
            children: [
              const Text("Hosts"),
              const SizedBox(
                width: 2,
              ),
              InkWell(
                borderRadius: const BorderRadius.all(Radius.circular(18)),
                onTap: () => showDialogMessage(
                  context,
                  "警告".tl,
                  "${"此功能已不再受支持".tl}\n${"请勿反馈相关问题".tl}"
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.red,
                  size: 18,
                ),
              )
            ]
          )
        ),
        ListTile(
          leading: const Icon(Icons.dns),
          title: Text("启用".tl),
          trailing: Switch(
            value: appdata.settings[58] == "1",
            onChanged: (value) {
              setState(() {
                appdata.settings[58] = value ? "1" : "0";
              });
              appdata.updateSettings();
              if (value) {
                HttpProxyServer.reload();
              }
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.rule),
          title: Text("规则".tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () {
            App.globalTo(() => const EditRuleView());
          },
        ),
        // ListTile(
        //   leading: const Icon(Icons.help),
        //   title: Text("帮助".tl),
        //   trailing: const Icon(Icons.arrow_right),
        //   onTap: (){
        //     launchUrlString("https://github.com/user/repo/blob/master/help.md");
        //   },
        // ),
        Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom))
      ],
    );
  }
}

class EditRuleView extends StatefulWidget {
  const EditRuleView({super.key});

  @override
  State<EditRuleView> createState() => _EditRuleViewState();
}

class _EditRuleViewState extends State<EditRuleView> {
  final file = File("${App.dataPath}/rule.json");

  late TextEditingController controller;

  @override
  void initState() {
    HttpProxyServer.createConfigFile();
    controller = TextEditingController(text: file.readAsStringSync());
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    file.writeAsStringSync(controller.text, mode: FileMode.writeOnly);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("rule.json"),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, MediaQuery.of(context).padding.bottom),
          child: TextField(
            keyboardType: TextInputType.multiline,
            maxLines: null,
            decoration: const InputDecoration(
                border: InputBorder.none
            ),
            controller: controller,
          ),
        )
      )
    );
  }
}
