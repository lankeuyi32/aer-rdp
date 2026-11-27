enum CredentialKind {
  account('account', '账号密码'),
  secretKey('secretKey', '密钥/口令');

  const CredentialKind(this.jsonValue, this.label);
  final String jsonValue;
  final String label;

  static CredentialKind? fromJson(Object? raw) {
    for (final kind in values) {
      if (kind.jsonValue == raw) return kind;
    }
    return null;
  }
}

/// Non-secret metadata for a reusable credential or secret key stored in the
/// user's vault. The actual password/key material is stored exclusively in
/// [CredentialVault] (Android Keystore / iOS Keychain) and never serialized to
/// JSON on disk.
class SavedCredential {
  const SavedCredential({
    required this.id,
    required this.name,
    this.kind = CredentialKind.account,
    this.username = '',
    this.domain = '',
    this.note = '',
    required this.updatedAt,
  });

  final String id;
  final String name;
  final CredentialKind kind;
  final String username;
  final String domain;
  final String note;
  final DateTime updatedAt;

  String get subtitle {
    if (kind == CredentialKind.account) {
      final userPart = domain.isEmpty ? username : '$domain\\$username';
      if (userPart.isNotEmpty && note.isNotEmpty) {
        return '$userPart · $note';
      }
      if (userPart.isNotEmpty) return userPart;
      if (note.isNotEmpty) return note;
      return '远程登录凭据';
    }
    return note.isNotEmpty ? note : '已加密保存的密钥/口令';
  }

  SavedCredential copyWith({
    String? id,
    String? name,
    CredentialKind? kind,
    String? username,
    String? domain,
    String? note,
    DateTime? updatedAt,
  }) {
    return SavedCredential(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      username: username ?? this.username,
      domain: domain ?? this.domain,
      note: note ?? this.note,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'kind': kind.jsonValue,
        'username': username,
        'domain': domain,
        'note': note,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  static SavedCredential? fromJsonMap(Map<String, dynamic> map) {
    final id = map['id'];
    final name = map['name'];
    if (id is! String || id.trim().isEmpty) return null;
    if (name is! String || name.trim().isEmpty) return null;

    // Reject if any forbidden plaintext secret field was injected.
    const forbidden = <String>{
      'password',
      'secret',
      'pass',
      'plaintextPassword',
      'token',
      'passwd',
      'privateKey',
    };
    for (final k in forbidden) {
      if (map.containsKey(k) && map[k] != null && map[k] != '') {
        return null;
      }
    }

    final kind = CredentialKind.fromJson(map['kind']) ?? CredentialKind.account;
    final username = map['username'] is String ? map['username'] as String : '';
    final domain = map['domain'] is String ? map['domain'] as String : '';
    final note = map['note'] is String ? map['note'] as String : '';
    final rawUpdated = map['updatedAt'];
    final updatedAt = (rawUpdated is String ? DateTime.tryParse(rawUpdated) : null)
            ?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    return SavedCredential(
      id: id.trim(),
      name: name.trim(),
      kind: kind,
      username: username,
      domain: domain,
      note: note,
      updatedAt: updatedAt,
    );
  }
}
