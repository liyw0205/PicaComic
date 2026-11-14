import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/webdav.dart';
import 'package:sqlite3/sqlite3.dart';

part "image_favorites.dart";

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get target;

  Object? get maxPage => null;

  HistoryType get historyType;
}

final class HistoryType {
  static HistoryType get picacg => const HistoryType(0);

  static HistoryType get ehentai => const HistoryType(1);

  static HistoryType get jmComic => const HistoryType(2);

  static HistoryType get hitomi => const HistoryType(3);

  static HistoryType get htmanga => const HistoryType(4);

  static HistoryType get nhentai => const HistoryType(5);

  final int value;

  String get name {
    if (value >= 0 && value <= 5) {
      return ["picacg", "ehentai", "jm", "hitomi", "htmanga", "nhentai"][value];
    } else {
      return ComicSource.fromIntKey(value)?.name ?? "Unknown";
    }
  }

  const HistoryType(this.value);

  @override
  bool operator ==(Object other) =>
      other is HistoryType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  ComicSource? get comicSource {
    if (value >= 0 && value <= 5) {
      return ComicSource.find(name);
    } else {
      return ComicSource.fromIntKey(value);
    }
  }
}

base class History extends LinkedListEntry<History> {
  HistoryType type;

  DateTime time;

  String title;

  String subtitle;

  String cover;

  /// 标记为0表示没有阅读位置记录
  int ep;

  int page;

  String target;

  Set<int> readEpisode;

  int? maxPage;

  History(this.type, this.time, this.title, this.subtitle, this.cover, this.ep,
      this.page, this.target,
      [this.readEpisode = const <int>{}, this.maxPage]);

  History.fromModel(
      {required HistoryMixin model,
      required this.ep,
      required this.page,
      this.readEpisode = const <int>{},
      DateTime? time})
      : type = model.historyType,
        title = model.title,
        subtitle = model.subTitle ?? '',
        cover = model.cover,
        target = model.target,
        time = time ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        "type": type.value,
        "time": time.millisecondsSinceEpoch,
        "title": title,
        "subtitle": subtitle,
        "cover": cover,
        "ep": ep,
        "page": page,
        "target": target,
        "readEpisode": readEpisode.toList(),
        "max_page": maxPage
      };

  History.fromMap(Map<String, dynamic> map)
      : type = HistoryType(map["type"]),
        time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
        title = map["title"],
        subtitle = map["subtitle"],
        cover = map["cover"],
        ep = map["ep"],
        page = map["page"],
        target = map["target"],
        readEpisode = Set<int>.from(
            (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <int>{}),
        maxPage = map["max_page"];

  @override
  String toString() {
    return 'NewHistory{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, target: $target}';
  }

  History.fromRow(Row row)
      : type = HistoryType(row["type"]),
        time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
        title = row["title"],
        subtitle = row["subtitle"],
        cover = row["cover"],
        ep = row["ep"],
        page = row["page"],
        target = row["target"],
        readEpisode = Set<int>.from((row["readEpisode"] as String)
            .split(',')
            .where((element) => element != "")
            .map((e) => int.parse(e))),
        maxPage = row.keys.contains("max_page") ? row["max_page"] : null;

  static Future<History> findOrCreate(
    HistoryMixin model, {
    int ep = 0,
    int page = 0,
  }) async {
    var history = await HistoryManager().find(model.target);
    if (history != null) {
      return history;
    }
    history = History.fromModel(model: model, ep: ep, page: page);
    await HistoryManager().addHistory(history);
    return history;
  }

  static Future<History> createIfNull(
      History? history, HistoryMixin model) async {
    if (history != null) {
      return history;
    }
    history = History.fromModel(model: model, ep: 0, page: 0);
    await HistoryManager().addHistory(history);
    return history;
  }
}

class HistoryManager {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  bool _isOpen = false;

  void close() {
    if (_isOpen) {
      _db.dispose();
      _isOpen = false;
    }
    _cachedHistory.clear();
  }

  Future<void> snapshotTo(String path) => DataMaintenance.run(() {
        _db.execute('VACUUM INTO ?;', [path]);
      });

  bool _deferWrite(void Function() operation) {
    if (!DataMaintenance.busy) return false;
    DataMaintenance.run(operation).catchError((Object error, StackTrace stack) {
      LogManager.addLog(LogLevel.error, 'HistoryManager', '$error\n$stack');
    });
    return true;
  }

  int get length => _db.select("select count(*) from history;").first[0] as int;

  static const _historyExistenceCacheLimit = 1024;
  final Map<String, bool> _cachedHistory = {};

