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
  static const String _vaultPrefix = 'aer_rdp_vault_';
  static const String _quickPrefix = 'aer_rdp_quick_';
  final SecretStorageBackend _backend;
  bool _inMemoryOnly;
  final Map<String, String> _memory = <String, String>{};

  String _storageKey(String profileId) => '$_keyPrefix$profileId';
  String _vaultKey(String credentialId) => '$_vaultPrefix$credentialId';
  String _quickKey(String historyId) => '$_quickPrefix$historyId';

  Future<void> _writeRaw(String key, String secret) async {
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

  Future<String?> _readRaw(String key) async {
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

  Future<void> _deleteRaw(String key) async {
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

  Future<void> savePassword(String profileId, String secret) =>
      _writeRaw(_storageKey(profileId), secret);

  Future<String?> loadPassword(String profileId) =>
      _readRaw(_storageKey(profileId));

  Future<void> deletePassword(String profileId) =>
      _deleteRaw(_storageKey(profileId));

  Future<void> saveVaultSecret(String credentialId, String secret) =>
      _writeRaw(_vaultKey(credentialId), secret);

  Future<String?> loadVaultSecret(String credentialId) =>
      _readRaw(_vaultKey(credentialId));

  Future<void> deleteVaultSecret(String credentialId) =>
      _deleteRaw(_vaultKey(credentialId));

  Future<void> saveQuickConnectPassword(String historyId, String secret) =>
      _writeRaw(_quickKey(historyId), secret);

  Future<String?> loadQuickConnectPassword(String historyId) =>
      _readRaw(_quickKey(historyId));

  Future<void> deleteQuickConnectPassword(String historyId) =>
      _deleteRaw(_quickKey(historyId));
}
