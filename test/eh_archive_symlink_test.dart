import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pica_comic/network/eh_network/archive_utils.dart';
import 'package:pica_comic/network/eh_network/image_response_utils.dart';
import 'package:pica_comic/tools/file_type.dart';

void main() {
  test('rejects Unix symlink entries before extraction', () async {
    final symlinkArchive = Archive()
      ..addFile(
          ArchiveFile.string('outside-link', '../outside.txt')..mode = 0xA1FF);
    final symlinkZip = ZipEncoder().encode(symlinkArchive)!;
    final centralDirectoryOffset =
        _findSignature(symlinkZip, [0x50, 0x4B, 0x01, 0x02]);
    expect(centralDirectoryOffset, greaterThanOrEqualTo(0));

    // Mark the entry as Unix-created so its external mode denotes a symlink.
    symlinkZip[centralDirectoryOffset + 4] = 20;
    symlinkZip[centralDirectoryOffset + 5] = 3;
    expect(
      ZipDecoder().decodeBytes(symlinkZip).files.single.isSymbolicLink,
      isTrue,
    );

    final directory = await Directory.systemTemp.createTemp('eh-symlink-');
    addTearDown(() => directory.delete(recursive: true));
    final zipFile = File('${directory.path}/symlink.zip');
    await zipFile.writeAsBytes(symlinkZip);

    expect(
      () => verifyNoArchiveSymbolicLinks(zipFile.path),
      throwsFormatException,
    );
  });

  test('validates archive paths, page counts and image payloads', () async {
    const entries = [
      'pages/1.jpg',
      'pages/2.jpeg',
      r'pages\10.webp',
      'cover.jpg',
      'notes/readme.txt',
      'pages/',
    ];
    expect(countArchivePageFiles(entries), 3);
    verifyArchivePageCount(3, 3);
    expect(() => verifyArchivePageCount(3, 2), throwsFormatException);

    expect(isSafeArchivePath('gallery/pages/1.jpg'), isTrue);
    expect(isSafeArchivePath('../outside.jpg'), isFalse);
    expect(isSafeArchivePath(r'gallery\..\outside.jpg'), isFalse);
    expect(isSafeArchivePath('/outside.jpg'), isFalse);
    expect(isSafeArchivePath(r'C:\outside.jpg'), isFalse);
    expect(isArchiveCoverFileName('0001-cover.jpg'), isTrue);
    expect(isArchiveCoverFileName('discover.jpg'), isFalse);
    final names = ['10.jpg', '2.jpg', '1.jpg']
      ..sort(compareNaturalArchivePaths);
    expect(names, ['1.jpg', '2.jpg', '10.jpg']);

    final multiPartNames = [
      'chapter-10/page-2.jpg',
      'chapter-2/page-10.jpg',
      'chapter-2/page-2.jpg',
      'chapter-2/page-01.jpg',
      'chapter-2/page-1.jpg',
    ]..sort(compareNaturalArchivePaths);
    expect(multiPartNames, [
      'chapter-2/page-01.jpg',
      'chapter-2/page-1.jpg',
      'chapter-2/page-2.jpg',
      'chapter-2/page-10.jpg',
      'chapter-10/page-2.jpg',
    ]);

    final directory = await Directory.systemTemp.createTemp('eh-archive-');
    addTearDown(() => directory.delete(recursive: true));
    final validPng = image.encodePng(image.Image(width: 1, height: 1));
    final validImage = File('${directory.path}/1.png')
      ..writeAsBytesSync(validPng);
    expect(await isValidArchiveImage(validImage), isTrue);
    expect(isValidImageData(validPng), isTrue);
    expect(isValidImageData(validPng.sublist(0, 16)), isFalse);

    final invalidImage = File('${directory.path}/2.jpg')
      ..writeAsBytesSync(List<int>.filled(128, 0));
    expect(await isValidArchiveImage(invalidImage), isFalse);
    expect(isValidImageData(await invalidImage.readAsBytes()), isFalse);

    final unsupported = File('${directory.path}/3.txt')
      ..writeAsStringSync('not an image');
    expect(await isValidArchiveImage(unsupported), isFalse);
  });

  test('validates EH image response chunks once', () async {
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

    expect(progress, [12, 27, bytes.length]);
    expect(completed, isNotNull);
    expect(completed!, orderedEquals(bytes));
    expect(written.takeBytes(), orderedEquals(bytes));

    await expectLater(
      readEhImageResponse(
        Stream<List<int>>.value(bytes),
        expectedBytes: bytes.length + 1,
        writeChunk: (_) async {},
      ).drain<void>(),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      readEhImageResponse(
        const Stream<List<int>>.empty(),
        expectedBytes: null,
        writeChunk: (_) async {},
      ).drain<void>(),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      readEhImageResponse(
        Stream<List<int>>.value(List<int>.filled(128, 0)),
        expectedBytes: null,
        writeChunk: (_) async {},
      ).drain<void>(),
      throwsA(isA<FormatException>()),
    );
  });
}

int _findSignature(List<int> bytes, List<int> signature) {
  for (var offset = 0; offset <= bytes.length - signature.length; offset++) {
    var matches = true;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return offset;
  }
  return -1;
}
