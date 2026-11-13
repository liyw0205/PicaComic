import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:pica_comic/network/eh_network/image_response_utils.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _expectFormatException(Future<void> Function() action) async {
  try {
    await action();
  } on FormatException {
    return;
  }
  throw StateError('Invalid response was accepted');
}

Future<void> main() async {
  final bytes =
      Uint8List.fromList(image.encodePng(image.Image(width: 2, height: 2)));
  final written = BytesBuilder(copy: false);
  final progress = <int>[];
  Uint8List? completed;

  await for (final event in readEhImageResponse(
    Stream<List<int>>.fromIterable([
      bytes.sublist(0, 12),
      bytes.sublist(12, 27),
      bytes.sublist(27),
    ]),
    expectedBytes: bytes.length,
    writeChunk: (chunk) async => written.add(chunk),
  )) {
    if (event is EhImageResponseProgress) {
      progress.add(event.receivedBytes);
    } else if (event is EhImageResponseComplete) {
      completed = event.bytes;
    }
  }

  _check(progress.length == 3, 'Response progress was not emitted per chunk');
  _check(progress.last == bytes.length, 'Progress byte count is incorrect');
  _check(completed != null, 'Valid response did not complete');
  _check(completed!.length == bytes.length, 'Completion byte count is wrong');
  _check(
      written.takeBytes().length == bytes.length, 'Cache writer got no data');

  await _expectFormatException(() async {
    await readEhImageResponse(
      Stream<List<int>>.value(bytes),
      expectedBytes: bytes.length + 1,
      writeChunk: (_) async {},
    ).drain<void>();
  });
  await _expectFormatException(() async {
    await readEhImageResponse(
      const Stream<List<int>>.empty(),
      expectedBytes: null,
      writeChunk: (_) async {},
    ).drain<void>();
  });
  await _expectFormatException(() async {
    await readEhImageResponse(
      Stream<List<int>>.value(List<int>.filled(128, 0)),
      expectedBytes: null,
      writeChunk: (_) async {},
    ).drain<void>();
  });
}
