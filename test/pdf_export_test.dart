import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/foundation/runtime_metrics.dart';
import 'package:pica_comic/tools/pdf.dart';

void main() {
  setUp(RuntimeMetrics.reset);

  Future<Directory> createComic() async {
    final root = await Directory.systemTemp.createTemp('pica-pdf-');
    // A tiny PNG is sufficient for pdf's image decoder and keeps this test
    // independent of platform image encoders.
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final bytes = <int>[..._decodeBase64(png)];
    await File('${root.path}/cover.png').writeAsBytes(bytes);
    await File('${root.path}/0.png').writeAsBytes(bytes);
    await File('${root.path}/1.png').writeAsBytes(bytes);
    return root;
  }

  Future<ByteData> loadFont() async {
    final file = File('fonts/NotoSansSC-Regular.ttf');
    expect(await file.exists(), isTrue,
        reason: 'the project font is required by the PDF export contract');
    return ByteData.sublistView(await file.readAsBytes());
  }

  test('cancellation between pages leaves the previous target intact',
      () async {
    final comic = await createComic();
    addTearDown(() => comic.delete(recursive: true));
    final output = File('${comic.path}/result.pdf');
    await output.writeAsString('previous complete PDF');
    final cancellation = PdfExportCancellation();

    await expectLater(
      createPdfFromComic(
        title: 'cancel test',
        comicPath: comic.path,
        savePath: output.path,
        font: await loadFont(),
        cancellation: cancellation,
        onProgress: (progress) {
          if (progress.completedPages == 1) cancellation.cancel();
        },
      ),
      throwsA(isA<PdfExportCancelledException>()),
    );
    expect(await output.readAsString(), 'previous complete PDF');
    expect(RuntimeMetrics.snapshot()['pdf.export']?.cancelled, 1);
  });

  test('successful export reports pages and installs a complete PDF', () async {
    final comic = await createComic();
    addTearDown(() => comic.delete(recursive: true));
    final output = File('${comic.path}/result.pdf');
    final progress = <PdfExportProgress>[];

    await createPdfFromComic(
      title: 'success test',
      comicPath: comic.path,
      savePath: output.path,
      font: await loadFont(),
      onProgress: progress.add,
      batchSize: 1,
    );

    final bytes = await output.readAsBytes();
    expect(bytes.take(5), <int>[37, 80, 68, 70, 45]);
    expect(progress.first.completedPages, 0);
    expect(progress.last.completedPages, 3);
    expect(progress.last.totalPages, 3);
    final metric = RuntimeMetrics.snapshot()['pdf.export']!;
    expect(metric.success, 1);
    expect(metric.bytes, greaterThan(0));
  });
}

List<int> _decodeBase64(String value) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final output = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final codeUnit in value.codeUnits) {
    if (codeUnit == 61) break;
    final index = alphabet.indexOf(String.fromCharCode(codeUnit));
    if (index < 0) continue;
    buffer = (buffer << 6) | index;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      output.add((buffer >> bits) & 255);
    }
  }
  return output;
}
