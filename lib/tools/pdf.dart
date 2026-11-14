import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:pdf/widgets.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/runtime_metrics.dart';
import 'package:pica_comic/tools/atomic_file.dart';

/// A cooperative cancellation source for PDF exports.
class PdfExportCancellation {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.from(_listeners);
    for (final listener in listeners) {
      listener();
    }
  }

  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void throwIfCancelled() {
    if (_cancelled) throw const PdfExportCancelledException();
  }
}

class PdfExportCancelledException implements Exception {
  const PdfExportCancelledException();

  @override
  String toString() => 'PDF export cancelled';
}

class PdfExportProgress {
  const PdfExportProgress({
    required this.completedPages,
    required this.totalPages,
  });

  final int completedPages;
  final int totalPages;

  double get fraction => totalPages == 0 ? 1 : completedPages / totalPages;
}

/// Creates a PDF from a downloaded comic.
///
/// The existing arguments remain unchanged. Image bytes are read one page at
/// a time, cancellation is checked between pages, and the destination is
/// replaced only after a complete PDF has been generated.
Future<void> createPdfFromComic({
  required String title,
  required String comicPath,
  required String savePath,
  required ByteData font,
  List<String>? chapters,
  List<int>? chapterIndexes,
  PdfExportCancellation? cancellation,
  void Function(PdfExportProgress progress)? onProgress,
  int batchSize = 8,
}) {
  if (batchSize <= 0) {
    throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
  }
  return DataMaintenance.run(
    () => _createPdfFromComic(
      title: title,
      comicPath: comicPath,
      savePath: savePath,
      font: font,
      chapters: chapters,
      chapterIndexes: chapterIndexes,
      cancellation: cancellation,
      onProgress: onProgress,
      batchSize: batchSize,
    ),
    operationName: 'pdf.export',
  );
}

Future<void> _createPdfFromComic({
  required String title,
  required String comicPath,
  required String savePath,
  required ByteData font,
  required List<String>? chapters,
  required List<int>? chapterIndexes,
  required PdfExportCancellation? cancellation,
  required void Function(PdfExportProgress progress)? onProgress,
  required int batchSize,
}) async {
  final timer = RuntimeMetrics.start('pdf.export');
  try {
    cancellation?.throwIfCancelled();
    final pages = await _collectPages(
      title: title,
      comicPath: comicPath,
      chapters: chapters,
      chapterIndexes: chapterIndexes,
      cancellation: cancellation,
    );
    final totalPages = pages.length;
    onProgress
        ?.call(PdfExportProgress(completedPages: 0, totalPages: totalPages));

    final pdf = Document(
      theme: ThemeData(
        defaultTextStyle: TextStyle(font: Font.ttf(font)),
      ),
    );

    var completedPages = 0;
    for (final page in pages) {
      cancellation?.throwIfCancelled();
      if (page.path != null && page.title != null) {
        final imageData = await File(page.path!).readAsBytes();
        cancellation?.throwIfCancelled();
        pdf.addPage(
          Page(
            build: (Context context) => Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 100,
                  child: Center(
                    child:
                        Text(page.title!, style: const TextStyle(fontSize: 20)),
                  ),
                ),
                Expanded(
                  child: Image(MemoryImage(imageData), fit: BoxFit.contain),
                ),
              ],
            ),
          ),
        );
      } else if (page.title != null) {
        pdf.addPage(
          Page(
            build: (Context context) => Center(
              child: Text(page.title!, style: const TextStyle(fontSize: 20)),
            ),
          ),
        );
      } else {
        final imageData = await File(page.path!).readAsBytes();
        cancellation?.throwIfCancelled();
        pdf.addPage(
          Page(
            build: (Context context) =>
                Image(MemoryImage(imageData), fit: BoxFit.contain),
          ),
        );
      }
      completedPages++;
      onProgress?.call(PdfExportProgress(
        completedPages: completedPages,
        totalPages: totalPages,
      ));
      if (completedPages % batchSize == 0) {
        // Give UI/event-loop cancellation a turn between page batches.
        await Future<void>.delayed(Duration.zero);
      }
    }

    cancellation?.throwIfCancelled();
    final output = await pdf.save();
    cancellation?.throwIfCancelled();
    await writeBytesFileAtomically(File(savePath), output);
    timer.finish(bytes: output.length);
  } on PdfExportCancelledException {
    timer.finish(cancelled: true);
    rethrow;
  } catch (_) {
    timer.finish(success: false);
    rethrow;
  }
}

