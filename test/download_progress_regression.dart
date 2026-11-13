import 'package:pica_comic/network/download_progress.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  final exactLength =
      DownloadProgress.inProgress(128, 128, 'image', '/tmp/image');
  _check(!exactLength.finished, 'Final network chunk was marked complete');
  _check(exactLength.expectedBytes == 129,
      'Exact-length progress did not reserve a completion event');

  final overrun = DownloadProgress.inProgress(129, 128, 'image', '/tmp/image');
  _check(!overrun.finished, 'Mismatched response was marked complete');

  final unknownLength =
      DownloadProgress.inProgress(128, null, 'image', '/tmp/image');
  _check(
      !unknownLength.finished, 'Unknown-length progress was marked complete');

  const completed = DownloadProgress(128, 128, 'image', '/tmp/image');
  _check(completed.finished, 'Explicit completion event was not recognized');

  const validated = DownloadProgress(
      128, 128, 'image', '/tmp/image', null, null, 'image', true);
  _check(validated.imageValidated, 'Validated image metadata was lost');
}
