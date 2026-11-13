import 'dart:typed_data';

import 'package:pica_comic/tools/file_type.dart';

sealed class EhImageResponseEvent {
  const EhImageResponseEvent();
}

class EhImageResponseProgress extends EhImageResponseEvent {
  final int receivedBytes;
  final int? expectedBytes;

  const EhImageResponseProgress(this.receivedBytes, this.expectedBytes);
}

class EhImageResponseComplete extends EhImageResponseEvent {
  final Uint8List bytes;

  const EhImageResponseComplete(this.bytes);
}

Stream<EhImageResponseEvent> readEhImageResponse(
  Stream<List<int>> stream, {
  required int? expectedBytes,
  required Future<void> Function(List<int> chunk) writeChunk,
}) async* {
  final data = BytesBuilder(copy: false);
  var receivedBytes = 0;

  await for (final chunk in stream) {
    if (chunk.isEmpty) continue;
    await writeChunk(chunk);
    data.add(chunk);
    receivedBytes += chunk.length;
    yield EhImageResponseProgress(receivedBytes, expectedBytes);
  }

  final bytes = data.takeBytes();
  if (bytes.isEmpty ||
      (expectedBytes != null && receivedBytes != expectedBytes)) {
    throw const FormatException('Incomplete image response');
  }
  if (!isValidImageData(bytes)) {
    throw const FormatException('Invalid image response');
  }

  yield EhImageResponseComplete(bytes);
}
