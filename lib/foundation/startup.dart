import 'dart:async';

class StartupStep {
  const StartupStep(this.name, this.run,
      {this.essential = true, this.deferUntilReady = false});

  final String name;
  final Future<void> Function() run;
  final bool essential;
  final bool deferUntilReady;
}

class StartupFailure {
  const StartupFailure(this.stage, this.error, this.stackTrace);

  final String stage;
  final Object error;
  final StackTrace stackTrace;
}

class StartupResult {
  const StartupResult(
      {this.failure, this.warnings = const [], this.timings = const {}});

  final StartupFailure? failure;
  final List<StartupFailure> warnings;
  final Map<String, Duration> timings;

  bool get ready => failure == null;
}

/// Retries only unfinished steps, so successfully opened databases and platform
/// subscriptions are not created a second time after a later stage fails.
class StartupCoordinator {
  StartupCoordinator(this.steps, {this.onStepFinished});

  final List<StartupStep> steps;
  final void Function(String stage, Duration elapsed, StartupFailure? failure)?
      onStepFinished;
  final _completed = <String>{};
  final _timings = <String, Duration>{};
  final _inFlight = <String, Future<StartupFailure?>>{};
  Future<StartupResult>? _running;
  Future<void>? _deferredRunning;

  Future<StartupResult> run({bool waitForOptional = true}) {
    final running = _running;
    if (running != null) return running;
    final completer = Completer<StartupResult>();
    _running = completer.future;
    _run(waitForOptional: waitForOptional)
        .then(completer.complete, onError: completer.completeError)
        .whenComplete(() {
      _running = null;
    });
    return completer.future;
  }

  Future<StartupResult> _run({required bool waitForOptional}) async {
    final warnings = <StartupFailure>[];
    for (final step in steps) {
      if (_completed.contains(step.name)) continue;
      if (step.deferUntilReady && !waitForOptional) {
        continue;
      }
      final running = _runStep(step);
      final failure = await running;
      if (failure == null) continue;
      if (step.essential) {
        return StartupResult(
          failure: failure,
          warnings: List.unmodifiable(warnings),
          timings: Map.unmodifiable(_timings),
        );
      }
      warnings.add(failure);
    }
    return StartupResult(
      warnings: List.unmodifiable(warnings),
      timings: Map.unmodifiable(_timings),
    );
  }

  /// Runs explicitly deferred work after the application is ready to render.
  /// Calls made while the same work is running share one future.
  Future<void> runDeferred() {
    final running = _deferredRunning;
    if (running != null) return running;
    final future = _runDeferred();
    _deferredRunning = future;
    future.whenComplete(() {
      if (identical(_deferredRunning, future)) _deferredRunning = null;
    });
    return future;
  }

  Future<void> _runDeferred() async {
    for (final step in steps) {
      if (!step.deferUntilReady || _completed.contains(step.name)) continue;
      await _runStep(step);
    }
  }

  Future<StartupFailure?> _runStep(StartupStep step) {
    final running = _inFlight[step.name];
    if (running != null) return running;
    final future = _runStepInternal(step);
    _inFlight[step.name] = future;
    future.whenComplete(() {
      if (identical(_inFlight[step.name], future)) {
        _inFlight.remove(step.name);
      }
    });
    return future;
  }

  Future<StartupFailure?> _runStepInternal(StartupStep step) async {
    final watch = Stopwatch()..start();
    StartupFailure? failure;
    try {
      await step.run();
      _completed.add(step.name);
    } catch (error, stack) {
      failure = StartupFailure(step.name, error, stack);
    } finally {
      watch.stop();
      _timings[step.name] = watch.elapsed;
      onStepFinished?.call(step.name, watch.elapsed, failure);
    }
    return failure;
  }
}
