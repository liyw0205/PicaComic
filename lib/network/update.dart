import 'package:dio/dio.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/network/app_dio.dart';

const updateRepository = 'liyw0205/PicaComic';

String? _updateInfo;

Future<String> getLatestVersion({Dio? client}) async {
  var dio = client ?? logDio();
  var res = await dio
      .get("https://api.github.com/repos/$updateRepository/releases/latest");
  _updateInfo = res.data["body"]?.toString() ?? '';
  final tag = res.data["tag_name"]?.toString();
  if (tag == null || tag.isEmpty) {
    throw const FormatException('GitHub release has no tag_name');
  }
  return tag.replaceFirst(RegExp(r'^v', caseSensitive: false), "");
}

Future<bool?> checkUpdate() async {
  try {
    var version = appVersion;
    var res = await getLatestVersion();
    return compareSemVer(res, version);
  } catch (e) {
    return null;
  }
}

bool compareSemVer(String ver1, String ver2) {
  final v1 = _parseVersion(ver1);
  final v2 = _parseVersion(ver2);
  if (v1 == null || v2 == null) return false;

  final components1 = [v1.major, v1.minor, v1.patch];
  final components2 = [v2.major, v2.minor, v2.patch];
  for (var i = 0; i < components1.length; i++) {
    final comparison =
        _compareNumericIdentifier(components1[i], components2[i]);
    if (comparison != 0) return comparison > 0;
  }

  final prerelease1 = v1.prerelease;
  final prerelease2 = v2.prerelease;
  if (prerelease1 == null) return prerelease2 != null;
  if (prerelease2 == null) return false;
  for (var i = 0; i < prerelease1.length && i < prerelease2.length; i++) {
    final a = prerelease1[i];
    final b = prerelease2[i];
    if (a == b) continue;
    final aNumber = RegExp(r'^\d+$').hasMatch(a);
    final bNumber = RegExp(r'^\d+$').hasMatch(b);
    if (aNumber && bNumber) {
      return _compareNumericIdentifier(a, b) > 0;
    }
    if (aNumber) return false;
    if (bNumber) return true;
    return a.compareTo(b) > 0;
  }
  return prerelease1.length > prerelease2.length;
}

class _ParsedVersion {
  final String major;
  final String minor;
  final String patch;
  final List<String>? prerelease;

  const _ParsedVersion(this.major, this.minor, this.patch, this.prerelease);
}

int _compareNumericIdentifier(String a, String b) {
  if (a.length != b.length) return a.length.compareTo(b.length);
  return a.compareTo(b);
}

_ParsedVersion? _parseVersion(String value) {
  final match = RegExp(
    r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:[-.]([0-9A-Za-z-]+(?:[.-][0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final core = [match[1]!, match[2]!, match[3]!];
  if (core.any((part) => part.length > 1 && part.startsWith('0'))) return null;
  final prerelease = match[4]?.split('.');
  if (prerelease != null &&
      prerelease.any((part) =>
          part.isEmpty ||
          (RegExp(r'^\d+$').hasMatch(part) &&
              part.length > 1 &&
              part.startsWith('0')))) {
    return null;
  }
  return _ParsedVersion(
    core[0],
    core[1],
    core[2],
    prerelease,
  );
}

Future<String?> getUpdatesInfo() async {
  final info = _updateInfo;
  if (info == null) return null;
  final lines = info.replaceAll('\r\n', '\n').split("\n");
  if (lines.length > 5) {
    return '${lines.take(5).join("\n")}\n...';
  }
  return info;
}

Future<String> getDownloadUrl() async {
  return "https://github.com/$updateRepository/releases/latest";
}
