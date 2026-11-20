import 'dart:async';
import 'dart:convert';

const nhentaiAuthCookieNames = {'sessionid', 'access_token', 'refresh_token'};

bool hasNhentaiSession(Map<String, String> values) {
  for (final name in ['sessionid', 'access_token']) {
    final value = values[name]?.trim();
    if (value != null &&
        value.isNotEmpty &&
        value != 'null' &&
        value != 'undefined') {
      return true;
    }
  }
  return false;
}

bool syncNhentaiAccountMarker(Map<String, dynamic> sourceData, bool logged) {
  final marker = logged ? 'ok' : null;
  if (sourceData['account'] == marker) return false;
  sourceData['account'] = marker;
  return true;
}

Map<String, String> decodeNhentaiStorage(dynamic result) {
  try {
    dynamic decoded = result is String ? jsonDecode(result) : result;
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  } catch (_) {
    return {};
  }
}

/// Owns one login window. Cancellation invalidates pending async probes.
class NhentaiLoginFlow {
  final _result = Completer<bool>();
  bool _probing = false;

  Future<bool> get result => _result.future;
  bool get active => !_result.isCompleted;

  void cancel() {
    if (active) _result.complete(false);
  }

  Future<void> probe({
    required Future<Map<String, String>> Function() readCookies,
    required Future<Map<String, String>> Function() readStorage,
    required Future<String?> Function() readUserAgent,
    required void Function(Map<String, String>, String?) persist,
    required void Function() close,
  }) async {
    if (!active || _probing) return;
    _probing = true;
    try {
      final cookies = Map<String, String>.from(await readCookies());
      Map<String, String> storage;
      try {
        storage = await readStorage();
      } catch (_) {
        storage = const {};
      }
      // Native cookies take precedence. Only known auth keys may be recovered
      // from browser storage; CSRF tokens and preferences are not sessions.
      bool usable(String? value) {
        final normalized = value?.trim();
        return normalized != null &&
            normalized.isNotEmpty &&
            normalized != 'null' &&
            normalized != 'undefined';
      }

      for (final name in nhentaiAuthCookieNames) {
        if (!usable(cookies[name]) && usable(storage[name])) {
          cookies[name] = storage[name]!;
        }
      }
      if (!active || !hasNhentaiSession(cookies)) return;
      final userAgent = await readUserAgent();
      if (!active) return;
      persist(cookies, userAgent);
      _result.complete(true);
      close();
    } finally {
      _probing = false;
    }
  }
}
