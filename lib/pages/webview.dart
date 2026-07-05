import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/ui_mode.dart';
import 'package:pica_comic/network/http_client.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:url_launcher/url_launcher_string.dart';

export 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show WebUri, URLRequest;

extension WebviewExtension on InAppWebViewController {
  String _normalizeCookieUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.isEmpty) {
      return "https://$url";
    }
    return uri.toString();
  }

  Future<List<Cookie>> getCookieList(String url) async {
    CookieManager cookieManager = CookieManager.instance();
    try {
      await cookieManager.flush();
    } catch (e) {
      debugPrint("[AppWebview] CookieManager.flush failed: $e");
    }
    return cookieManager.getCookies(
      url: WebUri(_normalizeCookieUrl(url)),
      webViewController: this,
    );
  }

  Future<Map<String, String>?> getCookies(String url) async {
    final cookies = await getCookieList(url);
    Map<String, String> res = {};
    for (var cookie in cookies) {
      res[cookie.name] = cookie.value.toString();
    }
    return res;
  }

  Future<String?> getUA() async {
    var res = await evaluateJavascript(source: "navigator.userAgent");
    if (res is String) {
      if (res.isNotEmpty && (res[0] == "'" || res[0] == "\"")) {
        res = res.substring(1, res.length - 1);
      }
    }
    return res is String ? res : null;
  }
}

class AppWebview extends StatefulWidget {
  const AppWebview(
      {required this.initialUrl,
      this.onTitleChange,
      this.onNavigation,
      this.singlePage = false,
      this.onStarted,
      this.onCookieLogin,
      this.onExtractCookie,
      super.key});

  final String initialUrl;

  final void Function(String title, InAppWebViewController controller)?
      onTitleChange;

  final bool Function(String url)? onNavigation;

  final void Function(InAppWebViewController controller)? onStarted;

  final void Function(BuildContext context, InAppWebViewController controller)?
      onCookieLogin;

  final void Function(BuildContext context, InAppWebViewController controller)?
      onExtractCookie;

  final bool singlePage;

  @override
  State<AppWebview> createState() => _AppWebviewState();
}

enum _AppWebviewMenuAction {
  openInBrowser,
  copyLink,
  reload,
  cookieLogin,
  extractCookie,
}

class _AppWebviewState extends State<AppWebview> {
  InAppWebViewController? controller;

  String title = "Webview";

  double _progress = 0;

  int _webviewKey = 0;

  @override
  Widget build(BuildContext context) {
    bool useCustomAppBar = !UiMode.m1(context) && !widget.singlePage;

    final actions = [
      Tooltip(
        message: "More",
        child: IconButton(
          icon: const Icon(Icons.more_horiz),
          onPressed: () async {
            final menuContext = context;
            final action = await showMenu<_AppWebviewMenuAction>(
                context: menuContext,
                position: RelativeRect.fromLTRB(
                    MediaQuery.of(menuContext).size.width,
                    0,
                    MediaQuery.of(menuContext).size.width,
                    0),
                items: [
                  PopupMenuItem(
                    value: _AppWebviewMenuAction.openInBrowser,
                    child: Text("在浏览器中打开".tl),
                  ),
                  PopupMenuItem(
                    value: _AppWebviewMenuAction.copyLink,
                    child: Text("复制链接".tl),
                  ),
                  PopupMenuItem(
                    value: _AppWebviewMenuAction.reload,
                    child: Text("重新加载".tl),
                  ),
                  if (widget.onCookieLogin != null)
                    PopupMenuItem(
                      value: _AppWebviewMenuAction.cookieLogin,
                      child: Text("Cookie 登录".tl),
                    ),
                  if (widget.onExtractCookie != null)
                    PopupMenuItem(
                      value: _AppWebviewMenuAction.extractCookie,
                      child: Text("提取 Cookie".tl),
                    ),
                ]);
            if (!menuContext.mounted || action == null) {
              return;
            }
            final webviewController = controller;
            debugPrint(
                "[AppWebview] menu action=$action controller=${webviewController != null}");
            if (webviewController == null) {
              showToast(message: "WebView 未就绪".tl);
              return;
            }
            switch (action) {
              case _AppWebviewMenuAction.openInBrowser:
                final url = (await webviewController.getUrl())?.toString();
                if (url != null) {
                  await launchUrlString(url);
                }
                break;
              case _AppWebviewMenuAction.copyLink:
                final url = (await webviewController.getUrl())?.toString();
                if (url != null) {
                  await Clipboard.setData(ClipboardData(text: url));
                }
                break;
              case _AppWebviewMenuAction.reload:
                webviewController.reload();
                break;
              case _AppWebviewMenuAction.cookieLogin:
                widget.onCookieLogin?.call(menuContext, webviewController);
                break;
              case _AppWebviewMenuAction.extractCookie:
                widget.onExtractCookie?.call(menuContext, webviewController);
                break;
            }
          },
        ),
      )
    ];

    Widget body = InAppWebView(
      key: ValueKey(_webviewKey),
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      initialSettings: InAppWebViewSettings(
        useHybridComposition: false,
        useOnRenderProcessGone: true,
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
      ),
      onTitleChanged: (c, t) {
        if (mounted) {
          setState(() {
            title = t ?? "Webview";
          });
        }
        final webviewController = controller;
        if (webviewController != null) {
          widget.onTitleChange?.call(title, webviewController);
        }
      },
      shouldOverrideUrlLoading: (c, r) async {
        var res =
            widget.onNavigation?.call(r.request.url?.toString() ?? "") ?? false;
        if (res) {
          return NavigationActionPolicy.CANCEL;
        } else {
          return NavigationActionPolicy.ALLOW;
        }
      },
      onWebViewCreated: (c) {
        controller = c;
        widget.onStarted?.call(c);
      },
      onRenderProcessGone: (c, detail) {
        if (!mounted) return;
        controller = null;
        showToast(message: "WebView 渲染进程已重启".tl);
        setState(() {
          _progress = 0;
          _webviewKey++;
        });
      },
      onProgressChanged: (c, p) {
        if (mounted) {
          setState(() {
            _progress = p / 100;
          });
        }
      },
    );

    body = Stack(
      children: [
        Positioned.fill(child: body),
        if (_progress < 1.0)
          const Positioned.fill(
              child: Center(child: CircularProgressIndicator()))
      ],
    );

    if (useCustomAppBar) {
      body = Column(
        children: [
          Appbar(
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: actions,
          ),
          Expanded(child: body)
        ],
      );
    }

    return Scaffold(
        appBar: !useCustomAppBar
            ? AppBar(
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: actions,
              )
            : null,
        body: body);
  }
}