  Future<void> tryUpdateDb() async {
    var file = File("${App.dataPath}/history_temp.db");
    if (!file.existsSync()) {
      LogManager.addLog(
          LogLevel.info, "HistoryManager.tryUpdateDb", "db file not exist");
      return;
    }
    await _mergeWithReadonlyFallback(() => mergeFrom(file.path));
    _deleteImportedSource(file);
  }

  Future<void> _mergeWithReadonlyFallback(
      Future<void> Function() operation) async {
    try {
      await operation();
    } on SqliteException catch (error) {
      // The source directory may be writable only for the already-open
      // database file. Avoid creating a rollback journal beside it on retry.
      if (error.resultCode != 8) rethrow;
      _db.execute('PRAGMA journal_mode = MEMORY;');
      await operation();
    }
  }

  void _deleteImportedSource(File file) {
    try {
      file.deleteSync();
    } catch (error, stack) {
      // The merge is already committed; cleanup must not turn a successful
      // import into a startup failure. Keep the source for a later retry.
      LogManager.addLog(
          LogLevel.warning,
          'HistoryManager',
          'Failed to remove imported source ${file.path}; retaining it for '
              'retry.\n$error\n$stack');
    }
  }

  /// Merge a validated archive into this connection without modifying its input.
  Future<void> mergeFrom(String sourcePath) => DataMaintenance.run(() {
        final source = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
        try {
          final histories = source
              .select('select * from history;')
              .map(History.fromRow)
              .toList();
          final hasImages = source.select(
            "select 1 from sqlite_master where type = 'table' and name = ?;",
            ['image_favorites'],
          ).isNotEmpty;
          final images = hasImages
              ? source.select('select * from image_favorites;').map((row) {
                  final favorite = ImageFavorite(
                      row['id'],
                      row['cover'],
                      row['title'],
                      row['ep'],
                      row['page'],
                      Map<String, dynamic>.from(jsonDecode(row['other'])));
                  return favorite;
                }).toList()
              : <ImageFavorite>[];
          _transaction(() {
            for (final history in histories) {
              _insertHistory(history, updateTime: false);
            }
            for (final image in images) {
              _db.execute('''
            insert or ignore into image_favorites
              (id, title, cover, ep, page, other) values (?, ?, ?, ?, ?, ?);
          ''', [
                image.id,
                image.title,
                image.imagePath,
                image.ep,
                image.page,
                jsonEncode(image.otherInfo)
              ]);
            }
          });
        } finally {
          source.dispose();
          _cachedHistory.clear();
        }
      }, suppressSync: true, operationName: 'history-import');

