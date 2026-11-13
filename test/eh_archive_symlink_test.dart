import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/network/eh_network/archive_utils.dart';

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
