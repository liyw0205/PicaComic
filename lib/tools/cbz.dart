import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:mime/mime.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:xml/xml.dart';

class CbzExportCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
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

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void throwIfCancelled() {
    if (_cancelled) throw const CbzExportCancelledException();
  }
}

class CbzExportCancelledException implements Exception {
  const CbzExportCancelledException();

  @override
  String toString() => 'CBZ export cancelled';
}

class CbzMetadata {
  const CbzMetadata({
    required this.title,
    required this.source,
    required this.id,
    this.artists = const [],
    this.tags = const [],
    this.series = const [],
    this.characters = const [],
    this.language,
    this.web,
  });

  final String title;
  final String source;
  final String id;
  final List<String> artists;
  final List<String> tags;
  final List<String> series;
  final List<String> characters;
  final String? language;
  final String? web;

  String toXml(List<String?> bookmarks) {
    final builder = XmlBuilder()
      ..processing('xml', 'version="1.0" encoding="UTF-8"');
    void field(String name, String? value) {
      if (value == null || value.trim().isEmpty) return;
      builder.element(name, nest: _xmlText(value));
    }

    builder.element('ComicInfo', nest: () {
      // ComicInfo v2.0 uses an ordered sequence and has no Tags element.
      field('Title', title);
      field('Series', _join(series));
      field('Notes', 'Source: $source | ID: $id');
      field('Penciller', _join(artists));
      field('Genre', _join(tags));
      field('Web', publicComicUrl(web));
      field('PageCount', bookmarks.length.toString());
      field('LanguageISO', language);
      field('Characters', _join(characters));
      builder.element('Pages', nest: () {
        for (var index = 0; index < bookmarks.length; index++) {
          builder.element('Page', attributes: {
            'Image': '$index',
            if (index == 0) 'Type': 'FrontCover',
            if (bookmarks[index] != null)
              'Bookmark': _xmlText(bookmarks[index]!),
          });
        }
      });
    });
    return builder.buildDocument().toXmlString();
  }
}

String _xmlText(String value) =>
    String.fromCharCodes(value.runes.where((rune) =>
        rune == 9 ||
        rune == 10 ||
        rune == 13 ||
        rune >= 0x20 && rune <= 0xD7FF ||
        rune >= 0xE000 && rune <= 0xFFFD ||
        rune >= 0x10000 && rune <= 0x10FFFF));

String _join(Iterable<String> values) => values
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toSet()
    .join(', ');

String? publicComicUrl(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty) {
    return null;
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

class _CbzPage {
  const _CbzPage(this.file, this.extension, this.bookmark);

  final File file;
  final String extension;
  final String? bookmark;
}

/// Archives original pages; the downloaded thumbnail is not an extra page.
Future<void> createCbzFromComic({
  required CbzMetadata metadata,
  required String comicPath,
  required String savePath,
  List<String>? chapters,
  List<int>? chapterIndexes,
  CbzExportCancellation? cancellation,
  void Function(int completed, int total)? onProgress,
}) =>
    DataMaintenance.run(() async {
      cancellation?.throwIfCancelled();
      final target = File(savePath);
      await target.parent.create(recursive: true);
      final work = await target.parent.createTemp('.pica-cbz-');
      try {
        final staged = File('${work.path}/comic.cbz');
        await _writeCbz(
          metadata: metadata,
          comicPath: comicPath,
          savePath: staged.path,
          chapters: chapters,
          chapterIndexes: chapterIndexes,
          cancellation: cancellation,
          onProgress: onProgress,
        );
        cancellation?.throwIfCancelled();
        await _installCbz(staged, target);
      } finally {
        await work.delete(recursive: true);
      }
    }, operationName: 'cbz.export');

Future<List<_CbzPage>> _collectCbzPages(
  String comicPath,
  List<String>? chapters,
  List<int>? chapterIndexes,
  CbzExportCancellation? cancellation,
) async {
  final root = Directory(comicPath);
  if (await FileSystemEntity.type(root.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw FileSystemException('Comic directory does not exist', comicPath);
  }
  if ((chapters == null) != (chapterIndexes == null)) {
    throw ArgumentError(
        'chapters and chapterIndexes must be supplied together');
  }
  if (chapters == null) {
    return _listCbzPages(root, null, cancellation);
  }
  final indexes = chapterIndexes!.toSet().toList()..sort();
  if (indexes.isEmpty ||
      indexes.any((index) => index < 0 || index >= chapters.length)) {
    throw ArgumentError('No valid downloaded chapters');
  }
  final pages = <_CbzPage>[];
  for (final index in indexes) {
    cancellation?.throwIfCancelled();
    final directory = Directory('${root.path}/${index + 1}');
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
          'Chapter directory does not exist', directory.path);
    }
    pages.addAll(await _listCbzPages(directory, chapters[index], cancellation));
  }
  return pages;
}

