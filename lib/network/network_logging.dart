import 'package:dio/dio.dart';

bool _sensitiveField(String name) {
  final key = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return key.contains('authorization') ||
      key.contains('cookie') ||
      key.contains('token') ||
      key.contains('jwt') ||
      key.contains('password') ||
      key.contains('passwd') ||
      key.contains('secret') ||
      key.contains('session') ||
      key == 'sid' ||
      key.endsWith('sid') ||
      key == 'state' ||
      key == 'code' ||
      key.contains('nonce') ||
      key.contains('csrf') ||
      key.contains('xsrf') ||
      key.contains('verifier') ||
      key.contains('assertion') ||
      key.contains('bearer') ||
      key.contains('hmac') ||
      key.contains('credential') ||
      key.contains('signature') ||
      key.endsWith('key') ||
      const {
        'fileid',
        'fileidentifier',
        'sig',
        'ticket',
        'auth',
      }.contains(key);
}

String safeNetworkUrl(String value) {
  try {
    final uri = Uri.parse(value);
    // Build the encoded query explicitly so an empty value keeps its `=`.
    // Uri.replace(queryParameters: ...) serializes `?page=` as `?page`, which
    // can merge with a caller-appended suffix and change the logged URL.
    final query = uri.queryParametersAll.entries.expand((entry) {
      final values =
          _sensitiveField(entry.key) ? const ['<redacted>'] : entry.value;
      return values.map((value) => '${Uri.encodeQueryComponent(entry.key)}='
          '${Uri.encodeQueryComponent(value)}');
    }).join('&');
    final pathSegments = uri.pathSegments.toList();
    for (var index = 0; index + 1 < pathSegments.length; index++) {
      if (pathSegments[index] == 's') {
        pathSegments[index + 1] = '<redacted>';
      }
    }
    final safeUri = uri.hasFragment ? uri.removeFragment() : uri;
    return safeUri
        .replace(
          userInfo: uri.userInfo.isNotEmpty ? '' : null,
          pathSegments: pathSegments,
          query: uri.hasQuery ? query : null,
        )
        .toString();
  } on FormatException {
    return '<invalid URL>';
  }
}

String safeNetworkError(Object? error) {
  if (error is String) return 'String(length:${error.length})';
  if (error is DioException) {
    final request = error.requestOptions;
    final status = error.response?.statusCode;
    return 'DioException(${error.type.name}) ${request.method} '
        '${safeNetworkUrl(request.uri.toString())}'
        '${status == null ? '' : ' status:$status'}';
  }
  return error?.runtimeType.toString() ?? '<null>';
}

Map<String, Object?> safeNetworkHeaders(Map<String, dynamic> headers) {
  return headers.map((key, value) {
    if (_sensitiveField(key)) return MapEntry(key, '<redacted>');
    final normalizedKey = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    if (normalizedKey == 'link') return MapEntry(key, '<redacted>');
    if (normalizedKey.contains('location') ||
        normalizedKey.endsWith('url') ||
        normalizedKey.endsWith('uri') ||
        normalizedKey == 'referer' ||
        normalizedKey == 'referrer') {
      if (value is Iterable) {
        return MapEntry(key, value.map((v) => safeNetworkUrl('$v')).toList());
      }
      return MapEntry(key, safeNetworkUrl('$value'));
    }
    return MapEntry(key, value);
  });
}

// Body values can contain credentials even when their field names look harmless.
String networkPayloadSummary(Object? value) {
  if (value == null) return '<empty>';
  if (value is String) return '<Text length:${value.length}>';
  if (value is Map) return '<Map entries:${value.length}>';
  if (value is List) return '<List length:${value.length}>';
  return '<${value.runtimeType}>';
}
