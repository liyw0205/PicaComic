import 'dart:async';

/// Return the first reachable line, or null when every probe fails or times out.
Future<int?> selectJmDomain(
  List<String> domains,
  Future<bool> Function(String domain) probe, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  if (domains.isEmpty) return null;
  final result = Completer<int?>();
  var remaining = domains.length;
  for (var i = 0; i < domains.length; i++) {
    final index = i;
    unawaited(() async {
      try {
        final available = await Future.sync(() => probe(domains[index]))
            .timeout(timeout, onTimeout: () => false);
        if (available && !result.isCompleted) result.complete(index);
      } catch (_) {
        // One failed line must not prevent the other probes from finishing.
      } finally {
        remaining--;
        if (remaining == 0 && !result.isCompleted) result.complete(null);
      }
    }());
  }
  return result.future;
}
