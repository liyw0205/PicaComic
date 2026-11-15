import 'dart:async';

import 'package:pica_comic/components/comment.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/network/jm_network/jm_network.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/res.dart';

typedef JmCommentsLoader = Future<Res<List<Comment>>> Function(
    String id, int page, String mode);

class JmCommentsPageLogic extends StateController {
  JmCommentsPageLogic(this.totalComments, {JmCommentsLoader? loader})
      : _loader = loader ??
            ((id, page, mode) => jmNetwork.getComment(id, page, mode));

  final JmCommentsLoader _loader;

  bool loading = true;
  List<Comment>? comments;
  String? message;
  int totalComments;
  int page = 1;
  var controller = TextEditingController();
  bool _initialRequestInFlight = false;
  bool _moreRequestInFlight = false;
  int _generation = 0;

  static const _defaultMode = "manhua";

  int _requestTotal(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? totalComments;
    return totalComments;
  }

  void change() {
    if (isDisposed) return;
    loading = !loading;
    update();
  }

  Future<void> get(String id, [String? mode]) async {
    if (isDisposed || _initialRequestInFlight) return;

    final requestGeneration = _generation;
    _initialRequestInFlight = true;
    try {
      final res = await _loader(id, 1, mode ?? _defaultMode);
      if (isDisposed || requestGeneration != _generation) return;
      if (res.error) {
        message = res.errorMessage;
      } else {
        comments = List<Comment>.from(res.data);
        totalComments = _requestTotal(res.subData);
        page = 1;
      }
      loading = false;
      update();
    } catch (error) {
      if (isDisposed || requestGeneration != _generation) return;
      message = error.toString();
      loading = false;
      update();
    } finally {
      if (requestGeneration == _generation) {
        _initialRequestInFlight = false;
      }
    }
  }

  void retry() {
    if (isDisposed) return;
    _generation++;
    message = null;
    comments = null;
    loading = true;
    page = 1;
    _initialRequestInFlight = false;
    _moreRequestInFlight = false;
    update();
  }

  Future<void> loadMore(String id, [String? mode]) async {
    if (isDisposed ||
        _moreRequestInFlight ||
        comments == null ||
        totalComments <= comments!.length) {
      return;
    }

    final requestGeneration = _generation;
    final requestedPage = page + 1;
    _moreRequestInFlight = true;
    try {
      final res = await _loader(id, requestedPage, mode ?? _defaultMode);
      if (isDisposed || requestGeneration != _generation) return;
      if (!res.error) {
        final currentComments = comments;
        if (currentComments == null) return;
        currentComments.addAll(res.data);
        page = requestedPage;
        totalComments = _requestTotal(res.subData);
        update();
      }
    } catch (_) {
      // Keep the current page so a later rebuild can retry the failed request.
    } finally {
      if (requestGeneration == _generation) {
        _moreRequestInFlight = false;
      }
    }
  }

  void refresh_() {
    if (isDisposed) return;
    _generation++;
    comments = null;
    message = null;
    page = 1;
    controller.text = "";
    loading = true;
    _initialRequestInFlight = false;
    _moreRequestInFlight = false;
    update();
  }

  @override
  void dispose() {
    _generation++;
    controller.dispose();
    super.dispose();
  }
}

class JmCommentsPage extends StatelessWidget {
  const JmCommentsPage(this.id, this.totalComments,
      {this.mode, this.popUp = false, Key? key})
      : super(key: key);
  final String id;
  final bool popUp;
  final String? mode;
  final int totalComments;

  @override
  Widget build(BuildContext context) {
    Widget body = StateBuilder<JmCommentsPageLogic>(
        init: JmCommentsPageLogic(totalComments),
        builder: (logic) {
          if (logic.loading) {
            unawaited(logic.get(id, mode));
            return const Center(
              child: CircularProgressIndicator(),
            );
          } else if (logic.comments == null) {
            return NetworkError(message: logic.message!, retry: logic.retry);
          } else {
            return Column(
              children: [
                Expanded(
                    child: CustomScrollView(
                  slivers: [
                    SliverList(
                        delegate: SliverChildBuilderDelegate(
                            childCount: logic.comments!.length,
                            (context, index) {
                      if (index == logic.comments!.length - 1) {
                        unawaited(logic.loadMore(id, mode));
                      }
                      return CommentTile(
                        avatarUrl: logic.comments![index].avatar,
                        name: logic.comments![index].name,
                        content: logic.comments![index].content,
                        comments: logic.comments![index].reply.length,
                        onTap: () => showReply(
                            context,
                            logic.comments![index].reply,
                            logic.comments![index]),
                        time: logic.comments![index].time,
                      );
                    })),
                    if (logic.totalComments > logic.comments!.length)
                      const SliverToBoxAdapter(
                        child: ListLoadingIndicator(),
                      ),
                    SliverPadding(
                        padding: EdgeInsets.only(
                            top: MediaQuery.of(App.globalContext!)
                                .padding
                                .bottom))
                  ],
                )),
                Container(
                  decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceTint
                          .withAlpha(0),
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(16))),
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
                              controller: logic.controller,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                isCollapsed: true,
                                hintText: "评论".tl,
                              ),
                              minLines: 1,
                              maxLines: 5,
                            ),
                          )),
                          IconButton(
                              onPressed: () async {
                                showToast(message: "正在发送评论".tl);
                                var res = await JmNetwork()
                                    .comment(id, logic.controller.text);
                                if (res.error) {
                                  showToast(message: res.errorMessage!);
                                } else {
                                  showToast(message: "成功发表评论".tl);
                                  logic.refresh_();
                                }
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
        });
    if (popUp) {
      return body;
    } else {
      return Scaffold(
        appBar: AppBar(
          title: Text("评论".tl),
        ),
        body: body,
      );
    }
  }
}

void showReply(BuildContext context, List<Comment> comments, Comment replyTo) {
  if (comments.isEmpty) return;
  showSideBar(
      context,
      SingleChildScrollView(
        child: Column(
          children: [
            CommentTile(
              avatarUrl: replyTo.avatar,
              name: replyTo.name,
              content: replyTo.content,
              time: replyTo.time,
            ),
            const Divider(),
            for (int index = 0; index < comments.length; index++)
              CommentTile(
                avatarUrl: comments[index].avatar,
                name: comments[index].name,
                content: comments[index].content,
                time: comments[index].time,
              )
          ],
        ),
      ),
      title: "回复".tl,
      showBarrier: false);
}

void showComments(BuildContext context, String id, int totalComments,
    [String? mode]) {
  showSideBar(
      context,
      JmCommentsPage(
        id,
        totalComments,
        popUp: true,
        mode: mode,
      ),
      title: "评论".tl);
}
