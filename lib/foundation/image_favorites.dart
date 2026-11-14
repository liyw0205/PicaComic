part of "history.dart";

// 直接用history.db了, 没必要再加一个favorites.db

class ImageFavorite {
  /// unique id for the comic
  final String id;

  final String imagePath;

  final String title;

  final int ep;

  final int page;

  final Map<String, dynamic> otherInfo;

  const ImageFavorite(
      this.id, this.imagePath, this.title, this.ep, this.page, this.otherInfo);

  String get key => '$id\u0000$ep\u0000$page';
}

/// A bounded image-favorite query and its keyset continuation cursor.
///
/// The cursor is the rowid of the last returned row. Unlike OFFSET, it does
/// not shift when a favorite is deleted while the user is scrolling.
class ImageFavoritePage {
  final List<ImageFavorite> items;
  final int? nextCursor;

  const ImageFavoritePage(this.items, this.nextCursor);

  bool get hasMore => nextCursor != null;
}

class ImageFavoriteManager {
  static Database get _db => HistoryManager()._db;
  static bool _uiRefreshQueued = false;
  static bool _refreshMePagePending = false;
  static bool _refreshImagePagePending = false;

  static void _scheduleUiRefresh(
      {bool mePage = false, bool imagePage = false}) {
    _refreshMePagePending = _refreshMePagePending || mePage;
    _refreshImagePagePending = _refreshImagePagePending || imagePage;
    if (_uiRefreshQueued) return;
    _uiRefreshQueued = true;
    // Let all writes in the current maintenance turn finish before notifying
    // pages. A timer event coalesces awaits inside one batch, while still
    // updating the UI promptly after the batch completes.
    Future<void>.delayed(Duration.zero).then((_) {
      _uiRefreshQueued = false;
      final refreshMePage = _refreshMePagePending;
      final refreshImagePage = _refreshImagePagePending;
      _refreshMePagePending = false;
      _refreshImagePagePending = false;
      if (refreshMePage) {
        StateController.findOrNull(tag: "me_page")?.update();
      }
      if (refreshImagePage) {
        StateController.findOrNull(tag: "image_favorites_page")?.refresh();
      }
    });
  }

  /// 检查表image_favorites是否存在, 不存在则创建
  static void init() {
    _init(_db);
  }

  static void _init(Database db) {
    db.execute("CREATE TABLE IF NOT EXISTS image_favorites ("
        "id TEXT,"
        "title TEXT NOT NULL,"
        "cover TEXT NOT NULL,"
        "ep INTEGER NOT NULL,"
        "page INTEGER NOT NULL,"
        "other TEXT NOT NULL,"
        "PRIMARY KEY (id, ep, page)"
        ");");
    // Keep title searches bounded by a cheap indexed prefix/order lookup. The
    // contains-style filter below still preserves the old search semantics.
    db.execute("""
      create index if not exists image_favorites_title
      on image_favorites(title collate nocase);
    """);
  }