class _PdfPage {
  const _PdfPage.image(this.path) : title = null;
  const _PdfPage.chapter(this.title) : path = null;
  const _PdfPage.cover(this.title, this.path);

  final String? path;
  final String? title;
}

Future<List<_PdfPage>> _collectPages({
  required String title,
  required String comicPath,
  required List<String>? chapters,
  required List<int>? chapterIndexes,
  required PdfExportCancellation? cancellation,
}) async {
  final pages = <_PdfPage>[];
  final comicDirectory = Directory(comicPath);
  if (!await comicDirectory.exists()) {
    throw FileSystemException('Comic directory does not exist', comicPath);
  }

  final cover = await _findCover(comicDirectory);
  if (cover == null) {
    throw FileSystemException('Comic cover does not exist', comicPath);
  }
  pages.add(_PdfPage.cover(title, cover.path));

  cancellation?.throwIfCancelled();
  final rootImages = await _listImageFiles(comicDirectory);
  if (rootImages.isNotEmpty) {
    pages.addAll(rootImages.map((file) => _PdfPage.image(file.path)));
    return pages;
  }

  if (chapters == null || chapterIndexes == null) {
    throw ArgumentError('chapters and chapterIndexes are required for a '
        'multi-chapter comic');
  }
  if (chapters.length < chapterIndexes.length) {
    throw ArgumentError('chapterIndexes contains an unknown chapter');
  }
  for (final index in chapterIndexes) {
    cancellation?.throwIfCancelled();
    if (index < 0 || index >= chapters.length) {
      throw RangeError.index(index, chapterIndexes, 'chapterIndexes');
    }
    final directory =
        Directory('$comicPath${Platform.pathSeparator}${index + 1}');
    if (!await directory.exists()) {
      throw FileSystemException(
          'Chapter directory does not exist', directory.path);
    }
    pages.add(_PdfPage.chapter(chapters[index]));
    final files = await _listImageFiles(directory);
    pages.addAll(files.map((file) => _PdfPage.image(file.path)));
  }
  return pages;
}

Future<File?> _findCover(Directory directory) async {
  for (final name in const <String>[
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
    'cover.webp',
    'cover.gif',
  ]) {
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    if (await file.exists()) return file;
  }
  return null;
}

Future<List<File>> _listImageFiles(Directory directory) async {
  final files = <File>[];
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    final lowerName = name.toLowerCase();
    if (lowerName == 'info.json' || lowerName.startsWith('cover.')) continue;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) continue;
    final extension = name.substring(dot + 1).toLowerCase();
    if (!const <String>{'jpg', 'jpeg', 'png', 'webp', 'gif'}
        .contains(extension)) {
      continue;
    }
    if (int.tryParse(name.substring(0, dot)) == null) continue;
    files.add(entity);
  }
  files.sort((a, b) {
    int index(File file) {
      final name = file.uri.pathSegments.last;
      return int.parse(name.substring(0, name.lastIndexOf('.')));
    }

    final byIndex = index(a).compareTo(index(b));
    return byIndex == 0 ? a.path.compareTo(b.path) : byIndex;
  });
  return files;
}

/// Runs the same pipeline in an isolate while retaining cooperative cancel.
Future<void> createPdfFromComicWithIsolate({
  required String title,
  required String comicPath,
  required String savePath,
  List<String>? chapters,
  List<int>? chapterIndexes,
  PdfExportCancellation? cancellation,
  void Function(PdfExportProgress progress)? onProgress,
  int batchSize = 8,
}) {
  if (batchSize <= 0) {
    throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
  }
  return DataMaintenance.run(
    () => _createPdfFromComicWithIsolate(
      title: title,
      comicPath: comicPath,
      savePath: savePath,
      chapters: chapters,
      chapterIndexes: chapterIndexes,
      cancellation: cancellation,
      onProgress: onProgress,
      batchSize: batchSize,
    ),
    operationName: 'pdf.export',
  );
}

