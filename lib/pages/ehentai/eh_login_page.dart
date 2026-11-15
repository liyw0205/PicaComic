import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebViewController;
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/pages/ehentai/eh_user_cookie_parser.dart';
import 'package:pica_comic/pages/webview.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../foundation/app.dart';
import '../../network/eh_network/eh_main_network.dart';

class EhLoginPage extends StatefulWidget {
  const EhLoginPage({Key? key}) : super(key: key);

  @override
  State<EhLoginPage> createState() => _EhLoginPageState();
}

class _EhLoginPageState extends State<EhLoginPage> {
  final c1 = TextEditingController();
  final c2 = TextEditingController();
  final c3 = TextEditingController();
  final c4 = TextEditingController();
  bool logging = false;
  late EhUserCookieParserController cookieParserController;
  bool _mobileWebviewOpen = false;
  bool _webviewCookieCaptureInFlight = false;
  DesktopWebview? _desktopWebview;

  @override
  void initState() {
    super.initState();
    cookieParserController = EhUserCookieParserController();
  }

  @override
  void dispose() {
    _desktopWebview?.close();
    _desktopWebview = null;
    c1.dispose();
    c2.dispose();
    c3.dispose();
    c4.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("登录".tl),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Center(
              child: SizedBox(
                width: 400,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "Cookies",
                      style: TextStyle(fontSize: 18),
                    ).paddingLeft(6),
                    const SizedBox(
                      height: 8,
                    ),
                    Padding(
                      padding: const EdgeInsets.all(5),
                      child: TextField(
                        controller: c1,
                        decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: "ipb_member_id"),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(5),
                      child: TextField(
                        controller: c2,
                        decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: "ipb_pass_hash"),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(5),
                      child: TextField(
                        controller: c3,
                        decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            labelText: "igneous(非必要)".tl),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(5),
                      child: TextField(
                        controller: c4,
                        decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            labelText: "star(非必要)".tl),
                      ),
                    ),
                    EhUserCookieParser(
                      controller: cookieParserController,
                    ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 500),
                      switchInCurve: Curves.easeInOut,
                      switchOutCurve: Curves.easeInOut,
                      child: cookieParserController.visible
                          ? _buildCookieParserButtonGroup(
                              cookieParserController)
                          : TextButton(
                              onPressed: () {
                                if (cookieParserController.visible) return;
                                cookieParserController.show();
                                setState(() {});
                              },
                              child: Text('通过 cookie 身份信息快速填写'.tl),
                            ),
                    ),
                    const SizedBox(
                      height: 8,
                    ),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                        child: !logging
                            ? FilledButton(
                                child: Text("登录".tl),
                                onPressed: () {
                                  if (c1.text == "" || c2.text == "") {
                                    showToast(message: "请填写完整".tl);
                                  } else {
                                    login(c1.text, c2.text, c3.text, c4.text);
                                  }
                                },
                              )
                            : const CircularProgressIndicator(),
                      ),
                    ),
                    const SizedBox(
                      height: 10,
                    ),
                    Center(
                      child: SizedBox(
                        height: 40,
                        child: TextButton(
                          onPressed: loginWithWebview,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text("在Webview中登录".tl),
                              const Icon(
                                Icons.arrow_outward,
                                size: 15,
                              )
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(
                      height: 5,
                    ),
                    Center(
                      child: SizedBox(
                        height: 40,
                        child: TextButton(
                          onPressed: () => launchUrlString(
                              "https://forums.e-hentai.org/index.php?act=Reg&CODE=00",
                              mode: LaunchMode.externalApplication),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text("注册".tl),
                              const Icon(
                                Icons.arrow_outward,
                                size: 15,
                              )
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  Row _buildCookieParserButtonGroup(
      EhUserCookieParserController cookieParserController) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Button.text(
          onPressed: () {
            cookieParserController.hide();
            setState(() {});
          },
          child: Text('隐藏'.tl),
        ),
        const SizedBox(width: 16),
        Button.outlined(
          onPressed: () {
            final cookieMap = cookieParserController.parse();
            setState(() {
              c1.text = cookieMap['ipb_member_id'] ?? '';
              c2.text = cookieMap['ipb_pass_hash'] ?? '';
              c3.text = cookieMap['igneous'] ?? '';
              c4.text = cookieMap['star'] ?? '';
            });
          },
          child: Text('解析'.tl),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  void loginWithWebview() {
    unawaited(_loginWithWebview());
  }

  Future<void> _loginWithWebview() async {
    if (!mounted || logging) return;
    if (App.isMobile) {
      if (_mobileWebviewOpen) return;
      _mobileWebviewOpen = true;
      try {
        await App.globalTo(() => AppWebview(
              singlePage: true,
              initialUrl:
                  "https://forums.e-hentai.org/index.php?act=Login&CODE=00",
              onTitleChange: (title, controller) {
                unawaited(_handleMobileWebviewTitle(title, controller));
              },
            ));
      } catch (error, stack) {
        _logLoginError("Failed to open mobile login webview", error, stack);
      } finally {
        _mobileWebviewOpen = false;
      }
    } else if (App.isDesktop) {
      if (_desktopWebview != null) return;
      try {
        if (!await DesktopWebview.isAvailable()) {
          if (mounted) showToast(message: "Unsupported device".tl);
          return;
        }
        if (!mounted || _desktopWebview != null) return;
        late final DesktopWebview webview;
        webview = DesktopWebview(
          initialUrl: "https://forums.e-hentai.org/index.php?act=Login&CODE=00",
          onClose: () {
            if (identical(_desktopWebview, webview)) {
              _desktopWebview = null;
            }
          },
          onTitleChange: (url, controller) {
            if (url == "E-Hentai Forums") {
              unawaited(_handleDesktopWebviewTitle(controller));
            }
          },
        );
        _desktopWebview = webview;
        await webview.open();
      } catch (error, stack) {
        _logLoginError("Failed to open desktop login webview", error, stack);
        final webview = _desktopWebview;
        _desktopWebview = null;
        webview?.close();
      }
    } else {
      if (mounted) {
        showToast(message: "Unsupported device".tl);
      }
    }
  }

  Future<void> _handleMobileWebviewTitle(
      String title, InAppWebViewController controller) async {
    if (title != "E-Hentai Forums" ||
        !mounted ||
        logging ||
        _webviewCookieCaptureInFlight) {
      return;
    }
    _webviewCookieCaptureInFlight = true;
    try {
      String? userAgent;
      try {
        userAgent = await controller.getUA();
      } catch (error, stack) {
        _logLoginError(
            "Failed to read mobile webview user agent", error, stack);
      }
      await _saveWebviewUserAgent(userAgent);
      if (!mounted) return;
      final cookies = await _collectWebviewCookies(
        () => controller.getCookies("https://e-hentai.org"),
        () => controller.getCookies("https://exhentai.org"),
      );
      if (!mounted) return;
      loginWithCookies(cookies);
      _closeMobileWebview();
    } catch (error, stack) {
      _logLoginError("Failed to read mobile login cookies", error, stack);
      if (mounted) showToast(message: "登录失败".tl);
    } finally {
      _webviewCookieCaptureInFlight = false;
    }
  }

  Future<void> _handleDesktopWebviewTitle(DesktopWebview webview) async {
    if (!mounted ||
        logging ||
        _webviewCookieCaptureInFlight ||
        !identical(_desktopWebview, webview)) {
      return;
    }
    _webviewCookieCaptureInFlight = true;
    try {
      await _saveWebviewUserAgent(webview.userAgent);
      if (!mounted) return;
      final cookies = await _collectWebviewCookies(
        () => webview.getCookies("https://e-hentai.org"),
        () => webview.getCookies("https://exhentai.org"),
      );
      if (!mounted) return;
      webview.close();
      loginWithCookies(cookies);
    } catch (error, stack) {
      _logLoginError("Failed to read desktop login cookies", error, stack);
      if (mounted) showToast(message: "登录失败".tl);
    } finally {
      _webviewCookieCaptureInFlight = false;
      if (identical(_desktopWebview, webview)) {
        webview.close();
      }
    }
  }

  Future<Map<String, String>> _collectWebviewCookies(
      Future<Map<String, String>?> Function() loadEh,
      Future<Map<String, String>?> Function() loadExh) async {
    final cookies = <String, String>{};
    final results = await Future.wait([loadEh(), loadExh()]);
    for (final result in results) {
      if (result != null) cookies.addAll(result);
    }
    return cookies;
  }

  Future<void> _saveWebviewUserAgent(String? userAgent) async {
    if (userAgent == null || userAgent.isEmpty) return;
    appdata.implicitData[3] = userAgent;
    try {
      await appdata.writeImplicitData();
    } catch (error, stack) {
      _logLoginError("Failed to persist webview user agent", error, stack);
    }
  }

  void _closeMobileWebview() {
    try {
      if (App.globalContext?.mounted == true) App.globalBack();
    } catch (error, stack) {
      _logLoginError("Failed to close mobile login webview", error, stack);
    }
  }

  void _logLoginError(String message, Object error, StackTrace stack) {
    LogManager.addLog(
      LogLevel.error,
      "EH Login",
      "$message: ${safeNetworkError(error)}\n$stack",
    );
  }

  void login(String id, String hash, String igneous, String star) {
    loginWithCookies({
      "ipb_member_id": id,
      "ipb_pass_hash": hash,
      if (igneous != "") "igneous": igneous,
      if (star != "") "star": star,
    });
  }

  void loginWithCookies(Map<String, String> cookiesMap) {
    unawaited(_loginWithCookies(cookiesMap));
  }

  Future<void> _loginWithCookies(Map<String, String> cookiesMap) async {
    if (!mounted || logging) return;
    setState(() => logging = true);
    EhNetwork? network;
    try {
      network = EhNetwork();
      _clearEhCookies(network);
      final cookies = cookiesMap.entries
          .map((entry) => Cookie(entry.key, entry.value))
          .toList(growable: false);
      final ehCookies = cookies
          .map((cookie) => cookie..domain = ".e-hentai.org")
          .toList(growable: false);
      final exhCookies = cookies
          .map((cookie) =>
              Cookie(cookie.name, cookie.value)..domain = ".exhentai.org")
          .toList(growable: false);
      network.cookieJar
          .saveFromResponse(Uri.parse("https://e-hentai.org"), ehCookies);
      network.cookieJar
          .saveFromResponse(Uri.parse("https://exhentai.org"), exhCookies);

      final valid = await network.validateCookies();
      if (!valid) {
        _clearEhCookies(network);
      }
      if (!mounted) return;
      if (valid) {
        context.pop();
        showToast(message: "登录成功".tl);
      } else {
        showToast(message: "登录失败".tl);
      }
    } catch (error, stack) {
      if (network != null) _clearEhCookies(network);
      _logLoginError("Failed to validate EH cookies", error, stack);
      if (mounted) showToast(message: "登录失败".tl);
    } finally {
      if (mounted) {
        setState(() => logging = false);
      }
    }
  }

  void _clearEhCookies(EhNetwork network) {
    try {
      network.cookieJar.deleteUri(Uri.parse('https://e-hentai.org'));
      network.cookieJar.deleteUri(Uri.parse('https://exhentai.org'));
    } catch (error, stack) {
      _logLoginError("Failed to clear EH cookies", error, stack);
    }
  }
}
