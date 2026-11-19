import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/tools/app_links.dart';
import 'package:pica_comic/tools/translations.dart';

import 'ehentai/subscription.dart';
import 'jm/jm_comic_page.dart';
import 'webview.dart';

void openTool() {
  showModalBottomSheet(
    context: App.globalContext!,
    builder: (context) => Column(
      children: [
        ListTile(
          title: Text("工具".tl),
        ),
        ListTile(
          leading: const Icon(Icons.subscriptions),
          title: Text("EH订阅".tl),
          onTap: () {
            App.globalBack();
            App.mainNavigatorKey?.currentContext
                ?.to(() => const SubscriptionPage());
          },
        ),
        ListTile(
          leading: const Icon(Icons.image_search_outlined),
          title: Text("图片搜索 [搜图bot酱]".tl),
          onTap: () async {
            App.globalBack();
            if (App.isMobile) {
              App.mainNavigatorKey?.currentContext?.to(
                () => AppWebview(
                  initialUrl: "https://soutubot.moe/",
                  onNavigation: (uri) {
                    return handleAppLinks(Uri.parse(uri),
                        showMessageWhenError: false);
                  },
                ),
              );
            } else {
              var webview = DesktopWebview(
                initialUrl: "https://soutubot.moe/",
                onNavigation: (s, webview) {
                  if (handleAppLinks(Uri.parse(s),
                      showMessageWhenError: false)) {
                    Future.microtask(() => webview.close());
                  }
                },
              );
              unawaited(webview.open());
            }
          },
          trailing: const Icon(Icons.open_in_new),
        ),
        ListTile(
          leading: const Icon(Icons.image_search),
          title: Text("图片搜索 [SauceNAO]".tl),
          onTap: () async {
            App.globalBack();
            if (App.isMobile || App.isMacOS) {
              App.mainNavigatorKey?.currentContext?.to(
                () => AppWebview(
                  initialUrl: "https://saucenao.com/",
                  onNavigation: (uri) {
                    return handleAppLinks(Uri.parse(uri),
                        showMessageWhenError: false);
                  },
                ),
              );
            } else {
              var webview = DesktopWebview(
                initialUrl: "https://saucenao.com/",
                onNavigation: (s, webview) {
                  if (handleAppLinks(Uri.parse(s),
                      showMessageWhenError: false)) {
                    Future.microtask(() => webview.close());
                  }
                },
              );
              unawaited(webview.open());
            }
          },
          trailing: const Icon(Icons.open_in_new),
        ),
        ListTile(
          leading: const Icon(Icons.link),
          title: Text("打开链接".tl),
          onTap: () => _openComicInput(context, isJmId: false),
        ),
        ListTile(
          leading: const Icon(Icons.numbers),
          title: Text("禁漫漫画ID".tl),
          onTap: () => _openComicInput(context, isJmId: true),
        )
      ],
    ),
  );
}

Future<void> _openComicInput(BuildContext context,
    {required bool isJmId}) async {
  final route = ModalRoute.of(context);
  final navigator = Navigator.of(context);
  final value = await showDialog<String>(
    context: context,
    builder: (_) => _ComicInputDialog(isJmId: isJmId),
  );
  if (value == null ||
      !context.mounted ||
      !navigator.mounted ||
      route?.isActive != true) {
    return;
  }
  if (route!.isCurrent) {
    navigator.pop();
  } else {
    navigator.removeRoute(route);
  }
  if (isJmId) {
    App.mainNavigatorKey?.currentContext?.to(() => JmComicPage(value));
  } else {
    handleAppLinks(Uri.parse(value));
  }
}

class _ComicInputDialog extends StatefulWidget {
  const _ComicInputDialog({required this.isJmId});

  final bool isJmId;

  @override
  State<_ComicInputDialog> createState() => _ComicInputDialogState();
}

class _ComicInputDialogState extends State<_ComicInputDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _submitted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submitted) return;
    var value = _controller.text.trim();
    if (!widget.isJmId && value.isNotEmpty) {
      final uri = Uri.tryParse(value);
      if (uri != null && !uri.hasScheme) value = 'https://$value';
    }
    final valid =
        widget.isJmId ? RegExp(r'^[0-9]+$').hasMatch(value) : canHandle(value);
    if (!valid) {
      setState(() => _error = widget.isJmId ? "输入的ID不是数字".tl : "不支持的链接".tl);
      return;
    }
    _submitted = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isJmId ? "输入禁漫漫画ID".tl : "输入链接".tl),
      content: TextField(
        autofocus: true,
        controller: _controller,
        keyboardType: widget.isJmId ? TextInputType.number : TextInputType.url,
        textInputAction: TextInputAction.done,
        inputFormatters:
            widget.isJmId ? [FilteringTextInputFormatter.digitsOnly] : null,
        decoration: InputDecoration(
          errorText: _error,
          border: widget.isJmId ? const OutlineInputBorder() : null,
          labelText: widget.isJmId ? 'ID' : null,
          prefix: widget.isJmId ? const Text('JM') : null,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
            onPressed: _submit, child: Text(widget.isJmId ? "提交".tl : "打开".tl)),
      ],
    );
  }
}
