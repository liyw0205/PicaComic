import 'package:pica_comic/network/eh_network/archive_utils.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  const entries = [
    'pages/1.jpg',
    'pages/2.jpeg',
    r'pages\10.webp',
    'cover.jpg',
    'notes/readme.txt',
    'pages/',
  ];
  final expected = countArchivePageFiles(entries);
  _check(expected == 3, 'Archive page entries were counted incorrectly');
  verifyArchivePageCount(expected, 3);

  var rejectedMissingPage = false;
  try {
    verifyArchivePageCount(expected, 2);
  } on FormatException {
    rejectedMissingPage = true;
  }
  _check(rejectedMissingPage, 'An extraction missing one page was accepted');
}
