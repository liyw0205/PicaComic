import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'file_downloader_regression.dart';

void main() {
  for (final scenario in fileDownloadCases) {
    test(scenario, () async {
      final overrides = HttpOverrides.current;
      addTearDown(() => HttpOverrides.global = overrides);
      await HttpOverrides.runZoned(() => verifyFileDownload(scenario));
    });
  }
}
