import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/pair.dart';

class SimpleController extends StateController {
  final void Function()? refresh_;

  SimpleController({this.refresh_});

  @override
  void refresh() {
    (refresh_ ?? super.refresh)();
  }
}

abstract class StateController {
  static final _controllers = <StateControllerWrapped>[];

  static T put<T extends StateController>(T controller,
      {Object? tag, bool autoRemove = false}) {
    controller._ensureCanRegister();
    _controllers.add(StateControllerWrapped(controller, autoRemove, tag));
    return controller;
  }

  static T putIfNotExists<T extends StateController>(T controller,
      {Object? tag, bool autoRemove = false}) {
    return findOrNull<T>(tag: tag) ??
        put(controller, tag: tag, autoRemove: autoRemove);
  }

  static T find<T extends StateController>({Object? tag}) {
    try {
      return _controllers
          .lastWhere((element) =>
              element.controller is T && (tag == null || tag == element.tag))
          .controller as T;
    } catch (e) {
      throw StateError("$T with tag $tag Not Found");
    }
  }

  static List<T> findAll<T extends StateController>({Object? tag}) {
    return _controllers
        .where((element) =>
            element.controller is T && (tag == null || tag == element.tag))
        .map((e) => e.controller as T)
        .toList();
  }

  static T? findOrNull<T extends StateController>({Object? tag}) {
    try {
      return _controllers
          .lastWhere((element) =>
              element.controller is T && (tag == null || tag == element.tag))
          .controller as T;
    } catch (e) {
      return null;
    }
  }

  static void remove<T>([Object? tag, bool check = false]) {
    for (int i = _controllers.length - 1; i >= 0; i--) {
      var element = _controllers[i];
      if (element.controller is T && (tag == null || tag == element.tag)) {
        if (check && !element.autoRemove) {
          continue;
        }
        _controllers.removeAt(i);
        if (!_controllers.any((candidate) =>
            identical(candidate.controller, element.controller))) {
          element.controller.dispose();
        }
        return;
      }
    }
  }

  static SimpleController putSimpleController(
      void Function() onUpdate, Object? tag,
      {void Function()? refresh}) {
    var controller = SimpleController(refresh_: refresh);
    controller.subscribe(onUpdate);
    _controllers.add(StateControllerWrapped(controller, false, tag));
    return controller;
  }

  final _stateUpdaters = <int, Pair<Object?, void Function()>>{};
  int _nextSubscriptionToken = 0;
  bool _disposed = false;

  /// Whether this controller has been disposed and can no longer be observed.
  bool get isDisposed => _disposed;

  /// A read-only snapshot kept for compatibility with existing diagnostics.
  /// New listeners must use [subscribe] so they receive a removable token.
  List<Pair<Object?, void Function()>> get stateUpdaters =>
      List.unmodifiable(_stateUpdaters.values);

  /// Registers a listener and returns its one-shot removal token.
  StateControllerSubscription subscribe(void Function() updater, {Object? id}) {
    _ensureCanRegister();
    final token = ++_nextSubscriptionToken;
    _stateUpdaters[token] = Pair(id, updater);
    return StateControllerSubscription._(this, token);
  }

  void _ensureCanRegister() {
    if (_disposed) {
      throw StateError('Cannot register a disposed StateController');
    }
  }

  void _removeSubscription(int token) {
    _stateUpdaters.remove(token);
  }

  void update([List<Object>? ids]) {
    if (_disposed) {
      return;
    }
    final entries = _stateUpdaters.entries.toList(growable: false);
    for (final entry in entries) {
      // A listener may dispose itself (or the controller) while an update is
      // running. Do not invoke a token that was removed earlier in this pass.
      if (_disposed || !_stateUpdaters.containsKey(entry.key)) {
        continue;
      }
      final updater = entry.value;
      if (ids == null || ids.contains(updater.left)) {
        updater.right();
      }
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _stateUpdaters.clear();
    _controllers.removeWhere((element) => identical(element.controller, this));
  }

  void refresh() {
    update();
  }
}

class StateControllerWrapped {
  StateController controller;
  bool autoRemove;
  Object? tag;

  StateControllerWrapped(this.controller, this.autoRemove, this.tag);
}

class StateBuilder<T extends StateController> extends StatefulWidget {
  const StateBuilder({
    super.key,
    this.init,
    this.dispose,
    this.initState,
    this.tag,
    required this.builder,
    this.id,
  });

  final T? init;

  final void Function(T controller)? dispose;

  final void Function(T controller)? initState;

  final Object? tag;

  final Widget Function(T controller) builder;

  Widget builderWrapped(StateController controller) {
    return builder(controller as T);
  }

  void initStateWrapped(StateController controller) {
    return initState?.call(controller as T);
  }

  void disposeWrapped(StateController controller) {
    return dispose?.call(controller as T);
  }

  final Object? id;

  @override
  State<StateBuilder> createState() => _StateBuilderState<T>();
}

class _StateBuilderState<T extends StateController>
    extends State<StateBuilder> {
  late T controller;

  @override
  void initState() {
    if (widget.init != null) {
      StateController.put(widget.init!, tag: widget.tag, autoRemove: true);
    }
    try {
      controller = StateController.find<T>(tag: widget.tag);
    } catch (e) {
      throw "Controller Not Found";
    }
    _subscription = controller.subscribe(() {
      if (mounted) {
        setState(() {});
      }
    }, id: widget.id);
    widget.initStateWrapped(controller);
    super.initState();
  }

  late final StateControllerSubscription _subscription;

  @override
  void dispose() {
    _subscription.dispose();
    try {
      widget.disposeWrapped(controller);
    } finally {
      StateController.remove<T>(widget.tag, true);
      super.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => widget.builderWrapped(controller);
}

abstract class StateWithController<T extends StatefulWidget> extends State<T> {
  late final SimpleController _controller;

  void refresh() {
    _controller.update();
  }

  @override
  @mustCallSuper
  void initState() {
    _controller = StateController.putSimpleController(
      () {
        if (mounted) {
          setState(() {});
        }
      },
      tag,
      refresh: refresh,
    );
    super.initState();
  }

  @override
  @mustCallSuper
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void update() {
    _controller.update();
  }

  Object? get tag;
}

/// A one-shot, immutable token for a [StateController.subscribe] call.
class StateControllerSubscription {
  final StateController _controller;
  final int token;
  bool _disposed = false;

  StateControllerSubscription._(this._controller, this.token);

  bool get isDisposed => _disposed;

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _controller._removeSubscription(token);
  }
}
