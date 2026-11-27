import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../../models/profile_validator.dart';
import '../../models/saved_credential.dart';
import '../../services/credential_vault.dart';
import '../../services/quick_connect_history_store.dart';
import '../../services/saved_credential_store.dart';
import '../aer_keys.dart';
import '../common/adaptive_dialog.dart';

class QuickConnectResult {
  const QuickConnectResult({
    required this.profile,
    required this.password,
    this.rememberPassword = true,
  });

  final ConnectionProfile profile;
  final String password;
  final bool rememberPassword;
}

class QuickConnectDialog extends StatefulWidget {
  const QuickConnectDialog({
    super.key,
    this.historyStore,
    this.savedCredentialStore,
    this.credentialVault,
  });

  final QuickConnectHistoryStore? historyStore;
  final SavedCredentialStore? savedCredentialStore;
  final CredentialVault? credentialVault;

  @override
  State<QuickConnectDialog> createState() => _QuickConnectDialogState();
}

class _QuickConnectDialogState extends State<QuickConnectDialog> {
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController(text: '3389');
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _domainCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();

  String? _selectedCredentialId;
  bool _rememberPassword = true;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    widget.historyStore?.addListener(_onStoreChanged);
    widget.savedCredentialStore?.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    widget.historyStore?.removeListener(_onStoreChanged);
    widget.savedCredentialStore?.removeListener(_onStoreChanged);
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _domainCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _applyHistoryEntry(
    QuickConnectEntry entry, {
    required bool connectImmediately,
  }) async {
    _hostCtrl.text = entry.host;
    _portCtrl.text = '${entry.port}';
    _userCtrl.text = entry.username;
    _domainCtrl.text = entry.domain;

    final String? validCredId =
        widget.savedCredentialStore?.byId(entry.credentialId) != null
            ? entry.credentialId
            : null;
    _selectedCredentialId = validCredId;

    String loadedPw = '';
    if (validCredId == null &&
        entry.hasSavedPassword &&
        widget.credentialVault != null) {
      loadedPw =
          await widget.credentialVault!.loadQuickConnectPassword(entry.id) ??
              '';
    }
    if (!mounted) return;
    setState(() {
      _passwordCtrl.text = loadedPw;
      _rememberPassword = entry.hasSavedPassword || validCredId != null;
      _errorMessage = null;
    });

    if (connectImmediately) {
      _connect();
    }
  }

  Future<void> _removeHistoryEntry(QuickConnectEntry entry) async {
    await widget.historyStore?.removeById(entry.id);
    await widget.credentialVault?.deleteQuickConnectPassword(entry.id);
  }

  Future<void> _clearAllHistory() async {
    final ids = await widget.historyStore?.clearAll() ?? const <String>[];
    final vault = widget.credentialVault;
    if (vault != null) {
      for (final id in ids) {
        await vault.deleteQuickConnectPassword(id);
      }
    }
  }

  void _selectCredential(SavedCredential? cred) {
    setState(() {
      _selectedCredentialId = cred?.id;
      if (cred != null && cred.kind == CredentialKind.account) {
        if (cred.username.isNotEmpty) {
          _userCtrl.text = cred.username;
        }
        _domainCtrl.text = cred.domain;
      }
    });
  }

  void _connect() {
    final hostError = ProfileValidator.validateHost(_hostCtrl.text);
    if (hostError != null) {
      setState(() => _errorMessage = hostError);
      return;
    }
    final port = ProfileValidator.parseValidPort(_portCtrl.text);
    if (port == null) {
      setState(() => _errorMessage = 'Port must be between 1 and 65535');
      return;
    }

    final host = _hostCtrl.text.trim();
    final bool useVaultCred = _selectedCredentialId != null;
    final pw = useVaultCred ? '' : _passwordCtrl.text;
    final profile = ConnectionProfile(
      id: 'quick-${DateTime.now().microsecondsSinceEpoch}',
      name: host,
      host: host,
      port: port,
      username: _userCtrl.text.trim(),
      domain: _domainCtrl.text.trim(),
      credentialId: _selectedCredentialId,
      authMode:
          (useVaultCred || pw.isNotEmpty) ? AuthMode.saved : AuthMode.prompt,
    );

    Navigator.of(context).pop(
      QuickConnectResult(
        profile: profile,
        password: pw,
        rememberPassword: _rememberPassword,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final historyEntries =
        widget.historyStore?.entries ?? const <QuickConnectEntry>[];
    final savedCreds =
        widget.savedCredentialStore?.items ?? const <SavedCredential>[];
    final bool useVaultCred = _selectedCredentialId != null;

    return AdaptiveDialogShell(
      maxWidth: 440,
      heightFactor: 0.70,
      title: const Text('快速连接'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: AerKeys.profileFormSave,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          ),
          onPressed: _connect,
          child: const Text('连接'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_errorMessage != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: cs.onErrorContainer, fontSize: 12.5),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (historyEntries.isNotEmpty) ...[
            Container(
              key: AerKeys.quickConnectHistorySection,
              padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.history, size: 16, color: cs.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '最近连接记录 (${historyEntries.length})',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: _clearAllHistory,
                        child: const Text('清空', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ...historyEntries.take(6).map((entry) {
                    final linkedCred =
                        widget.savedCredentialStore?.byId(entry.credentialId);
                    final String sub = linkedCred != null
                        ? '凭据: ${linkedCred.name}'
                        : entry.username.isNotEmpty
                            ? (entry.domain.isEmpty
                                ? entry.username
                                : '${entry.domain}\\${entry.username}')
                            : '连接时输入账号';
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _applyHistoryEntry(
                        entry,
                        connectImmediately: false,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${entry.host}:${entry.port}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    sub,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: cs.onSurfaceVariant,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: '直接连接',
                              icon: Icon(
                                Icons.play_circle_outline,
                                size: 20,
                                color: cs.primary,
                              ),
                              onPressed: () => _applyHistoryEntry(
                                entry,
                                connectImmediately: true,
                              ),
                            ),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: '删除记录',
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () => _removeHistoryEntry(entry),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: AerKeys.profileFormHost,
                  controller: _hostCtrl,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '主机地址 / IP',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 86,
                child: TextField(
                  key: AerKeys.profileFormPort,
                  controller: _portCtrl,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          if (savedCreds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  selected: _selectedCredentialId == null,
                  label: const Text('手动输入密码'),
                  onSelected: (_) => _selectCredential(null),
                ),
                ...savedCreds.map((c) {
                  return ChoiceChip(
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selected: _selectedCredentialId == c.id,
                    label: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onSelected: (_) => _selectCredential(c),
                  );
                }),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: AerKeys.profileFormUser,
                  controller: _userCtrl,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '用户名 (选填)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
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
          if (!useVaultCred) ...[
            const SizedBox(height: 8),
            TextField(
              key: AerKeys.profileFormPassword,
              controller: _passwordCtrl,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: '密码 (选填)',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 18,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            SwitchListTile(
              key: AerKeys.quickConnectRememberPassword,
              contentPadding: EdgeInsets.zero,
              dense: true,
              visualDensity: VisualDensity.compact,
              title: const Text('在历史记录中加密保存密码'),
              value: _rememberPassword,
              onChanged: (v) => setState(() => _rememberPassword = v),
            ),
          ],
        ],
      ),
    );
  }
}
