import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

const backupManifestName = 'backup-manifest.json';

Future<String> fileDigest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

void checkBackupDatabase(String path, String table) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    if (db.select('PRAGMA quick_check').single.values.single != 'ok' ||
        db.select('SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
            ['table', table]).isEmpty) {
      throw const FormatException('Invalid backup database');
    }
  } finally {
    db.dispose();
  }
}

/// Uses SQLite itself rather than copying a file which may have a live WAL.
void snapshotDatabase(String source, String destination) {
  final db = sqlite3.open(source, mode: OpenMode.readOnly);
  try {
    db.execute('VACUUM INTO ?', [destination]);
  } finally {
    db.dispose();
  }
}

Future<void> writeBackupManifest(Directory root,
    {Map<String, Object?>? revision}) async {
  final files = <String, Object>{};
  final sensitive = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is Link) throw const FormatException('Backup contains a link');
    if (entity is! File || entity.path.endsWith('/$backupManifestName'))
      continue;
    final name =
        entity.path.substring(root.path.length + 1).replaceAll('\\', '/');
    files[name] = {
      'size': await entity.length(),
      'sha256': await fileDigest(entity)
    };
    if (name == 'cookies.db' || name.startsWith('comic_source/')) {
      sensitive.add(name);
    }
  }
  await File('${root.path}/$backupManifestName').writeAsString(
      jsonEncode({
        'formatVersion': 1,
        'files': files,
        if (sensitive.isNotEmpty) 'sensitive': sensitive,
        if (revision != null) 'revision': revision,
      }),
      flush: true);
}

class _ZipEntryInfo {
  _ZipEntryInfo({
    required this.name,
    required this.localOffset,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.crc32,
    required this.compressionMethod,
    required this.flags,
    required this.isDirectory,
  });

  final String name;
  final int localOffset;
  final int compressedSize;
  final int uncompressedSize;
  final int crc32;
  final int compressionMethod;
  final int flags;
  final bool isDirectory;

  int localDataOffset = 0;
}

/// Random-access reader used so central headers can be checked without asking
/// archive's ZipDecoder to read any entry payload.
class _ZipReader {
  _ZipReader(this.input) : length = input.length;

  final InputFileStream input;
  final int length;
  int centralOffset = 0;

  int get position => input.position;

  void seek(int offset) {
    if (offset < 0 || offset > length)
      throw const FormatException('Invalid ZIP offset');
    input.position = offset;
  }

  int u8() {
    if (input.position >= length) throw const FormatException('Truncated ZIP');
    return input.readByte();
  }

  int u16() {
    if (input.position + 2 > length)
      throw const FormatException('Truncated ZIP');
    return input.readUint16();
  }

  int u32() {
    if (input.position + 4 > length)
      throw const FormatException('Truncated ZIP');
    return input.readUint32();
  }

  int u64() {
    if (input.position + 8 > length)
      throw const FormatException('Truncated ZIP');
    final value = input.readUint64();
    if (value < 0) throw const FormatException('Invalid ZIP integer');
    return value;
  }

  Uint8List bytes(int count) {
    if (count < 0 || input.position + count > length) {
      throw const FormatException('Truncated ZIP');
    }
    return input.readBytes(count).toUint8List();
  }
}

String _zipName(List<int> bytes, int flags) {
  if ((flags & 0x800) != 0) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('Invalid UTF-8 ZIP path');
    }
  }
  return String.fromCharCodes(bytes);
}

int _extraUint64(List<int> bytes, int offset) {
  if (offset < 0 || offset + 8 > bytes.length) {
    throw const FormatException('Invalid ZIP64 extra field');
  }
  var value = 0;
  for (var i = 7; i >= 0; i--) {
    value = (value << 8) | bytes[offset + i];
  }
  if (value < 0) throw const FormatException('Invalid ZIP64 integer');
  return value;
}

List<int> _zip64Values(
    List<int> extra, int compressed, int uncompressed, int offset, int disk) {
  var p = 0;
  while (p + 4 <= extra.length) {
    final id = extra[p] | (extra[p + 1] << 8);
    final size = extra[p + 2] | (extra[p + 3] << 8);
    p += 4;
    if (p + size > extra.length)
      throw const FormatException('Invalid ZIP extra field');
    if (id == 1) {
      final data = extra.sublist(p, p + size);
      var q = 0;
      if (uncompressed == 0xffffffff) {
        uncompressed = _extraUint64(data, q);
        q += 8;
      }
      if (compressed == 0xffffffff) {
        compressed = _extraUint64(data, q);
        q += 8;
      }
      if (offset == 0xffffffff) {
        offset = _extraUint64(data, q);
        q += 8;
      }
      if (disk == 0xffff) {
        if (q + 4 > data.length)
          throw const FormatException('Invalid ZIP64 extra field');
        disk = data[q] |
            (data[q + 1] << 8) |
            (data[q + 2] << 16) |
            (data[q + 3] << 24);
      }
    }
    p += size;
  }
  if (p != extra.length) throw const FormatException('Invalid ZIP extra field');
  return [compressed, uncompressed, offset, disk];
}

