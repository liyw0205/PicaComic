import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/network/file_downloader.dart';

const fileDownloadCases = [
  'parallel ranges',
  'ignored Range',
  'unknown length',
  'unsupported HEAD',
  'missing partial file',
  'changed validator',
  'validated resume',
  'wrong Content-Range',
  'truncated range',
  'oversized range',
  'cancel during HEAD',
  'cancel subscription',
  'file write failure',
];

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> verifyFileDownload(String scenario) async {
  final bytes =
      Uint8List(scenario == 'parallel ranges' ? 32 * 1024 * 1024 + 1 : 8);
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] = (i % 251) + 1;
  }
  final root = await Directory.systemTemp.createTemp('pica-download-test-');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final url = 'http://127.0.0.1:${server.port}/file';
  final file = File('${root.path}/file.bin');
  final started = Completer<void>();
  int active = 0;
  int peak = 0;
  final ranges = <String?>[];
  server.listen((request) async {
    if (!started.isCompleted) started.complete();
    final response = request.response;
    try {
      response.headers.set('etag', '"version1"');
      if (request.method == 'HEAD') {
        if (scenario.startsWith('cancel ')) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        if (scenario == 'unsupported HEAD') {
          response.statusCode = 405;
        } else if (scenario == 'unknown length') {
          response.headers.chunkedTransferEncoding = true;
        } else {
          response.contentLength = bytes.length;
        }
      } else {
        final range = request.headers.value('range');
        ranges.add(range);
        if (range == null || scenario == 'ignored Range') {
          response.add(bytes);
        } else {
          final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
          final start = int.parse(match[1]!);
          final end = int.parse(match[2]!);
          response.statusCode = 206;
          response.headers
              .set('content-range', 'bytes $start-$end/${bytes.length}');
          final probe = start == 0 && end == 0;
          if (!probe && scenario == 'wrong Content-Range') {
            response.headers
                .set('content-range', 'bytes 9-$end/${bytes.length}');
          }
          active++;
          if (active > peak) peak = active;
          if (!probe && scenario == 'parallel ranges') {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          if (!probe && scenario == 'truncated range') {
            response.add(bytes.sublist(start, end));
          } else if (!probe && scenario == 'oversized range') {
            response.add(bytes.sublist(start, end + 1));
            response.add([0]);
          } else {
            response.add(Uint8List.sublistView(bytes, start, end + 1));
          }
          await response.close();
          active--;
          return;
        }
      }
      await response.close();
    } on IOException {
      // Requests are deliberately cancelled in the lifecycle cases.
    }
  });
  try {
    if (scenario == 'file write failure') {
      await Directory(file.path).create();
    } else if (const {'ignored Range', 'changed validator', 'validated resume'}
        .contains(scenario)) {
      await file.writeAsBytes([...bytes.take(4), 0, 0, 0, 0]);
    }
    if (scenario == 'missing partial file' || scenario == 'ignored Range') {
      await File('${file.path}.download').writeAsString('0-8-8');
    } else if (scenario == 'changed validator' ||
        scenario == 'validated resume') {
      await File('${file.path}.download').writeAsString(jsonEncode({
        'version': 1,
        'url': url,
        'size': 8,
        'validator': scenario == 'changed validator' ? '"old"' : '"version1"',
        'blocks': [
          {'start': 0, 'end': 8, 'downloaded': 4}
        ],
      }));
    }
    final downloader = FileDownloader(url, file.path, null, maxConcurrent: 2);
    final statuses = <DownloadingStatus>[];
    Object? failure;
    if (scenario == 'cancel subscription') {
      final subscription = downloader
          .start()
          .listen(statuses.add, onError: (Object e) => failure = e);
      await started.future;
      await subscription.cancel().timeout(const Duration(seconds: 3));
      _check(statuses.every((s) => !s.isFinished),
          'Cancelled subscription finished');
    } else {
      final result = downloader.start().toList().then((items) {
        statuses.addAll(items);
      }, onError: (Object e) {
        failure = e;
      });
      if (scenario == 'cancel during HEAD') {
        await started.future;
        await downloader.stop().timeout(const Duration(seconds: 3));
      }
      await result.timeout(const Duration(seconds: 15));
      final shouldFail = const {
        'wrong Content-Range',
        'truncated range',
        'oversized range',
        'cancel during HEAD',
        'file write failure',
      }.contains(scenario);
      if (shouldFail) {
        _check(failure != null && statuses.every((s) => !s.isFinished),
            '$scenario was incorrectly marked complete');
      } else {
        _check(failure == null, '$scenario failed: $failure');
        _check(
            statuses.last.isFinished &&
                statuses.last.downloadedBytes == bytes.length &&
                statuses.last.totalBytes == bytes.length,
            'Incorrect final progress');
        final actual = await file.readAsBytes();
        _check(actual.length == bytes.length, 'Incorrect file length');
        for (int i = 0; i < bytes.length; i++) {
          _check(actual[i] == bytes[i], 'Wrong file byte at $i');
        }
        if (scenario == 'validated resume') {
          _check(ranges.last == 'bytes=4-7',
              'Validated bytes were downloaded again');
        }
        if (scenario == 'parallel ranges') {
          _check(peak == 2, 'Parallel request limit was not respected: $peak');
        }
      }
    }
    await downloader.stop();
  } finally {
    await server.close(force: true);
    await root.delete(recursive: true);
  }
}

Future<void> main() async {
  for (final scenario in fileDownloadCases) {
    await verifyFileDownload(scenario);
    stdout.writeln('PASS: $scenario');
  }
}
