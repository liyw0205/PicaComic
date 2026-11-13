import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:pica_comic/tools/file_type.dart';

const archiveImageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp'};

bool isArchiveCoverFileName(String name) =>
    RegExp(r'(^|[^a-z0-9])cover([^a-z0-9]|$)', caseSensitive: false)
        .hasMatch(name);

bool isArchivePageFileName(String name) {
  final normalized = name.replaceAll('\\', '/');
  final basename = normalized.split('/').last;
  final extension =
      basename.contains('.') ? basename.split('.').last.toLowerCase() : '';
  return !isArchiveCoverFileName(basename) &&
      archiveImageExtensions.contains(extension);
}

int countArchivePageFiles(Iterable<String> names) =>
    names.where(isArchivePageFileName).length;

void verifyArchivePageCount(int expected, int extracted) {
  if (expected != extracted) {
    throw FormatException(
        'Archive page count mismatch: expected $expected, extracted $extracted');
  }
}

void verifyNoArchiveSymbolicLinks(String archivePath) {
  final input = InputFileStream(archivePath);
  try {
    final archive = ZipDecoder().decodeBuffer(input);
    if (archive.files.any((file) => file.isSymbolicLink)) {
      throw const FormatException('Archive contains a symbolic link');
    }
  } finally {
    input.closeSync();
  }
}

bool isSafeArchivePath(String name) {
  final normalized = name.replaceAll('\\', '/');
  return normalized.isNotEmpty &&
      !normalized.startsWith('/') &&
      !normalized.contains('\u0000') &&
      !RegExp(r'^[A-Za-z]:').hasMatch(normalized) &&
      !normalized.split('/').contains('..');
}

int compareNaturalArchivePaths(String left, String right) {
  final leftParts =
      RegExp(r'\d+|\D+').allMatches(left).map((match) => match[0]!).toList();
  final rightParts =
      RegExp(r'\d+|\D+').allMatches(right).map((match) => match[0]!).toList();
  for (var i = 0; i < math.min(leftParts.length, rightParts.length); i++) {
    final a = leftParts[i];
    final b = rightParts[i];
    final aNumber = int.tryParse(a);
    final bNumber = int.tryParse(b);
    final compare = aNumber != null && bNumber != null
        ? aNumber.compareTo(bNumber)
        : a.compareTo(b);
    if (compare != 0) return compare;
  }
  return leftParts.length.compareTo(rightParts.length);
}

Future<bool> isValidArchiveImage(File file) async {
  final filename = file.uri.pathSegments.last;
  final extension =
      filename.contains('.') ? filename.split('.').last.toLowerCase() : '';
  if (!archiveImageExtensions.contains(extension)) return false;

  try {
    final bytes = await file.readAsBytes();
    return isValidImageData(bytes);
  } catch (_) {
    return false;
  }
}
