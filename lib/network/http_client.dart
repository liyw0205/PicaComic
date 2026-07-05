import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:socks5_proxy/socks_client.dart';
import '../base.dart';
import '../foundation/app.dart';

class AppProxyConfig {
  AppProxyConfig({
    required this.scheme,
    required this.host,
    required this.port,
    this.username = "",
    this.password = "",
    this.useHostRules = false,
  });

  final String scheme;
  final String host;
  final int port;
  final String username;
  final String password;
  final bool useHostRules;

  bool get isSocks5 => scheme == "socks5";

  bool get hasAuth => username.isNotEmpty || password.isNotEmpty;

  String get connectionHost {
    if (host.startsWith("[") && host.endsWith("]")) {
      return host.substring(1, host.length - 1);
    }
    return host;
  }

  String get hostPort {
    if (connectionHost.contains(":")) {
      return "[$connectionHost]:$port";
    }
    return "$connectionHost:$port";
  }

  String get userInfo {
    if (!hasAuth) return "";
    return "${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}";
  }

  String get uriString {
    var auth = hasAuth ? "$userInfo@" : "";
    return "$scheme://$auth$hostPort";
  }

  String get proxyRule => "${isSocks5 ? "SOCKS" : "PROXY"} $hostPort;";

  Uri? get http2ProxyUri => isSocks5 ? null : Uri.parse(uriString);

  static String normalizeScheme(String scheme) {
    scheme = scheme.toLowerCase();
    if (scheme == "socks" || scheme == "socket5") return "socks5";
    if (scheme == "https") return "http";
    return scheme;
  }

  static int defaultPort(String scheme) => scheme == "socks5" ? 1080 : 80;

  static AppProxyConfig? tryParse(String value) {
    value = value.trim();
    if (value.isEmpty || value == "0") return null;
    value = value.replaceFirst(RegExp(r'^PROXY\s+', caseSensitive: false), "");
    value = value.replaceFirst(
        RegExp(r'^SOCKS5?\s+', caseSensitive: false), "socks5://");
    value = value.replaceAll(";", "");

    var rawScheme = "";
    if (value.contains("://")) {
      rawScheme = value.substring(0, value.indexOf("://"));
    }
    var scheme = normalizeScheme(rawScheme.isEmpty ? "http" : rawScheme);
    if (scheme != "http" && scheme != "socks5") return null;

    var uriText = value.contains("://") ? value : "$scheme://$value";
    Uri uri;
    try {
      uri = Uri.parse(uriText);
    } catch (_) {
      return null;
    }
    var host = uri.host;
    if (host.isEmpty) return null;
    var port = uri.hasPort ? uri.port : defaultPort(scheme);
    if (port <= 0 || port > 65535) return null;

    var username = "";
    var password = "";
    if (uri.userInfo.isNotEmpty) {
      var index = uri.userInfo.indexOf(":");
      if (index == -1) {
        username = Uri.decodeComponent(uri.userInfo);
      } else {
        username = Uri.decodeComponent(uri.userInfo.substring(0, index));
        password = Uri.decodeComponent(uri.userInfo.substring(index + 1));
      }
    }
    return AppProxyConfig(
      scheme: scheme,
      host: host,
      port: port,
      username: username,
      password: password,
    );
  }
}

AppProxyConfig? _getHostRulesProxyConfig() {
  try {
    final file = File("${App.dataPath}/rule.json");
    var json = const JsonDecoder().convert(file.readAsStringSync());
    var port = json["port"] is int
        ? json["port"] as int
        : int.tryParse(json["port"].toString());
    if (port == null || port <= 0 || port > 65535) return null;
    return AppProxyConfig(
      scheme: "http",
      host: InternetAddress.loopbackIPv4.address,
      port: port,
      useHostRules: true,
    );
  } catch (e, s) {
    LogManager.addLog(
        LogLevel.error, "Network", "Read host rules failed\n$e\n$s");
    return null;
  }
}

///获取系统设置中的代理, 仅windows,安卓有效
Future<AppProxyConfig?> _getSystemProxyConfig() async {
  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("com.github.pacalini.pica_comic/proxy");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  if (res == "No Proxy") return null;
  //windows上部分代理工具会将代理设置为http=127.0.0.1:8888;https=127.0.0.1:8888;ftp=127.0.0.1:7890的形式
  //下面的代码从中提取正确的代理地址
  if (res.contains("https")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return AppProxyConfig.tryParse(proxy.substring(6));
      }
    }
  }

  return AppProxyConfig.tryParse(res);
}

Future<AppProxyConfig?> getProxyConfig() async {
  // 手动代理优先，避免已废弃的 Hosts 功能覆盖用户显式设置的代理。
  if (appdata.settings[8].removeAllBlank != "" && appdata.settings[8] != "0") {
    return AppProxyConfig.tryParse(appdata.settings[8]);
  }

  // 对于安卓, 将获取WIFI设置中的代理。
  if (appdata.settings[8] == "0") {
    var systemProxy = await _getSystemProxyConfig();
    if (systemProxy != null) return systemProxy;
  }

  if (appdata.settings[58] == "1") {
    return _getHostRulesProxyConfig();
  }

  return null;
}

