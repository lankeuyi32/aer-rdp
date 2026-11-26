import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef TrustDirectoryProvider = Future<Directory> Function();

class CertTrustStore extends ChangeNotifier {
  CertTrustStore({
    TrustDirectoryProvider? directoryProvider,
    bool inMemoryOnly = false,
  })  : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
        _inMemoryOnly = inMemoryOnly;

  factory CertTrustStore.inMemory([Map<String, String> initial = const {}]) {
    final store = CertTrustStore(inMemoryOnly: true);
    initial.forEach((k, v) {
      store._pins[k.toLowerCase()] = normalizeFingerprint(v);
    });
    return store;
  }

  final TrustDirectoryProvider _directoryProvider;
  final bool _inMemoryOnly;
  final Map<String, String> _pins = <String, String>{};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  static String endpointKey(String host, int port) =>
      '${host.trim().toLowerCase()}:$port';

  static String normalizeFingerprint(String raw) {
    var trimmed = raw.trim();
    if (trimmed.toLowerCase().startsWith('sha256:')) {
      trimmed = trimmed.substring(7);
    }
    return trimmed
        .replaceAll(RegExp(r'[^0-9a-fA-F]'), '')
        .toLowerCase();
  }

  String? getPinnedFingerprint(String host, int port) {
    return _pins[endpointKey(host, port)];
  }

  Future<File?> _resolveStorageFile() async {
    if (_inMemoryOnly) return null;
    try {
      final dir = await _directoryProvider();
      return File('${dir.path}${Platform.pathSeparator}cert_trust_v1.json');
    } on MissingPluginException {
      return null;
    } on UnimplementedError {
      return null;
    } on UnsupportedError {
      return null;
    }
  }

  Future<void> load() async {
    final file = await _resolveStorageFile();
    if (file == null) {
      _loaded = true;
      notifyListeners();
      return;
    }
    try {
      if (!await file.exists()) {
        _loaded = true;
        notifyListeners();
        return;
      }
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['pins'] is Map) {
        final rawPins = decoded['pins'] as Map<Object?, Object?>;
        _pins.clear();
        rawPins.forEach((k, v) {
          if (k is String && v is String) {
            final norm = normalizeFingerprint(v);
            if (norm.length == 64) {
              _pins[k.toLowerCase()] = norm;
            }
          }
        });
      }
    } catch (_) {
      // Ignore corrupt trust store and start empty cleanly.
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final file = await _resolveStorageFile();
    if (file == null) return;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    final encoded = jsonEncode(<String, Object?>{
      'version': 1,
      'pins': _pins,
    });
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> trustFingerprint(String host, int port, String sha256Hex) async {
    final normalized = normalizeFingerprint(sha256Hex);
    if (normalized.isEmpty) return;
    _pins[endpointKey(host, port)] = normalized;
    notifyListeners();
    await _persist();
  }

  Future<void> clearFingerprint(String host, int port) async {
    if (_pins.remove(endpointKey(host, port)) != null) {
      notifyListeners();
      await _persist();
    }
  }
}
