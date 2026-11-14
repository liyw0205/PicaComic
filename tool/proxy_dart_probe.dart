import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

const proxyProbeTimeout = Duration(seconds: 8);

class SocketByteReader {
  SocketByteReader(Socket socket) {
    subscription = socket.listen(
      (data) {
        buffer.addAll(data);
        wake();
      },
      onError: (Object error, StackTrace stackTrace) {
        this.error = error;
        this.stackTrace = stackTrace;
        wake();
      },
      onDone: () {
        closed = true;
        wake();
      },
      cancelOnError: true,
    );
  }

  final buffer = <int>[];
  final waiters = <Completer<void>>[];
  late final StreamSubscription<List<int>> subscription;
  Object? error;
  StackTrace? stackTrace;
  var closed = false;

  Future<List<int>> read(int count) async {
    while (buffer.length < count) {
      if (error != null) {
        Error.throwWithStackTrace(error!, stackTrace ?? StackTrace.current);
      }
      if (closed) {
        throw const SocketException(
            'Connection closed before enough data was received');
      }
      final completer = Completer<void>();
      waiters.add(completer);
      await completer.future;
    }
    final result = List<int>.of(buffer.take(count));
    buffer.removeRange(0, count);
    return result;
  }

  void wake() {
    final pending = List<Completer<void>>.of(waiters);
    waiters.clear();
    for (final waiter in pending) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  Future<void> cancel() => subscription.cancel();
}

class ProbeProxy {
  ProbeProxy({
    required this.scheme,
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  final String scheme;
  final String host;
  final int port;
  final String? username;
  final String? password;

  bool get isSocks5 => scheme == 'socks5' || scheme == 'socks5h';

  bool get hasAuth =>
      (username ?? '').isNotEmpty || (password ?? '').isNotEmpty;

  String get rule => '${isSocks5 ? 'SOCKS' : 'PROXY'} $host:$port;';

  static ProbeProxy? parse(String value) {
    value = value.trim();
    if (value.isEmpty) return null;
    if (!value.contains('://')) value = 'http://$value';

    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;

    final userInfo = uri.userInfo;
    String? username;
    String? password;
    if (userInfo.isNotEmpty) {
      final index = userInfo.indexOf(':');
      if (index == -1) {
        username = Uri.decodeComponent(userInfo);
      } else {
        username = Uri.decodeComponent(userInfo.substring(0, index));
        password = Uri.decodeComponent(userInfo.substring(index + 1));
      }
    }

    return ProbeProxy(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port,
      username: username,
      password: password,
    );
  }
}

final targets = <String, Uri>{
  'cf-http-204': Uri.http('cp.cloudflare.com', '/generate_204'),
  'gstatic-204': Uri.https('www.gstatic.com', '/generate_204'),
  'gstatic-http': Uri.http('www.gstatic.com', '/generate_204'),
  'google-204': Uri.https('www.google.com', '/generate_204'),
  'android-204': Uri.https('connectivitycheck.gstatic.com', '/generate_204'),
  'cf-trace': Uri.https('www.cloudflare.com', '/cdn-cgi/trace'),
  'msft': Uri.http('www.msftconnecttest.com', '/connecttest.txt'),
  'example': Uri.https('example.com', '/'),
  'e-hentai': Uri.https('e-hentai.org', '/'),
  'nhentai': Uri.https('nhentai.net', '/'),
  'hitomi': Uri.https('hitomi.la', '/'),
};

Future<InternetAddress> resolveProxyAddress(String host) async {
  final parsed = InternetAddress.tryParse(host);
  if (parsed != null) return parsed;
  final addresses = await InternetAddress.lookup(host);
  if (addresses.isEmpty) throw SocketException('Failed host lookup: $host');
  return addresses.first;
}

Future<void> writeAndFlush(Socket socket, List<int> data) async {
  socket.add(data);
  await socket.flush().timeout(proxyProbeTimeout);
}

Future<void> socks5Tunnel(
  Socket socket,
  SocketByteReader reader,
  ProbeProxy proxy,
  String targetHost,
  int targetPort,
) async {
  final methods = proxy.hasAuth ? [0x02] : [0x00];
  await writeAndFlush(socket, [0x05, methods.length, ...methods]);

  final selected = await reader.read(2).timeout(proxyProbeTimeout);
  if (selected[0] != 0x05) {
    throw SocketException('Unsupported SOCKS version: ${selected[0]}');
  }
  if (selected[1] == 0xff) {
    throw const SocketException('SOCKS5 authentication method rejected');
  }
  if (proxy.hasAuth && selected[1] != 0x02) {
    throw SocketException('Unexpected SOCKS5 auth method: ${selected[1]}');
  }

  if (selected[1] == 0x02) {
    final username = utf8.encode(proxy.username ?? '');
    final password = utf8.encode(proxy.password ?? '');
    await writeAndFlush(socket, [
      0x01,
      username.length,
      ...username,
      password.length,
      ...password,
    ]);
    final auth = await reader.read(2).timeout(proxyProbeTimeout);
    if (auth[0] != 0x01 || auth[1] != 0x00) {
      throw const SocketException('SOCKS5 authentication failed');
    }
  } else if (selected[1] != 0x00) {
    throw SocketException('Unsupported SOCKS5 auth method: ${selected[1]}');
  }

  final host = utf8.encode(targetHost);
  await writeAndFlush(socket, [
    0x05,
    0x01,
    0x00,
    0x03,
    host.length,
    ...host,
    (targetPort & 0xff00) >> 8,
    targetPort & 0x00ff,
  ]);

  final response = await reader.read(4).timeout(proxyProbeTimeout);
  if (response[0] != 0x05) {
    throw SocketException('Unsupported SOCKS response: ${response[0]}');
  }
  if (response[1] != 0x00) {
    throw SocketException('SOCKS5 connect failed: ${response[1]}');
  }
  switch (response[3]) {
    case 0x01:
      await reader.read(4).timeout(proxyProbeTimeout);
    case 0x03:
      final length = await reader.read(1).timeout(proxyProbeTimeout);
      await reader.read(length[0]).timeout(proxyProbeTimeout);
    case 0x04:
      await reader.read(16).timeout(proxyProbeTimeout);
    default:
      throw SocketException('Unsupported SOCKS5 address type: ${response[3]}');
  }
  await reader.read(2).timeout(proxyProbeTimeout);
}

Future<String> readHttpProxyHeaders(SocketByteReader reader) async {
  final bytes = <int>[];
  while (bytes.length < 8192) {
    bytes.addAll(await reader.read(1).timeout(proxyProbeTimeout));
    final length = bytes.length;
    if (length >= 4 &&
        bytes[length - 4] == 13 &&
        bytes[length - 3] == 10 &&
        bytes[length - 2] == 13 &&
        bytes[length - 1] == 10) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
  throw const SocketException('HTTP proxy response headers are too large');
}

Future<void> httpTunnel(
  Socket socket,
  SocketByteReader reader,
  ProbeProxy proxy,
  String targetHost,
  int targetPort,
) async {
  final connectHost = targetHost.contains(':') ? '[$targetHost]' : targetHost;
  var auth = '';
  if (proxy.hasAuth) {
    final token = base64Encode(
        utf8.encode('${proxy.username ?? ''}:${proxy.password ?? ''}'));
    auth = 'Proxy-Authorization: Basic $token\r\n';
  }
  await writeAndFlush(
    socket,
    utf8.encode(
      'CONNECT $connectHost:$targetPort HTTP/1.1\r\n'
      'Host: $connectHost:$targetPort\r\n'
      'Proxy-Connection: close\r\n'
      '$auth'
      '\r\n',
    ),
  );
  final headers = await readHttpProxyHeaders(reader);
  final statusLine = headers.split('\r\n').first;
  final parts = statusLine.split(' ');
  final status = parts.length > 1 ? int.tryParse(parts[1]) : null;
  if (status == null || status < 200 || status >= 300) {
    throw SocketException('HTTP CONNECT failed: $statusLine');
  }
}

Future<void> tunnelProbe(ProbeProxy proxy, String name, Uri url) async {
  final stopwatch = Stopwatch()..start();
  Socket? socket;
  SocketByteReader? reader;
  try {
    socket = await Socket.connect(proxy.host, proxy.port,
        timeout: const Duration(seconds: 6));
    reader = SocketByteReader(socket);
    final targetPort =
        url.hasPort ? url.port : (url.isScheme('http') ? 80 : 443);
    if (proxy.isSocks5) {
      await socks5Tunnel(socket, reader, proxy, url.host, targetPort);
    } else {
      await httpTunnel(socket, reader, proxy, url.host, targetPort);
    }
    stopwatch.stop();
    print('${name.padRight(12)} TUN  total=${stopwatch.elapsedMilliseconds}ms');
  } catch (e) {
    stopwatch.stop();
    print(
        '${name.padRight(12)} TUN-FAIL total=${stopwatch.elapsedMilliseconds}ms error=$e');
  } finally {
    await reader?.cancel();
    socket?.destroy();
  }
}

HttpClient createClient(ProbeProxy proxy) {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  client.idleTimeout = const Duration(seconds: 10);
  client.badCertificateCallback = (_, __, ___) => false;

  if (proxy.isSocks5) {
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      Socket? activeSocket;
      final proxyAddress = await resolveProxyAddress(proxy.host);
      final settings = ProxySettings(
        proxyAddress,
        proxy.port,
        username: proxy.hasAuth ? proxy.username : null,
        password: proxy.hasAuth ? proxy.password : null,
      );
      final socketFuture = SocksTCPClient.connect(
        [settings],
        InternetAddress(uri.host, type: InternetAddressType.unix),
        uri.port,
      ).then<Socket>((socket) async {
        activeSocket = socket;
        if (uri.isScheme('https')) {
          final secureSocket = await socket.secure(uri.host);
          activeSocket = secureSocket;
          return secureSocket;
        }
        return socket;
      });
      return ConnectionTask.fromSocket(socketFuture, () {
        activeSocket?.destroy();
      });
    };
  } else {
    client.findProxy = (_) => proxy.rule;
    if (proxy.hasAuth) {
      client.authenticateProxy = (host, port, scheme, realm) async {
        if (host == proxy.host && port == proxy.port) {
          client.addProxyCredentials(
            host,
            port,
            realm ?? '',
            HttpClientBasicCredentials(
              proxy.username ?? '',
              proxy.password ?? '',
            ),
          );
          return true;
        }
        return false;
      };
    }
  }

  return client;
}

HttpClient createCustomSocksClient(ProbeProxy proxy) {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  client.idleTimeout = const Duration(seconds: 10);
  client.badCertificateCallback = (_, __, ___) => false;

  if (!proxy.isSocks5) return createClient(proxy);

  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    Socket? activeSocket;
    final socketFuture = () async {
      final proxyAddress = await resolveProxyAddress(proxy.host);
      var socket = await Socket.connect(
        proxyAddress,
        proxy.port,
        timeout: const Duration(seconds: 6),
      );
      activeSocket = socket;
      final reader = SocketByteReader(socket);
      try {
        await socks5Tunnel(socket, reader, proxy, uri.host, uri.port);
      } finally {
        await reader.cancel();
      }
      if (uri.isScheme('https')) {
        final secureSocket = await SecureSocket.secure(socket, host: uri.host);
        activeSocket = secureSocket;
        return secureSocket;
      }
      return socket;
    }();
    return ConnectionTask.fromSocket(socketFuture, () {
      activeSocket?.destroy();
    });
  };

  return client;
}

Future<void> probe(ProbeProxy proxy, String name, Uri url) async {
  final client = createClient(proxy);
  final stopwatch = Stopwatch()..start();
  try {
    final request =
        await client.getUrl(url).timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Android) AppleWebKit/537.36 PicaComicProbe/1.0');
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    request.headers
        .set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9,en;q=0.8');
    request.headers.set(HttpHeaders.connectionHeader, 'close');
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    request.followRedirects = false;
    request.persistentConnection = false;
    final response = await request.close().timeout(const Duration(seconds: 20));
    await response.take(1).drain().timeout(const Duration(seconds: 3));
    stopwatch.stop();
    print(
        '${name.padRight(12)} OK   code=${response.statusCode} total=${stopwatch.elapsedMilliseconds}ms');
  } catch (e) {
    stopwatch.stop();
    print(
        '${name.padRight(12)} FAIL total=${stopwatch.elapsedMilliseconds}ms error=$e');
  } finally {
    client.close(force: true);
  }
}

Future<void> customProbe(ProbeProxy proxy, String name, Uri url) async {
  final client = createCustomSocksClient(proxy);
  final stopwatch = Stopwatch()..start();
  try {
    final request =
        await client.getUrl(url).timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Android) AppleWebKit/537.36 PicaComicProbe/1.0');
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    request.headers
        .set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9,en;q=0.8');
    request.headers.set(HttpHeaders.connectionHeader, 'close');
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    request.followRedirects = false;
    request.persistentConnection = false;
    final response = await request.close().timeout(const Duration(seconds: 20));
    await response.take(1).drain().timeout(const Duration(seconds: 3));
    stopwatch.stop();
    print(
        '${name.padRight(12)} CUST OK   code=${response.statusCode} total=${stopwatch.elapsedMilliseconds}ms');
  } catch (e) {
    stopwatch.stop();
    print(
        '${name.padRight(12)} CUST FAIL total=${stopwatch.elapsedMilliseconds}ms error=$e');
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final proxyText =
      args.isNotEmpty ? args.first : Platform.environment['PROXY_URL'];
  final proxy = proxyText == null ? null : ProbeProxy.parse(proxyText);
  if (proxy == null) {
    stderr.writeln('Usage: dart run tool/proxy_dart_probe.dart <proxy>');
    exitCode = 2;
    return;
  }

  final proxyAddress = await resolveProxyAddress(proxy.host);
  final tcpStopwatch = Stopwatch()..start();
  Socket? socket;
  try {
    socket = await Socket.connect(proxyAddress, proxy.port,
        timeout: const Duration(seconds: 6));
    tcpStopwatch.stop();
    print('tcp-connect  OK   ${tcpStopwatch.elapsedMilliseconds}ms');
  } catch (e) {
    tcpStopwatch.stop();
    print('tcp-connect  FAIL ${tcpStopwatch.elapsedMilliseconds}ms error=$e');
  } finally {
    socket?.destroy();
  }

  for (final entry in targets.entries) {
    await probe(proxy, entry.key, entry.value);
  }

  print('');
  print('Tunnel-only domain probes');
  for (final entry in <String, Uri>{
    'e-hentai': Uri.https('e-hentai.org', '/'),
    'nhentai': Uri.https('nhentai.net', '/'),
    'hitomi': Uri.https('hitomi.la', '/'),
  }.entries) {
    await tunnelProbe(proxy, entry.key, entry.value);
  }

  print('');
  print('Custom SOCKS5 full request probes');
  for (final entry in <String, Uri>{
    'gstatic-204': Uri.https('www.gstatic.com', '/generate_204'),
    'e-hentai': Uri.https('e-hentai.org', '/'),
    'nhentai': Uri.https('nhentai.net', '/'),
    'hitomi': Uri.https('hitomi.la', '/'),
  }.entries) {
    await customProbe(proxy, entry.key, entry.value);
  }
}