String _normaliseZipPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/');
  final hasTrailingSlash = parts.isNotEmpty && parts.last.isEmpty;
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized.contains('\u0000') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    throw const FormatException('Unsafe or duplicate backup path');
  }
  if (hasTrailingSlash) parts.removeLast();
  if (parts.isEmpty ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const FormatException('Unsafe or duplicate backup path');
  }
  return parts.join('/');
}

List<_ZipEntryInfo> _readZipHeaders(_ZipReader reader,
    {required int maxFiles,
    required int maxExpandedBytes,
    required int maxFileBytes}) {
  final searchStart = reader.length > 0x10016 ? reader.length - 0x10016 : 0;
  var eocd = -1;
  for (var p = reader.length - 22; p >= searchStart; p--) {
    reader.seek(p);
    if (reader.u32() == 0x06054b50) {
      eocd = p;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('Invalid ZIP archive');
  reader.seek(eocd + 4);
  final disk = reader.u16();
  final centralDisk = reader.u16();
  final countOnDisk = reader.u16();
  final count = reader.u16();
  final centralSize32 = reader.u32();
  final centralOffset32 = reader.u32();
  final commentLength = reader.u16();
  if (eocd + 22 + commentLength > reader.length ||
      disk != 0 ||
      centralDisk != 0 ||
      countOnDisk != count ||
      count == 0xffff ||
      centralSize32 == 0xffffffff ||
      centralOffset32 == 0xffffffff) {
    throw const FormatException('Unsupported ZIP directory');
  }
  if (count > maxFiles ||
      centralOffset32 > reader.length ||
      centralSize32 > reader.length - centralOffset32 ||
      centralOffset32 + centralSize32 > eocd) {
    throw const FormatException('Invalid ZIP directory');
  }
  reader.centralOffset = centralOffset32;

  reader.seek(centralOffset32);
  final entries = <_ZipEntryInfo>[];
  final names = <String, bool>{};
  var total = 0;
  for (var i = 0; i < count; i++) {
    if (reader.u32() != 0x02014b50)
      throw const FormatException('Invalid ZIP central header');
    final versionMadeBy = reader.u16();
    reader.u16(); // version needed
    final flags = reader.u16();
    final method = reader.u16();
    reader.u16();
    reader.u16();
    final crc = reader.u32();
    var compressed = reader.u32();
    var uncompressed = reader.u32();
    final filenameLength = reader.u16();
    final extraLength = reader.u16();
    final fileCommentLength = reader.u16();
    var diskStart = reader.u16();
    reader.u16(); // internal attributes
    final externalAttributes = reader.u32();
    var localOffset = reader.u32();
    final filename = _zipName(reader.bytes(filenameLength), flags);
    final extra = reader.bytes(extraLength);
    reader.bytes(fileCommentLength);
    final zip64 =
        _zip64Values(extra, compressed, uncompressed, localOffset, diskStart);
    compressed = zip64[0];
    uncompressed = zip64[1];
    localOffset = zip64[2];
    diskStart = zip64[3];
    if (diskStart != 0 ||
        (flags & 0x1) != 0 ||
        (flags & ~(0x8 | 0x800)) != 0 ||
        (method != 0 && method != 8) ||
        compressed < 0 ||
        uncompressed < 0 ||
        compressed > maxFileBytes ||
        uncompressed > maxFileBytes ||
        uncompressed > maxExpandedBytes - total) {
      throw const FormatException('Unsupported or oversized ZIP entry');
    }
    total += uncompressed;
    final normalized = _normaliseZipPath(filename);
    final unixMode = (versionMadeBy >> 8) == 3 ? externalAttributes >> 16 : 0;
    final fileType = unixMode & 0xf000;
    final directory = filename.endsWith('/') ||
        (externalAttributes & 0x10) != 0 ||
        fileType == 0x4000;
    if (fileType == 0xa000 ||
        (fileType != 0 && fileType != 0x4000 && fileType != 0x8000)) {
      throw const FormatException('Unsupported ZIP file type');
    }
    if (!names.containsKey(normalized)) {
      names[normalized] = directory;
    } else {
      throw const FormatException('Unsafe or duplicate backup path');
    }
    if (directory && (compressed != 0 || uncompressed != 0)) {
      throw const FormatException('Invalid ZIP directory entry');
    }
    entries.add(_ZipEntryInfo(
        name: normalized,
        localOffset: localOffset,
        compressedSize: compressed,
        uncompressedSize: uncompressed,
        crc32: crc,
        compressionMethod: method,
        flags: flags,
        isDirectory: directory));
  }
  if (reader.position != centralOffset32 + centralSize32) {
    throw const FormatException('Invalid ZIP central directory size');
  }
  // A file cannot also be a parent directory. This is checked before any
  // destination directory is created.
  for (final entry in entries) {
    var parent = entry.name;
    while (parent.contains('/')) {
      parent = parent.substring(0, parent.lastIndexOf('/'));
      if (names[parent] == false)
        throw const FormatException('ZIP path conflict');
    }
  }
  return entries;
}

void _validateZipLocalHeaders(
    _ZipReader reader, List<_ZipEntryInfo> entries, int centralOffset) {
  final ranges = <({int start, int end})>[];
  for (final entry in entries) {
    reader.seek(entry.localOffset);
    if (reader.u32() != 0x04034b50)
      throw const FormatException('Invalid ZIP local header');
    reader.u16();
    final flags = reader.u16();
    final method = reader.u16();
    reader.u16();
    reader.u16();
    reader.u32();
    reader.u32();
    reader.u32();
    final filenameLength = reader.u16();
    final extraLength = reader.u16();
    final localName = _zipName(reader.bytes(filenameLength), flags);
    reader.bytes(extraLength);
    final dataOffset = reader.position;
    final dataEnd = dataOffset + entry.compressedSize;
    if (flags != entry.flags ||
        method != entry.compressionMethod ||
        _normaliseZipPath(localName) != entry.name ||
        dataOffset < 0 ||
        dataEnd < dataOffset ||
        dataEnd > centralOffset) {
      throw const FormatException('Invalid ZIP local header');
    }
    entry.localDataOffset = dataOffset;
    ranges.add((start: entry.localOffset, end: dataEnd));
  }
  ranges.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < ranges.length; i++) {
    if (ranges[i].start < ranges[i - 1].end) {
      throw const FormatException('Overlapping ZIP entries');
    }
  }
}

class _CrcOutput extends OutputStreamBase {
  _CrcOutput(this.output, this.limit);

  final OutputFileStream output;
  final int limit;
  int crc = 0;
  final List<int> _history = <int>[];
  int _historyStart = 0;

  @override
  int get length => output.length;

  void _check(int count) {
    if (count < 0 || length > limit - count) {
      throw const FormatException('Backup entry exceeds size limit');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    output.writeByte(value);
    crc = getCrc32([value], crc);
    _remember([value]);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    len ??= bytes.length;
    _check(len);
    output.writeBytes(bytes, len);
    crc = getCrc32(bytes.sublist(0, len), crc);
    _remember(bytes, len);
  }

  void _remember(List<int> bytes, [int? len]) {
    len ??= bytes.length;
    _history.addAll(bytes.take(len));
    if (_history.length > 32768) {
      final remove = _history.length - 32768;
      _history.removeRange(0, remove);
      _historyStart += remove;
    }
  }

  // Inflate uses the last 32 KiB as its LZ77 dictionary. Keeping only that
  // window preserves streaming output without allocating the full entry.
  List<int> subset(int start, [int? end]) {
    var from = start < 0 ? length + start : start;
    var to = end == null ? length : (end < 0 ? length + end : end);
    if (from < _historyStart || to < from || to > length) {
      throw const FormatException('Invalid ZIP deflate distance');
    }
    final historyFrom = from - _historyStart;
    final historyTo = to - _historyStart;
    return List<int>.from(_history.sublist(historyFrom, historyTo));
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    const chunkSize = 64 * 1024;
    while (stream.length > 0) {
      final chunk = stream
          .readBytes(stream.length > chunkSize ? chunkSize : stream.length)
          .toUint8List();
      writeBytes(chunk);
    }
  }

  @override
  void flush() => output.flush();

  @override
  void writeUint16(int value) {
    writeByte(value);
    writeByte(value >> 8);
  }

  @override
  void writeUint32(int value) {
    writeUint16(value);
    writeUint16(value >> 16);
  }

  @override
  void writeUint64(int value) {
    writeUint32(value);
    writeUint32(value >> 32);
  }
}

void _extractZipEntry(
    _ZipReader reader, _ZipEntryInfo entry, String target, int maxFileBytes) {
  if (entry.isDirectory) {
    Directory(target).createSync(recursive: true);
    return;
  }
  File(target).parent.createSync(recursive: true);
  final outputFile = OutputFileStream(target);
  // Cap output by both policy and the header's declared size. A forged small
  // size therefore fails before writing a large decompressed payload.
  final output = _CrcOutput(
      outputFile,
      entry.uncompressedSize < maxFileBytes
          ? entry.uncompressedSize
          : maxFileBytes);
  try {
    final compressed =
        reader.input.subset(entry.localDataOffset, entry.compressedSize);
    if (entry.compressionMethod == ZipFile.zipCompressionStore) {
      output.writeInputStream(compressed);
    } else {
      Inflate.stream(compressed, output);
      if (compressed.length != 0) {
        // Inflate must consume the complete central-directory payload. Any
        // trailing bytes would otherwise allow an unverified payload suffix.
        throw const FormatException('Invalid ZIP deflate stream');
      }
    }
    if (output.length != entry.uncompressedSize || output.crc != entry.crc32) {
      throw const FormatException('Backup entry checksum failed');
    }
  } finally {
    outputFile.closeSync();
  }
}

/// Validates all entry names and sizes before writing the first entry.
Future<Map<String, dynamic>> extractDataBackup(String source, Directory root,
    {int maxFiles = 100000,
    int maxExpandedBytes = 8 * 1024 * 1024 * 1024,
    int maxFileBytes = 256 * 1024 * 1024}) async {
  final input = InputFileStream(source);
  try {
    final reader = _ZipReader(input);
    final entries = _readZipHeaders(reader,
        maxFiles: maxFiles,
        maxExpandedBytes: maxExpandedBytes,
        maxFileBytes: maxFileBytes);
    _validateZipLocalHeaders(reader, entries, reader.centralOffset);
    // Refuse an existing extraction directory, including a planted symlink.
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('Extraction directory already exists');
    }
    try {
      root.createSync(recursive: true);
      for (final entry in entries) {
        _extractZipEntry(
            reader, entry, '${root.path}/${entry.name}', maxFileBytes);
      }
    } catch (_) {
      if (FileSystemEntity.typeSync(root.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        root.deleteSync(recursive: true);
      }
      rethrow;
    }
  } finally {
    input.closeSync();
  }
  final manifestFile = File('${root.path}/$backupManifestName');
  Map<String, dynamic> manifest = {};
  if (manifestFile.existsSync()) {
    manifest = Map<String, dynamic>.from(
        jsonDecode(await manifestFile.readAsString()) as Map);
    if (manifest['formatVersion'] != 1 || manifest['files'] is! Map) {
      throw const FormatException('Unsupported backup format');
    }
    final listed = Map<String, dynamic>.from(manifest['files'] as Map);
    final actual = <String>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || entity.path == manifestFile.path) continue;
      final name =
          entity.path.substring(root.path.length + 1).replaceAll('\\', '/');
      actual.add(name);
      final record = listed[name];
      if (record is! Map ||
          record['size'] != await entity.length() ||
          record['sha256'] != await fileDigest(entity)) {
        throw const FormatException('Backup integrity check failed');
      }
    }
    if (actual.length != listed.length)
      throw const FormatException('Backup file is missing');
  }
  final data = jsonDecode(await File('${root.path}/appdata').readAsString());
  if (data is! Map ||
      data['settings'] is! List ||
      (data['settings'] as List).isEmpty ||
      (data['settings'] as List).any((e) => e is! String)) {
    throw const FormatException('Invalid backup settings');
  }
  for (final entry in {
    'local_favorite.db': 'folder_order',
    'history.db': 'history',
    'cookies.db': 'cookies'
  }.entries) {
    final file = File('${root.path}/${entry.key}');
    if (file.existsSync())
      checkBackupDatabase(file.path, entry.value);
    else if (manifest.isNotEmpty && entry.key != 'cookies.db') {
      throw FormatException('Missing ${entry.key}');
    }
  }
  return manifest;
}

