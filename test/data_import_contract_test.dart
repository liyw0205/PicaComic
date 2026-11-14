import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('pica-data-import-');
    App.dataPath = '${root.path}/data';
    App.cachePath = '${root.path}/cache';
    await Directory(App.dataPath).create(recursive: true);
    await Directory(App.cachePath).create(recursive: true);
  });

  setUp(() async {
    await DataMaintenance.waitForIdle();
    SharedPreferences.setMockInitialValues({});
  });

  tearDownAll(() async {
    await DataMaintenance.waitForIdle();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('readDataFromJson waits for persistence before completing', () async {
    final isolated = Appdata()
      ..blockingKeyword = ['local']
      ..favoriteTags = {'local'};
    final payload = isolated.toJson(includeSensitive: true);
    final importedSettings =
        List<String>.from(payload['settings'] as List<dynamic>);
    importedSettings[1] = 'da';
    payload['settings'] = importedSettings;
    payload['blockingKeywords'] = ['imported'];
    payload['favoriteTags'] = ['imported-tag'];

    await isolated.readDataFromJson(payload, importHistory: false);

    final saved =
        jsonDecode(await File('${App.dataPath}/settings').readAsString())
            as List<dynamic>;
    expect(saved[1], 'da');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('blockingKeyword'),
        containsAll(<String>['local', 'imported']));
    expect(preferences.getStringList('favoriteTags'),
        containsAll(<String>['local', 'imported-tag']));
    expect(DataMaintenance.lastStats?.operation, 'data-import');
  });

  test('readDataFromJson propagates malformed payload errors', () async {
    final isolated = Appdata();
    final malformed = <String, dynamic>{
      'schemaVersion': 1,
      'settings': <String, dynamic>{'not': 'a list'},
    };

    await expectLater(
      isolated.readDataFromJson(malformed, importHistory: false),
      throwsA(isA<FormatException>()),
    );
  });

  test('legacy import bool reports an older archive as false', () async {
    final previousVersion = appdata.settings[46];
    appdata.settings[46] = '2';
    addTearDown(() => appdata.settings[46] = previousVersion);

    final archive = Archive()
      ..addFile(ArchiveFile.string(
        'appdata',
        jsonEncode({
          'schemaVersion': 1,
          'settings': <String>[...appdata.settings]..[46] = '1',
          'firstUse': appdata.firstUse,
          'blockingKeywords': const <String>[],
          'favoriteTags': const <String>[],
        }),
      ));
    final file = File('${root.path}/older.picadata');
    await file.writeAsBytes(ZipEncoder().encode(archive)!, flush: true);

    expect(await importDataResult(file.path, checkVersion: true),
        DataImportResult.skipped);
    expect(await importData(file.path), isFalse);
  });
}
