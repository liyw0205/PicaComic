import 'dart:io';
import 'dart:typed_data';

class DownloadProgress {
  final int _currentBytes;
  final int _expectedBytes;
  final String url;
  final String savePath;
  final Uint8List? data;
  final String? ext;
  final String cacheKey;
  final bool imageValidated;

  int get currentBytes => _currentBytes;

  int get expectedBytes => _expectedBytes;

  bool get finished => _currentBytes == _expectedBytes;

  const DownloadProgress(
      this._currentBytes, this._expectedBytes, this.url, this.savePath,
      [this.data, this.ext, String? cacheKey, this.imageValidated = false])
      : cacheKey = cacheKey ?? url;

  factory DownloadProgress.inProgress(
      int currentBytes, int? expectedBytes, String url, String savePath,
      [String? cacheKey]) {
    final safeExpectedBytes =
        expectedBytes == null || expectedBytes <= currentBytes
            ? currentBytes + 1
            : expectedBytes;
    return DownloadProgress(
        currentBytes, safeExpectedBytes, url, savePath, null, null, cacheKey);
  }

  File getFile() => File(savePath);
}