/// Copies a validated backup entity without blocking the caller on file I/O.
///
/// Restore's final rename/journal steps intentionally remain synchronous and
/// atomic; only the potentially large staging copy is asynchronous.
Future<void> copyBackupEntity(String source, String target) async {
  final type = await FileSystemEntity.type(source, followLinks: false);
  if (type == FileSystemEntityType.file) {
    await File(target).parent.create(recursive: true);
    await File(source).copy(target);
  } else if (type == FileSystemEntityType.directory) {
    await Directory(target).create(recursive: true);
    await for (final entry in Directory(source).list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((e) => e.isNotEmpty).last;
      await copyBackupEntity(entry.path, '$target/$name');
    }
  } else {
    throw const FormatException('Unsupported backup entity');
  }
}

void _deleteEntity(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.directory)
    Directory(path).deleteSync(recursive: true);
  else if (type == FileSystemEntityType.file)
    File(path).deleteSync();
  else if (type != FileSystemEntityType.notFound)
    throw const FormatException('Unexpected restore link');
}

String _normaliseRestorePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.length > 1
      ? normalized.replaceFirst(RegExp(r'/+$'), '')
      : normalized;
  return Platform.isWindows ? trimmed.toLowerCase() : trimmed;
}

bool _isRestorePathWithin(String root, String path) {
  final rootPath = _normaliseRestorePath(root);
  final targetPath = _normaliseRestorePath(path);
  return targetPath == rootPath || targetPath.startsWith('$rootPath/');
}