Future<String?> getProxy() async {
  var proxy = await getProxyConfig();
  if (proxy == null) return null;
  if (proxy.scheme == "http" && !proxy.hasAuth) {
    return proxy.hostPort;
  }
  return proxy.uriString;
}

ProxyHttpOverrides? proxyHttpOverrides;

///获取代理设置并应用
Future<void> setNetworkProxy() async {
  //Image加载使用的是Image.network()和CachedNetworkImage(), 均使用flutter内置http进行网络请求
  var proxyConfig = await getProxyConfig();
  var proxy = proxyConfig?.proxyRule;

  if (proxyHttpOverrides == null) {
    proxyHttpOverrides = ProxyHttpOverrides(proxy, proxyConfig);
    HttpOverrides.global = proxyHttpOverrides;
    Log.info("Network", "Set Proxy $proxy");
  } else if (proxyHttpOverrides!.proxy != proxy ||
      proxyHttpOverrides!.proxyConfig?.uriString != proxyConfig?.uriString ||
      proxyHttpOverrides!.proxyConfig?.useHostRules !=
          proxyConfig?.useHostRules) {
    proxyHttpOverrides!.proxy = proxy;
    proxyHttpOverrides!.proxyConfig = proxyConfig;
    Log.info("Network", "Set Proxy $proxy");
  }
}

void setProxy(String? proxy) {
  var proxyConfig = proxy == null ? null : AppProxyConfig.tryParse(proxy);
  var proxyRule = proxyConfig?.proxyRule;
  var proxyHttpOverrides = ProxyHttpOverrides(proxyRule, proxyConfig);
  HttpOverrides.global = proxyHttpOverrides;
}

class ProxyHttpOverrides extends HttpOverrides {
  String? proxy;
  AppProxyConfig? proxyConfig;

  ProxyHttpOverrides(this.proxy, [this.proxyConfig]);

  String? get proxyStr {
    var config = proxyConfig;
    if (config != null) {
      return (config.isSocks5 || config.hasAuth)
          ? config.uriString
          : config.hostPort;
    }
    return proxy
        ?.replaceAll("PROXY", "")
        .replaceAll("SOCKS", "")
        .replaceAll(" ", "")
        .replaceAll(";", "");
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    final config = proxyConfig;
    client.connectionTimeout = const Duration(seconds: 5);

    if (config?.isSocks5 == true) {
      client.findProxy = (uri) => "DIRECT";
      _setSocks5Proxy(client, config!, context);
    } else {
      client.findProxy = (uri) => proxy ?? "DIRECT";
    }

    if (config?.hasAuth == true && config?.isSocks5 != true) {
      client.authenticateProxy = (host, port, scheme, realm) async {
        if (host == config!.connectionHost && port == config.port) {
          client.addProxyCredentials(
            host,
            port,
            realm ?? "",
            HttpClientBasicCredentials(
              config.username,
              config.password,
            ),
          );
          return true;
        }
        return false;
      };
    }
    client.idleTimeout = const Duration(seconds: 100);
    client.badCertificateCallback = _allowBadCertificate;
    return client;
  }

  Future<InternetAddress> _resolveProxyAddress(String host) async {
    var parsed = InternetAddress.tryParse(host);
    if (parsed != null) return parsed;
    var addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      throw SocketException("Failed host lookup: $host");
    }
    return addresses.first;
  }

  void _setSocks5Proxy(
    HttpClient client,
    AppProxyConfig config,
    SecurityContext? context,
  ) {
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      Socket? activeSocket;
      var proxyAddress = await _resolveProxyAddress(config.connectionHost);
      var settings = ProxySettings(
        proxyAddress,
        config.port,
        username: config.hasAuth ? config.username : null,
        password: config.hasAuth ? config.password : null,
      );
      var socketFuture = SocksTCPClient.connect(
        [settings],
        InternetAddress(uri.host, type: InternetAddressType.unix),
        uri.port,
      ).then<Socket>((socket) async {
        activeSocket = socket;
        if (uri.isScheme("https")) {
          var secureSocket = await socket.secure(
            uri.host,
            context: context,
            onBadCertificate: (cert) =>
                _allowBadCertificate(cert, uri.host, uri.port),
          );
          activeSocket = secureSocket;
          return secureSocket;
        }
        return socket;
      });
      return ConnectionTask.fromSocket(socketFuture, () {
        activeSocket?.destroy();
      });
    };
  }

  bool _allowBadCertificate(X509Certificate cert, String host, int port) {
    if (host.contains("cdn")) return true;
    final ipv4RegExp = RegExp(
        r'^((25[0-5]|2[0-4]\d|[0-1]?\d?\d)(\.(25[0-5]|2[0-4]\d|[0-1]?\d?\d)){3})$');
    if (ipv4RegExp.hasMatch(host)) {
      // 允许ip访问
      return true;
    }
    return false;
  }
}
