import 'dart:convert';

enum SyncStatus { success, unchanged, skipped, conflict, failed }

class SyncResult {
  const SyncResult(this.status, {this.heads = const []});
  final SyncStatus status;
  final List<SyncRevision> heads;
  bool get succeeded =>
      status != SyncStatus.failed && status != SyncStatus.conflict;
}

/// Published only after the immutable archive has been read back and verified.
class SyncRevision {
  const SyncRevision(
      {required this.id,
      required this.device,
      required this.parents,
      required this.sha256,
      this.legacyVersion});
  final String id;
  final String device;
  final List<String> parents;
  final String sha256;
  final int? legacyVersion;
  bool get legacy => legacyVersion != null;
  String get archiveName =>
      legacy ? '$legacyVersion.picadata' : 'revision-$id.picadata';
  String get descriptorName => 'revision-$id.json';

  Map<String, Object> get metadata =>
      {'id': id, 'device': device, 'parents': parents};
  Map<String, Object> toJson() =>
      {'protocol': 2, ...metadata, 'sha256': sha256};

  factory SyncRevision.fromJson(Object? data, String expectedId) {
    if (data is! Map ||
        data['protocol'] != 2 ||
        data['id'] != expectedId ||
        !isRevisionId(expectedId) ||
        data['device'] is! String ||
        !isRevisionId(data['device'] as String) ||
        data['parents'] is! List ||
        (data['parents'] as List)
            .any((e) => e is! String || !isRevisionId(e)) ||
        (data['parents'] as List).contains(expectedId) ||
        data['sha256'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['sha256'] as String)) {
      throw const FormatException('Invalid sync revision');
    }
    return SyncRevision(
        id: expectedId,
        device: data['device'] as String,
        parents: List<String>.from(data['parents'] as List),
        sha256: data['sha256'] as String);
  }
}

bool isRevisionId(String value) =>
    RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$').hasMatch(value);

/// Clock values cannot choose between branches; only recorded ancestry can.
List<SyncRevision> revisionHeads(Iterable<SyncRevision> revisions) {
  final all = <String, SyncRevision>{};
  for (final revision in revisions) {
    if (!isRevisionId(revision.id)) {
      throw const FormatException('Invalid sync revision id');
    }
    if (all.containsKey(revision.id)) {
      throw const FormatException('Duplicate sync revision id');
    }
    all[revision.id] = revision;
  }

  // A descriptor with an absent parent is incomplete. Treating it as a root
  // would hide a partial upload and could make conflict resolution discard an
  // unseen branch.
  for (final revision in all.values) {
    final parents = <String>{};
    for (final parent in revision.parents) {
      if (!isRevisionId(parent) || !parents.add(parent)) {
        throw const FormatException('Invalid sync revision parents');
      }
      if (!all.containsKey(parent)) {
        throw const FormatException('Missing sync revision parent');
      }
    }
  }
  final ancestors = <String>{};
  void visit(String id, Set<String> chain) {
    if (!chain.add(id)) throw const FormatException('Cyclic sync revisions');
    for (final parent in all[id]!.parents) {
      ancestors.add(parent);
      visit(parent, Set.of(chain));
    }
  }

  for (final id in all.keys) {
    visit(id, {});
  }
  final heads = all.values.where((e) => !ancestors.contains(e.id)).toList();
  // Earlier numeric snapshots belong to the legacy single-version protocol.
  // V2 branches remain incomparable with legacy data until explicitly merged.
  final legacy = heads.where((e) => e.legacy).toList()
    ..sort((a, b) => b.legacyVersion!.compareTo(a.legacyVersion!));
  return [...heads.where((e) => !e.legacy), if (legacy.isNotEmpty) legacy.first]
    ..sort((a, b) => a.id.compareTo(b.id));
}

String encodeSyncRevision(SyncRevision revision) =>
    jsonEncode(revision.toJson());
