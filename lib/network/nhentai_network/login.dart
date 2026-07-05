import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/pages/webview.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebViewController;

const _nhLoginLogTag = "[nhLogin]";

bool _isHttpUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && (uri.scheme == "http" || uri.scheme == "https");
}

Future<Map<String, String>> _readMobileNhCookies(
  InAppWebViewController controller,
) async {
  final baseUrl = NhentaiNetwork().baseUrl;
  final urls = <String>{
    "$baseUrl/",
    baseUrl,
  };
  final currentUrl = await controller.getUrl();
  final currentUrlString = currentUrl?.toString();
  if (currentUrlString != null && _isHttpUrl(currentUrlString)) {
    urls.add(currentUrlString);
  }

  final res = <String, String>{};
  for (final url in urls) {
    try {
      final cookies = await controller.getCookieList(url);
      debugPrint(
          "$_nhLoginLogTag manual url=$url cookieNames=${cookies.map((e) => e.name).join(",")}");
      for (final cookie in cookies) {
        res[cookie.name] = cookie.value.toString();
      }
    } catch (e) {
      debugPrint("$_nhLoginLogTag manual getCookies failed url=$url error=$e");
    }
  }
  debugPrint("$_nhLoginLogTag manual mergedCookieNames=${res.keys.join(",")}");
  return res;
}

List<io.Cookie> _buildNhCookieList(Map<String, String> cookies) {
  final cookiesList = <io.Cookie>[];
  for (final entry in cookies.entries) {
    final cookie = io.Cookie(entry.key, entry.value)
      ..domain = ".nhentai.net"
      ..path = "/";
    cookiesList.add(cookie);
  }
  return cookiesList;
}

String _formatNhCookieHeader(Map<String, String> cookies) {
  return cookies.entries
      .where((e) => e.key.isNotEmpty)
      .map((e) => "${e.key}=${e.value}")
      .join("; ");
}

Map<String, String> _parseNhCookieInput(String rawCookieData) {
  final cookies = <String, String>{};
  for (var line in rawCookieData.replaceAll("\r\n", "\n").split("\n")) {
    line = line.trim();
    if (line.isEmpty) {
      continue;
    }

    final lowerLine = line.toLowerCase();
    if (lowerLine.startsWith("cookie:")) {
      line = line.substring(line.indexOf(":") + 1).trim();
    } else if (lowerLine.startsWith("set-cookie:")) {
      line = line.substring(line.indexOf(":") + 1).trim();
      try {
        final cookie = io.Cookie.fromSetCookieValue(line);
        cookies[cookie.name] = cookie.value;
        continue;
      } catch (_) {}
    }

    final colonIndex = line.indexOf(":");
    final equalsIndex = line.indexOf("=");
    if (colonIndex > 0 && (equalsIndex == -1 || colonIndex < equalsIndex)) {
      final key = line.substring(0, colonIndex).trim();
      final value = line.substring(colonIndex + 1).trim();
      if (key.isNotEmpty) {
        cookies[key] = value;
      }
      continue;
    }

    for (var part in line.split(";")) {
      part = part.trim();
      final index = part.indexOf("=");
      if (index <= 0) {
        continue;
      }
      final key = part.substring(0, index).trim();
      final value = part.substring(index + 1).trim();
      if (key.isEmpty) {
        continue;
      }
      cookies[key] = value;
    }
  }
  if (cookies.isEmpty && rawCookieData.trim().isNotEmpty) {
    cookies[NhentaiNetwork.apiKeyCookie] = rawCookieData.trim();
  }
  _normalizeNhAuthInput(cookies);
  return cookies;
}

void _normalizeNhAuthInput(Map<String, String> cookies) {
  String? authKey;
  String? authValue;
  for (final entry in cookies.entries) {
    if (entry.key.toLowerCase() == NhentaiNetwork.authHeaderCookie) {
      authKey = entry.key;
      authValue = entry.value.trim();
      break;
    }
  }
  if (authKey != null) {
    cookies.remove(authKey);
  }
  if (authValue == null || authValue.isEmpty) {
    return;
  }
  final lower = authValue.toLowerCase();
  if (lower.startsWith("key ")) {
    cookies[NhentaiNetwork.apiKeyCookie] = authValue.substring(4).trim();
  } else if (lower.startsWith("user ")) {
    cookies[NhentaiNetwork.accessTokenCookie] = authValue.substring(5).trim();
  } else if (lower.startsWith("bearer ")) {
    cookies[NhentaiNetwork.accessTokenCookie] = authValue.substring(7).trim();
  } else {
    cookies[NhentaiNetwork.apiKeyCookie] = authValue;
  }
}

