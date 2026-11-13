import 'package:dio/dio.dart';
import 'package:pica_comic/network/network_logging.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  const secret = 'fixture-secret-93c7';
  final safeUrl = safeNetworkUrl(
    'https://user:$secret@example.org/path?token=$secret&sid=$secret&jwt=$secret&code=$secret&state=$secret&nonce=$secret&csrf_token=$secret&image_key=$secret&page=4#$secret',
  );
  _check(!safeUrl.contains(secret), 'URL credentials or query leaked');
  _check(Uri.parse(safeUrl).queryParameters['page'] == '4',
      'Non-sensitive URL parameters were lost');

  final safeHeaders = safeNetworkHeaders({
    'Authorization': 'Bearer $secret',
    'Set-Cookie': ['session=$secret'],
    'Content-Location': 'https://example.org/?sid=$secret',
    'X-Request-URI': '/download?jwt=$secret',
    'Link': '<https://example.org/?code=$secret>; rel="next"',
    'Content-Type': 'application/json',
  });
  _check(!safeHeaders.toString().contains(secret), 'Header value leaked');
  _check(safeHeaders['Content-Type'] == 'application/json',
      'Safe diagnostic header was hidden');

  final error = DioException(
    requestOptions: RequestOptions(
      path: 'https://example.org/download?token=$secret',
    ),
    message: secret,
    error: secret,
    response: Response(
      requestOptions: RequestOptions(path: '/download'),
      statusCode: 403,
      data: secret,
    ),
  );
  final summary = safeNetworkError(error);
  _check(!summary.contains(secret), 'Dio error details leaked');
  _check(summary.contains('status:403'), 'Dio status was lost');
}
