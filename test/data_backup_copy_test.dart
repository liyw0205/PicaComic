import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/tools/data_backup.dart';

void main() {
  test('copyBackupEntity copies nested backup files asynchronously', () async {
    final root = await Directory.systemTemp.createTemp('backup-copy-test-');
    addTearDown(() => root.delete(recursive: true));

    final source = Directory('${root.path}/source');
    await Directory('${source.path}/nested').create(recursive: true);
    await File('${source.path}/root.txt').writeAsString('root', flush: true);
    await File('${source.path}/nested/child.txt')
        .writeAsString('child', flush: true);

    final destination = '${root.path}/destination';
    await copyBackupEntity(source.path, destination);

    expect(await File('$destination/root.txt').readAsString(), 'root');
    expect(await File('$destination/nested/child.txt').readAsString(), 'child');
  });
}
