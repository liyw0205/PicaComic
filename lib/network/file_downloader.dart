import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pica_comic/network/http_client.dart';

class FileDownloader {
  final String url;
  final String savePath;
  final String? proxy;
  final int maxConcurrent;

  FileDownloader(this.url, this.savePath, this.proxy,
      {this.maxConcurrent = 4}) {
    if (maxConcurrent < 1)
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent');
  }

  final _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Accept-Encoding': 'identity'}));
  final _cancel = CancelToken();
  final _done = Completer<void>();
  RandomAccessFile? _file;
  Future<void> _writes = Future.value();
  final _blocks = <_DownloadBlock>[];
  int _fileSize = 0;
  int _currentBytes = 0;
  int _lastBytes = 0;
  String? _validator;
  bool _canceled = false;
  bool _started = false;
  bool _running = false;
  bool _listenerCancelled = false;
  DateTime _lastCheckpoint = DateTime.fromMillisecondsSinceEpoch(0);

  File get _statusFile => File('$savePath.download');

  Stream<DownloadingStatus> start() {
    if (_started) throw StateError('Downloader has already started');
    _started = true;
    setProxy(proxy);
    late StreamController<DownloadingStatus> controller;
    controller = StreamController<DownloadingStatus>(
      onListen: () {
        _running = true;
        unawaited(_download(controller));
      },
      onCancel: () {
        _listenerCancelled = true;
        return stop();
      },
    );
    return controller.stream;
  }

  DownloadingStatus _status([bool finished = false, int speed = 0]) =>
      DownloadingStatus(
          _currentBytes,
          finished || _fileSize > 0 ? _fileSize : _currentBytes + 1,
          speed,
          finished);

