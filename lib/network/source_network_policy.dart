import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A stable category used by built-in and JavaScript comic sources.
///
/// The category intentionally does not include exception text.  Callers can
/// show a localized message while diagnostics retain only bounded counters.
enum SourceNetworkErrorKind {
  cancelled,
  timeout,
  connection,
  tls,
  authentication,
  rateLimited,
  server,
  client,
  responseTooLarge,
  circuitOpen,
  parse,
  unknown,
}

class SourceNetworkConfig {
  const SourceNetworkConfig({
    this.maxConcurrent = 4,
    this.minInterval = const Duration(milliseconds: 100),
    this.maxResponseBytes = 32 * 1024 * 1024,
    this.maxRetries = 1,
    this.baseBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 8),
    this.failureThreshold = 3,
    this.circuitCooldown = const Duration(seconds: 30),
  })  : assert(maxConcurrent > 0),
        assert(maxResponseBytes > 0),
        assert(maxRetries >= 0),
        assert(failureThreshold > 0);

  final int maxConcurrent;
  final Duration minInterval;
  final int maxResponseBytes;
  final int maxRetries;
  final Duration baseBackoff;
  final Duration maxBackoff;
  final int failureThreshold;
  final Duration circuitCooldown;
}

class SourceNetworkException implements Exception {
  SourceNetworkException({
    required this.kind,
    required this.sourceKey,
    this.statusCode,
    this.retryAfter,
    required this.message,
  });

  final SourceNetworkErrorKind kind;
  final String sourceKey;
  final int? statusCode;
  final Duration? retryAfter;
  final String message;

  @override
  String toString() => 'SourceNetworkException(${kind.name})';
}

class SourceNetworkHealth {
  int requests = 0;
  int successes = 0;
  int failures = 0;
  int retries = 0;
  int cancellations = 0;
  int rateLimited = 0;
  int authenticationFailures = 0;
  int serverFailures = 0;
  int connectionFailures = 0;
  int parseFailures = 0;
  int consecutiveFailures = 0;
  DateTime? openedUntil;

  String get state {
    final until = openedUntil;
    if (until != null && until.isAfter(DateTime.now())) return 'open';
    return consecutiveFailures == 0 ? 'healthy' : 'degraded';
  }

  Map<String, Object?> toJson() {
    final until = openedUntil;
    final remaining = until == null
        ? 0
        : until.difference(DateTime.now()).inMilliseconds.clamp(0, 1 << 31);
    return {
      'state': state,
      'requests': requests,
      'successes': successes,
      'failures': failures,
      'retries': retries,
      'cancelled': cancellations,
      'rateLimited': rateLimited,
      'authenticationFailures': authenticationFailures,
      'serverFailures': serverFailures,
      'connectionFailures': connectionFailures,
      'parseFailures': parseFailures,
      'consecutiveFailures': consecutiveFailures,
      'cooldownRemainingMs': remaining,
    };
  }
}