  static Future<void> add(ImageFavorite favorite) {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(() => add(favorite));
    }
    return _add(favorite);
  }

  static Future<void> _add(ImageFavorite favorite) async {
    _db.execute("""
      insert into image_favorites(id, title, cover, ep, page, other)
      values(?, ?, ?, ?, ?, ?);
    """, [
      favorite.id,
      favorite.title,
      favorite.imagePath,
      favorite.ep,
      favorite.page,
      jsonEncode(favorite.otherInfo)
    ]);
    DataMaintenance.recordSyncRequest();
    if (!DataMaintenance.syncSuppressed) await Webdav.uploadData();
    _scheduleUiRefresh(mePage: true, imagePage: true);
  }

  static List<ImageFavorite> getAll() {
    var res = _db.select("""
      select * from image_favorites
      order by rowid desc;
    """);
    return res.map(_fromRow).toList();
  }

  /// Read one bounded page using a stable keyset cursor.
  static ImageFavoritePage getPage({
    int limit = 60,
    int? afterRowId,
    String keyword = '',
  }) {
    if (limit <= 0) return const ImageFavoritePage([], null);
    final conditions = <String>[];
    final parameters = <Object?>[];
    final normalizedKeyword = keyword.trim().toLowerCase();
    if (normalizedKeyword.isNotEmpty) {
      conditions.add('instr(lower(title), ?) > 0');
      parameters.add(normalizedKeyword);
    }
    if (afterRowId != null) {
      conditions.add('rowid < ?');
      parameters.add(afterRowId);
    }
    parameters.add(limit + 1);
    final rows = _db.select('''
      select rowid as image_favorite_rowid, *
      from image_favorites
      ${conditions.isEmpty ? '' : 'where ${conditions.join(' and ')}'}
      order by rowid desc
      limit ?;
    ''', parameters);
    final hasMore = rows.length > limit;
    final visible = rows.take(limit).toList();
    return ImageFavoritePage(
      visible.map(_fromRow).toList(growable: false),
      hasMore && visible.isNotEmpty
          ? visible.last['image_favorite_rowid'] as int
          : null,
    );
  }

  /// Count all favorites, or only favorites matching a title search.
  static int count({String keyword = ''}) {
    final normalizedKeyword = keyword.trim().toLowerCase();
    final rows = normalizedKeyword.isEmpty
        ? _db.select('select count(*) as count from image_favorites;')
        : _db.select('''
            select count(*) as count from image_favorites
            where instr(lower(title), ?) > 0;
          ''', [normalizedKeyword]);
    return rows.single['count'] as int;
  }

  static ImageFavorite _fromRow(Row row) => ImageFavorite(
        row["id"],
        row["cover"],
        row["title"],
        row["ep"],
        row["page"],
        jsonDecode(row["other"]),
      );

  static bool _exists(ImageFavorite favorite) {
    final res = _db.select('''
      select 1 from image_favorites
      where id = ? and ep = ? and page = ?;
    ''', [favorite.id, favorite.ep, favorite.page]);
    return res.isNotEmpty;
  }

  /// Returns keys that still exist using bounded, parameterized batches.
  ///
  /// The image-favorites page keeps already loaded rows so a refresh can
  /// reconcile external deletes. Querying [_exists] once per row makes that
  /// refresh increasingly expensive; batching keeps it to a small number of
  /// round trips without constructing an unbounded SQL parameter list.
  static Set<String> existingKeys(Iterable<ImageFavorite> favorites) {
    final items = favorites.toList(growable: false);
    if (items.isEmpty) return <String>{};

    final result = <String>{};
    const batchSize = 250;
    for (var offset = 0; offset < items.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, items.length);
      final batch = items.sublist(offset, end);
      final predicates =
          List.filled(batch.length, '(id = ? and ep = ? and page = ?)');
      final parameters = <Object?>[];
      for (final favorite in batch) {
        parameters
          ..add(favorite.id)
          ..add(favorite.ep)
          ..add(favorite.page);
      }
      final rows = _db.select('''
        select id, ep, page
        from image_favorites
        where ${predicates.join(' or ')};
      ''', parameters);
      result.addAll(rows
          .map((row) => '${row['id']}\u0000${row['ep']}\u0000${row['page']}'));
    }
    return result;
  }

  static Future<void> delete(ImageFavorite favorite) {
    if (DataMaintenance.busy) {
      return DataMaintenance.run<void>(() => delete(favorite));
    }
    return _delete(favorite);
  }

  static Future<void> _delete(ImageFavorite favorite) async {
    _db.execute("""
      delete from image_favorites
      where id = ? and ep = ? and page = ?;
    """, [favorite.id, favorite.ep, favorite.page]);
    DataMaintenance.recordSyncRequest();
    if (!DataMaintenance.syncSuppressed) await Webdav.uploadData();
    _scheduleUiRefresh(imagePage: true);
  }

  static bool exist(String id, int ep, int page) {
    return _exists(ImageFavorite(id, '', '', ep, page, const {}));
  }

  static int get length {
    return count();
  }
}
