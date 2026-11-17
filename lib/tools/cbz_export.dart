import 'dart:io';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_download_model.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/tools/cbz.dart';
import 'package:pica_comic/tools/io_extensions.dart';

CbzMetadata cbzMetadataFor(DownloadedItem comic) {
  final artists = <String>[];
  var tags = comic.tags;
  final series = <String>[];
  final characters = <String>[];
  String? language;
  String? web;
  var source = comic.type.name;
  if (comic is DownloadedComic) {
    artists.add(comic.comicItem.author);
  } else if (comic is DownloadedJmComic) {
    artists.addAll(comic.comic.author);
    series.addAll(comic.comic.works);
    characters.addAll(comic.comic.actors);
  } else if (comic is DownloadedGallery) {
    final categories = comic.gallery.tags;
    artists.addAll(categories['artist'] ?? const []);
    series.addAll(categories['parody'] ?? const []);
    characters.addAll(categories['character'] ?? const []);
    tags = comic.gallery.toBrief().tags;
    language = _languageCode(categories['language'] ?? const []);
    web = comic.gallery.link;
  } else if (comic is DownloadedHitomiComic) {
    artists.addAll(comic.comic.artists ?? const []);
    series.addAll(comic.comic.parodys?.map((tag) => tag.name) ?? const []);
    characters
        .addAll(comic.comic.characters?.map((tag) => tag.name) ?? const []);
    language = _languageCode([comic.comic.lang]);
    web = comic.link;
  } else if (comic is CustomDownloadedItem) {
    source = comic.sourceName;
    web = publicComicUrl(comic.comicId);
  }
  Iterable<String> known(Iterable<String> values) => values.where((value) =>
      !const {'', 'n/a', 'unknown', '未知'}.contains(value.trim().toLowerCase()));
  return CbzMetadata(
    title: comic.name,
    source: source,
    id: comic.id,
    artists: known(artists).toList(),
    tags: List.of(tags),
    series: known(series).toList(),
    characters: known(characters).toList(),
    language: language,
    web: web,
  );
}

String? _languageCode(Iterable<String> values) {
  const languages = {
    'chinese': 'zh',
    '中文': 'zh',
    'japanese': 'ja',
    '日本語': 'ja',
    'english': 'en',
    '英语': 'en',
    'korean': 'ko',
    '한국어': 'ko',
    'french': 'fr',
    'german': 'de',
    'spanish': 'es',
    'italian': 'it',
    'portuguese': 'pt',
    'russian': 'ru',
  };
  final codes = values
      .map((value) => languages[value.trim().toLowerCase()])
      .whereType<String>()
      .toSet();
  return codes.length == 1 ? codes.single : null;
}

class CbzExportResult {
  const CbzExportResult(this.saved, {this.cancelled = false});

  final int saved;
  final bool cancelled;
}

class CbzExportException implements Exception {
  const CbzExportException(this.saved, this.cause);

  final int saved;
  final Object cause;

  @override
  String toString() => 'CBZ export failed after $saved saved comics: $cause';
}

String _cbzFileName(String title) {
  final cleaned = title.replaceAll(RegExp(r'[\x00-\x1F]'), '').trim();
  var name = cleaned.isEmpty ? 'comic' : sanitizeFileName(cleaned);
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in name.runes) {
    final character = String.fromCharCode(rune);
    bytes += utf8.encode(character).length;
    if (bytes > 240) break;
    buffer.write(character);
  }
  name = buffer.toString().replaceFirst(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = 'comic';
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
          caseSensitive: false)
      .hasMatch(name)) {
    name = '_$name';
  }
  return '$name.cbz';
}

/// Saves each selected comic separately so each archive has its own metadata.
Future<CbzExportResult> exportCbzComics(
  List<DownloadedItem> comics, {
  required CbzExportCancellation cancellation,
  String Function(DownloadedItem comic)? comicPath,
  Future<bool> Function(String path)? saveFile,
  Directory? temporaryRoot,
}) async {
  var saved = 0;
  if (comics.isEmpty) return const CbzExportResult(0);
  final work = await (temporaryRoot ?? Directory(App.cachePath))
      .createTemp('cbz-export-');
  try {
    for (final comic in comics) {
      cancellation.throwIfCancelled();
      final output = File('${work.path}/${_cbzFileName(comic.name)}');
      final hasChapters = comic is DownloadedComic ||
          comic is DownloadedJmComic ||
          comic is CustomDownloadedItem && comic.chapters?.isNotEmpty == true;
      await createCbzFromComicWithIsolate(
        metadata: cbzMetadataFor(comic),
        comicPath: comicPath?.call(comic) ??
            '${DownloadManager().path}/${DownloadManager().getDirectory(comic.id)}',
        savePath: output.path,
        chapters: hasChapters ? comic.eps : null,
        chapterIndexes: hasChapters ? comic.downloadedEps : null,
        cancellation: cancellation,
      );
      cancellation.throwIfCancelled();
      final didSave = await (saveFile ?? _saveCbz)(output.path);
      if (!didSave) return CbzExportResult(saved, cancelled: true);
      saved++;
      await output.delete();
    }
    return CbzExportResult(saved);
  } on CbzExportCancelledException {
    return CbzExportResult(saved, cancelled: true);
  } catch (error) {
    throw CbzExportException(saved, error);
  } finally {
    await work.delete(recursive: true);
  }
}

Future<bool> _saveCbz(String path) async {
  if (App.isMobile) {
    return await FlutterFileDialog.saveFile(
            params: SaveFileDialogParams(sourceFilePath: path)) !=
        null;
  }
  final result = await getSaveLocation(
    suggestedName: File(path).uri.pathSegments.last,
    acceptedTypeGroups: [
      const XTypeGroup(label: 'CBZ', extensions: ['cbz'])
    ],
  );
  if (result == null) return false;
  await XFile(path, mimeType: 'application/vnd.comicbook+zip')
      .saveTo(result.path);
  return true;
}