  void _checkCancelled() {
    if (_canceled) {
      throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel);
    }
  }

  Future<Response<ResponseBody>> _get([Map<String, String>? headers]) =>
      _dio.get<ResponseBody>(url,
          cancelToken: _cancel,
          options:
              Options(responseType: ResponseType.stream, headers: headers));

  Future<void> _download(StreamController<DownloadingStatus> controller) async {
    Timer? timer;
    Object? failure;
    StackTrace? failureStack;
    try {
      _checkCancelled();
      try {
        final head = await _dio.head(url, cancelToken: _cancel);
        _fileSize =
            int.tryParse(head.headers.value('content-length') ?? '') ?? 0;
        final etag = head.headers.value('etag');
        _validator = etag != null && !etag.startsWith('W/')
            ? etag
            : head.headers.value('last-modified');
      } on DioException catch (e) {
        if (!const {405, 501}.contains(e.response?.statusCode)) rethrow;
      }
      _checkCancelled();
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_canceled && !controller.isClosed) {
          controller.add(_status(false, _currentBytes - _lastBytes));
          _lastBytes = _currentBytes;
        }
      });
      if (_fileSize <= 0) {
        await _downloadSingle(await _get());
      } else {
        // Probe before starting parallel writes; a server may ignore Range entirely.
        final probe = await _get({'Range': 'bytes=0-0'});
        if (probe.statusCode == 200) {
          await _downloadSingle(probe);
        } else {
          try {
            _validateRange(probe, 0, 1);
          } catch (_) {
            await probe.data?.stream.listen((_) {}).cancel();
            rethrow;
          }
          int received = 0;
          await for (final data in probe.data!.stream) {
            received += data.length;
            if (received > 1)
              throw const FormatException('Invalid range probe length');
          }
          if (received != 1)
            throw const FormatException('Invalid range probe length');
          await _prepareBlocks();
          controller.add(_status());
          await _scheduleDownload();
          if (_currentBytes != _fileSize ||
              _blocks.any((block) =>
                  block.downloadedBytes != block.end - block.start)) {
            throw const FormatException('Incomplete download');
          }
        }
      }
      _checkCancelled();
      await _file!.flush();
      if (await _file!.length() != _fileSize) {
        throw const FormatException('Downloaded file length mismatch');
      }
      if (await _statusFile.exists()) await _statusFile.delete();
    } catch (e, s) {
      failure = e;
      failureStack = s;
      _cancel.cancel('Download stopped');
    } finally {
      timer?.cancel();
      try {
        await _writes.catchError((Object _) {});
        if (_file != null) {
          try {
            await _file!.flush();
            if (failure != null && _blocks.isNotEmpty) await _writeStatus();
          } finally {
            await _file!.close();
          }
        }
      } catch (e, s) {
        failure ??= e;
        failureStack ??= s;
      }
      _file = null;
      _dio.close(force: true);
      if (!_listenerCancelled && !controller.isClosed) {
        if (failure != null) {
          controller.addError(failure, failureStack);
        } else {
          controller.add(_status(true));
        }
      }
      _running = false;
      _done.complete();
      unawaited(controller.close());
    }
  }

  Future<void> _downloadSingle(Response<ResponseBody> response) async {
    if (response.statusCode != 200 || response.data == null) {
      await response.data?.stream.listen((_) {}).cancel();
      throw const FormatException('Expected a complete HTTP response');
    }
    final encoding = response.headers.value('content-encoding');
    final expected = encoding == null || encoding == 'identity'
        ? response.data!.contentLength
        : -1;
    _fileSize = max(0, expected);
    final file = File(savePath);
    await file.parent.create(recursive: true);
    _file = await file.open(mode: FileMode.write);
    if (await _statusFile.exists()) await _statusFile.delete();
    await for (final data in response.data!.stream) {
      _checkCancelled();
      await _file!.writeFrom(data);
      _currentBytes += data.length;
      if (expected >= 0 && _currentBytes > expected) {
        throw const FormatException('Response exceeds Content-Length');
      }
    }
    if (expected >= 0 && _currentBytes != expected) {
      throw const FormatException('Response is shorter than Content-Length');
    }
    _fileSize = _currentBytes;
  }

  void _validateRange(Response<ResponseBody> response, int start, int end) {
    final header = response.headers.value('content-range') ?? '';
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(header);
    final encoding = response.headers.value('content-encoding');
    if (response.statusCode != 206 ||
        match == null ||
        response.data == null ||
        int.parse(match[1]!) != start ||
        int.parse(match[2]!) != end - 1 ||
        int.parse(match[3]!) != _fileSize ||
        (encoding != null && encoding != 'identity')) {
      throw FormatException(
          'Invalid ranged response: ${response.statusCode} $header');
    }
  }

  Future<void> _prepareBlocks() async {
    final file = File(savePath);
    final chunkSize = _fileSize > 1024 * 1024 * 1024
        ? 64 * 1024 * 1024
        : _fileSize > 512 * 1024 * 1024
            ? 32 * 1024 * 1024
            : 16 * 1024 * 1024;
    for (int i = 0; i < _fileSize; i += chunkSize) {
      _blocks.add(_DownloadBlock(i, min(i + chunkSize, _fileSize), 0));
    }
    bool resume = false;
    if (_validator != null &&
        await file.exists() &&
        await file.length() == _fileSize &&
        await _statusFile.exists()) {
      try {
        final state = jsonDecode(await _statusFile.readAsString());
        if (state is Map &&
            state['version'] == 1 &&
            state['url'] == url &&
            state['size'] == _fileSize &&
            state['validator'] == _validator &&
            state['blocks'] is List &&
            (state['blocks'] as List).length == _blocks.length) {
          resume = true;
          for (int i = 0; i < _blocks.length; i++) {
            final saved = state['blocks'][i];
            final block = _blocks[i];
            if (saved is! Map ||
                saved['start'] != block.start ||
                saved['end'] != block.end ||
                saved['downloaded'] is! int ||
                saved['downloaded'] < 0 ||
                saved['downloaded'] > block.end - block.start) {
              resume = false;
              break;
            }
            block.downloadedBytes = saved['downloaded'];
          }
        }
      } on FormatException {
        // Unversioned or damaged state cannot prove which bytes belong to this file.
      }
    }
    await file.parent.create(recursive: true);
    _file = await file.open(mode: resume ? FileMode.append : FileMode.write);
    if (!resume) {
      await _file!.truncate(_fileSize);
      for (final block in _blocks) {
        block.downloadedBytes = 0;
      }
    }
    _currentBytes =
        _blocks.fold(0, (sum, block) => sum + block.downloadedBytes);
    await _writeStatus();
  }

  Future<void> _writeStatus() async {
    final state = {
      'version': 1,
      'url': url,
      'size': _fileSize,
      'validator': _validator,
      'blocks': _blocks
          .map((block) => {
                'start': block.start,
                'end': block.end,
                'downloaded': block.downloadedBytes,
              })
          .toList(),
    };
    final temporary = File('$savePath.download.tmp');
    await temporary.writeAsString(jsonEncode(state), flush: true);
    await temporary.rename(_statusFile.path);
    _lastCheckpoint = DateTime.now();
  }

  Future<void> _scheduleDownload() async {
    int next = 0;
    Future<void> worker() async {
      try {
        while (next < _blocks.length) {
          _checkCancelled();
          final block = _blocks[next++];
          if (block.downloadedBytes == block.end - block.start) continue;
          await _fetchBlock(block);
        }
      } catch (_) {
        _cancel.cancel('A download block failed');
        rethrow;
      }
    }

    await Future.wait(
        List.generate(min(maxConcurrent, _blocks.length), (_) => worker()));
  }

  Future<void> _writeBlock(_DownloadBlock block, Uint8List data,
      {bool checkpoint = false}) {
    final write = _writes.then((_) async {
      _checkCancelled();
      await _file!.setPosition(block.start + block.downloadedBytes);
      await _file!.writeFrom(data);
      block.downloadedBytes += data.length;
      _currentBytes += data.length;
      if (checkpoint ||
          DateTime.now().difference(_lastCheckpoint).inSeconds >= 1) {
        await _file!.flush();
        await _writeStatus();
      }
    });
    _writes = write;
    return write;
  }

  Future<void> _fetchBlock(_DownloadBlock block) async {
    final start = block.start + block.downloadedBytes;
    final response = await _get({
      'Range': 'bytes=$start-${block.end - 1}',
      if (_validator != null) 'If-Range': _validator!,
    });
    try {
      _validateRange(response, start, block.end);
    } catch (_) {
      await response.data?.stream.listen((_) {}).cancel();
      rethrow;
    }
    final buffer = BytesBuilder(copy: false);
    int received = 0;
    await for (final data in response.data!.stream) {
      _checkCancelled();
      received += data.length;
      if (received > block.end - start)
        throw const FormatException('Range overflow');
      buffer.add(data);
      if (buffer.length >= 256 * 1024)
        await _writeBlock(block, buffer.takeBytes());
    }
    if (received != block.end - start)
      throw const FormatException('Truncated range');
    await _writeBlock(block, buffer.takeBytes(), checkpoint: true);
  }

  Future<void> stop() async {
    if (_done.isCompleted) return;
    _canceled = true;
    _cancel.cancel('Download cancelled');
    if (_running) await _done.future;
  }
}

class DownloadingStatus {
  final int downloadedBytes;
  final int totalBytes;
  final bool isFinished;
  final int bytesPerSecond;

  const DownloadingStatus(
      this.downloadedBytes, this.totalBytes, this.bytesPerSecond,
      [this.isFinished = false]);

  @override
  String toString() =>
      'Downloaded: $downloadedBytes/$totalBytes ${isFinished ? "Finished" : ""}';
}

class _DownloadBlock {
  final int start;
  final int end;
  int downloadedBytes;

  _DownloadBlock(this.start, this.end, this.downloadedBytes);
}