void _validateRestoreArtifact(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw const FormatException('Unexpected restore link');
  }
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file &&
      type != FileSystemEntityType.directory) {
    throw const FormatException('Unexpected restore entity');
  }
}

void _validateRestoreEntryArtifacts(Map entry) {
  for (final key in const ['target', 'staged', 'backup']) {
    final path = entry[key];
    if (path is! String) {
      throw const FormatException('Invalid restore journal paths');
    }
    _validateRestoreArtifact(path);
  }
}

bool _restoreTargetsOverlap(String first, String second) =>
    _isRestorePathWithin(first, second) || _isRestorePathWithin(second, first);

/// Resolves roots before they are persisted in a restore journal. A journal
/// can survive process termination, so the raw path spelling is not a
/// sufficient identity for an external restore boundary.
Future<String> _canonicalRestoreRoot(String root) async {
  if (!File(root).isAbsolute) {
    throw const FormatException('Invalid restore root');
  }

  // The configured download directory may be removed between a failed
  // restore and the next startup. Resolve every existing ancestor so a
  // symlink cannot redirect the boundary, then append only the missing,
  // lexical tail. A missing root is safe to compare lexically because its
  // nearest existing ancestor has already been resolved.
  var cursor = Directory(root);
  final missing = <String>[];
  while (true) {
    final type = FileSystemEntity.typeSync(cursor.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.directory) {
        throw const FormatException('Invalid restore root');
      }
      var resolved = await cursor.resolveSymbolicLinks();
      for (final part in missing.reversed) {
        resolved = '$resolved${Platform.pathSeparator}$part';
      }
      return resolved;
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) {
      throw const FormatException('Invalid restore root');
    }
    final segments = cursor.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) throw const FormatException('Invalid restore root');
    missing.add(segments.last);
    cursor = parent;
  }
}

