import 'dart:async';

import 'package:pica_comic/components/comment.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';
import 'package:pica_comic/tools/translations.dart';

class CommentsPageLogic extends StateController {
  bool isLoading = true;
  var comments = Comments([], "", 0, 0);
  bool sending = false;
  var controller = TextEditingController();
  bool _initialRequestInFlight = false;
  bool _nextPageInFlight = false;
  int _generation = 0;
  int _sendGeneration = 0;

  Future<void> loadInitial(String id, String type) async {
    if (isDisposed || _initialRequestInFlight) return;
    _initialRequestInFlight = true;
    final generation = ++_generation;
    try {
      final result = await network.getCommends(id, type: type);
      if (isDisposed || generation != _generation) return;
      comments = result;
      isLoading = false;
      update();
    } catch (_) {
      if (isDisposed || generation != _generation) return;
      comments = Comments([], id, 0, 0);
      isLoading = false;
      update();
    } finally {
      if (generation == _generation) {
        _initialRequestInFlight = false;
      }
    }
  }

  void retry(String id) {
    if (isDisposed || _initialRequestInFlight) return;
    _generation++;
    _sendGeneration++;
    _nextPageInFlight = false;
    sending = false;
    isLoading = true;
    comments = Comments([], id, 0, 0);
    update();
  }

  Future<void> sendComment(String id, String type) async {
    if (isDisposed || sending) return;
    final content = controller.text;
    if (content.length < 2) {
      showToast(message: "评论至少需要2个字".tl);
      return;
    }
    final generation = ++_sendGeneration;
    final loadGeneration = _generation;
    sending = true;
    update();
    try {
      final sent = await network.comment(id, content, false, type: type);
      if (isDisposed ||
          generation != _sendGeneration ||
          loadGeneration != _generation) {
        return;
      }
      if (!sent) {
        showToast(message: "网络错误".tl);
        return;
      }
      controller.clear();
      final result = await network.getCommends(id, type: type);
      if (isDisposed ||
          generation != _sendGeneration ||
          loadGeneration != _generation) {
        return;
      }
      comments = result;
      update();
    } catch (_) {
      if (!isDisposed &&
          generation == _sendGeneration &&
          loadGeneration == _generation) {
        showToast(message: "网络错误".tl);
      }
    } finally {
      if (!isDisposed && generation == _sendGeneration) {
        sending = false;
        update();
      }
    }
  }

  @override
  void dispose() {
    _sendGeneration++;
    controller.dispose();
    super.dispose();
  }

  Future<void> loadMore(String type) async {
    final target = comments;
    if (isDisposed ||
        _nextPageInFlight ||
        target.loaded == target.pages ||
        isLoading) {
      return;
    }
    _nextPageInFlight = true;
    final generation = _generation;
    try {
      await network.loadMoreCommends(target, type: type);
      if (isDisposed ||
          generation != _generation ||
          !identical(comments, target)) {
        return;
      }
      update();
    } catch (_) {
      // Keep the current page visible; a later scroll can retry the request.
    } finally {
      _nextPageInFlight = false;
    }
  }
}

class CommentsPage extends StatelessWidget {
  final String id;
  final String type;
  final bool popUp;

