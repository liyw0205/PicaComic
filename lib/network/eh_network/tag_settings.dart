import 'package:flutter/foundation.dart';
import 'package:pica_comic/comic_source/comic_source.dart';

class EhTagSettings {
  EhTagSettings._();

  static const _stackEnabledKey = 'tagStackEnabled';

  @visibleForTesting
  static Map<String, dynamic>? Function() dataProvider =
      () => ComicSource.find('ehentai')?.data;

  @visibleForTesting
  static Future<void> Function() saver =
      () async => await ComicSource.find('ehentai')?.saveData();

  static final changes = ValueNotifier<int>(0);

  static bool get stackEnabled => dataProvider()?[_stackEnabledKey] != false;

  static Future<void> setStackEnabled(bool value) async {
    final data = dataProvider();
    if (data == null) return;
    data[_stackEnabledKey] = value;
    changes.value++;
    await saver();
  }
}
