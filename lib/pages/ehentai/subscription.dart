import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/tools/translations.dart';
import '../../network/eh_network/eh_main_network.dart';
import '../../network/eh_network/eh_models.dart';
import '../../network/eh_network/subscription_pager.dart';
import '../../network/res.dart';

class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key, @visibleForTesting this.pager});

  final EhSubscriptionPager? pager;

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> {
  late final _comics = EhSubscriptionComics(pager: widget.pager);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("EH订阅".tl),
        actions: [
          IconButton(
            tooltip: "刷新".tl,
            icon: const Icon(Icons.refresh),
            onPressed: _comics.refresh,
          ),
          Tooltip(
            message: "更多".tl,
            child: IconButton(
              icon: const Icon(Icons.more_horiz),
              onPressed: () {
                Future.microtask(() => showDialog(
                    context: App.globalContext!,
                    builder: (context) {
                      return AlertDialog(
                        title: Text("订阅".tl),
                        content: Text("请在网页端管理订阅".tl),
                        actions: [
                          TextButton(
                              onPressed: () => App.globalBack(),
                              child: Text("返回".tl)),
                        ],
                      );
                    }));
              },
            ),
          )
        ],
      ),
      body: _comics,
    );
  }
}

class EhSubscriptionComics extends ComicsPage<EhGalleryBrief> {
  EhSubscriptionComics({super.key, EhSubscriptionPager? pager})
      : _pager = pager ??
            EhSubscriptionPager(
              loader: (url) => EhNetwork().getGalleries(url),
              baseUrl: () => EhNetwork().ehBaseUrl,
            );

  final EhSubscriptionPager _pager;

  @override
  Future<Res<List<EhGalleryBrief>>> getComics(int i) => _pager.load(i);

  @override
  String? get tag => "EhSubscriptionPage";

  @override
  String? get title => null;

  @override
  String get sourceKey => 'ehentai';
}
