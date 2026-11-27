import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/saved_credential.dart';
import '../../services/cert_trust_store.dart';
import '../../services/credential_vault.dart';
import '../../services/saved_credential_store.dart';
import '../aer_keys.dart';
import '../common/adaptive_dialog.dart';

class CredentialVaultDialog extends StatefulWidget {
  const CredentialVaultDialog({
    super.key,
    required this.savedCredentialStore,
    required this.credentialVault,
    this.certTrustStore,
    this.onCredentialDeleted,
  });

  final SavedCredentialStore savedCredentialStore;
  final CredentialVault credentialVault;
  final CertTrustStore? certTrustStore;
  final ValueChanged<String>? onCredentialDeleted;

  @override
  State<CredentialVaultDialog> createState() => _CredentialVaultDialogState();
}

class _CredentialVaultDialogState extends State<CredentialVaultDialog> {
  CredentialKind? _filterKind; // null == all
  final Map<String, String> _revealedSecrets = <String, String>{};

  @override
  void initState() {
    super.initState();
    widget.savedCredentialStore.addListener(_onChanged);
    widget.certTrustStore?.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.savedCredentialStore.removeListener(_onChanged);
    widget.certTrustStore?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openCreateOrEdit([SavedCredential? existing]) async {
    String initialSecret = '';
    if (existing != null) {
      initialSecret =
          await widget.credentialVault.loadVaultSecret(existing.id) ?? '';
    }
    if (!mounted) return;

    final res = await showDialog<_CredentialEditResult>(
      context: context,
      builder: (_) => _CredentialEditDialog(
        existing: existing,
        initialSecret: initialSecret,
      ),
    );
    if (res == null) return;

    await widget.savedCredentialStore.upsert(res.item);
    await widget.credentialVault.saveVaultSecret(res.item.id, res.secret);
    if (mounted && _revealedSecrets.containsKey(res.item.id)) {
      setState(() {
        _revealedSecrets[res.item.id] = res.secret;
      });
    }
  }

  Future<void> _toggleReveal(SavedCredential item) async {
    if (_revealedSecrets.containsKey(item.id)) {
      setState(() {
        _revealedSecrets.remove(item.id);
      });
      return;
    }
    final secret = await widget.credentialVault.loadVaultSecret(item.id);
    if (!mounted) return;
    setState(() {
      _revealedSecrets[item.id] = secret ?? '';
    });
  }

  Future<void> _copySecret(SavedCredential item) async {
    final secret = await widget.credentialVault.loadVaultSecret(item.id);
    if (secret == null || secret.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: secret));
    } catch (_) {
      // Clipboard may be unavailable in headless tests.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          item.kind == CredentialKind.account
              ? '已复制「${item.name}」的密码'
              : '已复制「${item.name}」的密钥内容',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deleteItem(SavedCredential item) async {
    await widget.savedCredentialStore.delete(item.id);
    await widget.credentialVault.deleteVaultSecret(item.id);
    _revealedSecrets.remove(item.id);
    widget.onCredentialDeleted?.call(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final allItems = widget.savedCredentialStore.items;
    final filtered = _filterKind == null
        ? allItems
        : allItems.where((e) => e.kind == _filterKind).toList(growable: false);
    final pinnedCerts =
        widget.certTrustStore?.entries ?? const <MapEntry<String, String>>[];

    return AdaptiveDialogShell(
      key: AerKeys.credentialVaultDialog,
      maxWidth: 520,
      title: const Text('凭据与密钥库'),
      titleTrailing: FilledButton.tonalIcon(
        key: AerKeys.credentialVaultAddButton,
        onPressed: () => _openCreateOrEdit(),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('新增'),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selected: _filterKind == null,
                label: Text('全部 (${allItems.length})'),
                onSelected: (_) => setState(() => _filterKind = null),
              ),
              ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selected: _filterKind == CredentialKind.account,
                label: const Text('账号密码'),
                onSelected: (_) =>
                    setState(() => _filterKind = CredentialKind.account),
              ),
              ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selected: _filterKind == CredentialKind.secretKey,
                label: const Text('密钥/口令'),
                onSelected: (_) =>
                    setState(() => _filterKind = CredentialKind.secretKey),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (filtered.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.key_outlined, size: 36, color: cs.primary),
                  const SizedBox(height: 8),
                  Text(
                    '暂无已保存的密码或密钥',
                    style: theme.textTheme.titleSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '保存在此处的账号密码可在添加设备或快速连接时一键选用；密钥与口令均使用系统级安全存储加密。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          else
            ...filtered.map((item) {
              final revealed = _revealedSecrets[item.id];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: cs.outlineVariant),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            item.kind == CredentialKind.account
                                ? Icons.badge_outlined
                                : Icons.vpn_key_outlined,
                            size: 20,
                            color: cs.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  item.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: revealed != null ? '隐藏内容' : '查看内容',
                            icon: Icon(
                              revealed != null
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 18,
                            ),
                            onPressed: () => _toggleReveal(item),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '复制密码/密钥',
                            icon: const Icon(Icons.copy_outlined, size: 18),
                            onPressed: () => _copySecret(item),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '编辑',
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () => _openCreateOrEdit(item),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () => _deleteItem(item),
                          ),
                        ],
                      ),
                      if (revealed != null) ...[
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SelectableText(
                            revealed.isEmpty ? '(空)' : revealed,
                            maxLines: 4,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }),
          if (pinnedCerts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '已信任主机证书指纹 (${pinnedCerts.length})',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            ...pinnedCerts.map((entry) {
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.verified_user_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            entry.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'SHA-256: ${entry.value.substring(0, 16)}…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '移除证书信任',
                      icon: const Icon(Icons.link_off, size: 18),
                      onPressed: () {
                        widget.certTrustStore?.removeEndpointKey(entry.key);
                      },
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

class _CredentialEditResult {
  const _CredentialEditResult({
    required this.item,
    required this.secret,
  });

  final SavedCredential item;
  final String secret;
}

class _CredentialEditDialog extends StatefulWidget {
  const _CredentialEditDialog({
    this.existing,
    this.initialSecret = '',
  });

  final SavedCredential? existing;
  final String initialSecret;

  @override
  State<_CredentialEditDialog> createState() => _CredentialEditDialogState();
}

class _CredentialEditDialogState extends State<_CredentialEditDialog> {
  late CredentialKind _kind;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _domainCtrl;
  late final TextEditingController _secretCtrl;
  late final TextEditingController _noteCtrl;

  bool _obscureSecret = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _kind = existing?.kind ?? CredentialKind.account;
    _nameCtrl = TextEditingController(text: existing?.name ?? '');
    _userCtrl = TextEditingController(text: existing?.username ?? '');
    _domainCtrl = TextEditingController(text: existing?.domain ?? '');
    _secretCtrl = TextEditingController(text: widget.initialSecret);
    _noteCtrl = TextEditingController(text: existing?.note ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _userCtrl.dispose();
    _domainCtrl.dispose();
    _secretCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称或备注别名');
      return;
    }
    if (_kind == CredentialKind.account && _userCtrl.text.trim().isEmpty) {
      setState(() => _error = '账号密码类型请填写用户名');
      return;
    }
    if (_secretCtrl.text.isEmpty) {
      setState(
        () => _error =
            _kind == CredentialKind.account ? '请填写密码' : '请填写密钥或口令内容',
      );
      return;
    }

    final now = DateTime.now().toUtc();
    final item = SavedCredential(
      id: widget.existing?.id ?? 'cred-${now.microsecondsSinceEpoch}',
      name: name,
      kind: _kind,
      username: _kind == CredentialKind.account ? _userCtrl.text.trim() : '',
      domain: _kind == CredentialKind.account ? _domainCtrl.text.trim() : '',
      note: _noteCtrl.text.trim(),
      updatedAt: now,
    );

    Navigator.of(context).pop(
      _CredentialEditResult(item: item, secret: _secretCtrl.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final cs = Theme.of(context).colorScheme;
    final isAccount = _kind == CredentialKind.account;

    return AdaptiveDialogShell(
      maxWidth: 440,
      title: Text(isEdit ? '编辑凭据 / 密钥' : '新增凭据 / 密钥'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: AerKeys.credentialFormSaveButton,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          ),
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: cs.onErrorContainer, fontSize: 12.5),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: CredentialKind.values.map((k) {
              return ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selected: _kind == k,
                label: Text(k.label),
                onSelected: (_) => setState(() => _kind = k),
              );
            }).toList(growable: false),
          ),
          const SizedBox(height: 10),
          TextField(
            key: AerKeys.credentialFormName,
            controller: _nameCtrl,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: isAccount ? '凭据名称 (如: 家里主力机)' : '密钥名称 (如: SSH 私钥 / 恢复码)',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          if (isAccount) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: AerKeys.credentialFormUser,
                    controller: _userCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: AerKeys.credentialFormDomain,
                    controller: _domainCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: '域 (选填)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            key: AerKeys.credentialFormSecret,
            controller: _secretCtrl,
            obscureText: isAccount ? _obscureSecret : (_obscureSecret && _secretCtrl.text.length < 80),
            minLines: isAccount ? 1 : (_obscureSecret ? 1 : 3),
            maxLines: isAccount ? 1 : (_obscureSecret ? 1 : 6),
            decoration: InputDecoration(
              labelText: isAccount ? '密码' : '密钥 / 私钥 / 口令内容',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _obscureSecret
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
                onPressed: () =>
                    setState(() => _obscureSecret = !_obscureSecret),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: AerKeys.credentialFormNote,
            controller: _noteCtrl,
            decoration: const InputDecoration(
              labelText: '备注说明 (选填)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}
