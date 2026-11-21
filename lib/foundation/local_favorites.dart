import 'dart:async';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/data_maintenance.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/network/eh_network/eh_main_network.dart';
import 'package:pica_comic/network/eh_network/eh_models.dart';
import 'package:pica_comic/network/eh_network/get_gallery_id.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_models.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/jm_network/jm_image.dart';
import 'package:pica_comic/network/jm_network/jm_models.dart';
import 'package:pica_comic/network/nhentai_network/models.dart';
import 'package:pica_comic/network/picacg_network/models.dart';
import 'package:pica_comic/pages/favorites/main_favorites_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:sqlite3/sqlite3.dart';
import 'dart:io';
import '../network/base_comic.dart';
import '../network/webdav.dart';

String getCurTime() {
  return DateTime.now()
      .toIso8601String()
      .replaceFirst("T", " ")
      .substring(0, 19);
}

final class FavoriteType {
  final int key;

  const FavoriteType(this.key);

  static const _legacyBuiltInTypes = <String, int>{
    'picacg': 0,
    'ehentai': 1,
    'jm': 2,
    'hitomi': 3,
    'htmanga': 4,
    'nhentai': 6,
  };

  List<int> get _compatibleKeys {
    final keys = <int>{key};
    for (final entry in _legacyBuiltInTypes.entries) {
      final legacyKey = entry.key.hashCode;
      if (key == entry.value || key == legacyKey) {
        keys
          ..add(entry.value)
          ..add(legacyKey);
      }
    }
    return keys.toList();
  }

  int get _canonicalBuiltInKey {
    for (final entry in _legacyBuiltInTypes.entries) {
      if (key == entry.value || key == entry.key.hashCode) {
        return entry.value;
      }
    }
    return key;
  }

  static FavoriteType get picacg => const FavoriteType(0);

  static FavoriteType get ehentai => const FavoriteType(1);

  static FavoriteType get jm => const FavoriteType(2);

  static FavoriteType get hitomi => const FavoriteType(3);

  static FavoriteType get htManga => const FavoriteType(4);

  static FavoriteType get nhentai => const FavoriteType(6);

  ComicType get comicType {
    final canonicalKey = _canonicalBuiltInKey;
    if (canonicalKey >= 0 && canonicalKey <= 6) {
      return ComicType.values[canonicalKey];
    }
    return ComicType.other;
  }

  ComicSource get comicSource {
    final canonicalKey = _canonicalBuiltInKey;
    if (canonicalKey >= 0 && canonicalKey <= 6) {
      var key = comicType.name.toLowerCase();
      return ComicSource.find(key)!;
    }
    return ComicSource.sources
            .firstWhereOrNull((element) => element.intKey == key) ??
        (throw "Comic Source Not Found");
  }

  String get name {
    if (comicType != ComicType.other) {
      return comicType.name;
    } else {
      try {
        return comicSource.name;
      } catch (e) {
        return "**Unknown**";
      }
    }
  }

  @override
  bool operator ==(Object other) {
    return other is FavoriteType &&
        other._canonicalBuiltInKey == _canonicalBuiltInKey;
  }

  @override
  int get hashCode => _canonicalBuiltInKey.hashCode;
}

class FavoriteItem {
  String name;
  String author;
  FavoriteType type;
  List<String> tags;
  String target;
  String coverPath;
  String time = getCurTime();

  bool get available {
    if (type._canonicalBuiltInKey <= 6 && type._canonicalBuiltInKey >= 0) {
      return true;
    }
    return ComicSource.sources
            .firstWhereOrNull((element) => element.intKey == type.key) !=
        null;
  }

  String toDownloadId() {
    try {
      return switch (type.comicType) {
        ComicType.picacg => target,
        ComicType.ehentai => getGalleryId(target),
        ComicType.jm => "jm$target",
        ComicType.hitomi => hitomiGalleryIdFromTarget(target) == null
            ? target
            : "hitomi${hitomiGalleryIdFromTarget(target)}",
        // WNACG download records use the same capitalized prefix as
        // DownloadManager.addHtDownload and DownloadedHtComic.id.
        ComicType.htManga => "Ht$target",
        ComicType.nhentai => "nhentai$target",
        _ => () {
            final source = ComicSource.fromIntKey(type.key);
            if (source != null) {
              return DownloadManager().generateId(source.key, target);
            }
            return DownloadManager().findCustomDownloadId(type.key, target) ??
                "**Invalid ID**";
          }(),
      };
    } catch (e) {
      return "**Invalid ID**";
    }
  }

  FavoriteItem({
    required this.target,
    required this.name,
    required this.coverPath,
    required this.author,
    required this.type,
    required this.tags,
  });

  FavoriteItem.fromPicacg(ComicItemBrief comic)
      : name = comic.title,
        author = comic.author,
        type = FavoriteType.picacg,
        tags = comic.tags,
        target = comic.id,
        coverPath = comic.path;

  FavoriteItem.fromEhentai(EhGalleryBrief comic)
      : name = comic.title,
        author = comic.uploader,
        type = FavoriteType.ehentai,
        tags = comic.tags,
        target = comic.link,
        coverPath = comic.coverPath;

  FavoriteItem.fromJmComic(JmComicBrief comic)
      : name = comic.name,
        author = comic.author,
        type = FavoriteType.jm,
        tags = [],
        target = comic.id,
        coverPath = getJmCoverUrl(comic.id);

  FavoriteItem.fromHitomi(HitomiComicBrief comic)
      : name = comic.name,
        author = comic.artist,
        type = FavoriteType.hitomi,
        tags = List.generate(
            comic.tagList.length, (index) => comic.tagList[index].name),
        target = canonicalHitomiTarget(comic.link),
        coverPath = comic.cover;

  FavoriteItem.fromHtcomic(HtComicBrief comic)
      : name = comic.name,
        author = "${comic.pages}Pages",
        type = FavoriteType.htManga,
        tags = [],
        target = comic.id,
        coverPath = comic.image;

