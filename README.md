# Pica Comic

[![Flutter](https://img.shields.io/badge/flutter-3.44.0-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/liyw0205/PicaComic)](https://github.com/liyw0205/PicaComic/blob/master/LICENSE)
[![Latest release](https://img.shields.io/github/v/release/liyw0205/PicaComic)](https://github.com/liyw0205/PicaComic/releases)
[![Build](https://github.com/liyw0205/PicaComic/actions/workflows/android.yml/badge.svg)](https://github.com/liyw0205/PicaComic/actions/workflows/android.yml)

Pica Comic is a Flutter comic reader and downloader with multiple source
adapters. This repository is the maintained fork at
`github.com/liyw0205/PicaComic`.

## Downloads

Download Android packages from the [GitHub releases](https://github.com/liyw0205/PicaComic/releases)
page. The project can also be added to [Obtainium](https://github.com/ImranR98/Obtainium)
with this repository URL:

```text
https://github.com/liyw0205/PicaComic
```

An [AUR package](https://aur.archlinux.org/packages/pica-comic-bin) is maintained
by Lilinzta.

## Sources

Built-in sources:

- Pica Comic (`picacg`)
- E-Hentai / ExHentai (`ehentai`)
- JMComic (`jm`)
- Hitomi (`hitomi`)
- HTManga (`htmanga`)
- nhentai (`nhentai`)

Remote JavaScript sources are loaded from the companion
[pica_configs repository](https://github.com/liyw0205/pica_configs):

- CopyManga (`copy_manga`)
- Baozi Manga (`baozi`)
- Komiic (`Komiic`)
- AiKanMan (`ikmmh`)

## Features

- Browse and search comics across configured sources
- Online reading with chapter history and boundary navigation
- Background downloads with resume, retry, and integrity checks
- Local and source-backed favorites
- WebDAV data synchronization
- Archive export and local library management

## Build

Install the Flutter version listed in `.flutter-version` (`3.44.0`), then run:

```shell
git clone https://github.com/liyw0205/PicaComic.git
cd PicaComic
flutter pub get --enforce-lockfile
flutter run
```

The Android release workflow builds and publishes only for tags matching `v*`.
The tag must match the package version in `pubspec.yaml`; ordinary branch pushes
run no Android release build.

Useful checks before submitting a change:

```shell
dart analyze
bash tool/check-analyzer-baseline.sh
bash tool/check-async-boundary.sh
bash tool/run_flutter_tests.sh
sh test/native_curl/run.sh
```

## Contributing

Open a bug report or feature request in the
[issue tracker](https://github.com/liyw0205/PicaComic/issues). Keep changes
focused, add a regression test for behavior changes, and do not commit local
development notes from `docs/`.

## Credits

The project originated from [wgh136/PicaComic](https://github.com/wgh136/PicaComic).
The JM image restructuring algorithm is adapted from
[JMComic-qt](https://github.com/tonquer/JMComic-qt). Tag translations use the
[EhTagTranslation database](https://github.com/EhTagTranslation/Database).