/// A per-source request budget shared by Dart and JavaScript sources.
///
/// The policy is deliberately transport-facing: existing source APIs keep
/// their signatures, while retries and budgets are applied before bytes reach
/// a parser.  A host is used as a fallback key for old callers that do not
/// provide a source key.
class SourceNetworkPolicy {
  SourceNetworkPolicy({
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final SourceNetworkPolicy instance = SourceNetworkPolicy();
  static const int maxBuckets = 256;

  final DateTime Function() _now;
  final Map<String, SourceNetworkConfig> _configs =
      <String, SourceNetworkConfig>{};
  final Map<String, _SourceBucket> _buckets = <String, _SourceBucket>{};

  void configure(String sourceKey,
      [SourceNetworkConfig config = const SourceNetworkConfig()]) {
    final key = _normaliseKey(sourceKey);
    if (key == null) return;
    _configs[key] = config;
    final bucket = _buckets[key];
    if (bucket != null) {
      if (bucket.config.maxConcurrent != config.maxConcurrent) {
        bucket.limiter = _AsyncLimiter(config.maxConcurrent);
      }
      bucket.config = config;
    }
  }

  SourceNetworkConfig configFor(String sourceKey) {
    final key = _normaliseKey(sourceKey);
    return (key == null ? null : _configs[key]) ?? const SourceNetworkConfig();
  }

  String keyFor(RequestOptions options) {
    final extra = options.extra;
    final explicit =
        extra['sourceKey'] ?? extra['source_key'] ?? extra['picaSourceKey'];
    final key = _normaliseKey(explicit?.toString());
    if (key != null) return key;
    final host = options.uri.host.toLowerCase();
    return host.isEmpty ? 'unknown' : 'host:$host';
  }

  Future<SourceNetworkLease> beforeRequest(
    RequestOptions options, {
    Future<void>? cancelFuture,
  }) async {
    final key = keyFor(options);
    final bucket = _bucket(key);
    final health = bucket.health;
    health.requests++;
    final openedUntil = bucket.openedUntil;
    if (openedUntil != null && openedUntil.isAfter(_now())) {
      throw SourceNetworkException(
        kind: SourceNetworkErrorKind.circuitOpen,
        sourceKey: key,
        message: 'Source circuit is open',
      );
    }

    final permit = await bucket.limiter.acquire(options, cancelFuture);
    try {
      final wait = bucket.nextAllowed.difference(_now());
      if (wait > Duration.zero) {
        final cancelled = await _waitOrCancel(wait, cancelFuture);
        if (cancelled) {
          throw _cancelled(options, key);
        }
      }
      bucket.nextAllowed = _now().add(bucket.config.minInterval);
      final openedAfterWait = bucket.openedUntil;
      if (openedAfterWait != null && openedAfterWait.isAfter(_now())) {
        throw SourceNetworkException(
          kind: SourceNetworkErrorKind.circuitOpen,
          sourceKey: key,
          message: 'Source circuit is open',
        );
      }
      return SourceNetworkLease._(bucket, permit, key);
    } catch (_) {
      permit.release();
      rethrow;
    }
  }

  bool shouldRetry(
    RequestOptions options,
    SourceNetworkErrorKind kind,
    int attempt,
    String sourceKey,
  ) {
    final method = options.method.toUpperCase();
    if (!const {'GET', 'HEAD'}.contains(method)) return false;
    if (attempt >= configFor(sourceKey).maxRetries) return false;
    return const {
      SourceNetworkErrorKind.timeout,
      SourceNetworkErrorKind.connection,
      SourceNetworkErrorKind.rateLimited,
      SourceNetworkErrorKind.server,
    }.contains(kind);
  }

  Duration retryDelay(
    String sourceKey,
    int attempt, {
    Duration? retryAfter,
  }) {
    final config = configFor(sourceKey);
    if (retryAfter != null && retryAfter > Duration.zero) {
      return retryAfter > config.maxBackoff ? config.maxBackoff : retryAfter;
    }
    if (attempt <= 0) return Duration.zero;
    var micros = config.baseBackoff.inMicroseconds;
    for (var i = 1; i < attempt; i++) {
      if (micros >= config.maxBackoff.inMicroseconds) {
        micros = config.maxBackoff.inMicroseconds;
        break;
      }
      micros *= 2;
    }
    micros = micros.clamp(0, config.maxBackoff.inMicroseconds);
    return Duration(microseconds: micros);
  }

  SourceNetworkErrorKind classify(Object error, {int? statusCode}) {
    if (error is SourceNetworkException) return error.kind;
    if (error is DioException) {
      if (error.type == DioExceptionType.cancel) {
        return SourceNetworkErrorKind.cancelled;
      }
      final code = error.response?.statusCode ?? statusCode;
      final byStatus = classifyStatus(code);
      if (byStatus != null) return byStatus;
      if (error.type == DioExceptionType.badCertificate ||
          error.error is HandshakeException) {
        return SourceNetworkErrorKind.tls;
      }
      if (const {
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      }.contains(error.type)) {
        return SourceNetworkErrorKind.timeout;
      }
      if (error.type == DioExceptionType.connectionError ||
          error.error is SocketException ||
          error.error is HttpException) {
        return SourceNetworkErrorKind.connection;
      }
      if (error.type == DioExceptionType.badResponse) {
        return SourceNetworkErrorKind.server;
      }
    }
    if (error is SocketException || error is HttpException) {
      return SourceNetworkErrorKind.connection;
    }
    if (error is TimeoutException) return SourceNetworkErrorKind.timeout;
    if (error is FormatException || error is TypeError) {
      return SourceNetworkErrorKind.parse;
    }
    return SourceNetworkErrorKind.unknown;
  }

  SourceNetworkErrorKind? classifyStatus(int? statusCode) {
    if (statusCode == null || statusCode < 400) return null;
    if (statusCode == 401 || statusCode == 403) {
      return SourceNetworkErrorKind.authentication;
    }
    if (statusCode == 408) return SourceNetworkErrorKind.timeout;
    if (statusCode == 429) return SourceNetworkErrorKind.rateLimited;
    if (statusCode >= 500) return SourceNetworkErrorKind.server;
    return SourceNetworkErrorKind.client;
  }

  Duration? retryAfter(ResponseBody response) {
    final raw = response.headers['retry-after']?.first;
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    DateTime? date;
    try {
      date = HttpDate.parse(raw);
    } catch (_) {
      date = null;
    }
    if (date == null) return null;
    final delay = date.difference(_now());
    return delay.isNegative ? Duration.zero : delay;
  }

  ResponseBody enforceResponseLimit(
    ResponseBody response,
    String sourceKey,
  ) {
    final max = configFor(sourceKey).maxResponseBytes;
    if (response.contentLength > max) {
      throw SourceNetworkException(
        kind: SourceNetworkErrorKind.responseTooLarge,
        sourceKey: sourceKey,
        statusCode: response.statusCode,
        message: 'Response exceeds source limit',
      );
    }
    final original = response.stream;
    response.stream =
        _limitedStream(original, max, sourceKey, response.statusCode);
    return response;
  }

  void reportSuccess(SourceNetworkLease lease, {ResponseBody? response}) {
    final health = lease._bucket.health;
    health.successes++;
    health.consecutiveFailures = 0;
    if (response == null) {
      lease.release();
      return;
    }
    response.stream = _releaseAfterStream(response.stream, lease);
  }

  void reportResponse(SourceNetworkLease lease, int? statusCode) {
    final kind = classifyStatus(statusCode);
    if (kind == null) {
      reportSuccess(lease);
      return;
    }
    final error = SourceNetworkException(
      kind: kind,
      sourceKey: lease.sourceKey,
      statusCode: statusCode,
      message: 'HTTP response classified as ${kind.name}',
    );
    reportFailure(lease, error);
  }

  void recordRetry(String sourceKey) {
    _bucket(_normaliseKey(sourceKey) ?? 'unknown').health.retries++;
  }

  void reportFailure(SourceNetworkLease lease, Object error) {
    if (lease._released) return;
    final kind = classify(error);
    final health = lease._bucket.health;
    health.failures++;
    switch (kind) {
      case SourceNetworkErrorKind.cancelled:
        health.cancellations++;
      case SourceNetworkErrorKind.rateLimited:
        health.rateLimited++;
      case SourceNetworkErrorKind.authentication:
        health.authenticationFailures++;
      case SourceNetworkErrorKind.server:
        health.serverFailures++;
      case SourceNetworkErrorKind.connection:
      case SourceNetworkErrorKind.timeout:
        health.connectionFailures++;
      case SourceNetworkErrorKind.parse:
        health.parseFailures++;
      default:
        break;
    }
    if (const {
      SourceNetworkErrorKind.connection,
      SourceNetworkErrorKind.timeout,
      SourceNetworkErrorKind.rateLimited,
      SourceNetworkErrorKind.server,
    }.contains(kind)) {
      health.consecutiveFailures++;
      if (health.consecutiveFailures >= lease._bucket.config.failureThreshold) {
        lease._bucket.openedUntil =
            _now().add(lease._bucket.config.circuitCooldown);
      }
    } else {
      // Client, parse, TLS, cancellation and size failures are not a
      // consecutive transient outage and must not contribute to the circuit.
      health.consecutiveFailures = 0;
    }
    lease.release();
  }

  Map<String, Object?> diagnosticSummary() => {
        for (final entry in _buckets.entries)
          entry.key: entry.value.health.toJson(),
      };

  void reset() {
    _buckets.clear();
    _configs.clear();
  }

  _SourceBucket _bucket(String key) {
    var bucket = _buckets[key];
    if (bucket != null) return bucket;
    if (_buckets.length >= maxBuckets) {
      key = 'overflow';
      bucket = _buckets[key];
      if (bucket != null) return bucket;
    }
    final config = _configs[key] ?? const SourceNetworkConfig();
    bucket = _SourceBucket(config);
    _buckets[key] = bucket;
    return bucket;
  }

  Future<bool> _waitOrCancel(
      Duration duration, Future<void>? cancelFuture) async {
    if (cancelFuture == null) {
      await Future<void>.delayed(duration);
      return false;
    }
    return Future.any<bool>([
      Future<void>.delayed(duration).then((_) => false),
      cancelFuture.then((_) => true),
    ]);
  }

  DioException _cancelled(RequestOptions options, String sourceKey) =>
      DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
        error: SourceNetworkException(
          kind: SourceNetworkErrorKind.cancelled,
          sourceKey: sourceKey,
          message: 'Request cancelled while waiting for source budget',
        ),
      );

  String? _normaliseKey(String? value) {
    if (value == null) return null;
    final key = value.trim().toLowerCase();
    if (key.isEmpty ||
        key.length > 96 ||
        !RegExp(r'^[a-z0-9._:-]+$').hasMatch(key)) {
      return null;
    }
    return key;
  }

  Stream<Uint8List> _limitedStream(
    Stream<Uint8List> source,
    int max,
    String sourceKey,
    int statusCode,
  ) async* {
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      if (total > max) {
        throw SourceNetworkException(
          kind: SourceNetworkErrorKind.responseTooLarge,
          sourceKey: sourceKey,
          statusCode: statusCode,
          message: 'Response exceeds source limit',
        );
      }
      yield chunk;
    }
  }