  FavoriteItem.fromNhentai(NhentaiComicBrief comic)
      : name = comic.title,
        author = "",
        type = FavoriteType.nhentai,
        tags = comic.tags,
        target = comic.id,
        coverPath = comic.cover;

  FavoriteItem.custom(CustomComic comic)
      : name = comic.title,
        author = comic.subTitle,
        type = FavoriteType(comic.sourceKey.hashCode),
        tags = comic.tags,
        target = comic.id,
        coverPath = comic.cover;

  Map<String, dynamic> toJson() => {
        "name": name,
        "author": author,
        "type": type.key,
        "tags": tags,
        "target": target,
        "coverPath": coverPath,
        "time": time
      };

  FavoriteItem.fromJson(Map<String, dynamic> json)
      : name = json["name"],
        author = json["author"],
        type = FavoriteType(json["type"]),
        tags = List<String>.from(json["tags"]),
        target = json["target"],
        coverPath = json["coverPath"],
        time = json["time"];

  FavoriteItem.fromRow(Row row)
      : name = row["name"],
        author = row["author"],
        type = FavoriteType(row["type"]),
        tags = ((row["tags"] as String?) ?? "").split(","),
        target = row["target"],
        coverPath = row["cover_path"],
        time = row["time"] {
    tags.remove("");
  }

  factory FavoriteItem.fromBaseComic(BaseComic comic) {
    if (comic is ComicItemBrief) {
      return FavoriteItem.fromPicacg(comic);
    } else if (comic is EhGalleryBrief) {
      return FavoriteItem.fromEhentai(comic);
    } else if (comic is JmComicBrief) {
      return FavoriteItem.fromJmComic(comic);
    } else if (comic is HtComicBrief) {
      return FavoriteItem.fromHtcomic(comic);
    } else if (comic is NhentaiComicBrief) {
      return FavoriteItem.fromNhentai(comic);
    } else if (comic is CustomComic) {
      return FavoriteItem.custom(comic);
    }
    throw UnimplementedError();
  }

  @override
  bool operator ==(Object other) {
    return other is FavoriteItem &&
        _favoriteTargetsMatch(type, other.target, target) &&
        other.type == type;
  }

  @override
  int get hashCode =>
      (type.comicType == ComicType.hitomi
              ? canonicalHitomiTarget(target)
              : target)
          .hashCode ^
      type.hashCode;

  @override
  String toString() {
    var s = "FavoriteItem: $name $author $coverPath $hashCode $tags";
    if (s.length > 100) {
      return s.substring(0, 100);
    }
    return s;
  }
}

class FavoriteItemWithFolderInfo {
  FavoriteItem comic;
  String folder;

  FavoriteItemWithFolderInfo(this.comic, this.folder);

  @override
  bool operator ==(Object other) {
    return other is FavoriteItemWithFolderInfo &&
        other.comic == comic &&
        other.folder == folder;
  }

  @override
  int get hashCode => comic.hashCode ^ folder.hashCode;
}

class FolderSync {
  String folderName;
  String time = getCurTime();
  String key;
  String syncData; // 内容是 json, 存一下选中的文件夹 folderId
  FolderSync(this.folderName, this.key, this.syncData);

  Map<String, dynamic> get syncDataObj => jsonDecode(syncData);
}

extension SQL on String {
  String get toParam => replaceAll('\'', "''").replaceAll('"', "\"\"");
}

class LocalFavoritesManager {
  factory LocalFavoritesManager() =>
      cache ?? (cache = LocalFavoritesManager._create());

  LocalFavoritesManager._create();

  LocalFavoritesManager.create();

  static LocalFavoritesManager? cache;

  late Database _db;
  late String _deletionsPath;

  bool _isOpen = false;

  bool _inTransaction = false;

  static String _identifier(String name) => '"${name.replaceAll('"', '""')}"';

  void close() {
    if (_isOpen) {
      _db.dispose();
      _isOpen = false;
    }
    _modifiedAfterLastCache = true;
  }

  Future<void> snapshotTo(String path) => DataMaintenance.run(() {
        _db.execute('VACUUM INTO ?;', [path]);
        final deletions = sqlite3.open(_deletionsPath, mode: OpenMode.readOnly);
        try {
          deletions.execute('VACUUM INTO ?;', ['$path.deletions']);
        } finally {
          deletions.dispose();
        }
      });

  bool _deferWrite(void Function() operation) {
    if (!DataMaintenance.busy) return false;
    DataMaintenance.run(operation).catchError((Object error, StackTrace stack) {
      LogManager.addLog(LogLevel.error, 'LocalFavoritesManager',
          '${safeNetworkError(error)}\n$stack');
    });
    return true;
  }

  Future<void> init({String? databasePath, bool importLegacy = true}) async {
    close();
    final path = databasePath ?? "${App.dataPath}/local_favorite.db";
    _deletionsPath = '$path.deletions';
    _db = sqlite3.open(path);
    _db.execute('ATTACH DATABASE ? AS deletions;', [_deletionsPath]);
    _isOpen = true;
    _db.createFunction(
      functionName: 'pica_lower',
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
      function: (arguments) => (arguments.single as String?)?.toLowerCase(),
    );
    _checkAndCreate();
    if (importLegacy) await readData();
  }

  void _transaction(void Function() operation) {
    _db.execute('BEGIN IMMEDIATE;');
    _inTransaction = true;
    try {
      operation();
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    } finally {
      _inTransaction = false;
    }
  }

