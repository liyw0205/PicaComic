import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage boundary for values which must not be part of ordinary settings.
///
/// Platform-backed implementations can be installed without changing callers.
abstract interface class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

/// Private-file fallback used until native Keystore/Keychain adapters are
/// available. It intentionally has a narrow API so a secure implementation
/// can replace it without changing migration or WebDAV code.
/// Uses Android Keystore, iOS/macOS Keychain, and the corresponding secure
/// storage backend on supported desktop platforms.
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class SecretStoreRegistry {
  SecretStoreRegistry._();

  static SecretStore instance = MemorySecretStore();

  static void configure(SecretStore store) {
    instance = store;
  }
}

const webdavUsernameSecret = 'webdav.username';
const webdavPasswordSecret = 'webdav.password';

String redactUriCredentials(String value) {
  if (value.isEmpty) return value;
  final at = value.lastIndexOf('@');
  try {
    final uri = Uri.parse(value);
    if (uri.userInfo.isEmpty) {
      return at >= 0 ? value.substring(at + 1) : value;
    }
    return uri.replace(userInfo: '').toString();
  } catch (_) {
    return at >= 0 ? value.substring(at + 1) : value;
  }
}

/// Returns settings safe for a normal user export. The positions remain
/// stable for older clients, but credentials are never copied into the archive.
List<String> redactSettingsForExport(Iterable<String> source) {
  final values = List<String>.from(source);
  if (values.length > 45) {
    final webdav = values[45].split(';');
    values[45] = webdav.length == 4 ? '${webdav[0]};;;${webdav[3]}' : '';
  }
  for (final index in const [8, 90]) {
    if (values.length > index) {
      values[index] = redactUriCredentials(values[index]);
    }
  }
  return values;
}