  Stream<Uint8List> _releaseAfterStream(
      Stream<Uint8List> source, SourceNetworkLease lease) async* {
    try {
      await for (final chunk in source) {
        yield chunk;
      }
    } finally {
      lease.release();
    }
  }
}

class SourceNetworkLease {
  SourceNetworkLease._(this._bucket, this._permit, this.sourceKey);

  final _SourceBucket _bucket;
  final _Permit _permit;
  final String sourceKey;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _permit.release();
  }
}

class _SourceBucket {
  _SourceBucket(this.config) : limiter = _AsyncLimiter(config.maxConcurrent);

  SourceNetworkConfig config;
  _AsyncLimiter limiter;
  DateTime nextAllowed = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? openedUntil;
  final SourceNetworkHealth health = SourceNetworkHealth();
}

class _Waiter {
  final Completer<_Permit> completer = Completer<_Permit>();
  bool done = false;
}

class _AsyncLimiter {
  _AsyncLimiter(this.limit);

  final int limit;
  int active = 0;
  final Queue<_Waiter> queue = Queue<_Waiter>();

  Future<_Permit> acquire(RequestOptions options, Future<void>? cancelFuture) {
    if (active < limit) {
      active++;
      return Future.value(_Permit(this));
    }
    final waiter = _Waiter();
    queue.addLast(waiter);
    void cancel() {
      if (waiter.done) return;
      waiter.done = true;
      queue.remove(waiter);
      waiter.completer.completeError(DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      ));
    }

    cancelFuture?.then((_) => cancel());
    return waiter.completer.future;
  }

  void release() {
    if (active > 0) active--;
    while (queue.isNotEmpty) {
      final waiter = queue.removeFirst();
      if (waiter.done) continue;
      waiter.done = true;
      active++;
      waiter.completer.complete(_Permit(this));
      break;
    }
  }
}

class _Permit {
  _Permit(this.owner);

  final _AsyncLimiter owner;
  bool released = false;

  void release() {
    if (released) return;
    released = true;
    owner.release();
  }
}
