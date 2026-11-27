import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/saved_credential.dart';

typedef SavedCredentialDirectoryProvider = Future<Directory> Function();

class SavedCredentialStore extends ChangeNotifier {
  SavedCredentialStore({
    SavedCredentialDirectoryProvider? directoryProvider,
    bool inMemoryOnly = false,
  })  : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
        _inMemoryOnly = inMemoryOnly;

  factory SavedCredentialStore.inMemory([
    List<SavedCredential> initial = const <SavedCredential>[],
  ]) {
    final store = SavedCredentialStore(inMemoryOnly: true);
    for (final item in initial) {
      store._items[item.id] = item;
    }
    return store;
  }

  final SavedCredentialDirectoryProvider _directoryProvider;
  final bool _inMemoryOnly;
  final Map<String, SavedCredential> _items = <String, SavedCredential>{};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  List<SavedCredential> get items {
    final list = _items.values.toList(growable: false);
    list.sort((a, b) {
      final cmp = b.updatedAt.compareTo(a.updatedAt);
      if (cmp != 0) return cmp;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return List<SavedCredential>.unmodifiable(list);
  }

  List<SavedCredential> get accountItems => items
      .where((c) => c.kind == CredentialKind.account)
      .toList(growable: false);

  SavedCredential? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    return _items[id];
  }

  Future<File?> _resolveStorageFile() async {
    if (_inMemoryOnly) return null;
    try {
      final dir = await _directoryProvider();
      return File(
        '${dir.path}${Platform.pathSeparator}saved_credentials_v1.json',
      );
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
      if (decoded is Map<String, dynamic> && decoded['items'] is List) {
        final rawList = decoded['items'] as List<Object?>;
        _items.clear();
        for (final entry in rawList) {
          if (entry is Map<String, dynamic>) {
            final parsed = SavedCredential.fromJsonMap(entry);
            if (parsed != null) {
              _items[parsed.id] = parsed;
            }
          }
        }
      }
    } catch (_) {
      // Keep clean state on corrupt metadata.
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
    final encoded = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'version': 1,
      'items': items.map((e) => e.toJson()).toList(growable: false),
    });
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> upsert(SavedCredential item) async {
    _items[item.id] = item;
    notifyListeners();
    await _persist();
  }

  Future<void> delete(String id) async {
    if (_items.remove(id) != null) {
      notifyListeners();
      await _persist();
    }
  }
}
