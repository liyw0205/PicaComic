import 'dart:io';

import 'package:pica_comic/tools/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replaces a text file without leaving a temporary sibling', () async {
    final root = await Directory.systemTemp.createTemp('pica-atomic-file-');
    addTearDown(() => root.delete(recursive: true));

    final target = File('${root.path}/nested/rule.json');
    await writeTextFileAtomically(target, 'first');
    expect(await target.readAsString(), 'first');

    await writeTextFileAtomically(target, 'second');
    expect(await target.readAsString(), 'second');
    final siblings = await target.parent
        .list()
        .where((entry) => entry.path.contains('.tmp'))
        .toList();
    expect(siblings, isEmpty);
  });

  test('keeps the previous destination when replacement cannot complete',
      () async {
    final root = await Directory.systemTemp.createTemp('pica-atomic-file-');
    addTearDown(() => root.delete(recursive: true));

    final destination = Directory('${root.path}/existing');
    await destination.create();
    final target = File(destination.path);

    await expectLater(writeTextFileAtomically(target, 'new'),
        throwsA(isA<FileSystemException>()));
    expect(await destination.exists(), isTrue);
  });

  test('replaces binary data atomically', () async {
    final root = await Directory.systemTemp.createTemp('pica-atomic-file-');
    addTearDown(() => root.delete(recursive: true));

    final target = File('${root.path}/nested/output.pdf');
    await writeBytesFileAtomically(target, <int>[0, 1, 2, 255]);
    expect(await target.readAsBytes(), <int>[0, 1, 2, 255]);

    await writeBytesFileAtomically(target, <int>[37, 80, 68, 70]);
    expect(await target.readAsBytes(), <int>[37, 80, 68, 70]);
    final siblings = await target.parent.list().toList();
    expect(siblings.where((entry) => entry.path.contains('.tmp')), isEmpty);
  });
}
