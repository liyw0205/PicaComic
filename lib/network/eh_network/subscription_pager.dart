import 'eh_models.dart';
import '../res.dart';

class _SubscriptionPages {
  _SubscriptionPages(this.baseUrl)
      : next = Uri.parse(baseUrl).resolve('/watched').toString();

  final String baseUrl;
  String? next;
  final pages = <int, List<EhGalleryBrief>>{};
  final visited = <String>{};
  Future<void> pending = Future<void>.value();
}

/// Keeps cursor pagination separate from the list's mutable display buffers.
class EhSubscriptionPager {
  EhSubscriptionPager({required this.loader, required this.baseUrl});

  final Future<Res<Galleries>> Function(String) loader;
  final String Function() baseUrl;
  _SubscriptionPages? _pages;

  bool _isCurrent(_SubscriptionPages pages) =>
      identical(_pages, pages) && pages.baseUrl == baseUrl();

  Future<Res<List<EhGalleryBrief>>> load(int page) {
    if (page < 1) return Future.value(const Res.error('Invalid page'));
    final site = baseUrl();
    if (page != 1 && _pages != null && _pages!.baseUrl != site) {
      // Do not append a new site's page to an old site's display buffer.
      return Future.value(const Res.error('EH site changed'));
    }
    // The shared list caches back-navigation itself. A new page-one request
    // represents refresh/retry and must invalidate the previous cursor chain.
    if (page == 1 || _pages == null) {
      _pages = _SubscriptionPages(site);
    }
    final pages = _pages!;
    final request = pages.pending.then((_) => _load(pages, page));
    pages.pending = request.then<void>((_) {}, onError: (_, __) {});
    return request;
  }

  Future<Res<List<EhGalleryBrief>>> _load(
      _SubscriptionPages pages, int page) async {
    while (pages.pages.length < page && pages.next != null) {
      if (!_isCurrent(pages)) {
        return const Res.error('Subscription request superseded');
      }
      final url = pages.next!;
      if (pages.visited.contains(url)) {
        return const Res.error('Invalid subscription pagination');
      }
      final response = await loader(url);
      if (!_isCurrent(pages)) {
        return const Res.error('Subscription request superseded');
      }
      if (response.error) return Res.fromErrorRes(response);
      final data = response.data;
      final next = data.next?.trim();
      final nextUrl = next == null || next.isEmpty
          ? null
          : Uri.parse(url).resolve(next).toString();
      pages.pages[pages.pages.length + 1] =
          List<EhGalleryBrief>.unmodifiable(data.galleries);
      pages.visited.add(url);
      pages.next = nextUrl;
    }
    if (!_isCurrent(pages)) {
      return const Res.error('Subscription request superseded');
    }
    return Res(List<EhGalleryBrief>.of(pages.pages[page] ?? const []),
        subData: pages.next == null ? pages.pages.length : null);
  }
}
