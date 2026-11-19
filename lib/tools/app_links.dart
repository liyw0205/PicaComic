import 'package:flutter/widgets.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/network_logging.dart';
import '../foundation/app.dart';
import '../pages/ehentai/eh_gallery_page.dart';
import '../pages/hitomi/hitomi_comic_page.dart';
import '../pages/nhentai/comic_page.dart';

bool canHandle(String text) {
  final uri = Uri.tryParse(text);
  return uri != null && _comicPageForLink(uri) != null;
}

bool handleAppLinks(Uri uri, {bool showMessageWhenError = true}) {
  LogManager.addLog(
      LogLevel.info, "App Link", "Open Link ${safeNetworkUrl(uri.toString())}");
  final page = _comicPageForLink(uri);
  if (page == null) {
    if (showMessageWhenError) showToast(message: "Unknown Link");
    return false;
  }
  final context = App.mainNavigatorKey?.currentContext;
  if (context == null || !context.mounted) return false;
  context.to(() => page);
  return true;
}

Widget? _comicPageForLink(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final List<String> segments;
  try {
    segments = uri.pathSegments;
  } on FormatException {
    return null;
  }
  switch (uri.host) {
    case "e-hentai.org":
    case "exhentai.org":
      if (!RegExp(r'^/g/[0-9]+/[A-Za-z0-9]+/?$').hasMatch(uri.path)) {
        return null;
      }
      return EhGalleryPage.fromLink("https://${uri.host}${uri.path}");
    case "nhentai.net":
    case "nhentai.xxx":
      final match = RegExp(r'^/g/([0-9]+)/?$').firstMatch(uri.path);
      return match == null ? null : NhentaiComicPage(match[1]!);
    case "hitomi.la":
      if (segments.length != 2 ||
          !["galleries", "doujinshi", "cg", "manga"].contains(segments.first) ||
          !segments.last.endsWith('.html') ||
          hitomiGalleryIdFromTarget(uri.path) == null) {
        return null;
      }
      return HitomiComicPage.fromLink(canonicalHitomiTarget(uri.toString()));
    default:
      return null;
  }
}
