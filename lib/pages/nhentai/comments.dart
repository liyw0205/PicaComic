import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pica_comic/components/comment.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/nhentai_network/nhentai_main_network.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/components/components.dart';

typedef NhentaiCommentsLoader = Future<Res<List<NhentaiComment>>> Function(
    String id);

class NhentaiCommentsPageLogic extends StateController {
  NhentaiCommentsPageLogic(this.id, {NhentaiCommentsLoader? loader})
      : _loader = loader ?? ((id) => NhentaiNetwork().getComments(id));

  final String id;
  final NhentaiCommentsLoader _loader;

  bool loading = true;
  List<NhentaiComment>? comments;
  String? message;
  bool _requestInFlight = false;
  int _generation = 0;

  Future<void> get() async {
    if (isDisposed || _requestInFlight) return;
    final requestGeneration = _generation;
    _requestInFlight = true;
    try {
      final res = await _loader(id);
      if (isDisposed || requestGeneration != _generation) return;
      if (res.error) {
        message = res.errorMessageWithoutNull;
      } else {
        comments = List<NhentaiComment>.from(res.data);
      }
      loading = false;
      update();
    } catch (error) {
      if (isDisposed || requestGeneration != _generation) return;
      message = safeNetworkError(error);
      loading = false;
      update();
    } finally {
      if (requestGeneration == _generation) {
        _requestInFlight = false;
      }
    }
  }

  void retry() {
    if (isDisposed) return;
    _generation++;
    _requestInFlight = false;
    loading = true;
    comments = null;
    message = null;
    update();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}

class NhentaiCommentsPage extends StatelessWidget {
  const NhentaiCommentsPage(this.id, {super.key});

  final String id;

  @override
  Widget build(BuildContext context) {
    return StateBuilder<NhentaiCommentsPageLogic>(
      init: NhentaiCommentsPageLogic(id),
      builder: (logic) {
        if (logic.loading) {
          unawaited(logic.get());
          return const Center(
            child: CircularProgressIndicator(),
          );
        } else if (logic.message != null) {
          return NetworkError(
            message: logic.message!,
            retry: logic.retry,
            withAppbar: false,
          );
        } else {
          return Column(
            children: [
              Expanded(
                  child: CustomScrollView(
                slivers: [
                  SliverList(
                      delegate: SliverChildBuilderDelegate(
                          childCount: logic.comments!.length, (context, index) {
                    return CommentTile(
                      avatarUrl: logic.comments![index].avatar,
                      name: logic.comments![index].userName,
                      content: logic.comments![index].content,
                    );
                  })),
                  SliverPadding(
                      padding: EdgeInsets.only(
                          top: MediaQuery.of(context).padding.bottom))
                ],
              )),
              Container(
                decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceTint.withAlpha(0),
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(16))),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
                  child: Container(
                    decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withAlpha(160),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(30))),
                    child: Row(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                            child: TextField(
                              enabled: false,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                isCollapsed: true,
                                hintText: "评论".tl,
                              ),
                              minLines: 1,
                              maxLines: 5,
                            ),
                          ),
                        ),
                        IconButton(
                            onPressed: () {
                              // TODO: comment submission is not implemented.
                              showToast(message: "未完成");
                            },
                            icon: Icon(
                              Icons.send,
                              color: Theme.of(context).colorScheme.secondary,
                            ))
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }
      },
    );
  }
}

void showComments(BuildContext context, String id) {
  showSideBar(context, NhentaiCommentsPage(id), title: "评论".tl);
}
