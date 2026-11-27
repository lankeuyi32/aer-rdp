import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

typedef QuickHistoryDirectoryProvider = Future<Directory> Function();

class QuickConnectEntry {
  const QuickConnectEntry({
    required this.id,
    required this.host,
    this.port = 3389,
    this.username = '',
    this.domain = '',
    this.credentialId,
    this.hasSavedPassword = false,
    required this.lastConnectedAt,
  });

  final String id;
  final String host;
  final int port;
  final String username;
  final String domain;
  final String? credentialId;
  final bool hasSavedPassword;
  final DateTime lastConnectedAt;

  String get endpointKey => '${host.trim().toLowerCase()}:$port';

  QuickConnectEntry copyWith({
    String? id,
    String? host,
    int? port,
    String? username,
    String? domain,
    String? credentialId,
    bool clearCredentialId = false,
    bool? hasSavedPassword,
    DateTime? lastConnectedAt,
  }) {
    return QuickConnectEntry(
      id: id ?? this.id,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      domain: domain ?? this.domain,
      credentialId:
          clearCredentialId ? null : (credentialId ?? this.credentialId),
      hasSavedPassword: hasSavedPassword ?? this.hasSavedPassword,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'host': host,
        'port': port,
        'username': username,
        'domain': domain,
        'credentialId': credentialId,
        'hasSavedPassword': hasSavedPassword,
        'lastConnectedAt': lastConnectedAt.toUtc().toIso8601String(),
      };

  static QuickConnectEntry? fromJsonMap(Map<String, dynamic> map) {
    final id = map['id'];
    final host = map['host'];
    final port = map['port'];
    if (id is! String || id.trim().isEmpty) return null;
    if (host is! String || host.trim().isEmpty) return null;
    if (port is! int || port < 1 || port > 65535) return null;

    // Never accept plaintext secrets in history JSON.
    if (map.containsKey('password') &&
        map['password'] != null &&
        map['password'] != '') {
      return null;
    }

    final username = map['username'] is String ? map['username'] as String : '';
    final domain = map['domain'] is String ? map['domain'] as String : '';
    final rawCredId = map['credentialId'];
    final String? credentialId =
        (rawCredId is String && rawCredId.trim().isNotEmpty)
            ? rawCredId.trim()
            : null;
    final hasSavedPassword = map['hasSavedPassword'] == true;
    final rawLast = map['lastConnectedAt'];
    final lastConnectedAt =
        (rawLast is String ? DateTime.tryParse(rawLast) : null)?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    return QuickConnectEntry(
      id: id.trim(),
      host: host.trim(),
      port: port,
      username: username,
      domain: domain,
      credentialId: credentialId,
      hasSavedPassword: hasSavedPassword,
      lastConnectedAt: lastConnectedAt,
    );
  }
}

class QuickConnectHistoryStore extends ChangeNotifier {
  QuickConnectHistoryStore({
    QuickHistoryDirectoryProvider? directoryProvider,
    bool inMemoryOnly = false,
    this.maxEntries = 20,
  })  : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
        _inMemoryOnly = inMemoryOnly;

  factory QuickConnectHistoryStore.inMemory([
    List<QuickConnectEntry> initial = const <QuickConnectEntry>[],
  ]) {
    final store = QuickConnectHistoryStore(inMemoryOnly: true);
    store._entries.addAll(initial);
    store._sortAndTrim();
    return store;
  }

  final QuickHistoryDirectoryProvider _directoryProvider;
  final bool _inMemoryOnly;
  final int maxEntries;
  final List<QuickConnectEntry> _entries = <QuickConnectEntry>[];
  bool _loaded = false;

  bool get isLoaded => _loaded;

  List<QuickConnectEntry> get entries =>
      List<QuickConnectEntry>.unmodifiable(_entries);

  void _sortAndTrim() {
    _entries.sort((a, b) => b.lastConnectedAt.compareTo(a.lastConnectedAt));
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
  }

  Future<File?> _resolveStorageFile() async {
    if (_inMemoryOnly) return null;
    try {
      final dir = await _directoryProvider();
      return File(
        '${dir.path}${Platform.pathSeparator}quick_connect_history_v1.json',
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
      if (decoded is Map<String, dynamic> && decoded['entries'] is List) {
        final rawList = decoded['entries'] as List<Object?>;
        _entries.clear();
        final seenKeys = <String>{};
        for (final item in rawList) {
          if (item is Map<String, dynamic>) {
            final parsed = QuickConnectEntry.fromJsonMap(item);
            if (parsed != null && seenKeys.add(parsed.endpointKey)) {
              _entries.add(parsed);
            }
          }
        }
        _sortAndTrim();
      }
    } catch (_) {
      // Ignore corrupt history and start fresh.
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
      'entries': _entries.map((e) => e.toJson()).toList(growable: false),
    });
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  /// Records or updates a quick-connect endpoint (deduplicated by `host:port`)
  /// and returns the resulting [QuickConnectEntry] plus any evicted entry IDs.
  Future<(QuickConnectEntry, List<String>)> recordConnection({
    required String host,
    required int port,
    String username = '',
    String domain = '',
    String? credentialId,
    bool hasSavedPassword = false,
    DateTime? connectedAt,
  }) async {
    final normalizedKey = '${host.trim().toLowerCase()}:$port';
    final existingIdx =
        _entries.indexWhere((e) => e.endpointKey == normalizedKey);
    final now = (connectedAt ?? DateTime.now()).toUtc();

    final QuickConnectEntry updated;
    if (existingIdx >= 0) {
      final prev = _entries.removeAt(existingIdx);
      updated = prev.copyWith(
        host: host.trim(),
        port: port,
        username: username.trim(),
        domain: domain.trim(),
        credentialId: credentialId,
        clearCredentialId: credentialId == null,
        hasSavedPassword: hasSavedPassword,
        lastConnectedAt: now,
      );
    } else {
      updated = QuickConnectEntry(
        id: 'qch-${now.microsecondsSinceEpoch}',
        host: host.trim(),
        port: port,
        username: username.trim(),
        domain: domain.trim(),
        credentialId: credentialId,
        hasSavedPassword: hasSavedPassword,
        lastConnectedAt: now,
      );
    }

    _entries.insert(0, updated);
    final evictedIds = <String>[];
    if (_entries.length > maxEntries) {
      for (final evicted in _entries.sublist(maxEntries)) {
        evictedIds.add(evicted.id);
      }
      _entries.removeRange(maxEntries, _entries.length);
    }

    notifyListeners();
    await _persist();
    return (updated, evictedIds);
  }

  Future<void> detachCredentialId(String credentialId) async {
    bool changed = false;
    for (int i = 0; i < _entries.length; i++) {
      if (_entries[i].credentialId == credentialId) {
        _entries[i] = _entries[i].copyWith(clearCredentialId: true);
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      await _persist();
    }
  }

  Future<QuickConnectEntry?> removeById(String id) async {
    final idx = _entries.indexWhere((e) => e.id == id);
    if (idx < 0) return null;
    final removed = _entries.removeAt(idx);
    notifyListeners();
    await _persist();
    return removed;
  }

  Future<List<String>> clearAll() async {
    if (_entries.isEmpty) return const <String>[];
    final ids = _entries.map((e) => e.id).toList(growable: false);
    _entries.clear();
    notifyListeners();
    await _persist();
    return ids;
  }
}
