import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/connection_profile.dart';
import '../models/profile_validator.dart';

typedef DirectoryProvider = Future<Directory> Function();

class ProfileStore extends ChangeNotifier {
  ProfileStore({
    DirectoryProvider? directoryProvider,
    bool inMemoryOnly = false,
  })  : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
        _inMemoryOnly = inMemoryOnly;

  factory ProfileStore.inMemory([List<ConnectionProfile> initial = const []]) {
    final store = ProfileStore(inMemoryOnly: true);
    for (final p in initial) {
      store._profiles[p.id] = p;
    }
    return store;
  }

  final DirectoryProvider _directoryProvider;
  final bool _inMemoryOnly;
  final Map<String, ConnectionProfile> _profiles = <String, ConnectionProfile>{};
  bool _loaded = false;

  bool get isLoaded => _loaded;

  List<ConnectionProfile> get profiles {
    final list = _profiles.values.toList(growable: false);
    list.sort((a, b) {
      if (a.favorite != b.favorite) {
        return a.favorite ? -1 : 1;
      }
      final DateTime? aLast = a.lastConnectedAt;
      final DateTime? bLast = b.lastConnectedAt;
      if (aLast != null && bLast != null) {
        final cmp = bLast.compareTo(aLast);
        if (cmp != 0) return cmp;
      } else if (aLast != null || bLast != null) {
        return aLast != null ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return List<ConnectionProfile>.unmodifiable(list);
  }

  List<ConnectionProfile> search(String query) {
    final all = profiles;
    if (query.isEmpty) {
      return all;
    }
    final q = query.toLowerCase();
    return all
        .where(
          (p) =>
              p.name.toLowerCase().contains(q) ||
              p.host.toLowerCase().contains(q) ||
              p.username.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  ConnectionProfile? byId(String id) => _profiles[id];

  Future<File?> _resolveStorageFile() async {
    if (_inMemoryOnly) return null;
    try {
      final dir = await _directoryProvider();
      return File('${dir.path}${Platform.pathSeparator}profiles_v1.json');
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
      final result = ProfileValidator.validateBundleJson(raw);
      if (!result.isValid) {
        final backupPath =
            '${file.path}.corrupt.${DateTime.now().toUtc().millisecondsSinceEpoch}';
        await file.rename(backupPath);
        _profiles.clear();
      } else {
        _profiles
          ..clear()
          ..addEntries(result.profiles.map((p) => MapEntry(p.id, p)));
      }
    } catch (_) {
      // Keep cleanly initialized state on I/O failure.
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
    await tmp.writeAsString(exportBundleJson(), flush: true);
    await tmp.rename(file.path);
  }

  Future<void> upsert(ConnectionProfile profile) async {
    _profiles[profile.id] = profile;
    notifyListeners();
    await _persist();
  }

  Future<void> delete(String id) async {
    if (_profiles.remove(id) != null) {
      notifyListeners();
      await _persist();
    }
  }

  Future<void> toggleFavorite(String id) async {
    final existing = _profiles[id];
    if (existing == null) return;
    _profiles[id] = existing.copyWith(favorite: !existing.favorite);
    notifyListeners();
    await _persist();
  }

  Future<void> markConnected(String id, DateTime when) async {
    final existing = _profiles[id];
    if (existing == null) return;
    _profiles[id] = existing.copyWith(lastConnectedAt: when.toUtc());
    notifyListeners();
    await _persist();
  }

  String exportBundleJson() {
    return ProfileBundleV1(profiles: profiles).toPrettyJson();
  }

  Future<ProfileBundleValidationResult> importBundleJson(
    String rawJson, {
    bool mergeById = true,
  }) async {
    final result = ProfileValidator.validateBundleJson(rawJson);
    if (!result.isValid) {
      return result;
    }
    if (!mergeById) {
      _profiles.clear();
    }
    for (final profile in result.profiles) {
      _profiles[profile.id] = profile;
    }
    notifyListeners();
    await _persist();
    return result;
  }
}