Future<bool> _validateNhCookies(Map<String, String> cookies) async {
  if (NhentaiNetwork().cookieJar == null) {
    await NhentaiNetwork().init();
  }
  final uri = Uri.parse(NhentaiNetwork().baseUrl);
  final cookieJar = NhentaiNetwork().cookieJar!;
  final oldCookies = cookieJar.loadForRequest(uri);
  final oldLogged = NhentaiNetwork().logged;
  try {
    cookieJar.deleteUri(uri);
    cookieJar.saveFromResponse(uri, _buildNhCookieList(cookies));
    NhentaiNetwork().logged = true;
    final res = await NhentaiNetwork().validateLogin();
    debugPrint("$_nhLoginLogTag validate success=${res.success} "
        "error=${res.errorMessage ?? ""}");
    return res.success;
  } catch (e, s) {
    debugPrint("$_nhLoginLogTag validate failed: $e\n$s");
    return false;
  } finally {
    cookieJar.deleteUri(uri);
    if (oldCookies.isNotEmpty) {
      cookieJar.saveFromResponse(uri, oldCookies);
    }
    NhentaiNetwork().logged = oldLogged;
  }
}

Future<void> _saveNhCookies(Map<String, String> cookies) async {
  if (NhentaiNetwork().cookieJar == null) {
    await NhentaiNetwork().init();
  }
  NhentaiNetwork().cookieJar!.deleteUri(Uri.parse(NhentaiNetwork().baseUrl));
  NhentaiNetwork().logged = true;
  NhentaiNetwork().cookieJar!.saveFromResponse(
      Uri.parse(NhentaiNetwork().baseUrl), _buildNhCookieList(cookies));
}

Future<void> _showManualNhCookieLoginDialog(
  BuildContext context,
  void Function() onFinished,
) async {
  final controller = TextEditingController();
  var validating = false;
  await showDialog(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text("Cookie 登录".tl),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 8,
            minLines: 5,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: "refresh_token=...; access_token=...\napi_key=...".tl,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed:
                validating ? null : () => Navigator.of(dialogContext).pop(),
            child: Text("取消".tl),
          ),
          TextButton(
            onPressed: validating
                ? null
                : () async {
                    final cookies = _parseNhCookieInput(controller.text);
                    debugPrint("$_nhLoginLogTag manual input cookieNames="
                        "${cookies.keys.join(",")} count=${cookies.length}");
                    if (cookies.isEmpty) {
                      showToast(message: "未读取到登录 Cookie".tl);
                      return;
                    }
                    setState(() {
                      validating = true;
                    });
                    final valid = await _validateNhCookies(cookies);
                    if (!dialogContext.mounted) {
                      return;
                    }
                    if (!valid) {
                      setState(() {
                        validating = false;
                      });
                      showToast(message: "Cookie 验证失败".tl);
                      return;
                    }
                    await _saveNhCookies(cookies);
                    if (!dialogContext.mounted) {
                      return;
                    }
                    Navigator.of(dialogContext).pop();
                    debugPrint("$_nhLoginLogTag manual input saved");
                    showToast(message: "Cookie 登录成功".tl);
                    onFinished();
                    App.globalBack();
                  },
            child: Text(validating ? "验证中".tl : "保存".tl),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
}

Future<void> _showExtractNhCookieDialog(
  BuildContext context,
  InAppWebViewController controller,
) async {
  final cookies = await _readMobileNhCookies(controller);
  if (!context.mounted) {
    return;
  }
  final cookieText = _formatNhCookieHeader(cookies);
  if (cookieText.isEmpty) {
    showToast(message: "cookie 为空".tl);
    return;
  }
  await showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text("提取 Cookie".tl),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(cookieText),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text("关闭".tl),
        ),
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: cookieText));
            showToast(message: "已复制".tl, icon: const Icon(Icons.check));
          },
          child: Text("复制".tl),
        ),
      ],
    ),
  );
}

void nhLogin(void Function() onFinished) async {
  if (App.isDesktop && (await DesktopWebview.isAvailable())) {
    var webview = DesktopWebview(
      initialUrl: "${NhentaiNetwork().baseUrl}/login/?next=/",
      onTitleChange: (title, controller) async {
        debugPrint(title);
        if (title == "nhentai.net") return;
        if (!title.contains("Login") &&
            !title.contains("Register") &&
            title.contains("nhentai")) {
          var ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData[3] = ua;
            appdata.writeImplicitData();
          }
          var cookies =
              await controller.getCookies("${NhentaiNetwork().baseUrl}/");
          List<io.Cookie> cookiesList = [];
          cookies.forEach((key, value) {
            var cookie = io.Cookie(key, value);
            cookie.domain = ".nhentai.net";
            cookiesList.add(cookie);
          });
          if (cookiesList.isEmpty) return;
          NhentaiNetwork().logged = true;
          NhentaiNetwork().cookieJar!.saveFromResponse(
              Uri.parse(NhentaiNetwork().baseUrl), cookiesList);
          onFinished();
          controller.close();
        }
      },
    );
    webview.open();
  } else if (App.isMobile) {
    App.globalTo(() => AppWebview(
          initialUrl: "${NhentaiNetwork().baseUrl}/login/?next=/",
          singlePage: true,
          onCookieLogin: (context, controller) {
            _showManualNhCookieLoginDialog(context, onFinished);
          },
          onExtractCookie: (context, controller) {
            _showExtractNhCookieDialog(context, controller);
          },
        ));
  } else {
    showToast(message: "当前设备不支持".tl);
  }
}
