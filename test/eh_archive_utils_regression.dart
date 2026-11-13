import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;

import 'package:pica_comic/network/eh_network/archive_utils.dart';
import 'package:pica_comic/tools/file_type.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  _check(isSafeArchivePath('gallery/pages/1.jpg'), 'Safe path rejected');
  _check(!isSafeArchivePath('../outside.jpg'), 'Traversal path accepted');
  _check(!isSafeArchivePath(r'gallery\..\outside.jpg'),
      'Backslash traversal accepted');
  _check(!isSafeArchivePath('/outside.jpg'), 'Absolute path accepted');
  _check(!isSafeArchivePath(r'C:\outside.jpg'), 'Drive path accepted');
  _check(isArchiveCoverFileName('0001-cover.jpg'), 'Cover file not detected');
  _check(!isArchiveCoverFileName('discover.jpg'),
      'Page filename was a false cover');

  final names = ['10.jpg', '2.jpg', '1.jpg']..sort(compareNaturalArchivePaths);
  _check(names.join(',') == '1.jpg,2.jpg,10.jpg', 'Natural order is incorrect');

  final directory = await Directory.systemTemp.createTemp('pica-eh-archive-');
  try {
    final validImage = File('${directory.path}/1.png');
    final validPng = image.encodePng(image.Image(width: 1, height: 1));
    await validImage.writeAsBytes(validPng);
    _check(await isValidArchiveImage(validImage), 'Valid PNG was rejected');
    _check(isValidImageData(validPng), 'Valid image payload was rejected');
    _check(!isValidImageData(validPng.sublist(0, 16)),
        'Truncated PNG payload was accepted');

    final invalidImage = File('${directory.path}/2.jpg');
    await invalidImage.writeAsBytes(List<int>.filled(128, 0));
    _check(
        !await isValidArchiveImage(invalidImage), 'Corrupt image was accepted');
    _check(!isValidImageData(await invalidImage.readAsBytes()),
        'Corrupt image payload was accepted');

    final symlinkArchive = Archive()
      ..addFile(
          ArchiveFile.string('outside-link', '../outside.txt')..mode = 0xA1FF);
    final symlinkZip = ZipEncoder().encode(symlinkArchive)!;
    final centralDirectoryOffset =
        _findSignature(symlinkZip, [0x50, 0x4B, 0x01, 0x02]);
    _check(centralDirectoryOffset >= 0, 'ZIP central directory was not found');
    symlinkZip[centralDirectoryOffset + 4] = 20;
    symlinkZip[centralDirectoryOffset + 5] = 3;
    _check(ZipDecoder().decodeBytes(symlinkZip).files.single.isSymbolicLink,
        'Malicious ZIP fixture was not recognized as a symlink');
    final symlinkArchiveFile = File('${directory.path}/symlink.zip');
    await symlinkArchiveFile.writeAsBytes(symlinkZip);
    var symlinkRejected = false;
    try {
      verifyNoArchiveSymbolicLinks(symlinkArchiveFile.path);
    } on FormatException {
      symlinkRejected = true;
    }
    _check(symlinkRejected, 'Archive symlink was accepted');

    final unsupported = File('${directory.path}/3.txt');
    await unsupported.writeAsString('not an image');
    _check(!await isValidArchiveImage(unsupported),
        'Unsupported file was accepted');
  } finally {
    await directory.delete(recursive: true);
  }
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