  const CommentsPage(this.id,
      {Key? key, this.type = "comics", this.popUp = false})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    Widget body = StateBuilder<CommentsPageLogic>(
      init: CommentsPageLogic(),
      builder: (logic) {
        if (logic.isLoading) {
          unawaited(logic.loadInitial(id, type));
          return const Center(
            child: CircularProgressIndicator(),
          );
        } else if (logic.comments.loaded == 0) {
          return NetworkError(
            message: "网络错误".tl,
            retry: () {
              logic.retry(id);
            },
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
                          childCount: logic.comments.comments.length,
                          (context, index) {
                    if (index == logic.comments.comments.length - 1 &&
                        logic.comments.pages != logic.comments.loaded) {
                      unawaited(logic.loadMore(type));
                    }
                    var comment = logic.comments.comments[index];
                    var subInfo =
                        "${comment.time.substring(0, 10)}  ${comment.time.substring(11, 19)}";
                    return CommentTile(
                      avatarUrl: comment.avatarUrl,
                      name: comment.name,
                      content: comment.text,
                      slogan: comment.slogan,
                      level: comment.level,
                      time: subInfo,
                      like: () {
                        network.likeOrUnlikeComment(comment.id);
                        comment.isLiked = !comment.isLiked;
                        comment.isLiked ? comment.likes++ : comment.likes--;
                        logic.update();
                      },
                      likes: comment.likes,
                      liked: comment.isLiked,
                      comments: comment.reply,
                      onTap: () => showReply(context, comment.id, comment),
                    );
                  })),
                  if (logic.comments.loaded != logic.comments.pages &&
                      logic.comments.pages != 1)
                    const SliverToBoxAdapter(
                      child: ListLoadingIndicator(),
                    ),
                  SliverPadding(
                      padding: EdgeInsets.only(
                          top:
                              MediaQuery.of(App.globalContext!).padding.bottom))
                ],
              )),
              Container(
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(16))),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
                  child: Material(
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
                                  hintText: "评论".tl),
                              minLines: 1,
                              maxLines: 5,
                            ),
                          )),
                          logic.sending
                              ? const Padding(
                                  padding: EdgeInsets.all(8.5),
                                  child: SizedBox(
                                    width: 23,
                                    height: 23,
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              : IconButton(
                                  onPressed: () =>
                                      unawaited(logic.sendComment(id, type)),
                                  icon: Icon(
                                    Icons.send,
                                    color:
                                        Theme.of(context).colorScheme.secondary,
                                  ))
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
      },
    );

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

void showComments(BuildContext context, String id) {
  showSideBar(
      context,
      CommentsPage(
        id,
        popUp: true,
      ),
      title: "评论".tl);
}

class ReplyPageLogic extends StateController {
  bool isLoading = true;
  var comments = Reply("", 0, 1, []);
  bool sending = false;
  var controller = TextEditingController();
  bool _initialRequestInFlight = false;
  bool _nextPageInFlight = false;
  int _generation = 0;
  int _sendGeneration = 0;

  Future<void> loadInitial(String id) async {
    if (isDisposed || _initialRequestInFlight) return;
    _initialRequestInFlight = true;
    final generation = ++_generation;
    try {
      final result = await network.getReply(id);
      if (isDisposed || generation != _generation) return;
      comments = result;
      isLoading = false;
      update();
    } catch (_) {
      if (isDisposed || generation != _generation) return;
      comments = Reply(id, 0, 1, []);
      isLoading = false;
      update();
    } finally {
      if (generation == _generation) {
        _initialRequestInFlight = false;
      }
    }
  }

  void retry(String id) {
    if (isDisposed || _initialRequestInFlight) return;
    _generation++;
    _sendGeneration++;
    _nextPageInFlight = false;
    sending = false;
    isLoading = true;
    comments = Reply(id, 0, 1, []);
    update();
  }

  Future<void> sendReply(String id) async {
    if (isDisposed || sending) return;
    final content = controller.text;
    if (content.length < 2) {
      showToast(message: "评论至少需要2个字".tl);
      return;
    }
    final generation = ++_sendGeneration;
    final loadGeneration = _generation;
    sending = true;
    update();
    try {
      final sent = await network.comment(id, content, true);
      if (isDisposed ||
          generation != _sendGeneration ||
          loadGeneration != _generation) {
        return;
      }
      if (!sent) {
        showToast(message: "网络错误".tl);
        return;
      }
      controller.clear();
      final result = await network.getReply(id);
      if (isDisposed ||
          generation != _sendGeneration ||
          loadGeneration != _generation) {
        return;
      }
      comments = result;
      update();
    } catch (_) {
      if (!isDisposed &&
          generation == _sendGeneration &&
          loadGeneration == _generation) {
        showToast(message: "网络错误".tl);
      }
    } finally {
      if (!isDisposed && generation == _sendGeneration) {
        sending = false;
        update();
      }
    }
  }

  @override
  void dispose() {
    _sendGeneration++;
    controller.dispose();
    super.dispose();
  }

  Future<void> loadMore() async {
    final target = comments;
    if (isDisposed ||
        _nextPageInFlight ||
        target.loaded == target.total ||
        isLoading) {
      return;
    }
    _nextPageInFlight = true;
    final generation = _generation;
    try {
      await network.getMoreReply(target);
      if (isDisposed ||
          generation != _generation ||
          !identical(comments, target)) {
        return;
      }
      update();
    } catch (_) {
      // Keep the current page visible; a later scroll can retry the request.
    } finally {
      _nextPageInFlight = false;
    }
  }
}

