import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_download_model.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/nhentai_network/download.dart';
import 'package:pica_comic/tools/cbz.dart';
import 'package:pica_comic/tools/cbz_export.dart';
import 'package:xml/xml.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pica-cbz-test-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<File> page(String path, [String marker = '']) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
    await file.writeAsBytes([...png, ...utf8.encode(marker)]);
    return file;
  }

  const metadata = CbzMetadata(
    title: 'Title & <test> \u4e2d\u6587',
    source: 'fixture',
    id: '123',
    artists: ['Artist & One', 'Artist Two'],
    tags: ['artist:Artist & One', 'language:chinese', 'tag one', 'tag one'],
    language: 'zh',
    web: 'https://user:password@example.test/g/123/token/?auth=secret#cookie',
  );

  Archive readArchive(File file) =>
      ZipDecoder().decodeBytes(file.readAsBytesSync(), verify: true);

  XmlElement comicInfo(Archive archive) => XmlDocument.parse(
          utf8.decode(archive.findFile('ComicInfo.xml')!.content as List<int>))
      .rootElement;

  Future<void> expectNoTemporaryFiles() async {
    expect(
      await root
          .list(recursive: true)
          .where((entry) =>
              entry.path.contains('.pica-cbz-') ||
              entry.path.contains('cbz-export-'))
          .toList(),
      isEmpty,
    );
  }

  test('CBZ keeps original pages in chapter order with valid ComicInfo XML',
      () async {
    final ten = await page('comic/1/10.png', 'ten');
    final two = await page('comic/1/2.png', 'two');
    final one = await page('comic/1/1.png', 'one');
    for (var index = 3; index < 10; index++) {
      await page('comic/1/$index.png', '$index');
    }
    final last = await page('comic/3/0.png', 'last');
    await page('comic/cover.png', 'thumbnail');
    await page('comic/2/0.png', 'not downloaded');
    final output = File('${root.path}/result.cbz');
    await output.writeAsString('previous complete archive');
    final progress = <int>[];

    await createCbzFromComicWithIsolate(
      metadata: metadata,
      comicPath: '${root.path}/comic',
      savePath: output.path,
      chapters: ['Same & <chapter>', 'Ignore', 'Same & <chapter>'],
      chapterIndexes: [2, 0, 2],
      onProgress: (completed, total) {
        expect(total, 11);
        progress.add(completed);
      },
    );

    final archive = readArchive(output);
    expect(archive.files.map((entry) => entry.name), [
      'ComicInfo.xml',
      '000001.png',
      '000002.png',
      '000003.png',
      '000004.png',
      '000005.png',
      '000006.png',
      '000007.png',
      '000008.png',
      '000009.png',
      '000010.png',
      '000011.png',
    ]);
    expect(archive.findFile('000001.png')!.content, await one.readAsBytes());
    expect(archive.findFile('000002.png')!.content, await two.readAsBytes());
    expect(archive.findFile('000010.png')!.content, await ten.readAsBytes());
    expect(archive.findFile('000011.png')!.content, await last.readAsBytes());
    final xml = comicInfo(archive);
    expect(xml.name.local, 'ComicInfo');
    expect(xml.getElement('Title')!.innerText, metadata.title);
    expect(xml.getElement('Penciller')!.innerText, 'Artist & One, Artist Two');
    expect(xml.getElement('Genre')!.innerText,
        'artist:Artist & One, language:chinese, tag one');
    expect(
        xml.getElement('Web')!.innerText, 'https://example.test/g/123/token/');
    expect(xml.getElement('PageCount')!.innerText, '11');
    expect(xml.getElement('LanguageISO')!.innerText, 'zh');
    expect(xml.childElements.map((element) => element.name.local), [
      'Title',
      'Notes',
      'Penciller',
      'Genre',
      'Web',
      'PageCount',
      'LanguageISO',
      'Pages',
    ]);
    final pages = xml.getElement('Pages')!.childElements.toList();
    expect(pages.map((element) => element.getAttribute('Image')),
        List.generate(11, (index) => '$index'));
    expect(pages.first.getAttribute('Type'), 'FrontCover');
    expect(pages.map((element) => element.getAttribute('Bookmark')), [
      'Same & <chapter>',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      'Same & <chapter>',
    ]);
    expect(progress, List.generate(12, (index) => index));
    await expectNoTemporaryFiles();
  });

  test('CBZ failures and cancellation leave the previous destination intact',
      () async {
    await page('comic/0.png');
    await page('comic/1.png');
    final output = File('${root.path}/result.cbz');
    await output.writeAsString('previous complete archive');
    final cancelled = CbzExportCancellation()..cancel();
    await expectLater(
      createCbzFromComicWithIsolate(
        metadata: metadata,
        comicPath: '${root.path}/comic',
        savePath: output.path,
        cancellation: cancelled,
      ),
      throwsA(isA<CbzExportCancelledException>()),
    );
    final workerCancellation = CbzExportCancellation();
    await expectLater(
      createCbzFromComicWithIsolate(
        metadata: metadata,
        comicPath: '${root.path}/comic',
        savePath: output.path,
        cancellation: workerCancellation,
        onProgress: (completed, _) {
          if (completed == 1) workerCancellation.cancel();
        },
      ),
      throwsA(isA<CbzExportCancelledException>()),
    );
    expect(await output.readAsString(), 'previous complete archive');
    final cancellation = CbzExportCancellation();
    await expectLater(
      createCbzFromComic(
        metadata: metadata,
        comicPath: '${root.path}/comic',
        savePath: output.path,
        cancellation: cancellation,
        onProgress: (completed, _) {
          if (completed == 1) cancellation.cancel();
        },
      ),
      throwsA(isA<CbzExportCancelledException>()),
    );
    for (final indexes in [
      <int>[],
      [0, 5],
      [0, 1]
    ]) {
      await expectLater(
        createCbzFromComicWithIsolate(
          metadata: metadata,
          comicPath: '${root.path}/comic',
          savePath: output.path,
          chapters: ['First', 'Missing'],
          chapterIndexes: indexes,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await output.readAsString(), 'previous complete archive');
    }
    // A source disappearing after enumeration still closes both ZIP handles.
    await expectLater(
      createCbzFromComic(
        metadata: metadata,
        comicPath: '${root.path}/comic',
        savePath: output.path,
        onProgress: (completed, _) {
          if (completed == 1) File('${root.path}/comic/1.png').deleteSync();
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await output.readAsString(), 'previous complete archive');
    await expectNoTemporaryFiles();
  });

  test('CBZ rejects duplicate pages, empty pages and links', () async {
    await page('comic/0.png');
    await page('comic/00.png');
    final output = File('${root.path}/result.cbz');
    await expectLater(
      createCbzFromComic(
          metadata: metadata,
          comicPath: '${root.path}/comic',
          savePath: output.path),
      throwsA(isA<FormatException>()),
    );
    await File('${root.path}/comic/00.png').delete();
    await File('${root.path}/comic/1.png').writeAsBytes([]);
    await expectLater(
      createCbzFromComic(
          metadata: metadata,
          comicPath: '${root.path}/comic',
          savePath: output.path),
      throwsA(isA<FileSystemException>()),
    );
    await File('${root.path}/comic/1.png').delete();
    final external = await page('external.png');
    await Link('${root.path}/comic/1.png').create(external.path);
    await expectLater(
      createCbzFromComic(
          metadata: metadata,
          comicPath: '${root.path}/comic',
          savePath: output.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await output.exists(), isFalse);
    await expectNoTemporaryFiles();
  });

  test('CBZ maps source authors without treating uploaders as artists', () {
    final gallery = Gallery(
        'Title',
        'Manga',
        'time',
        'Uploader',
        4,
        null,
        'cover.jpg',
        {
          'artist': ['Artist'],
          'language': ['chinese'],
          'parody': ['Series'],
          'character': ['Character']
        },
        [],
        null,
        false,
        'https://example.test/g/1/token/',
        '1',
        20,
        [],
        'jpg',
        100,
        null);
    final eh = cbzMetadataFor(DownloadedGallery(gallery, 1));
    expect(eh.artists, ['Artist']);
    expect(eh.tags, [
      'artist:Artist',
      'language:chinese',
      'parody:Series',
      'character:Character'
    ]);
    expect(eh.language, 'zh');
    expect(eh.series, ['Series']);
    expect(eh.characters, ['Character']);
    gallery.tags.clear();
    expect(cbzMetadataFor(DownloadedGallery(gallery, 1)).artists, isEmpty);
    final jm = DownloadedJmComic(
        JmComicInfo('Title', '1', ['First', 'Second'], '', 0, 0, {}, [], [], [],
            [], false, false, 0, []),
        1,
        [0]);
    expect(cbzMetadataFor(jm).artists, ['First', 'Second']);
    final hitomi = DownloadedHitomiComic(
        HitomiComic('1', 'Title', [], 'manga', ['N/A', 'Artist', '未知'],
            'english', null, null, [], '', [], [], ''),
        1,
        'https://hitomi.la/reader/1.html',
        '');
    expect(cbzMetadataFor(hitomi).artists, ['Artist']);
    expect(cbzMetadataFor(hitomi).language, 'en');
    expect(cbzMetadataFor(hitomi).series, isEmpty);
    final custom = CustomDownloadedItem(1, [0], null, 'source-1', 'Title',
        'Uploader', [], 'source', 'Source', '', 'https://example.test/comic/1');
    expect(cbzMetadataFor(custom).artists, isEmpty);
    expect(cbzMetadataFor(custom).web, 'https://example.test/comic/1');
    for (final value in ['javascript:alert(1)', '/relative', '', null]) {
      expect(publicComicUrl(value), isNull);
    }
  });

  test('batch CBZ export saves separate metadata and stops on dialog cancel',
      () async {
    await page('comic/0.png');
    final comics = [
      NhentaiDownloadedComic('nhentai1', 'Same Title', 1, '', ['tag one']),
      NhentaiDownloadedComic('nhentai2', 'Same Title', 1, '', ['tag two']),
    ];
    final ids = <String>[];
    final tags = <String>[];
    final result = await exportCbzComics(
      comics,
      cancellation: CbzExportCancellation(),
      temporaryRoot: root,
      comicPath: (_) => '${root.path}/comic',
      saveFile: (path) async {
        final xml = comicInfo(readArchive(File(path)));
        ids.add(xml.getElement('Notes')!.innerText);
        tags.add(xml.getElement('Genre')!.innerText);
        return true;
      },
    );
    expect(result.saved, 2);
    expect(result.cancelled, isFalse);
    expect(ids,
        ['Source: nhentai | ID: nhentai1', 'Source: nhentai | ID: nhentai2']);
    expect(tags, ['tag one', 'tag two']);
    var dialogs = 0;
    final cancelled = await exportCbzComics(
      comics,
      cancellation: CbzExportCancellation(),
      temporaryRoot: root,
      comicPath: (_) => '${root.path}/comic',
      saveFile: (_) async {
        dialogs++;
        return false;
      },
    );
    expect(cancelled.saved, 0);
    expect(cancelled.cancelled, isTrue);
    expect(dialogs, 1);
    await expectNoTemporaryFiles();
  });

  test('Hitomi downloaded metadata survives restart with legacy defaults', () {
    final original = HitomiComic(
      '1',
      'Title',
      [2, 3],
      'manga',
      ['Artist'],
      'english',
      [Tag('Series', '/series')],
      [Tag('Character', '/character')],
      [Tag('tag', '/tag')],
      '2026-01-01',
      [HitomiFile('page.jpg', 'hash', false, false, 100, 100, '1')],
      ['Group'],
      'cover.jpg',
    );
    final restored = HitomiComic.fromMap(original.toMap());
    expect(restored.related, original.related);
    expect(restored.artists, original.artists);
    expect(restored.parodys!.map((tag) => tag.name), ['Series']);
    expect(restored.characters!.map((tag) => tag.name), ['Character']);
    expect(restored.tags.map((tag) => tag.name), ['tag']);
    expect(restored.group, ['Group']);
    final legacy = HitomiComic.fromMap({
      'id': '2',
      'name': 'Legacy',
      'type': 'manga',
      'time': '',
      'artists': ['N/A'],
      'lang': 'english',
      'files': [],
    });
    expect(legacy.related, isEmpty);
    expect(legacy.tags, isEmpty);
    expect(legacy.parodys, isEmpty);
    expect(legacy.characters, isEmpty);
  });
}