String _canonicalRestoreRootSync(String root) {
  if (!File(root).isAbsolute) {
    throw const FormatException('Invalid restore root');
  }

  var cursor = Directory(root);
  final missing = <String>[];
  while (true) {
    final type = FileSystemEntity.typeSync(cursor.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.directory) {
        throw const FormatException('Invalid restore root');
      }
      var resolved = cursor.resolveSymbolicLinksSync();
      for (final part in missing.reversed) {
        resolved = '$resolved${Platform.pathSeparator}$part';
      }
      return resolved;
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) {
      throw const FormatException('Invalid restore root');
    }
    final segments = cursor.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) throw const FormatException('Invalid restore root');
    missing.add(segments.last);
    cursor = parent;
  }
}

/// Checks a journal artifact against the current canonical restore roots.
/// `allowedRoots` must have already passed the journal root identity check.
bool _isSafeRestorePathSync(String dataPath, String target,
    {Iterable<String> allowedRoots = const []}) {
  if (!File(target).isAbsolute ||
      target.contains('\u0000') ||
      target
          .replaceAll('\\', '/')
          .split('/')
          .any((part) => part == '.' || part == '..')) {
    return false;
  }
  final roots = <String>[
    Directory(dataPath).resolveSymbolicLinksSync(),
    ...allowedRoots,
  ];
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type == FileSystemEntityType.link) return false;
  if (type != FileSystemEntityType.notFound) {
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      return false;
    }
    final resolved = type == FileSystemEntityType.directory
        ? Directory(target).resolveSymbolicLinksSync()
        : File(target).resolveSymbolicLinksSync();
    return roots.any((root) => _isRestorePathWithin(root, resolved));
  }
  if (roots.any((root) => _isRestorePathWithin(root, target))) return true;
  var ancestor = File(target).parent;
  while (true) {
    final ancestorType =
        FileSystemEntity.typeSync(ancestor.path, followLinks: false);
    if (ancestorType != FileSystemEntityType.notFound) {
      if (ancestorType != FileSystemEntityType.directory) return false;
      final resolved = ancestor.resolveSymbolicLinksSync();
      return roots.any((root) => _isRestorePathWithin(root, resolved));
    }
    final parent = ancestor.parent;
    if (parent.path == ancestor.path) return false;
    ancestor = parent;
  }
}

Future<List<String>> _canonicalRestoreRoots(Iterable<String> roots) async {
  final result = <String>[];
  for (final root in roots) {
    final resolved = await _canonicalRestoreRoot(root);
    if (!result.any((existing) =>
        _normaliseRestorePath(existing) == _normaliseRestorePath(resolved))) {
      result.add(resolved);
    }
  }
  return result;
}