  void _checkAndCreate() {
    _transaction(() {
      final tables = _getTablesWithDB();
      if (!tables.contains('folder_sync')) {
        _db.execute("""
      create table folder_sync (
        folder_name text primary key,
        time TEXT,
        key TEXT,
        sync_data TEXT
      );
    """);
      }
      if (!tables.contains('folder_order')) {
        _db.execute("""
      create table folder_order (
        folder_name text primary key,
        order_value int
      );
    """);
      }
      _db.execute('''
        create table if not exists deletions.deleted_items (
          folder_name text,
          target text,
          type int,
          deleted_at text,
          primary key (folder_name, target, type)
        );
      ''');
      tables.remove('folder_sync');
      tables.remove('folder_order');
      for (final table in tables) {
        var res = _db.select("""
      PRAGMA table_info(${_identifier(table)});
    """);
        final keyColumns = res
            .where((row) => row['pk'] != 0)
            .map((row) => row['name'])
            .toSet();
        if (keyColumns.length != 2 ||
            !keyColumns.containsAll(['target', 'type'])) {
          var tempName = "${table}_dw5d8g2_temp";
          while (_getTablesWithDB().contains(tempName)) {
            tempName += '_';
          }
          final originalCount = count(table);
          _db.execute("""
          ALTER TABLE ${_identifier(table)} RENAME TO ${_identifier(tempName)};
          CREATE TABLE ${_identifier(table)} (
            target text,
            name TEXT,
            author TEXT,
            type int,
            tags TEXT,
            cover_path TEXT,
            time TEXT,
            display_order int,
            primary key (target, type)
          );
          INSERT INTO ${_identifier(table)}
            (target, name, author, type, tags, cover_path, time, display_order)
            SELECT target, name, author, type, tags, cover_path, time, display_order
            FROM ${_identifier(tempName)};
        """);
          if (count(table) != originalCount) {
            throw StateError('Favorite migration row count mismatch: $table');
          }
          _db.execute('DROP TABLE ${_identifier(tempName)};');
        }
      }
      for (final table in tables) {
        // Folder pages always use this stable ordering. Keeping the index per
        // folder avoids a full table sort as collections grow.
        final indexName =
            _identifier('pica_favorites_${table}_display_order_target_type');
        _db.execute('''
          create index if not exists $indexName
          on ${_identifier(table)}(display_order, target, type);
        ''');
      }
      if ((_db.select('PRAGMA user_version;').single[0] as int) < 1) {
        _db.execute('PRAGMA user_version = 1;');
      }
    });
  }

  void updateUI() {
    Future.microtask(
        () => StateController.findOrNull(tag: "me page")?.update());
    Future.microtask(
        () => StateController.findOrNull<FavoritesPageController>()?.update());
  }

