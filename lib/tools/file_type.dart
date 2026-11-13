import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:mime/mime.dart';

class FileType {
  final String ext;
  final String mime;

  const FileType(this.ext, this.mime);
}

FileType detectFileType(List<int> data) {
  var mime = lookupMimeType('no-file', headerBytes: data);
  var ext = mime == null ? '' : extensionFromMime(mime);
  if (ext == 'jpe') {
    ext = 'jpg';
  }
  return FileType(".$ext", mime ?? 'application/octet-stream');
}

bool isValidImageData(List<int> data) {
  if (data.isEmpty) return false;
  final extension = detectFileType(data).ext;
  if (!const {'.jpg', '.jpeg', '.png', '.gif', '.webp'}.contains(extension)) {
    return false;
  }

  try {
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final decoded = image.decodeImage(bytes);
    return decoded != null && decoded.width > 0 && decoded.height > 0;
  } catch (_) {
    return false;
  }
}