Future<void> _createPdfFromComicWithIsolate({
  required String title,
  required String comicPath,
  required String savePath,
  required List<String>? chapters,
  required List<int>? chapterIndexes,
  required PdfExportCancellation? cancellation,
  required void Function(PdfExportProgress progress)? onProgress,
  required int batchSize,
}) async {
  cancellation?.throwIfCancelled();
  final fontData = await _loadFont();
  final events = ReceivePort();
  final errors = ReceivePort();
  final exits = ReceivePort();
  final completed = Completer<void>();
  Isolate? worker;
  SendPort? commands;
  var cancelRequested = cancellation?.isCancelled ?? false;

  void sendCancel() {
    cancelRequested = true;
    commands?.send('cancel');
  }

  void completeError(Object error, [StackTrace? stack]) {
    if (!completed.isCompleted) {
      completed.completeError(error, stack ?? StackTrace.current);
    }
  }

  final eventSubscription = events.listen((dynamic event) {
    if (event is SendPort) {
      commands = event;
      if (cancelRequested) commands!.send('cancel');
      return;
    }
    if (event is! Map) return;
    switch (event['type']) {
      case 'progress':
        try {
          onProgress?.call(PdfExportProgress(
            completedPages: event['completed'] as int,
            totalPages: event['total'] as int,
          ));
        } catch (_) {
          // A diagnostic/UI callback must not abort the export worker.
        }
      case 'done':
        if (!completed.isCompleted) completed.complete();
      case 'cancelled':
        if (!completed.isCompleted) {
          completed.completeError(const PdfExportCancelledException());
        }
      case 'error':
        completeError(
            StateError(event['error'] as String? ?? 'PDF export failed'));
    }
  });
  final errorSubscription = errors.listen((dynamic error) {
    final message = error is List && error.isNotEmpty ? error.first : error;
    completeError(StateError('PDF export isolate failed: $message'));
  });
  final exitSubscription = exits.listen((dynamic _) {
    completeError(StateError('PDF export isolate exited before completion'));
  });
  cancellation?.addListener(sendCancel);

  try {
    worker = await Isolate.spawn<Map<String, Object?>>(
      _pdfWorkerEntry,
      <String, Object?>{
        'events': events.sendPort,
        'title': title,
        'comicPath': comicPath,
        'savePath': savePath,
        'font': Uint8List.fromList(fontData.buffer.asUint8List(
          fontData.offsetInBytes,
          fontData.lengthInBytes,
        )),
        'chapters': chapters == null ? null : List<String>.from(chapters),
        'chapterIndexes':
            chapterIndexes == null ? null : List<int>.from(chapterIndexes),
        'batchSize': batchSize,
      },
      onError: errors.sendPort,
      onExit: exits.sendPort,
    );
    if (cancelRequested) sendCancel();
    await completed.future;
  } finally {
    cancellation?.removeListener(sendCancel);
    await eventSubscription.cancel();
    await errorSubscription.cancel();
    await exitSubscription.cancel();
    events.close();
    errors.close();
    exits.close();
    worker?.kill(priority: Isolate.beforeNextEvent);
  }
}

Future<void> _pdfWorkerEntry(Map<String, Object?> args) async {
  final events = args['events'] as SendPort;
  final commands = ReceivePort();
  final cancellation = PdfExportCancellation();
  final commandSubscription = commands.listen((dynamic message) {
    if (message == 'cancel') cancellation.cancel();
  });
  events.send(commands.sendPort);
  try {
    await createPdfFromComic(
      title: args['title'] as String,
      comicPath: args['comicPath'] as String,
      savePath: args['savePath'] as String,
      font: ByteData.sublistView(
          Uint8List.fromList((args['font'] as List).cast<int>())),
      chapters: (args['chapters'] as List?)?.cast<String>(),
      chapterIndexes: (args['chapterIndexes'] as List?)?.cast<int>(),
      cancellation: cancellation,
      batchSize: args['batchSize'] as int,
      onProgress: (progress) => events.send(<String, Object?>{
        'type': 'progress',
        'completed': progress.completedPages,
        'total': progress.totalPages,
      }),
    );
    events.send(<String, Object?>{'type': 'done'});
  } on PdfExportCancelledException {
    events.send(<String, Object?>{'type': 'cancelled'});
  } catch (error, stack) {
    events.send(<String, Object?>{
      'type': 'error',
      'error': error.toString(),
      'stack': stack.toString(),
    });
  } finally {
    await commandSubscription.cancel();
    commands.close();
  }
}

Future<ByteData> _loadFont() async {
  if (Platform.isWindows) {
    return rootBundle.load('fonts/NotoSansSC-Regular.ttf');
  }
  final fontFile = File('${App.dataPath}/font.ttf');
  if (!await fontFile.exists()) {
    throw Exception('Font file not found');
  }
  final value = await fontFile.readAsBytes();
  return ByteData.sublistView(value);
}
