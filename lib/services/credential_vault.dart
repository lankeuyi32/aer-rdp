import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SecretStorageBackend {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
}

class FlutterSecureStorageBackend implements SecretStorageBackend {
  const FlutterSecureStorageBackend([
    FlutterSecureStorage? storage,
  ]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> write({required String key, required String value}) {
    return _storage.write(key: key, value: value);
  }

  @override
  Future<String?> read({required String key}) {
    return _storage.read(key: key);
  }

  @override
  Future<void> delete({required String key}) {
    return _storage.delete(key: key);
  }
}

class CredentialVault {
  CredentialVault({
    SecretStorageBackend? backend,
    bool inMemoryOnly = false,
  })  : _backend = backend ?? const FlutterSecureStorageBackend(),
        _inMemoryOnly = inMemoryOnly;

  factory CredentialVault.inMemory() => CredentialVault(inMemoryOnly: true);

  static const String _keyPrefix = 'aer_rdp_cred_';
  final SecretStorageBackend _backend;
  bool _inMemoryOnly;
  final Map<String, String> _memory = <String, String>{};

  String _storageKey(String profileId) => '$_keyPrefix$profileId';

  Future<void> savePassword(String profileId, String secret) async {
    final key = _storageKey(profileId);
    _memory[key] = secret;
    if (_inMemoryOnly) return;
    try {
      await _backend.write(key: key, value: secret);
    } on MissingPluginException {
      _inMemoryOnly = true;
    } on UnimplementedError {
      _inMemoryOnly = true;
    } on PlatformException {
      // Keep in-memory copy for current session if keystore is unavailable.
    }
  }

  Future<String?> loadPassword(String profileId) async {
    final key = _storageKey(profileId);
    if (_inMemoryOnly) {
      return _memory[key];
    }
    try {
      final val = await _backend.read(key: key);
      if (val != null) {
        _memory[key] = val;
        return val;
      }
      return _memory[key];
    } on MissingPluginException {
      _inMemoryOnly = true;
      return _memory[key];
    } on UnimplementedError {
      _inMemoryOnly = true;
      return _memory[key];
    } on PlatformException {
      return _memory[key];
    }
  }

  Future<void> deletePassword(String profileId) async {
    final key = _storageKey(profileId);
    _memory.remove(key);
    if (_inMemoryOnly) return;
    try {
      await _backend.delete(key: key);
    } on MissingPluginException {
      _inMemoryOnly = true;
    } on UnimplementedError {
      _inMemoryOnly = true;
    } on PlatformException {
      // Memory entry already removed.
    }
  }
}