  Future<List<String>> find(String target, FavoriteType type) async {
    var res = <String>[];
    for (var folder in folderNames) {
      final rows = _matchingRows(folder, target, type);
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  Future<List<String>> findWithModel(FavoriteItem item) async {
    var res = <String>[];
    for (var folder in folderNames) {
      final rows = _matchingRows(folder, item.target, item.type);
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  Future<void> saveData() async {
    DataMaintenance.recordSyncRequest();
    if (!_inTransaction && !DataMaintenance.syncSuppressed) {
      await Webdav.uploadData();
    }
  }

  /// read data from json file or temp db.
  ///
  /// The source is retained if parsing, migration, committing, or cleanup
  /// fails.
  Future<void> readData() => DataMaintenance.run(() async {
        var file = File("${App.dataPath}/localFavorite");
        if (file.existsSync()) {
          await _mergeWithReadonlyFallback(() => mergeLegacyJson(file.path));
          _deleteImportedSource(file);
        } else if ((file = File("${App.dataPath}/local_favorite_temp.db"))
            .existsSync()) {
          await _mergeWithReadonlyFallback(() => mergeFrom(file.path));
          _deleteImportedSource(file);
        } else {
          LogManager.addLog(LogLevel.info, "LocalFavoritesManager",
              "no local favorites db file found");
        }
      }, suppressSync: true);

  Future<void> _mergeWithReadonlyFallback(
      Future<void> Function() operation) async {
    try {
      await operation();
    } on SqliteException catch (error) {
      // SQLite's default rollback journal is created beside the database. A
      // read-only parent directory can still contain a writable database, so
      // retry this import with an in-memory journal while preserving the
      // transaction boundary.
      if (error.resultCode != 8) rethrow;
      _db.execute('PRAGMA journal_mode = MEMORY;');
      await operation();
    }
  }

  void _deleteImportedSource(File file) {
    try {
      file.deleteSync();
    } catch (error, stack) {
      // The database merge is already committed; retain the source for a
      // later retry instead of failing startup on a cleanup-only error.
      LogManager.addLog(
          LogLevel.warning,
          'LocalFavoritesManager',
          'Failed to remove imported source ${file.path}; retaining it for '
              'retry.\n${safeNetworkError(error)}\n$stack');
    }
  }

  Future<void> mergeLegacyJson(String sourcePath) => DataMaintenance.run(() {
        final data = jsonDecode(File(sourcePath).readAsStringSync())
            as Map<String, dynamic>;
        final folders = <String, List<FavoriteItem>>{};
        for (final entry in data.entries) {
          folders[entry.key] = (entry.value as List)
              .map((comic) => FavoriteItem.fromJson(
                  Map<String, dynamic>.from(comic as Map)))
              .toSet()
              .toList();
        }
        try {
          _transaction(() {
            final existing = folderNames.toSet();
            for (final entry in folders.entries) {
              final isNew = !existing.contains(entry.key);
              final folder = isNew ? createFolder(entry.key, true) : entry.key;
              existing.add(folder);
              for (var i = 0; i < entry.value.length; i++) {
                _insertComic(folder, entry.value[i], order: isNew ? i : null);
              }
            }
          });
        } finally {
          _modifiedAfterLastCache = true;
        }
      }, suppressSync: true, operationName: 'favorites-import');

  /// Merge an archive into this connection; all database writes commit together.
  Future<void> mergeFrom(String sourcePath) => DataMaintenance.run(() {
        final source = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
        Database? sourceDeletions;
        try {
          final tables = source
              .select(
                  "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*';")
              .map((row) => row['name'] as String)
              .toList();
          final hasOrder = tables.remove('folder_order');
          final hasSync = tables.remove('folder_sync');
          final order = <String, int>{};
          if (hasOrder) {
            for (final row in source.select('select * from folder_order;')) {
              order[row['folder_name']] = row['order_value'];
            }
          }
          tables.sort((a, b) => (order[a] ?? 0).compareTo(order[b] ?? 0));
          final folders = <String, List<(FavoriteItem, int?)>>{};
          for (final table in tables) {
            folders[table] = source
                .select('select * from ${_identifier(table)};')
                .map((row) => (
                      FavoriteItem.fromRow(row),
                      row.keys.contains('display_order')
                          ? row['display_order'] as int?
                          : null
                    ))
                .toList();
          }
          final syncRows =
              hasSync ? source.select('select * from folder_sync;') : null;
          final deletionPath = '$sourcePath.deletions';
          sourceDeletions = File(deletionPath).existsSync()
              ? sqlite3.open(deletionPath, mode: OpenMode.readOnly)
              : null;
          _transaction(() {
            if (sourceDeletions != null) {
              for (final row
                  in sourceDeletions.select('select * from deleted_items;')) {
                _mergeDeletion(
                  row['folder_name'] as String,
                  row['target'] as String,
                  row['type'] as int,
                  row['deleted_at'] as String,
                );
              }
            }
            final existingFolders = folderNames.toSet();
            for (final folder in folders.keys) {
              final entries = folders[folder]!;
              if (!existingFolders.contains(folder) &&
                  entries.isNotEmpty &&
                  !entries.any((entry) => _mayMergeComic(folder, entry.$1))) {
                continue;
              }
              final isNewFolder = existingFolders.add(folder);
              if (isNewFolder) createFolder(folder);
              for (final (comic, displayOrder) in entries) {
                _mergeComic(folder, comic,
                    order: isNewFolder ? displayOrder : null);
              }
              if (isNewFolder && order.containsKey(folder)) {
                updateOrder({folder: order[folder]!});
              }
            }
            if (syncRows != null) {
              for (final row in syncRows) {
                _db.execute('''
              insert or ignore into folder_sync(folder_name,time,key,sync_data)
              values(?,?,?,?);
            ''', [
                  row['folder_name'],
                  row['time'],
                  row['key'],
                  row['sync_data']
                ]);
              }
            }
          });
        } finally {
          sourceDeletions?.dispose();
          source.dispose();
          _modifiedAfterLastCache = true;
        }
      }, suppressSync: true, operationName: 'favorites-import');

  List<String> _getTablesWithDB() {
    final tables = _db
        .select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*';")
        .map((element) => element["name"] as String)
        .toList();
    return tables;
  }

  List<String> _getFolderNamesWithDB() {
    final folders = _getTablesWithDB();
    folders.remove('folder_sync');
    folders.remove('folder_order');
    var folderToOrder = <String, int>{};
    for (var folder in folders) {
      var res = _db.select("""
        select * from folder_order
        where folder_name == ?;
      """, [folder]);
      if (res.isNotEmpty) {
        folderToOrder[folder] = res.first["order_value"];
      } else {
        folderToOrder[folder] = 0;
      }
    }
    folders.sort((a, b) {
      return folderToOrder[a]! - folderToOrder[b]!;
    });
    return folders;
  }

  void updateOrder(Map<String, int> order) {
    if (_deferWrite(() => updateOrder(Map.of(order)))) return;
    for (var folder in order.keys) {
      _db.execute("""
        insert or replace into folder_order (folder_name, order_value)
        values (?, ?);
      """, [folder, order[folder]]);
    }
  }

  Future<void> reorderFolders(List<String> folders) {
    final order = Map<String, int>.fromEntries(
        folders.mapIndexed((index, folder) => MapEntry(folder, index)));
    return DataMaintenance.run(() {
      _transaction(() => updateOrder(order));
      updateUI();
    }, operationName: 'favorites-folder-order');
  }

  List<FolderSync> _getFolderSyncWithDB() {
    return _db
        .select("SELECT * FROM folder_sync")
        .map((element) => FolderSync(
            element['folder_name'], element['key'], element['sync_data']))
        .toList();
  }

  void updateFolderSyncTime(FolderSync folderSync) {
    if (_deferWrite(() => updateFolderSyncTime(folderSync))) return;
    _db.execute("""
      update folder_sync
      set time = ?
      where folder_name == ?
    """, [folderSync.time, folderSync.folderName]);
  }

  void insertFolderSync(FolderSync folderSync) {
    if (_deferWrite(() => insertFolderSync(folderSync))) return;
    _db.execute("""
        insert into folder_sync (folder_name, time, key, sync_data)
        values (?, ?, ?, ?);
      """, [
      folderSync.folderName,
      folderSync.time,
      folderSync.key,
      folderSync.syncData
    ]);
  }

  int count(String folderName) {
    return _db.select("""
      select count(*) as c
      from ${_identifier(folderName)}
    """).first["c"];
  }

  List<String> get folderNames => _getFolderNamesWithDB();

  List<FolderSync> get folderSync => _getFolderSyncWithDB();

  int maxValue(String folder) {
    return _db.select("""
        SELECT MAX(display_order) AS max_value
        FROM ${_identifier(folder)};
      """).firstOrNull?["max_value"] ?? 0;
  }

  int minValue(String folder) {
    return _db.select("""
        SELECT MIN(display_order) AS min_value
        FROM ${_identifier(folder)};
      """).firstOrNull?["min_value"] ?? 0;
  }

  List<FavoriteItem> getAllComics(String folder) {
    var rows = _db.select("""
        select * from ${_identifier(folder)}
        ORDER BY display_order, target, type;
      """);
    return rows.map((element) => FavoriteItem.fromRow(element)).toList();
  }

  Future<void> addTagTo(String folder, String target, String tag,
      [FavoriteType? type]) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(
          () => addTagTo(folder, target, tag, type));
    }
    final keys = type?._compatibleKeys;
    _db.execute('''
      update ${_identifier(folder)}
      set tags = ? || ',' || tags
      where target == ? ${keys == null ? '' : 'and type IN (${_placeholders(keys.length)})'};
    ''', [tag, target, if (keys != null) ...keys]);
    await saveData();
  }

  List<FavoriteItemWithFolderInfo> allComics() {
    var res = <FavoriteItemWithFolderInfo>[];
    for (final folder in folderNames) {
      var comics = _db.select("""
        select * from ${_identifier(folder)};
      """);
      res.addAll(comics.map((element) =>
          FavoriteItemWithFolderInfo(FavoriteItem.fromRow(element), folder)));
    }
    return res;
  }

  /// create a folder
  String createFolder(String name, [bool renameWhenInvalidName = false]) {
    name = _availableFolderName(name, renameWhenInvalidName);
    final folderName = name;
    if (_deferWrite(() => createFolder(folderName))) return folderName;
    _createFolderTable(name);
    _modifiedAfterLastCache = true;
    unawaited(saveData());
    return name;
  }

  Future<String> createFolderAndSave(String name,
      {List<FavoriteItem> comics = const [],
      bool renameWhenInvalidName = false}) {
    final items = List<FavoriteItem>.of(comics);
    return DataMaintenance.run(() async {
      late String folderName;
      _transaction(() {
        folderName = _availableFolderName(name, renameWhenInvalidName);
        _createFolderTable(folderName);
        for (var i = 0; i < items.length; i++) {
          _insertComic(folderName, items[i], order: i);
        }
      });
      _modifiedAfterLastCache = true;
      updateUI();
      await saveData();
      return folderName;
    }, operationName: 'favorites-folder-create');
  }

  String _availableFolderName(String name, bool renameWhenInvalidName) {
    bool exists(String candidate) => _db.select('''
          select 1 from sqlite_master
          where type = 'table' and name = ? collate nocase;
        ''', [candidate]).isNotEmpty;
    if (name.isEmpty ||
        name.contains('\u0000') ||
        name.toLowerCase().startsWith('sqlite_') ||
        const ['folder_sync', 'folder_order'].contains(name.toLowerCase())) {
      if (renameWhenInvalidName) {
        int i = 0;
        while (exists(i.toString())) {
          i++;
        }
        name = i.toString();
      } else {
        throw "name is empty!";
      }
    }
    if (exists(name)) {
      if (renameWhenInvalidName) {
        var prevName = name;
        int i = 0;
        while (exists('$prevName$i')) {
          i++;
        }
        name = prevName + i.toString();
      } else {
        throw Exception("Folder is existing");
      }
    }
    return name;
  }

  void _createFolderTable(String name) {
    _db.execute("""
      create table ${_identifier(name)}(
        target text,
        name TEXT,
        author TEXT,
        type int,
        tags TEXT,
        cover_path TEXT,
        time TEXT,
        display_order int,
        primary key (target, type)
      );
    """);
    final indexName =
        _identifier('pica_favorites_${name}_display_order_target_type');
    _db.execute('''
      create index if not exists $indexName
      on ${_identifier(name)}(display_order, target, type);
    ''');
  }

  bool comicExists(String folder, String target, int type) {
    return _matchingRows(folder, target, FavoriteType(type)).isNotEmpty;
  }

  FavoriteItem getComic(String folder, String target, FavoriteType type) {
    final res = _matchingRows(folder, target, type);
    if (res.isEmpty) {
      throw Exception("Comic not found");
    }
    final current = res.firstWhereOrNull((row) => row['type'] == type.key);
    return FavoriteItem.fromRow(current ?? res.first);
  }

  /// add comic to a folder
  ///
  /// This method will download cover to local, to avoid problems like changing url
  Future<void> addComic(String folder, FavoriteItem comic,
      [int? order, bool downloadCover = true]) async {
    final inserted = await DataMaintenance.run(() async {
      if (!_insertComic(folder, comic, order: order)) return false;
      updateUI();
      await saveData();
      return true;
    });
    if (!inserted) return;
    if (downloadCover) await _cacheCover(comic);
  }

  bool _insertComic(String folder, FavoriteItem comic, {int? order}) {
    final deletedAt = _deletedAt(folder, comic.target, comic.type.key);
    if (deletedAt != null) {
      comic.time = _nextSyncTime(deletedAt);
      _removeDeletion(folder, comic.target, comic.type.key);
    }
    return _insertComicRow(folder, comic, order: order);
  }

  bool _mergeComic(String folder, FavoriteItem comic, {int? order}) {
    final deletedAt = _deletedAt(folder, comic.target, comic.type.key);
    if (deletedAt != null) {
      if (!_isTimeAfter(comic.time, deletedAt)) return false;
      _removeDeletion(folder, comic.target, comic.type.key);
    }
    final existing = _matchingRows(folder, comic.target, comic.type)
        .where((row) => row['target'] == comic.target)
        .toList();
    if (existing.isNotEmpty) {
      for (final row in existing) {
        final existingTime = row['time'] as String;
        if (_isTimeAfter(comic.time, existingTime)) {
          _db.execute('''
            update ${_identifier(folder)}
            set name = ?, author = ?, tags = ?, cover_path = ?, time = ?
            where target = ? and type = ?;
          ''', [
            comic.name,
            comic.author,
            comic.tags.join(','),
            comic.coverPath,
            comic.time,
            row['target'],
            row['type']
          ]);
          _modifiedAfterLastCache = true;
        }
      }
      return false;
    }
    return _insertComicRow(folder, comic, order: order);
  }

  bool _mayMergeComic(String folder, FavoriteItem comic) {
    final deletedAt = _deletedAt(folder, comic.target, comic.type.key);
    return deletedAt == null || _isTimeAfter(comic.time, deletedAt);
  }

  bool _insertComicRow(String folder, FavoriteItem comic, {int? order}) {
    if (!folderNames.contains(folder)) {
      throw Exception("Folder does not exists");
    }
    if (comicExists(folder, comic.target, comic.type.key)) return false;
    order ??= appdata.settings[53] == '0'
        ? maxValue(folder) + 1
        : minValue(folder) - 1;
    _db.execute('''
      insert into ${_identifier(folder)}
        (target, name, author, type, tags, cover_path, time, display_order)
      values (?, ?, ?, ?, ?, ?, ?, ?);
    ''', [
      comic.target,
      comic.name,
      comic.author,
      comic.type.key,
      comic.tags.join(','),
      comic.coverPath,
      comic.time,
      order
    ]);
    _modifiedAfterLastCache = true;
    return true;
  }

  int _canonicalType(int type) => FavoriteType(type)._canonicalBuiltInKey;

  String? _deletedAt(String folder, String target, int type) {
    final rows = _db.select('''
      select target, deleted_at from deletions.deleted_items
      where folder_name = ? and type = ?;
    ''', [folder, _canonicalType(type)]);
    final favoriteType = FavoriteType(type);
    final matching = rows
        .where((row) => _favoriteTargetsMatch(
            favoriteType, row['target'] as String, target))
        .map((row) => row['deleted_at'] as String)
        .toList();
    if (matching.isEmpty) return null;
    return matching
        .reduce((left, right) => _isTimeAfter(left, right) ? left : right);
  }

  void _removeDeletion(String folder, String target, int type) {
    final favoriteType = FavoriteType(type);
    final targets = _db
        .select('''
          select target from deletions.deleted_items
          where folder_name = ? and type = ?;
        ''', [folder, _canonicalType(type)])
        .map((row) => row['target'] as String)
        .where((deletedTarget) =>
            _favoriteTargetsMatch(favoriteType, deletedTarget, target))
        .toList();
    for (final deletedTarget in targets) {
      _db.execute('''
        delete from deletions.deleted_items
        where folder_name = ? and target = ? and type = ?;
      ''', [folder, deletedTarget, _canonicalType(type)]);
    }
  }

  String _nextSyncTime([String? after]) {
    var time = DateTime.now();
    final previous = after == null ? null : DateTime.tryParse(after);
    if (previous != null && !time.isAfter(previous)) {
      time = previous.add(const Duration(milliseconds: 1));
    }
    return time.toIso8601String().replaceFirst('T', ' ');
  }

  bool _isTimeAfter(String itemTime, String eventTime) {
    final item = DateTime.tryParse(itemTime);
    final event = DateTime.tryParse(eventTime);
    return item != null && event != null && item.isAfter(event);
  }

  void _recordDeletion(
      String folder, String target, int type, String deletedAt) {
    final current = _deletedAt(folder, target, type);
    final effective = current != null && _isTimeAfter(current, deletedAt)
        ? current
        : deletedAt;
    _db.execute('''
      insert into deletions.deleted_items(folder_name, target, type, deleted_at)
      values(?,?,?,?)
      on conflict(folder_name, target, type) do update set deleted_at = excluded.deleted_at;
    ''', [folder, target, _canonicalType(type), effective]);
  }

  void _mergeDeletion(
      String folder, String target, int type, String deletedAt) {
    final existing = _deletedAt(folder, target, type);
    final effective = existing != null && _isTimeAfter(existing, deletedAt)
        ? existing
        : deletedAt;
    var hasNewerFavorite = false;
    if (folderNames.contains(folder)) {
      for (final row in _matchingRows(folder, target, FavoriteType(type))) {
        final rowTime = row['time'] as String;
        if (_isTimeAfter(rowTime, effective)) {
          hasNewerFavorite = true;
        } else {
          _db.execute('''
            delete from ${_identifier(folder)}
            where target = ? and type = ?;
          ''', [row['target'], row['type']]);
        }
      }
    }
    if (hasNewerFavorite) {
      _removeDeletion(folder, target, type);
    } else {
      _recordDeletion(folder, target, type, effective);
    }
  }

  Future<void> _cacheCover(FavoriteItem comic) async {
    try {
      var file =
          (await (ImageManager().getImage(comic.coverPath)).last).getFile();
      var path =
          "${(await getApplicationSupportDirectory()).path}${pathSep}favoritesCover";
      var directory = Directory(path);
      if (!directory.existsSync()) {
        directory.createSync();
      }
      var hash =
          md5.convert(const Utf8Encoder().convert(comic.coverPath)).toString();
      file.copySync("$path$pathSep$hash.jpg");
    } catch (e) {
      //忽略
    }
  }

  /// get comic cover
  Future<File> getCover(FavoriteItem item) async {
    var path = "${App.dataPath}/favoritesCover";
    var hash =
        md5.convert(const Utf8Encoder().convert(item.coverPath)).toString();
    var file = File("$path/$hash.jpg");
    if (file.existsSync()) {
      return file;
    }
    if (item.coverPath.startsWith("file://")) {
      var data = DownloadManager()
          .getCover(item.coverPath.replaceFirst("file://", ""));
      file.createSync(recursive: true);
      file.writeAsBytesSync(data.readAsBytesSync());
      return file;
    }
    try {
      if (EhNetwork().cookiesStr == "") {
        await EhNetwork().getCookies(false);
      }
      var res = await (ImageManager().getImage(item.coverPath, {
        if (item.type == FavoriteType.ehentai) "cookie": EhNetwork().cookiesStr,
        if (item.type == FavoriteType.hitomi) "Referer": "https://hitomi.la/"
      }).last);
      file.createSync(recursive: true);
      file.writeAsBytesSync(res.getFile().readAsBytesSync());
      return file;
    } catch (e) {
      await Future.delayed(const Duration(seconds: 5));
      rethrow;
    }
  }

  /// Delete a folder and publish the local change before completing.
  Future<void> deleteFolder(String name) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(() => deleteFolder(name));
    }
    if (!folderNames.contains(name)) {
      throw StateError('Folder does not exist: $name');
    }
    _transaction(() {
      final deletedAt = _nextSyncTime();
      for (final row
          in _db.select('select target, type from ${_identifier(name)};')) {
        _recordDeletion(
            name, row['target'] as String, row['type'] as int, deletedAt);
      }
      _db.execute("""
      delete from folder_sync where folder_name == ?;
    """, [name]);
      _db.execute("""
      delete from folder_order where folder_name == ?;
    """, [name]);
      _db.execute("""
      drop table ${_identifier(name)};
    """);
    });
    _modifiedAfterLastCache = true;
    await saveData();
  }