Future<List<_CbzPage>> _listCbzPages(Directory directory, String? bookmark,
    CbzExportCancellation? cancellation) async {
  final indexed = <int, _CbzPage>{};
  final pattern =
      RegExp(r'^(\d+)\.(jpg|jpeg|png|webp|gif|avif)$', caseSensitive: false);
  await for (final entity in directory.list(followLinks: false)) {
    cancellation?.throwIfCancelled();
    final match = pattern.firstMatch(entity.uri.pathSegments.last);
    if (match == null) continue;
    if (entity is! File || await entity.length() == 0) {
      throw FileSystemException(
          'Page is not a nonempty regular file', entity.path);
    }
    final index = int.parse(match[1]!);
    if (indexed.containsKey(index)) {
      throw FormatException('Duplicate page number: $index');
    }
    indexed[index] = _CbzPage(entity, match[2]!.toLowerCase(), null);
  }
  if (indexed.isEmpty) {
    throw FileSystemException('No downloaded pages', directory.path);
  }
  final indexes = indexed.keys.toList()..sort();
  if (indexes.first > 1 || indexes.last - indexes.first + 1 != indexes.length) {
    throw FormatException(
        'Downloaded page numbers are incomplete: ${directory.path}');
  }
  final pages = <_CbzPage>[];
  for (final index in indexes) {
    final page = indexed[index]!;
    pages.add(
        _CbzPage(page.file, page.extension, pages.isEmpty ? bookmark : null));
  }
  return pages;
}

Future<void> _writeCbz({
  required CbzMetadata metadata,
  required String comicPath,
  required String savePath,
  List<String>? chapters,
  List<int>? chapterIndexes,
  CbzExportCancellation? cancellation,
  void Function(int completed, int total)? onProgress,
}) async {
  cancellation?.throwIfCancelled();
  final pages =
      await _collectCbzPages(comicPath, chapters, chapterIndexes, cancellation);
  final handle = FileHandle(savePath, openMode: AbstractFileOpenMode.write);
  final output = OutputFileStream.withFileHandle(handle);
  try {
    final encoder = ZipEncoder()..startEncode(output);
    final xml = utf8
        .encode(metadata.toXml(pages.map((page) => page.bookmark).toList()));
    encoder.addFile(
        ArchiveFile('ComicInfo.xml', xml.length, xml)..compress = false);
    final digits = pages.length.toString().length.clamp(6, 20);
    onProgress?.call(0, pages.length);
    for (var index = 0; index < pages.length; index++) {
      cancellation?.throwIfCancelled();
      final page = pages[index];
      final input = InputFileStream(page.file.path);
      try {
        final header = input.readBytes(input.length.clamp(0, 64)).toUint8List();
        final mime = lookupMimeType('page', headerBytes: header);
        final expectedMime =
            page.extension == 'jpg' ? 'image/jpeg' : 'image/${page.extension}';
        if (mime != expectedMime) {
          throw FormatException(
              'Page image header does not match its extension: ${page.file.path}');
        }
        input.reset();
        final entry = ArchiveFile.stream(
          '${(index + 1).toString().padLeft(digits, '0')}.${page.extension}',
          input.length,
          input,
        )..compress = false;
        encoder.addFile(entry, autoClose: false);
      } finally {
        input.closeSync();
      }
      onProgress?.call(index + 1, pages.length);
      // The worker accepts cancellation between original image files.
      await Future<void>.delayed(Duration.zero);
    }
    cancellation?.throwIfCancelled();
    encoder.endEncode();
    output.flush();
  } finally {
    // Close the handle even if flushing an almost-full disk failed.
    await handle.close();
  }
}

