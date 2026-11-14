import 'dart:async';

class StartupStep {
  const StartupStep(this.name, this.run, {this.essential = true});

  final String name;
  final Future<void> Function() run;
  final bool essential;
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
  Future<StartupResult>? _running;

  Future<StartupResult> run() {
    final running = _running;
    if (running != null) return running;
    final completer = Completer<StartupResult>();
    _running = completer.future;
    _run()
        .then(completer.complete, onError: completer.completeError)
        .whenComplete(() {
      _running = null;
    });
    return completer.future;
  }

  Future<StartupResult> _run() async {
    final warnings = <StartupFailure>[];
    for (final step in steps) {
      if (_completed.contains(step.name)) continue;
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
      if (failure != null) {
        if (step.essential) {
          return StartupResult(
            failure: failure,
            warnings: List.unmodifiable(warnings),
            timings: Map.unmodifiable(_timings),
          );
        }
        warnings.add(failure);
      }
    }
    return StartupResult(
      warnings: List.unmodifiable(warnings),
      timings: Map.unmodifiable(_timings),
    );
  }
}
