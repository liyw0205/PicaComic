import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:webdav_client/webdav_client.dart';

class SyncPointer {
  const SyncPointer(this.etag, {this.known = true});
  final String? etag;

  /// Whether the GET which produced this pointer completed successfully.
  ///
  /// A successful response without an ETag is still a known pointer and can
  /// use the graph re-read as its race detector.  An unknown pointer must not
  /// be turned into an unconditional PUT: a transient GET failure could
  /// otherwise replace a newer remote head.
  final bool known;
}

String _normaliseDirectory(String path) {
  final normalised = path.replaceAll('\\', '/');
  return normalised.endsWith('/') ? normalised : '$normalised/';
}

abstract class SyncTransport {
  Future<List<String>> list();
  Future<String> readText(String name);
  Future<void> download(String name, String destination);
  Future<void> upload(String source, String name);
  Future<void> writeText(String name, String text);
  Future<SyncPointer> pointer();
  Future<bool> compareAndSetPointer(SyncPointer previous, String text);
  void close();
}

class WebdavSyncTransport implements SyncTransport {
  WebdavSyncTransport(List<String> config)
      : client = newClient(config[0], user: config[1], password: config[2]),
        directory = _normaliseDirectory(config[3]) {
    client.setConnectTimeout(8000);
    client.setSendTimeout(60000);
    client.setReceiveTimeout(60000);
  }
  final Client client;
  final String directory;

  @override
  Future<List<String>> list() async => (await client.readDir(directory))
      .map((e) => e.name)
      .whereType<String>()
      .toList();
  @override
  Future<String> readText(String name) async {
    final response = await client.c.req<String>(
        client, 'GET', '$directory$name',
        optionsHandler: (options) => options.responseType = ResponseType.plain);
    final statusCode = response.statusCode;
    if (statusCode != 200) {
      throw StateError('Sync metadata HTTP ${statusCode ?? "unknown"}');
    }
    return response.data!;
  }

  @override
  Future<void> download(String name, String destination) =>
      client.read2File('$directory$name', destination);
  @override
  Future<void> upload(String source, String name) =>
      client.writeFromFile(source, '$directory$name');
  @override
  Future<void> writeText(String name, String text) =>
      client.write('$directory$name', Uint8List.fromList(utf8.encode(text)));
  @override
  Future<SyncPointer> pointer() async {
    try {
      final response = await client.c.req<String>(
          client, 'GET', '${directory}sync-head.json',
          optionsHandler: (options) =>
              options.responseType = ResponseType.plain);
      final statusCode = response.statusCode;
      if (statusCode == 404) return const SyncPointer('*');
      if (statusCode != 200) return const SyncPointer(null, known: false);
      final etag = response.headers.value('etag');
      return SyncPointer(etag != null && !etag.startsWith('W/') ? etag : null);
    } catch (_) {
      return const SyncPointer(null, known: false);
    }
  }

  @override
  Future<bool> compareAndSetPointer(SyncPointer previous, String text) async {
    if (!previous.known) {
      throw StateError('Sync pointer state unavailable');
    }
    final response = await client.c
        .req(client, 'PUT', '${directory}sync-head.json', data: text,
            optionsHandler: (options) {
      options.headers = {
        if (previous.etag != null)
          previous.etag == '*' ? 'If-None-Match' : 'If-Match': previous.etag,
        'content-type': 'application/json'
      };
    });
    final statusCode = response.statusCode;
    if (statusCode == 412) return false;
    if (statusCode == 405 || statusCode == 501) return true;
    if (statusCode == null || statusCode < 200 || statusCode >= 300) {
      throw StateError('Sync pointer HTTP ${statusCode ?? "unknown"}');
    }
    // Immutable descriptors remain the source of truth on servers which do
    // not implement conditional PUT or reject an optional pointer file.
    return true;
  }

  @override
  void close() => client.c.close(force: true);
}
