import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import '../foundation/app.dart';
import '../foundation/log.dart';
import '../tools/atomic_file.dart';
import 'network_logging.dart';

class HttpProxyRequest {
  String host;
  int port;

  var sni = <String>[];

  final void Function() stop;

  HttpProxyRequest(this.host, this.port, this.stop);
}

class _HttpProxyHandler {
  var content = "";
  late Socket client;
  Socket? serverSocket;

  Future<void> handle(Socket c,
      FutureOr<void> Function(HttpProxyRequest request) onRequest) async {
    try {
      client = c;
      await for (var d in client) {
        if (serverSocket == null) {
          content += const Utf8Decoder().convert(d);
          if (content.contains("\n")) {
            if (content.split(" ").first != "CONNECT") {
              client
                  .write("HTTP/1.1 400 Bad Request\nContent-Type: text/plain\n"
                      "Content-Length: 29\n\nBad Request: Invalid Request");
              client.flush();
              client.close();
              return;
            }
            var uri = content
                .split('\n')
                .first
                .split(" ")
                .firstWhere((element) => element.contains(":"));
            bool stop = false;
            var request = HttpProxyRequest(
                uri.split(":").first, int.parse(uri.split(":").last), () {
              stop = true;
            });
            await onRequest(request);
            if (stop) {
              client.close();
              return;
            }
            unawaited(forward(request.host, request.port));
          }
        }
        if (serverSocket != null) {
          serverSocket!.add(d);
        }
      }
      close();
    } catch (e) {
      close();
    }
  }

  void close() {
    try {
      client.close();
      serverSocket?.close();
    } catch (e) {
      //
    }
  }

  Future<void> forward(String host, int port) async {
    try {
      serverSocket = await Socket.connect(host, port);
      serverSocket?.listen((event) {
        client.add(event);
      }, onDone: () {
        client.close();
        serverSocket = null;
      }, onError: (e) {
        client.close();
        serverSocket = null;
      }, cancelOnError: true);
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      client.flush();
    } catch (e) {
      close();
    }
  }
}

typedef RequestHandler = FutureOr<void> Function(HttpProxyRequest request);

class HttpProxyServer {
  HttpProxyServer(this.handler, this.port);

  final RequestHandler handler;

  final int port;

  ServerSocket? socket;

  Future<void> run() {
    return runZonedGuarded<Future<void>>(() async {
          socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
          socket?.listen((event) {
            unawaited(_HttpProxyHandler().handle(event, handler));
          });
        }, (error, stack) {
          LogManager.addLog(LogLevel.error, "Network Proxy",
              "${safeNetworkError(error)}\n$stack");
        }) ??
        Future<void>.value();
  }

  Future<void> close() {
    return socket?.close() ?? Future<void>.value();
  }

  static Isolate? _server;
  static Future<void> _startQueue = Future<void>.value();

  static Future<void> startServer() {
    final operation = _startQueue.then<void>((_) async {
      await ensureConfigFile();
      final config = await _readConfig(App.dataPath);
      _server?.kill();
      _server = await Isolate.spawn<Map<String, dynamic>>(
          _runProxyIsolate, {"dataPath": App.dataPath, "port": config["port"]});
      // The initial validation keeps a bad edit from silently replacing a
      // working proxy with a dead isolate.
    });
    _startQueue = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  static Future<void> reload() {
    return startServer();
  }

  static Future<Map<String, dynamic>> _readConfig(String dataPath) async {
    final file = File("$dataPath/rule.json");
    final value = jsonDecode(await file.readAsString());
    if (value is! Map) {
      throw const FormatException("Proxy config must be an object");
    }
    final config = Map<String, dynamic>.from(value);
    final port = config["port"];
    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException("Proxy config has an invalid port");
    }
    if (config["rule"] is! Map) {
      throw const FormatException("Proxy config has an invalid rule map");
    }
    return config;
  }

  static Future<void> _runProxyIsolate(Map<String, dynamic> message) async {
    final dataPath = message["dataPath"] as String;
    final server = HttpProxyServer((request) async {
      final config = await _readConfig(dataPath);
      final rules = Map<String, dynamic>.from(config["rule"] as Map);
      final replacement = rules[request.host];
      if (replacement is String && replacement.isNotEmpty) {
        request.host = replacement;
      }
    }, message["port"] as int);
    await server.run();
  }

  static Map<String, dynamic> _defaultConfig() {
    return {
      "port": 7891,
      "rule": {
        "picaapi.picacomic.com": "104.21.91.145",
        "img.picacomic.com": "104.21.91.145",
        "storage1.picacomic.com": "104.21.91.145",
        "storage-b.picacomic.com": "104.21.91.145",
        "e-hentai.org": "172.67.0.127",
        "exhentai.org": "178.175.129.254",
        "s.exhentai.org": "178.175.129.254"
      },
      "sni": ["e-hentai.org", "exhentai.org", "s.exhentai.org"]
    };
  }

  /// Ensures the rule file exists without blocking the settings page.
  static Future<void> ensureConfigFile() async {
    final file = File("${App.dataPath}/rule.json");
    if (await file.exists()) return;
    final encoder = JsonEncoder.withIndent(' ' * 4);
    await writeTextFileAtomically(file, encoder.convert(_defaultConfig()));
  }

  static Future<void> createConfigFile() {
    return ensureConfigFile();
  }
}