  void _transaction(void Function() operation) {
    _db.execute('BEGIN IMMEDIATE;');
    try {
      operation();
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
  }

  Future<void> init({String? databasePath, bool importLegacy = true}) async {
    close();
    _db = sqlite3.open(databasePath ?? "${App.dataPath}/history.db");
    _isOpen = true;
    _db.createFunction(
      functionName: 'pica_lower',
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
      function: (arguments) => (arguments.single as String?)?.toLowerCase(),
    );

    _transaction(() {
      _db.execute("""
        create table if not exists history  (
          target text primary key,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int
        );
      """);

      // 检查是否有max_page字段, 如果没有则添加
      var res = _db.select("""
      PRAGMA table_info(history);
    """);
      if (res.every((row) => row["name"] != "max_page")) {
        _db.execute("""
        alter table history
        add column max_page int;
      """);
      }

      _db.execute('''
      create index if not exists history_time_target on history(time DESC, target);
    ''');
      ImageFavoriteManager._init(_db);
      if ((_db.select('PRAGMA user_version;').single[0] as int) < 1) {
        _db.execute('PRAGMA user_version = 1;');
      }
    });

    // 迁移早期版本的数据
    if (importLegacy) {
      var file = File("${App.dataPath}/history.json");
      if (file.existsSync()) {
        await readDataFromJson(jsonDecode(file.readAsStringSync()));
        _deleteImportedSource(file);
      }
    }
  }

  Future<void> readDataFromJson(List<dynamic> json) => DataMaintenance.run(() {
        final histories = json
            .map((h) => History.fromMap(Map<String, dynamic>.from(h as Map)))
            .toList();
        try {
          _transaction(() {
            for (final history in histories) {
              _insertHistory(history, updateTime: false);
            }
          });
        } finally {
          _cachedHistory.clear();
        }
      }, suppressSync: true, operationName: 'history-import');

  Future<void> saveData() async {
    DataMaintenance.recordSyncRequest();
    if (!DataMaintenance.syncSuppressed) await Webdav.uploadData();
  }

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  Future<void> addHistory(History newItem) => DataMaintenance.run(() {
        _insertHistory(newItem);
        _rememberHistoryPresence(newItem.target, true);
        return saveData();
      });

  void _insertHistory(History newItem, {bool updateTime = true}) {
    var res = _db.select("""
      select 1 from history
      where target == ?;
    """, [newItem.target]);
    if (res.isEmpty) {
      _db.execute("""
        insert into history (target, title, subtitle, cover, time, type, ep, page, readEpisode, max_page)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """, [
        newItem.target,
        newItem.title,
        newItem.subtitle,
        newItem.cover,
        newItem.time.millisecondsSinceEpoch,
        newItem.type.value,
        newItem.ep,
        newItem.page,
        newItem.readEpisode.join(','),
        newItem.maxPage
      ]);
    } else if (updateTime) {
      _db.execute("""
        update history
        set time = ?
        where target == ?;
      """, [DateTime.now().millisecondsSinceEpoch, newItem.target]);
    }
  }

  ///退出阅读器时调用此函数, 修改阅读位置
  Future<void> saveReadHistory(History history, [bool updateMePage = true]) =>
      DataMaintenance.run(() async {
        _db.execute("""
        update history
        set time = ?, ep = ?, page = ?, readEpisode = ?, max_page = ?
        where target == ?;
    """, [
          DateTime.now().millisecondsSinceEpoch,
          history.ep,
          history.page,
          history.readEpisode.join(','),
          history.maxPage,
          history.target
        ]);
        if (updateMePage) {
          scheduleMicrotask(() {
            StateController.findOrNull(tag: "me_page")?.update();
          });
        }
        await saveData();
      });

  void clearHistory() {
    if (_deferWrite(clearHistory)) return;
    _db.execute("delete from history;");
    _cachedHistory.clear();
  }

  void remove(String id) {
    if (_deferWrite(() => remove(id))) return;
    _db.execute("""
      delete from history
      where target == ?;
    """, [id]);
    _rememberHistoryPresence(id, false);
  }

  Future<History?> find(String target) async {
    return findSync(target);
  }

  void updateCache() {
    // Presence is populated lazily by findSync. Keeping this method as a
    // cache reset preserves its historical API without scanning the table.
    _cachedHistory.clear();
  }

  void _rememberHistoryPresence(String target, bool exists) {
    _cachedHistory.remove(target);
    _cachedHistory[target] = exists;
    if (_cachedHistory.length > _historyExistenceCacheLimit) {
      _cachedHistory.remove(_cachedHistory.keys.first);
    }
  }

  History? findSync(String target) {
    if (_cachedHistory[target] == false) {
      return null;
    }

    var res = _db.select("""
      select * from history
      where target == ?;
    """, [target]);
    if (res.isEmpty) {
      _rememberHistoryPresence(target, false);
      return null;
    }
    _rememberHistoryPresence(target, true);
    return History.fromRow(res.first);
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC, target ASC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// Keyset pagination stays stable when preceding rows are deleted or added.
  List<History> getPage({int limit = 60, History? after, String keyword = ''}) {
    if (limit <= 0) return [];
    final conditions = <String>[];
    final parameters = <Object?>[];
    if (keyword.isNotEmpty) {
      conditions.add(
          '(instr(pica_lower(title), ?) > 0 or instr(pica_lower(subtitle), ?) > 0)');
      parameters.addAll([keyword.toLowerCase(), keyword.toLowerCase()]);
    }
    if (after != null) {
      conditions.add('(time <= ? and (time < ? or target > ?))');
      parameters.addAll([
        after.time.millisecondsSinceEpoch,
        after.time.millisecondsSinceEpoch,
        after.target
      ]);
    }
    parameters.add(limit);
    final rows = _db.select('''
      select * from history
      ${conditions.isEmpty ? '' : 'where ${conditions.join(' and ')}'}
      order by time DESC, target ASC limit ?;
    ''', parameters);
    return rows.map(History.fromRow).toList();
  }

  void vacuum() {
    if (_deferWrite(vacuum)) return;
    _db.execute("""
      vacuum;
    """);
  }

  /// 获取最近一周的阅读数据, 用于生成图表, List中的元素是当天阅读的漫画数量
  List<int> getWeekData(int days) {
    if (days <= 0) return [];
    final now = DateTime.now();
    var res = _db.select("""
      select time from history
      where time > ? and time <= ?
      order by time ASC;
    """, [
      now.subtract(Duration(days: days)).millisecondsSinceEpoch,
      now.millisecondsSinceEpoch
    ]);
    var data = List<int>.filled(days, 0);
    for (var element in res) {
      var time = DateTime.fromMillisecondsSinceEpoch(element["time"] as int);
      final index = now.difference(time).inDays;
      if (index >= 0 && index < days) data[index]++;
    }
    return data.reversed.toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC, target ASC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }
}