  Future<void> checkAndDeleteCover(FavoriteItem item) async {
    // Cache files are shared by cover URL, even across different comics.
    for (final folder in folderNames) {
      if (_db.select('''
        select 1 from ${_identifier(folder)} where cover_path == ? limit 1;
      ''', [item.coverPath]).isNotEmpty) {
        return;
      }
    }
    try {
      final hash = md5.convert(utf8.encode(item.coverPath)).toString();
      final file = File('${App.dataPath}/favoritesCover/$hash.jpg');
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException catch (error, stack) {
      LogManager.addLog(
          LogLevel.warning,
          'LocalFavoritesManager',
          'Failed to remove unused favorite cover; retaining the cache file.\n'
              '${safeNetworkError(error)}\n$stack');
    }
  }

  Future<void> deleteComic(String folder, FavoriteItem comic) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(() => deleteComic(folder, comic));
    }
    _modifiedAfterLastCache = true;
    _transaction(
        () => _deleteComicWithTarget(folder, comic.target, comic.type));
    await checkAndDeleteCover(comic);
    await saveData();
  }

  Future<void> deleteComicWithTarget(
      String folder, String target, FavoriteType type) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(
          () => deleteComicWithTarget(folder, target, type));
    }
    _modifiedAfterLastCache = true;
    _transaction(() => _deleteComicWithTarget(folder, target, type));
    await saveData();
  }

  void _deleteComicWithTarget(String folder, String target, FavoriteType type) {
    final deletedAt = _nextSyncTime();
    for (final row in _matchingRows(folder, target, type)) {
      _recordDeletion(
          folder, row['target'] as String, row['type'] as int, deletedAt);
      _db.execute("""
        delete from ${_identifier(folder)}
        where target == ? and type == ?;
      """, [row['target'], row['type']]);
    }
  }

  List<Row> _matchingRows(String folder, String target, FavoriteType type) {
    final keys = type._compatibleKeys;
    final rows = type._compatibleKeys.contains(FavoriteType.hitomi.key)
        ? _db.select('''
          select * from ${_identifier(folder)}
          where type IN (${_placeholders(keys.length)});
        ''', keys)
        : _db.select('''
          select * from ${_identifier(folder)}
          where target == ? and type IN (${_placeholders(keys.length)});
        ''', [target, ...keys]);
    if (!type._compatibleKeys.contains(FavoriteType.hitomi.key)) return rows;
    return rows
        .where((row) =>
            _favoriteTargetsMatch(type, row['target'] as String, target))
        .toList();
  }

  Future<void> clearAll() => DataMaintenance.run(() async {
        _transaction(() {
          for (final folder in folderNames) {
            final deletedAt = _nextSyncTime();
            for (final row in _db
                .select('select target, type from ${_identifier(folder)};')) {
              _recordDeletion(folder, row['target'] as String,
                  row['type'] as int, deletedAt);
            }
            _db.execute('DROP TABLE ${_identifier(folder)};');
          }
          _db.execute('delete from folder_sync; delete from folder_order;');
        });
        _modifiedAfterLastCache = true;
        await saveData();
      });

  Future<void> reorder(List<FavoriteItem> newFolder, String folder) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(
          () => reorder(List.of(newFolder), folder));
    }
    if (!folderNames.contains(folder)) {
      throw Exception("Failed to reorder: folder not found");
    }
    _transaction(() {
      for (int i = 0; i < newFolder.length; i++) {
        for (final row
            in _matchingRows(folder, newFolder[i].target, newFolder[i].type)) {
          _db.execute('''
            update ${_identifier(folder)} set display_order = ?
            where target = ? and type = ?;
          ''', [i, row['target'], row['type']]);
        }
      }
    });
    updateUI();
    await saveData();
  }

  Future<void> rename(String before, String after) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(() => rename(before, after));
    }
    if (folderNames.contains(after)) {
      throw "Name already exists!";
    }
    if (after.isEmpty ||
        after.contains('\u0000') ||
        after.toLowerCase().startsWith('sqlite_') ||
        const ['folder_sync', 'folder_order'].contains(after.toLowerCase())) {
      throw "Invalid name";
    }
    _transaction(() {
      _db.execute("""
      ALTER TABLE ${_identifier(before)}
      RENAME TO ${_identifier(after)};
    """);
      if (folderSync.isNotEmpty) {
        _db.execute("""
      UPDATE folder_sync
      set folder_name = ?
      where folder_name == ?
    """, [after, before]);
      }
      _db.execute(
          'update folder_order set folder_name = ? where folder_name = ?;',
          [after, before]);
      _db.execute('''
        update deletions.deleted_items set folder_name = ?
        where folder_name = ?;
      ''', [after, before]);
    });
    await saveData();
  }

  Future<void> onReadEnd(String target, FavoriteType type) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(() => onReadEnd(target, type));
    }
    _modifiedAfterLastCache = true;
    bool isModified = false;
    _transaction(() {
      for (final folder in folderNames) {
        final rows = _matchingRows(folder, target, type);
        if (rows.isNotEmpty) {
          isModified = true;
          var newTime = _nextSyncTime();
          int? order;
          if (appdata.settings[54] == "1") {
            int maxValue = _db.select("""
              SELECT MAX(display_order) AS max_value
              FROM ${_identifier(folder)};
            """).firstOrNull?["max_value"] ?? 0;
            order = maxValue + 1;
          } else if (appdata.settings[54] == "2") {
            int minValue = _db.select("""
              SELECT MIN(display_order) AS min_value
              FROM ${_identifier(folder)};
            """).firstOrNull?["min_value"] ?? 0;
            order = minValue - 1;
          }
          for (final row in rows) {
            _db.execute("""
              UPDATE ${_identifier(folder)}
              SET ${order == null ? '' : 'display_order = ?,'} time = ?
              WHERE target == ? and type == ?;
            """, [
              if (order != null) order,
              newTime,
              row['target'],
              row['type']
            ]);
          }
        }
      }
    });
    if (isModified) {
      updateUI();
    }
    await saveData();
  }

  String folderToJsonString(String folderName) {
    var data = <String, dynamic>{};
    data["info"] = "Generated by PicaComic.";
    data["website"] = "https://github.com/liyw0205/PicaComic";
    data["name"] = folderName;
    var comics = _db
        .select('select * from ${_identifier(folderName)};')
        .map((element) => FavoriteItem.fromRow(element).toJson())
        .toList();
    data["comics"] = comics;
    return const JsonEncoder().convert(data);
  }

  Future<(bool, String)> loadFolderData(String dataString) async {
    if (DataMaintenance.busy) {
      return (true, 'Data maintenance in progress');
    }
    try {
      var data =
          const JsonDecoder().convert(dataString) as Map<String, dynamic>;
      final name_ = data["name"] as String;
      var name = name_;
      int i = 0;
      while (folderNames.contains(name)) {
        name = name_ + i.toString();
        i++;
      }
      final comics = (data['comics'] as List)
          .map((json) =>
              FavoriteItem.fromJson(Map<String, dynamic>.from(json as Map)))
          .toList();
      _transaction(() {
        createFolder(name);
        for (var i = 0; i < comics.length; i++) {
          _insertComic(name, comics[i], order: i);
        }
      });
      updateUI();
      await saveData();
      return (false, "");
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "IO",
          "Failed to load data.\n${safeNetworkError(e)}\n$s");
      return (true, e.toString());
    }
  }

  List<FavoriteItemWithFolderInfo> search(String keyword, {int limit = 200}) {
    if (limit <= 0) return [];
    final keywords = keyword
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    final condition = keywords
        .map((_) =>
            '(instr(pica_lower(name), ?) > 0 or instr(pica_lower(author), ?) > 0 or instr(pica_lower(tags), ?) > 0)')
        .join(' and ');
    final parameters = <Object?>[
      for (final word in keywords) ...[word, word, word],
    ];
    final comics = <FavoriteItemWithFolderInfo>[];
    for (var table in folderNames) {
      var res = _db.select("""
        SELECT * FROM ${_identifier(table)}
        ${condition.isEmpty ? '' : 'WHERE $condition'}
        ORDER BY display_order, target, type LIMIT ?;
      """, [...parameters, limit - comics.length]);
      for (var comic in res) {
        comics.add(
            FavoriteItemWithFolderInfo(FavoriteItem.fromRow(comic), table));
      }
      if (comics.length >= limit) {
        break;
      }
    }
    return comics;
  }

  Future<void> editTags(String target, String folder, List<String> tags,
      [FavoriteType? type]) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(
          () => editTags(target, folder, List.of(tags), type));
    }
    final keys = type?._compatibleKeys;
    _db.execute('''
        update ${_identifier(folder)}
        set tags = ?
        where target == ? ${keys == null ? '' : 'and type IN (${_placeholders(keys.length)})'};
      ''', [tags.join(','), target, if (keys != null) ...keys]);
    await saveData();
  }

  final _cachedFavoritedTargets = <String, bool>{};

  bool isExist(String target) {
    if (_modifiedAfterLastCache) {
      _cacheFavoritedTargets();
    }
    return _cachedFavoritedTargets.containsKey(target);
  }

  bool _modifiedAfterLastCache = true;

  void _cacheFavoritedTargets() {
    _modifiedAfterLastCache = false;
    _cachedFavoritedTargets.clear();
    for (var folder in folderNames) {
      final res = _db.select("""
        select target, type from ${_identifier(folder)};
      """);
      for (var row in res) {
        _cachedFavoritedTargets[row["target"]] = true;
        if (FavoriteType.hitomi._compatibleKeys.contains(row['type'])) {
          final canonical = canonicalHitomiTarget(row['target'] as String);
          _cachedFavoritedTargets[canonical] = true;
        }
      }
    }
  }

  void updateInfo(String folder, FavoriteItem comic) {
    if (_deferWrite(() => updateInfo(folder, comic))) return;
    final keys = comic.type._compatibleKeys;
    _db.execute("""
      update ${_identifier(folder)}
      set name = ?, author = ?, cover_path = ?, tags = ?
      where target == ? and type IN (${_placeholders(keys.length)});
    """, [
      comic.name,
      comic.author,
      comic.coverPath,
      comic.tags.join(","),
      comic.target,
      ...keys,
    ]);
  }
}

String _placeholders(int count) => List.filled(count, '?').join(', ');

bool _favoriteTargetsMatch(FavoriteType type, String left, String right) {
  if (!type._compatibleKeys.contains(FavoriteType.hitomi.key)) {
    return left == right;
  }
  final leftId = hitomiGalleryIdFromTarget(left);
  final rightId = hitomiGalleryIdFromTarget(right);
  return leftId != null && rightId != null ? leftId == rightId : left == right;
}