/// Resolves the nearest existing parent so a symlink cannot redirect a
/// restore target outside the application's data directory. Missing target
/// files are valid; their existing ancestor is still checked.
Future<bool> _isSafeRestoreTarget(String dataPath, String target,
    {Iterable<String> allowedRoots = const []}) async {
  if (!File(target).isAbsolute ||
      target.contains('\u0000') ||
      target
          .replaceAll('\\', '/')
          .split('/')
          .any((part) => part == '.' || part == '..')) {
    return false;
  }
  final roots = <String>[await Directory(dataPath).resolveSymbolicLinks()];
  for (final allowedRoot in allowedRoots) {
    try {
      roots.add(await _canonicalRestoreRoot(allowedRoot));
    } catch (_) {
      // Invalid journal roots are rejected by the explicit trust comparison
      // below; a missing configured root is represented by its canonical
      // nearest-ancestor path rather than silently treated as dataPath.
    }
  }
  if (FileSystemEntity.typeSync(target, followLinks: false) ==
      FileSystemEntityType.link) {
    return false;
  }
  final targetType = FileSystemEntity.typeSync(target, followLinks: false);
  if (targetType != FileSystemEntityType.notFound) {
    if (targetType != FileSystemEntityType.file &&
        targetType != FileSystemEntityType.directory) {
      return false;
    }
    final resolvedTarget = targetType == FileSystemEntityType.directory
        ? await Directory(target).resolveSymbolicLinks()
        : await File(target).resolveSymbolicLinks();
    return roots.any((root) => _isRestorePathWithin(root, resolvedTarget));
  }
  // When the configured external root itself is missing, there is no
  // existing ancestor at which to resolve the target. The canonical root
  // above has already resolved its nearest existing ancestor, so a lexical
  // containment check is sufficient for this missing-tail case.
  if (roots.any((root) => _isRestorePathWithin(root, target))) return true;
  var ancestor = File(target).parent;
  while (true) {
    final type = FileSystemEntity.typeSync(ancestor.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.directory) return false;
      final resolved = await ancestor.resolveSymbolicLinks();
      return roots.any((root) => _isRestorePathWithin(root, resolved));
    }
    final parent = ancestor.parent;
    if (parent.path == ancestor.path) return false;
    ancestor = parent;
  }
}

/// The journal lives outside temporary work directories and precedes each move.
class DataRestoreTransaction {
  final File journal;
  final Map<String, dynamic> state;
  DataRestoreTransaction._(this.journal, this.state);

  List<String> _validateRestoreRootIdentity() {
    final persisted = state['allowedRoots'];
    if (persisted == null) return const [];
    if (persisted is! List || persisted.any((root) => root is! String)) {
      throw const FormatException('Invalid restore roots');
    }
    final roots = <String>[];
    for (final root in persisted.cast<String>()) {
      final canonical = _canonicalRestoreRootSync(root);
      if (_normaliseRestorePath(canonical) != _normaliseRestorePath(root)) {
        throw const FormatException('Restore root changed before recovery');
      }
      roots.add(canonical);
    }
    return roots;
  }

  void _validateEntryBoundaries(Map entry, List<String> allowedRoots) {
    final dataPath = journal.parent.parent.path;
    for (final key in const ['target', 'staged', 'backup']) {
      final path = entry[key];
      if (path is! String ||
          !_isSafeRestorePathSync(dataPath, path, allowedRoots: allowedRoots)) {
        throw const FormatException('Restore path changed before operation');
      }
    }
  }

  static Future<DataRestoreTransaction> prepare(
      String dataPath, Map<String, String> replacements,
      {Iterable<String> allowedRoots = const []}) async {
    final journal = File('$dataPath/data-restore/journal.json');
    if (journal.existsSync() || File('${journal.path}.previous').existsSync())
      throw StateError('An unfinished restore must be recovered first');
    journal.parent.createSync(recursive: true);
    final canonicalAllowedRoots = await _canonicalRestoreRoots(allowedRoots);
    final targets = <String>[];
    for (final target in replacements.keys) {
      if (_normaliseRestorePath(target) == _normaliseRestorePath(dataPath) ||
          _isRestorePathWithin(
              _normaliseRestorePath('$dataPath/data-restore'), target) ||
          targets.any((existing) => _restoreTargetsOverlap(existing, target)) ||
          !await _isSafeRestoreTarget(dataPath, target,
              allowedRoots: canonicalAllowedRoots)) {
        throw const FormatException('Invalid restore target path');
      }
      targets.add(target);
    }
    final prefs = await SharedPreferences.getInstance();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final entries = <Map<String, dynamic>>[];
    final transaction = DataRestoreTransaction._(journal, {
      'version': 1,
      'phase': 'prepare',
      'id': id,
      'entries': entries,
      'allowedRoots': canonicalAllowedRoots,
      'preferences': {
        for (final key in ['firstUse', 'blockingKeyword', 'favoriteTags'])
          key: prefs.getStringList(key)
      },
    });
    transaction._write();
    for (final entry in replacements.entries) {
      final target = entry.key;
      final staged = '$target.restore-new-$id';
      final backup = '$target.restore-old-$id';
      entries.add({
        'target': target,
        'staged': staged,
        'backup': backup,
        'existed': FileSystemEntity.typeSync(target, followLinks: false) !=
            FileSystemEntityType.notFound
      });
      transaction._write();
      await copyBackupEntity(entry.value, staged);
    }
    transaction.state['phase'] = 'replace';
    transaction._write();
    return transaction;
  }