class DesktopWebview {
  static Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  final String initialUrl;

  final void Function(String title, DesktopWebview controller)? onTitleChange;

  final void Function(String url, DesktopWebview webview)? onNavigation;

  final void Function(DesktopWebview controller)? onStarted;

  final void Function()? onClose;

  DesktopWebview(
      {required this.initialUrl,
      this.onTitleChange,
      this.onNavigation,
      this.onStarted,
      this.onClose});

  Webview? _webview;

  String? _ua;

  String? title;

  void onMessage(String message) {
    var json = jsonDecode(message);
    if (json is Map) {
      if (json["id"] == "document_created") {
        title = json["data"]["title"];
        _ua = json["data"]["ua"];
        onTitleChange?.call(title!, this);
      }
    }
  }

  String? get userAgent => _ua;

  Timer? timer;

  void _runTimer() {
    timer ??= Timer.periodic(const Duration(seconds: 2), (t) async {
      const js = '''
        function collect() {
          if(document.readyState === 'loading') {
            return '';
          }
          let data = {
            id: "document_created",
            data: {
              title: document.title,
              url: location.href,
              ua: navigator.userAgent
            }
          };
          return data;
        }
        collect();
      ''';
      if (_webview != null) {
        onMessage(await evaluateJavascript(js) ?? '');
      }
    });
  }

  void open() async {
    _webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
      useWindowPositionAndSize: true,
      userDataFolderWindows: "${App.dataPath}\\webview",
      title: "webview",
      proxy: proxyHttpOverrides?.proxyStr,
    ));
    _webview!.addOnWebMessageReceivedCallback(onMessage);
    _webview!.setOnNavigation((s) => onNavigation?.call(s, this));
    _webview!.launch(initialUrl, triggerOnUrlRequestEvent: false);
    _runTimer();
    _webview!.onClose.then((value) {
      _webview = null;
      timer?.cancel();
      timer = null;
      onClose?.call();
    });
    Future.delayed(const Duration(milliseconds: 200), () {
      onStarted?.call(this);
    });
  }

  Future<String?> evaluateJavascript(String source) {
    return _webview!.evaluateJavaScript(source);
  }

  Future<Map<String, String>> getCookies(String url) async {
    var allCookies = await _webview!.getAllCookies();
    var res = <String, String>{};
    for (var c in allCookies) {
      if (_cookieMatch(url, c.domain)) {
        res[_removeCode0(c.name)] = _removeCode0(c.value);
      }
    }
    return res;
  }

  String _removeCode0(String s) {
    var codeUints = List<int>.from(s.codeUnits);
    codeUints.removeWhere((e) => e == 0);
    return String.fromCharCodes(codeUints);
  }

  bool _cookieMatch(String url, String domain) {
    domain = _removeCode0(domain);
    var host = Uri.parse(url).host;
    var acceptedHost = _getAcceptedDomains(host);
    return acceptedHost.contains(domain.removeAllBlank);
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add(".${hostParts.sublist(i).join(".")}");
    }
    return acceptedDomains;
  }

  void close() {
    _webview?.close();
    _webview = null;
  }
}
