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
  static Future<void> _saveTail = Future<void>.value();

  static bool get stackEnabled => dataProvider()?[_stackEnabledKey] != false;

  static Future<void> setStackEnabled(bool value) async {
    final data = dataProvider();
    if (data == null) return;
    final operation = _saveTail.then<void>((_) async {
      if (!identical(dataProvider(), data) || stackEnabled == value) return;

      final hadPreviousValue = data.containsKey(_stackEnabledKey);
      final previousValue = data[_stackEnabledKey];
      data[_stackEnabledKey] = value;
      changes.value++;
      try {
        await saver();
      } catch (_) {
        if (identical(dataProvider(), data) &&
            data[_stackEnabledKey] == value) {
          if (hadPreviousValue) {
            data[_stackEnabledKey] = previousValue;
          } else {
            data.remove(_stackEnabledKey);
          }
          changes.value++;
        }
        rethrow;
      }
    });
    _saveTail = operation.then<void>((_) {}, onError: (_, __) {});
    await operation;
  }
}
