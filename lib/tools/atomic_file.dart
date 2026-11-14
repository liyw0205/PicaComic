import 'dart:io';

/// Writes text to [target] without exposing a partially-written destination.
///
/// The temporary file lives next to the destination so the final rename stays
/// on the same filesystem. A unique name also keeps concurrent source updates
/// from sharing a temporary file.
Future<void> writeTextFileAtomically(File target, String contents) async {
  await target.parent.create(recursive: true);
  final temporary =
      File('${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
  File? backup;
  try {
    await temporary.writeAsString(contents, flush: true);
    if (Platform.isWindows && await target.exists()) {
      backup = File(
          '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.bak');
      await target.rename(backup.path);
    }
    try {
      await temporary.rename(target.path);
    } catch (_) {
      if (backup != null && await backup.exists()) {
        try {
          await backup.rename(target.path);
          backup = null;
        } catch (_) {
          // Keep the backup when recovery itself cannot complete.
        }
      }
      rethrow;
    }
    if (backup != null && await backup.exists()) {
      // The new file is already installed. A stale backup is harmless if
      // cleanup fails, so do not turn a successful replacement into an error.
      try {
        await backup.delete();
      } catch (_) {
        // Keep the complete backup for the next maintenance pass.
      }
      backup = null;
    }
  } finally {
    if (await temporary.exists()) {
      try {
        await temporary.delete();
      } catch (_) {
        // Retain the temporary artifact if storage cleanup is unavailable.
      }
    }
  }
}

/// Writes binary data without exposing a partially-written destination.
///
/// The temporary sibling is deliberately kept next to [target] so that the
/// final rename is on the same filesystem. This is used for generated files
/// such as PDF exports where a truncated destination must never look complete.
Future<void> writeBytesFileAtomically(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final temporary =
      File('${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
  File? backup;
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    if (Platform.isWindows && await target.exists()) {
      backup = File(
          '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.bak');
      await target.rename(backup.path);
    }
    try {
      await temporary.rename(target.path);
    } catch (_) {
      if (backup != null && await backup.exists()) {
        try {
          await backup.rename(target.path);
          backup = null;
        } catch (_) {
          // Keep the backup when recovery itself cannot complete.
        }
      }
      rethrow;
    }
    if (backup != null && await backup.exists()) {
      try {
        await backup.delete();
      } catch (_) {
        // The complete replacement is already installed; cleanup can retry.
      }
      backup = null;
    }
  } finally {
    if (await temporary.exists()) {
      try {
        await temporary.delete();
      } catch (_) {
        // Retain the temporary artifact if storage cleanup is unavailable.
      }
    }
  }
}