Future<void> _installCbz(File staged, File target) async {
  File? backup;
  if (Platform.isWindows && await target.exists()) {
    backup = File(
        '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.bak');
    await target.rename(backup.path);
  }
  try {
    await staged.rename(target.path);
  } catch (_) {
    if (backup != null) await backup.rename(target.path);
    rethrow;
  }
  if (backup != null) {
    try {
      await backup.delete();
    } catch (_) {
      // Keep a complete backup if deleting it is temporarily unavailable.
    }
  }
}

/// The parent owns destination replacement and temporary-file cleanup.
Future<void> createCbzFromComicWithIsolate({
  required CbzMetadata metadata,
  required String comicPath,
  required String savePath,
  List<String>? chapters,
  List<int>? chapterIndexes,
  CbzExportCancellation? cancellation,
  void Function(int completed, int total)? onProgress,
}) =>
    DataMaintenance.run(() async {
      cancellation?.throwIfCancelled();
      final target = File(savePath);
      await target.parent.create(recursive: true);
      final work = await target.parent.createTemp('.pica-cbz-');
      try {
        final staged = File('${work.path}/comic.cbz');
        await _runCbzWorker(
          metadata,
          comicPath,
          staged.path,
          chapters,
          chapterIndexes,
          cancellation,
          onProgress,
        );
        cancellation?.throwIfCancelled();
        await _installCbz(staged, target);
      } finally {
        await work.delete(recursive: true);
      }
    }, operationName: 'cbz.export');

Future<void> _runCbzWorker(
  CbzMetadata metadata,
  String comicPath,
  String savePath,
  List<String>? chapters,
  List<int>? chapterIndexes,
  CbzExportCancellation? cancellation,
  void Function(int completed, int total)? onProgress,
) async {
  final events = ReceivePort();
  final result = Completer<void>();
  // Observe early worker errors even before Isolate.spawn finishes its handoff.
  unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  final exited = Completer<void>();
  SendPort? commands;
  void cancel() => commands?.send('cancel');
  final subscription = events.listen((dynamic event) {
    if (event is SendPort) {
      commands = event;
      if (cancellation?.isCancelled ?? false) cancel();
    } else if (event == null) {
      if (!exited.isCompleted) exited.complete();
      if (!result.isCompleted) {
        result.completeError(
            StateError('CBZ export worker exited before completion'));
      }
    } else if (event is Map && !result.isCompleted) {
      switch (event['type']) {
        case 'progress':
          try {
            onProgress?.call(event['completed'] as int, event['total'] as int);
          } catch (_) {
            // Progress observers cannot leave a live worker without an owner.
          }
        case 'done':
          result.complete();
        case 'cancelled':
          result.completeError(const CbzExportCancelledException());
        case 'error':
          result.completeError(StateError(event['message'] as String));
      }
    } else if (event is List && !result.isCompleted) {
      result.completeError(
          StateError('CBZ export worker failed: ${event.first}'));
    }
  });
  cancellation?.addListener(cancel);
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
      _cbzWorker,
      (
        events.sendPort,
        metadata,
        comicPath,
        savePath,
        chapters,
        chapterIndexes
      ),
      onError: events.sendPort,
      onExit: events.sendPort,
    );
    await result.future;
  } finally {
    cancellation?.removeListener(cancel);
    if (worker != null) await exited.future;
    await subscription.cancel();
    events.close();
  }
}

Future<void> _cbzWorker(
    (
      SendPort,
      CbzMetadata,
      String,
      String,
      List<String>?,
      List<int>?
    ) args) async {
  final (events, metadata, comicPath, savePath, chapters, chapterIndexes) =
      args;
  final commands = ReceivePort();
  final cancellation = CbzExportCancellation();
  final subscription = commands.listen((dynamic command) {
    if (command == 'cancel') cancellation.cancel();
  });
  events.send(commands.sendPort);
  try {
    await _writeCbz(
      metadata: metadata,
      comicPath: comicPath,
      savePath: savePath,
      chapters: chapters,
      chapterIndexes: chapterIndexes,
      cancellation: cancellation,
      onProgress: (completed, total) => events.send({
        'type': 'progress',
        'completed': completed,
        'total': total,
      }),
    );
    events.send({'type': 'done'});
  } on CbzExportCancelledException {
    events.send({'type': 'cancelled'});
  } catch (error) {
    events.send({'type': 'error', 'message': error.toString()});
  } finally {
    await subscription.cancel();
    commands.close();
  }
}
