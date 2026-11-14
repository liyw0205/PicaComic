import 'dart:async';

import '../image_manager.dart';
import 'image_task_priority.dart';

class ImageTaskCancelledException implements Exception {
  const ImageTaskCancelledException();

  @override
  String toString() => 'Image task cancelled';
}

/// Owns only the subscriptions created for one retained reader image.
class ImageTaskScope {
  ImageTaskScope({this.priority = 1});

  int priority;
  bool _cancelled = false;
  final _cancellations = <Future<void> Function()>{};

  bool get isCancelled => _cancelled;

  Stream<T> bind<T>(Stream<T> Function() createStream) {
    return Stream<T>.multi((controller) {
      if (_cancelled) {
        controller.addError(const ImageTaskCancelledException());
        controller.close();
        return;
      }
      final owner = Object();
      var finished = false;
      StreamSubscription<T>? subscription;
      final subscriptionReady = Completer<void>();
      late Future<void> Function() cancel;
      cancel = () async {
        if (finished) return;
        finished = true;
        ImageManager.cancelTasksForOwner(owner);
        controller.close();
        final active = subscription;
        if (active != null) {
          await active.cancel();
        } else {
          await subscriptionReady.future;
        }
      };
      _cancellations.add(cancel);
      try {
        final active = runZoned(
          () => ImageManager.withTaskOwner(createStream(), owner).listen(
            (value) {
              if (!finished) controller.add(value);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!finished) controller.addError(error, stackTrace);
            },
            onDone: () {
              finished = true;
              _cancellations.remove(cancel);
              controller.close();
            },
          ),
          zoneValues: {imageTaskPriorityZoneKey: priority},
        );
        subscription = active;
        subscriptionReady.complete();
        if (finished) {
          unawaited(active.cancel());
          return;
        }
      } catch (error, stackTrace) {
        finished = true;
        _cancellations.remove(cancel);
        if (!subscriptionReady.isCompleted) subscriptionReady.complete();
        controller.addError(error, stackTrace);
        controller.close();
        return;
      }
      controller
        ..onPause = subscription.pause
        ..onResume = subscription.resume
        ..onCancel = () async {
          finished = true;
          _cancellations.remove(cancel);
          final active = subscription;
          if (active != null) await active.cancel();
        };
    });
  }

  Future<void> cancel() async {
    _cancelled = true;
    await Future.wait(_cancellations.toList().map((cancel) => cancel()));
  }
}