  void _write() {
    final temp = File('${journal.path}.tmp');
    temp.writeAsStringSync(jsonEncode(state), flush: true);
    // On Windows, retain an earlier complete journal if rename cannot replace.
    if (Platform.isWindows && journal.existsSync()) {
      final previous = File('${journal.path}.previous');
      if (previous.existsSync()) previous.deleteSync();
      journal.renameSync(previous.path);
    }
    temp.renameSync(journal.path);
  }

  void apply({void Function(int)? afterReplace}) {
    final entries = (state['entries'] as List).cast<Map>();
    final allowedRoots = _validateRestoreRootIdentity();
    // Validate every artifact before moving the first target. This keeps a
    // concurrently planted link or an overlapping target from turning a
    // partially-applied restore into an unsafe replacement.
    for (final entry in entries) {
      _validateRestoreEntryArtifacts(entry);
      _validateEntryBoundaries(entry, allowedRoots);
      final target = entry['target'] as String;
      final existed = entry['existed'] == true;
      final targetType = FileSystemEntity.typeSync(target, followLinks: false);
      if (targetType == FileSystemEntityType.link ||
          (existed &&
              targetType != FileSystemEntityType.file &&
              targetType != FileSystemEntityType.directory) ||
          (!existed && targetType != FileSystemEntityType.notFound)) {
        throw const FormatException('Restore target changed before apply');
      }
      if (FileSystemEntity.typeSync(entry['backup'] as String,
              followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FormatException('Restore backup already exists');
      }
      final stagedType = FileSystemEntity.typeSync(entry['staged'] as String,
          followLinks: false);
      if (stagedType != FileSystemEntityType.file &&
          stagedType != FileSystemEntityType.directory) {
        throw const FormatException('Restore staging is unavailable');
      }
    }
    var index = 0;
    for (final entry in entries) {
      final target = entry['target'] as String;
      final backup = entry['backup'] as String;
      if (entry['existed'] == true) {
        final entity = FileSystemEntity.typeSync(target, followLinks: false) ==
                FileSystemEntityType.directory
            ? Directory(target)
            : File(target);
        entity.renameSync(backup);
      }
      final staged = entry['staged'] as String;
      final entity = FileSystemEntity.typeSync(staged, followLinks: false) ==
              FileSystemEntityType.directory
          ? Directory(staged)
          : File(staged);
      entity.renameSync(target);
      afterReplace?.call(index++);
    }
    state['phase'] = 'applied';
    _write();
  }

  void commit() {
    final previousPhase = state['phase'];
    state['phase'] = 'committed';
    try {
      _write();
    } catch (_) {
      // A failed commit marker must remain recoverable as an uncommitted
      // transaction. In particular, importData() may immediately call
      // recover() after this method throws.
      state['phase'] = previousPhase;
      rethrow;
    }
  }

  Future<void> recover() async {
    final entries = (state['entries'] as List).cast<Map>();
    final allowedRoots = _validateRestoreRootIdentity();
    for (final entry in entries) {
      _validateRestoreEntryArtifacts(entry);
      _validateEntryBoundaries(entry, allowedRoots);
      if (entry['existed'] == false &&
          FileSystemEntity.typeSync(entry['backup'] as String,
                  followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw const FormatException('Unexpected restore backup');
      }
    }
    if (state['phase'] != 'committed') {
      for (final entry in entries.toList().reversed) {
        final backup = entry['backup'] as String;
        final target = entry['target'] as String;
        final type = FileSystemEntity.typeSync(backup, followLinks: false);
        if (type != FileSystemEntityType.notFound) {
          _deleteEntity(target);
          if (type == FileSystemEntityType.directory)
            Directory(backup).renameSync(target);
          else
            File(backup).renameSync(target);
        } else if (entry['existed'] == false) {
          _deleteEntity(target);
        } else if (FileSystemEntity.typeSync(target, followLinks: false) ==
            FileSystemEntityType.notFound) {
          throw StateError(
              'Cannot prove original restore target exists; journal retained');
        }
      }
      final prefs = await SharedPreferences.getInstance();
      for (final entry in (state['preferences'] as Map).entries) {
        final success = entry.value == null
            ? await prefs.remove(entry.key as String)
            : await prefs.setStringList(
                entry.key as String, List<String>.from(entry.value as List));
        if (!success) throw StateError('Restore preferences failed');
      }
    }
    for (final entry in (state['entries'] as List).cast<Map>()) {
      _deleteEntity(entry['staged'] as String);
      _deleteEntity(entry['backup'] as String);
    }
    final previous = File('${journal.path}.previous');
    if (previous.existsSync()) previous.deleteSync();
    // Keep a committed canonical journal until the fallback copy is gone. If
    // cleanup is interrupted, recovery still sees the committed phase rather
    // than treating the previous journal as an unfinished rollback.
    if (journal.existsSync()) journal.deleteSync();
  }
}

Future<void> recoverPendingDataRestore(String dataPath,
    {Iterable<String> trustedAllowedRoots = const []}) async {
  final canonical = File('$dataPath/data-restore/journal.json');
  var journal = canonical;
  if (!journal.existsSync()) {
    final previous = File('${canonical.path}.previous');
    if (!previous.existsSync()) return;
    journal = previous;
  }
  final decoded = jsonDecode(await journal.readAsString());
  if (decoded is! Map) {
    throw const FormatException(
        'Invalid restore journal; retained for recovery');
  }
  final state = Map<String, dynamic>.from(decoded);
  final persistedAllowedRoots = state['allowedRoots'];
  if (state['version'] != 1 ||
      state['id'] is! String ||
      !(state['id'] as String).contains(RegExp(r'^[0-9]+$')) ||
      state['entries'] is! List ||
      (persistedAllowedRoots != null &&
          (persistedAllowedRoots is! List ||
              persistedAllowedRoots.any((e) => e is! String))) ||
      state['preferences'] is! Map ||
      !const ['prepare', 'replace', 'applied', 'committed']
          .contains(state['phase'])) {
    throw const FormatException(
        'Invalid restore journal; retained for recovery');
  }
  final journalRoots = persistedAllowedRoots == null
      ? const <String>[]
      : await _canonicalRestoreRoots(
          (persistedAllowedRoots as List).cast<String>());
  final dataRoot = await Directory(dataPath).resolveSymbolicLinks();
  final externalJournalRoots = journalRoots
      .where((root) => !_isRestorePathWithin(dataRoot, root))
      .toList(growable: false);
  final runtimeAllowedRoots = externalJournalRoots.isEmpty
      ? const <String>[]
      : await _canonicalRestoreRoots(trustedAllowedRoots);
  // Roots inside dataPath do not expand the trust boundary. Every external
  // root recorded in the journal must be explicitly supplied by the current
  // runtime; journal contents alone are never authority.
  for (final root in externalJournalRoots) {
    if (!runtimeAllowedRoots.any((trusted) =>
        _normaliseRestorePath(trusted) == _normaliseRestorePath(root))) {
      throw const FormatException('Untrusted external restore root');
    }
  }
  final preferences = (state['preferences'] as Map).cast<Object?, Object?>();
  const recoverablePreferenceKeys = {
    'firstUse',
    'blockingKeyword',
    'favoriteTags',
  };
  if (preferences.length != recoverablePreferenceKeys.length ||
      !recoverablePreferenceKeys.every(preferences.containsKey) ||
      preferences.keys.any((key) =>
          key is! String || !recoverablePreferenceKeys.contains(key))) {
    throw const FormatException('Invalid restore preferences');
  }

  final entries = state['entries'] as List;
  final targets = <String>[];
  for (final rawEntry in entries) {
    if (rawEntry is! Map) {
      throw const FormatException('Invalid restore journal entry');
    }
    final entry = Map<String, dynamic>.from(rawEntry);
    final target = entry['target'];
    if (target is! String ||
        target.contains('\u0000') ||
        _normaliseRestorePath(target) == _normaliseRestorePath(dataPath) ||
        _isRestorePathWithin(
            _normaliseRestorePath('$dataPath/data-restore'), target) ||
        !await _isSafeRestoreTarget(dataPath, target,
            allowedRoots: journalRoots) ||
        entry['existed'] is! bool ||
        entry['backup'] != '$target.restore-old-${state['id']}' ||
        entry['staged'] != '$target.restore-new-${state['id']}') {
      throw const FormatException('Invalid restore journal paths');
    }
    if (targets.any((existing) => _restoreTargetsOverlap(existing, target))) {
      throw const FormatException('Overlapping restore targets');
    }
    targets.add(target);
    _validateRestoreEntryArtifacts(entry);
  }
  // Use the canonical path even when the previous journal was the only
  // surviving complete record, so recovery cleans both names consistently.
  await DataRestoreTransaction._(canonical, state).recover();
}
