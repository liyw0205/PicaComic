import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/network/base_comic.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/network/source_network_policy.dart';

/// An operation used by an offline source contract case.
typedef ComicSourceContractOperation = Future<Object?> Function();

/// A named failure fixture and the category the source must expose.
class ComicSourceContractErrorCase {
  const ComicSourceContractErrorCase({
    required this.name,
    required this.operation,
    required this.expectedKind,
  });

  final String name;
  final ComicSourceContractOperation operation;
  final SourceNetworkErrorKind expectedKind;
}

/// A controlled error used by fixture sources to model cancellation and
/// source-specific failures without making a real request.
class ComicSourceContractException implements Exception {
  const ComicSourceContractException(this.kind, [this.message = 'fixture']);

  final SourceNetworkErrorKind kind;
  final String message;

  @override
  String toString() => 'ComicSourceContractException(${kind.name})';
}

/// One stable, machine-readable contract violation.
class ComicSourceContractViolation {
  const ComicSourceContractViolation(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// Result of validating a source definition and (optionally) its fixture.
class ComicSourceContractReport {
  const ComicSourceContractReport({
    required this.sourceKey,
    required this.violations,
    required this.pagesChecked,
    required this.emptyPages,
  });

  final String sourceKey;
  final List<ComicSourceContractViolation> violations;
  final List<int> pagesChecked;
  final List<int> emptyPages;

  bool get isValid => violations.isEmpty;
}

/// Reusable, network-free checks for the public ComicSource contract.
///
/// Definition checks are safe to run against [ComicSource.builtIn], because
/// they only inspect metadata and callback wiring. Runtime checks execute only
/// callbacks supplied by the source under test, which lets CI use redacted
/// fixture data instead of a live source endpoint.
class ComicSourceContract {
  const ComicSourceContract._();

  /// Checks metadata and callback wiring without invoking any network code.
  static List<ComicSourceContractViolation> validateDefinition(
      ComicSource source) {
    final violations = <ComicSourceContractViolation>[];
    final key = source.key.trim();
    if (key.isEmpty || !RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(key)) {
      violations.add(const ComicSourceContractViolation('invalid-key',
          'source key must contain only letters, numbers, and _'));
    }
    if (source.name.trim().isEmpty) {
      violations.add(const ComicSourceContractViolation(
          'missing-name', 'source name is empty'));
    }
    if (source.filePath.trim().isEmpty) {
      violations.add(const ComicSourceContractViolation(
          'missing-file-path', 'source file path is empty'));
    }
    if (source.searchPageData != null &&
        source.searchPageData!.loadPage == null &&
        source.searchPageData!.overrideSearchResultBuilder == null) {
      violations.add(const ComicSourceContractViolation(
          'missing-search-loader', 'search metadata has no page loader'));
    }
    // CategoryComicsData.load and AccountConfig.logout are required by the
    // public API, so their presence is enforced by the type system.
    return violations;
  }

  /// Runs an offline fixture against the source's search/detail/page API.
  ///
  /// An empty page is a valid terminal page. Duplicate comic IDs across pages,
  /// malformed detail records, and invalid image URLs are reported as stable
  /// violations. [errorCases] allows cancellation and transport/parse errors
  /// to be checked without opening a socket.
  static Future<ComicSourceContractReport> verify({
    required ComicSource source,
    String comicId = 'fixture-comic',
    String? episode = 'fixture-episode',
    String searchKeyword = 'fixture',
    List<String> searchOptions = const [],
    int maxPages = 8,
    List<ComicSourceContractErrorCase> errorCases = const [],
  }) async {
    final violations = <ComicSourceContractViolation>[
      ...validateDefinition(source),
    ];
    final pagesChecked = <int>[];
    final emptyPages = <int>[];

    if (maxPages < 1) {
      violations.add(const ComicSourceContractViolation(
          'invalid-page-limit', 'maxPages must be positive'));
    }

    final loader = source.searchPageData?.loadPage;
    if (loader != null && maxPages > 0) {
      final seenIds = <String>{};
      for (var page = 1; page <= maxPages; page++) {
        pagesChecked.add(page);
        Res<List<BaseComic>> result;
        try {
          result = await loader(searchKeyword, page, searchOptions);
        } catch (error) {
          violations.add(ComicSourceContractViolation(
              'search-page-throws', 'page $page threw ${error.runtimeType}'));
          break;
        }
        if (result.error) {
          violations.add(ComicSourceContractViolation('search-page-error',
              'page $page returned ${(_classifyResult(result) ?? SourceNetworkErrorKind.unknown).name}'));
          break;
        }
        final comics = result.dataOrNull;
        if (comics == null) {
          violations.add(ComicSourceContractViolation(
              'search-page-null', 'page $page returned no data'));
          break;
        }
        if (comics.isEmpty) {
          emptyPages.add(page);
          break;
        }
        for (final comic in comics) {
          final id = comic.id.trim();
          if (id.isEmpty) {
            violations.add(ComicSourceContractViolation(
                'comic-id-empty', 'page $page contains an empty comic id'));
          } else if (!seenIds.add(id)) {
            violations.add(ComicSourceContractViolation(
                'duplicate-comic', 'comic $id appears on more than one page'));
          }
          if (comic.title.trim().isEmpty) {
            violations.add(ComicSourceContractViolation(
                'comic-title-empty', 'comic $id has an empty title'));
          }
          if (comic.cover.trim().isEmpty) {
            violations.add(ComicSourceContractViolation(
                'comic-cover-empty', 'comic $id has an empty cover'));
          }
        }
        final subData = result.subData;
        if (subData != null && subData is! num) {
          violations.add(ComicSourceContractViolation(
              'invalid-max-page', 'page $page returned a non-numeric maxPage'));
        } else if (subData is num && subData <= 0) {
          violations.add(ComicSourceContractViolation('invalid-max-page',
              'page $page returned a non-positive maxPage'));
        } else if (subData is num && page >= subData) {
          break;
        }
      }
    }

    final detailLoader = source.loadComicInfo;
    if (detailLoader != null) {
      try {
        final result = await detailLoader(comicId);
        if (result.error) {
          violations.add(ComicSourceContractViolation('detail-error',
              'detail returned ${(_classifyResult(result) ?? SourceNetworkErrorKind.unknown).name}'));
        } else {
          final detail = result.dataOrNull;
          if (detail == null) {
            violations.add(const ComicSourceContractViolation(
                'detail-null', 'detail returned no data'));
          } else {
            _validateDetail(source, comicId, detail, violations);
          }
        }
      } catch (error) {
        violations.add(ComicSourceContractViolation(
            'detail-throws', 'detail threw ${error.runtimeType}'));
      }
    }

    final pagesLoader = source.loadComicPages;
    if (pagesLoader != null) {
      try {
        final result = await pagesLoader(comicId, episode);
        if (result.error) {
          violations.add(ComicSourceContractViolation('image-list-error',
              'image list returned ${(_classifyResult(result) ?? SourceNetworkErrorKind.unknown).name}'));
        } else {
          final images = result.dataOrNull;
          if (images == null) {
            violations.add(const ComicSourceContractViolation(
                'image-list-null', 'image list returned no data'));
          } else if (images.isEmpty) {
            violations.add(const ComicSourceContractViolation(
                'image-list-empty', 'image list is empty'));
          } else {
            for (var index = 0; index < images.length; index++) {
              final image = images[index].trim();
              if (image.isEmpty ||
                  _hasWhitespace(image) ||
                  Uri.tryParse(image) == null) {
                violations.add(ComicSourceContractViolation(
                    'image-url-invalid', 'image $index is not a valid URL'));
              }
            }
          }
        }
      } catch (error) {
        violations.add(ComicSourceContractViolation(
            'image-list-throws', 'image list threw ${error.runtimeType}'));
      }
    }

    for (final errorCase in errorCases) {
      SourceNetworkErrorKind? actual;
      try {
        final result = await errorCase.operation();
        actual = _classifyResult(result);
      } catch (error) {
        actual = _classifyError(error);
      }
      if (actual != errorCase.expectedKind) {
        violations.add(ComicSourceContractViolation(
            'error-kind-${errorCase.name}',
            'expected ${errorCase.expectedKind.name}, got ${actual?.name ?? 'success'}'));
      }
    }

    return ComicSourceContractReport(
      sourceKey: source.key,
      violations: List.unmodifiable(violations),
      pagesChecked: List.unmodifiable(pagesChecked),
      emptyPages: List.unmodifiable(emptyPages),
    );
  }

  static void _validateDetail(ComicSource source, String comicId,
      ComicInfoData detail, List<ComicSourceContractViolation> violations) {
    if (detail.title.trim().isEmpty) {
      violations.add(const ComicSourceContractViolation(
          'detail-title-empty', 'detail title is empty'));
    }
    if (detail.cover.trim().isEmpty) {
      violations.add(const ComicSourceContractViolation(
          'detail-cover-empty', 'detail cover is empty'));
    }
    if (detail.comicId != comicId) {
      violations.add(ComicSourceContractViolation('detail-id-mismatch',
          'expected comic id $comicId, got ${detail.comicId}'));
    }
    if (detail.sourceKey != source.key) {
      violations.add(ComicSourceContractViolation('detail-source-mismatch',
          'expected source ${source.key}, got ${detail.sourceKey}'));
    }
    detail.chapters?.forEach((chapter, chapterId) {
      if (chapter.trim().isEmpty || chapterId.trim().isEmpty) {
        violations.add(const ComicSourceContractViolation(
            'chapter-invalid', 'chapter names and ids must be non-empty'));
      }
    });
    detail.thumbnails?.asMap().forEach((index, thumbnail) {
      final value = thumbnail.trim();
      if (value.isEmpty ||
          _hasWhitespace(value) ||
          Uri.tryParse(value) == null) {
        violations.add(ComicSourceContractViolation(
            'thumbnail-url-invalid', 'thumbnail $index is not a valid URL'));
      }
    });
  }

  static SourceNetworkErrorKind? _classifyResult(Object? result) {
    if (result is Res && result.error) {
      return _classifyText(result.errorMessage);
    }
    if (result is ComicSourceContractException) return result.kind;
    if (result is SourceNetworkException) return result.kind;
    if (result is String) return _classifyText(result);
    return null;
  }

  static SourceNetworkErrorKind _classifyError(Object error) {
    if (error is ComicSourceContractException) return error.kind;
    final classified = SourceNetworkPolicy().classify(error);
    if (classified != SourceNetworkErrorKind.unknown) return classified;
    return _classifyText(error.toString()) ?? SourceNetworkErrorKind.unknown;
  }

  static SourceNetworkErrorKind? _classifyText(String? message) {
    if (message == null || message.trim().isEmpty) {
      return SourceNetworkErrorKind.unknown;
    }
    final text = message.toLowerCase();
    if (text.contains('cancel') || text.contains('abort')) {
      return SourceNetworkErrorKind.cancelled;
    }
    if (text.contains('429') || text.contains('rate limit')) {
      return SourceNetworkErrorKind.rateLimited;
    }
    if (text.contains('401') ||
        text.contains('403') ||
        text.contains('auth') ||
        text.contains('login')) {
      return SourceNetworkErrorKind.authentication;
    }
    if (text.contains('timeout') || text.contains('timed out')) {
      return SourceNetworkErrorKind.timeout;
    }
    if (text.contains('tls') || text.contains('certificate')) {
      return SourceNetworkErrorKind.tls;
    }
    if (text.contains('parse') ||
        text.contains('json') ||
        text.contains('format') ||
        text.contains('invalid')) {
      return SourceNetworkErrorKind.parse;
    }
    if (text.contains('circuit')) {
      return SourceNetworkErrorKind.circuitOpen;
    }
    if (text.contains('server') || RegExp(r'\b5\d{2}\b').hasMatch(text)) {
      return SourceNetworkErrorKind.server;
    }
    if (text.contains('connection') ||
        text.contains('network') ||
        text.contains('offline')) {
      return SourceNetworkErrorKind.connection;
    }
    return SourceNetworkErrorKind.unknown;
  }

  static bool _hasWhitespace(String value) => RegExp(r'\s').hasMatch(value);
}