class ReplyPage extends StatelessWidget {
  final String id;
  final Comment replyTo;
  final bool popUp;

  const ReplyPage(this.id, this.replyTo, {this.popUp = false, Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    var body = StateBuilder<ReplyPageLogic>(
      init: ReplyPageLogic(),
      builder: (commentsPageLogic) {
        if (commentsPageLogic.isLoading) {
          unawaited(commentsPageLogic.loadInitial(id));
          return const Center(
            child: CircularProgressIndicator(),
          );
        } else if (commentsPageLogic.comments.loaded == 0) {
          return NetworkError(
            message: "网络错误".tl,
            retry: () {
              commentsPageLogic.retry(id);
            },
            withAppbar: false,
          );
        } else {
          return Column(
            children: [
              Expanded(
                  child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: CommentTile(
                      avatarUrl: replyTo.avatarUrl,
                      name: replyTo.name,
                      content: replyTo.text,
                      time:
                          "${replyTo.time.substring(0, 10)}  ${replyTo.time.substring(11, 19)}",
                      slogan: replyTo.slogan,
                      level: replyTo.level,
                    ),
                  ),
                  const SliverPadding(padding: EdgeInsets.all(2)),
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 15),
                      child: Divider(),
                    ),
                  ),
                  SliverList(
                      delegate: SliverChildBuilderDelegate(
                          childCount: commentsPageLogic
                              .comments.comments.length, (context, index) {
                    if (index ==
                            commentsPageLogic.comments.comments.length - 1 &&
                        commentsPageLogic.comments.total !=
                            commentsPageLogic.comments.loaded) {
                      unawaited(commentsPageLogic.loadMore());
                    }
                    var comment = commentsPageLogic.comments.comments[index];
                    var subInfo =
                        "${comment.time.substring(0, 10)}  ${comment.time.substring(11, 19)}";
                    return CommentTile(
                      avatarUrl: comment.avatarUrl,
                      name: comment.name,
                      content: comment.text,
                      slogan: comment.slogan,
                      level: comment.level,
                      time: subInfo,
                      like: () {
                        network.likeOrUnlikeComment(comment.id);
                        comment.isLiked = !comment.isLiked;
                        comment.isLiked ? comment.likes++ : comment.likes--;
                        commentsPageLogic.update();
                      },
                      likes: comment.likes,
                      liked: comment.isLiked,
                    );
                  })),
                  if (commentsPageLogic.comments.loaded !=
                          commentsPageLogic.comments.total &&
                      commentsPageLogic.comments.total != 1)
                    const SliverToBoxAdapter(
                      child: ListLoadingIndicator(),
                    ),
                  SliverPadding(
                      padding: EdgeInsets.only(
                          top:
                              MediaQuery.of(App.globalContext!).padding.bottom))
                ],
              )),
              Container(
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(16))),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
                  child: Material(
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
                              controller: commentsPageLogic.controller,
                              decoration: InputDecoration(
                                  border: InputBorder.none,
                                  isCollapsed: true,
                                  hintText: "回复".tl),
                              minLines: 1,
                              maxLines: 5,
                            ),
                          )),
                          commentsPageLogic.sending
                              ? const Padding(
                                  padding: EdgeInsets.all(8.5),
                                  child: SizedBox(
                                    width: 23,
                                    height: 23,
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              : IconButton(
                                  onPressed: () => unawaited(
                                      commentsPageLogic.sendReply(id)),
                                  icon: Icon(
                                    Icons.send,
                                    color:
                                        Theme.of(context).colorScheme.secondary,
                                  ))
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                  padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).padding.bottom))
            ],
          );
        }
      },
    );

    if (popUp) {
      return body;
    } else {
      return Scaffold(
        appBar: AppBar(
          title: Text("回复".tl),
        ),
        body: body,
      );
    }
  }
}

void showReply(BuildContext context, String id, Comment replyTo) {
  showSideBar(
      context,
      ReplyPage(
        id,
        replyTo,
        popUp: true,
      ),
      title: "回复".tl,
      showBarrier: false);
}
