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

  static FavoriteType get picacg => const FavoriteType(0);

  static FavoriteType get ehentai => const FavoriteType(1);

  static FavoriteType get jm => const FavoriteType(2);

  static FavoriteType get hitomi => const FavoriteType(3);

  static FavoriteType get htManga => const FavoriteType(4);

  static FavoriteType get nhentai => const FavoriteType(6);

  ComicType get comicType {
    if (key >= 0 && key <= 6) {
      return ComicType.values[key];
    }
    return ComicType.other;
  }

  ComicSource get comicSource {
    if (key <= 6) {
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
    return other is FavoriteType && other.key == key;
  }

  @override
  int get hashCode => key.hashCode;
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
    if (type.key <= 6 && type.key >= 0) {
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
        ComicType.hitomi => RegExp(r"\d+(?=\.html)").hasMatch(target)
            ? "hitomi${RegExp(r"\d+(?=\.html)").firstMatch(target)?[0]}"
            : target,
        ComicType.htManga => "ht$target",
        ComicType.nhentai => "nhentai$target",
        _ => DownloadManager().generateId(type.comicSource.key, target)
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
        target = comic.link,
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
        tags = (row["tags"] as String).split(","),
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
        other.target == target &&
        other.type == type;
  }

  @override
  int get hashCode => target.hashCode ^ type.hashCode;

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
    _db = sqlite3.open(databasePath ?? "${App.dataPath}/local_favorite.db");
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
      var rows = _db.select("""
        select * from ${_identifier(folder)}
        where target == ? and type == ?;
      """, [target, type.key]);
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  Future<List<String>> findWithModel(FavoriteItem item) async {
    var res = <String>[];
    for (var folder in folderNames) {
      var rows = _db.select("""
        select * from ${_identifier(folder)}
        where target == ? and type == ?;
      """, [item.target, item.type.key]);
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
          await mergeLegacyJson(file.path);
          _deleteImportedSource(file);
        } else if ((file = File("${App.dataPath}/local_favorite_temp.db"))
            .existsSync()) {
          await mergeFrom(file.path);
          _deleteImportedSource(file);
        } else {
          LogManager.addLog(LogLevel.info, "LocalFavoritesManager",
              "no local favorites db file found");
        }
      }, suppressSync: true);

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
          _transaction(() {
            final existingFolders = folderNames.toSet();
            for (final folder in folders.keys) {
              final isNewFolder = existingFolders.add(folder);
              if (isNewFolder) createFolder(folder);
              for (final (comic, displayOrder) in folders[folder]!) {
                _insertComic(folder, comic,
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

  void addTagTo(String folder, String target, String tag,
      [FavoriteType? type]) {
    if (_deferWrite(() => addTagTo(folder, target, tag, type))) return;
    _db.execute("""
      update ${_identifier(folder)}
      set tags = ? || ',' || tags
      where target == ? ${type == null ? '' : 'and type == ?'};
    """, [tag, target, if (type != null) type.key]);
    saveData();
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
    if (name.isEmpty ||
        name.contains('\u0000') ||
        name.toLowerCase().startsWith('sqlite_') ||
        const ['folder_sync', 'folder_order'].contains(name.toLowerCase())) {
      if (renameWhenInvalidName) {
        int i = 0;
        while (folderNames.contains(i.toString())) {
          i++;
        }
        name = i.toString();
      } else {
        throw "name is empty!";
      }
    }
    if (folderNames.contains(name)) {
      if (renameWhenInvalidName) {
        var prevName = name;
        int i = 0;
        while (folderNames.contains(i.toString())) {
          i++;
        }
        name = prevName + i.toString();
      } else {
        throw Exception("Folder is existing");
      }
    }
    final folderName = name;
    if (_deferWrite(() => createFolder(folderName))) return folderName;
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
    _modifiedAfterLastCache = true;
    saveData();
    return name;
  }

  bool comicExists(String folder, String target, int type) {
    var res = _db.select("""
      select 1 from ${_identifier(folder)}
      where target == ? and type == ?;
    """, [target, type]);
    return res.isNotEmpty;
  }

  FavoriteItem getComic(String folder, String target, FavoriteType type) {
    var res = _db.select("""
      select * from ${_identifier(folder)}
      where target == ? and type == ?;
    """, [target, type.key]);
    if (res.isEmpty) {
      throw Exception("Comic not found");
    }
    return FavoriteItem.fromRow(res.first);
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
    _modifiedAfterLastCache = true;
    _db.execute("""
      delete from folder_sync where folder_name == ?;
    """, [name]);
    _db.execute("""
      delete from folder_order where folder_name == ?;
    """, [name]);
    _db.execute("""
      drop table ${_identifier(name)};
    """);
    await saveData();
  }

  Future<void> checkAndDeleteCover(FavoriteItem item) async {
    if ((await find(item.target, item.type)).isEmpty) {
      final hash = md5.convert(utf8.encode(item.coverPath)).toString();
      final file = File('${App.dataPath}/favoritesCover/$hash.jpg');
      if (file.existsSync()) file.deleteSync();
    }
  }

  Future<void> deleteComic(String folder, FavoriteItem comic) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(() => deleteComic(folder, comic));
    }
    _modifiedAfterLastCache = true;
    _deleteComicWithTarget(folder, comic.target, comic.type);
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
    _deleteComicWithTarget(folder, target, type);
    await saveData();
  }

  void _deleteComicWithTarget(String folder, String target, FavoriteType type) {
    _db.execute("""
      delete from ${_identifier(folder)}
      where target == ? and type == ?;
    """, [target, type.key]);
  }

  Future<void> clearAll() => DataMaintenance.run(() async {
        _transaction(() {
          for (final folder in folderNames) {
            _db.execute('DROP TABLE ${_identifier(folder)};');
          }
          _db.execute('delete from folder_sync; delete from folder_order;');
        });
        _modifiedAfterLastCache = true;
        await saveData();
      });

  void reorder(List<FavoriteItem> newFolder, String folder) {
    if (_deferWrite(() => reorder(List.of(newFolder), folder))) return;
    if (!folderNames.contains(folder)) {
      throw Exception("Failed to reorder: folder not found");
    }
    _transaction(() {
      for (int i = 0; i < newFolder.length; i++) {
        _db.execute('''
          update ${_identifier(folder)} set display_order = ?
          where target = ? and type = ?;
        ''', [i, newFolder[i].target, newFolder[i].type.key]);
      }
    });
    updateUI();
    saveData();
  }

  void rename(String before, String after) {
    if (_deferWrite(() => rename(before, after))) return;
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
    });
    saveData();
  }

  Future<void> onReadEnd(String target, FavoriteType type) async {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(() => onReadEnd(target, type));
    }
    _modifiedAfterLastCache = true;
    bool isModified = false;
    for (final folder in folderNames) {
      var rows = _db.select("""
        select * from ${_identifier(folder)}
        where target == ? and type == ?;
      """, [target, type.key]);
      if (rows.isNotEmpty) {
        isModified = true;
        var newTime = DateTime.now()
            .toIso8601String()
            .replaceFirst("T", " ")
            .substring(0, 19);
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
        _db.execute("""
            UPDATE ${_identifier(folder)}
            SET ${order == null ? '' : 'display_order = ?,'} time = ?
            WHERE target == ? and type == ?;
          """, [if (order != null) order, newTime, target, type.key]);
      }
    }
    if (isModified) {
      updateUI();
    }
    await saveData();
  }

  String folderToJsonString(String folderName) {
    var data = <String, dynamic>{};
    data["info"] = "Generated by PicaComic.";
    data["website"] = "https://github.com/Pacalini/PicaComic";
    data["name"] = folderName;
    var comics = _db
        .select('select * from ${_identifier(folderName)};')
        .map((element) => FavoriteItem.fromRow(element).toJson())
        .toList();
    data["comics"] = comics;
    return const JsonEncoder().convert(data);
  }

  (bool, String) loadFolderData(String dataString) {
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
      saveData();
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
    _db.execute("""
        update ${_identifier(folder)}
        set tags = ?
        where target == ? ${type == null ? '' : 'and type == ?'};
      """, [tags.join(','), target, if (type != null) type.key]);
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
      var res = _db.select("""
        select target from ${_identifier(folder)};
      """);
      for (var row in res) {
        _cachedFavoritedTargets[row["target"]] = true;
      }
    }
  }

  void updateInfo(String folder, FavoriteItem comic) {
    if (_deferWrite(() => updateInfo(folder, comic))) return;
    _db.execute("""
      update ${_identifier(folder)}
      set name = ?, author = ?, cover_path = ?, tags = ?
      where target == ? and type == ?;
    """, [
      comic.name,
      comic.author,
      comic.coverPath,
      comic.tags.join(","),
      comic.target,
      comic.type.key
    ]);
  }
}
