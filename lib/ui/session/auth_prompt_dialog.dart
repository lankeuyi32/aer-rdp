import 'package:material_ui/material_ui.dart';

import '../../models/saved_credential.dart';
import '../../models/session_models.dart';
import '../../services/credential_vault.dart';
import '../../services/saved_credential_store.dart';
import '../aer_keys.dart';
import '../common/adaptive_dialog.dart';

class AuthPromptDialog extends StatefulWidget {
  const AuthPromptDialog({
    super.key,
    required this.initialUsername,
    required this.initialDomain,
    this.reason,
    this.savedCredentialStore,
    this.credentialVault,
    required this.onSubmit,
    required this.onCancel,
  });

  final String initialUsername;
  final String initialDomain;
  final String? reason;
  final SavedCredentialStore? savedCredentialStore;
  final CredentialVault? credentialVault;
  final ValueChanged<AuthCredentials> onSubmit;
  final VoidCallback onCancel;

  @override
  State<AuthPromptDialog> createState() => _AuthPromptDialogState();
}

class _AuthPromptDialogState extends State<AuthPromptDialog> {
  late final TextEditingController _userCtrl;
  late final TextEditingController _domainCtrl;
  final TextEditingController _passwordCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _userCtrl = TextEditingController(text: widget.initialUsername);
    _domainCtrl = TextEditingController(text: widget.initialDomain);
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _domainCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _fillFromSaved(SavedCredential item) async {
    final secret =
        await widget.credentialVault?.loadVaultSecret(item.id) ?? '';
    if (!mounted) return;
    setState(() {
      if (item.kind == CredentialKind.account) {
        if (item.username.isNotEmpty) _userCtrl.text = item.username;
        _domainCtrl.text = item.domain;
      }
      _passwordCtrl.text = secret;
    });
  }

  void _submit() {
    final dom = _domainCtrl.text.trim();
    widget.onSubmit(
      AuthCredentials(
        username: _userCtrl.text.trim(),
        domain: dom.isEmpty ? null : dom,
        password: _passwordCtrl.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final savedItems =
        widget.savedCredentialStore?.items ?? const <SavedCredential>[];
    return AdaptiveDialogShell(
      key: AerKeys.authPromptDialog,
      maxWidth: 380,
      title: const Text('Remote Credentials'),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: AerKeys.authPromptSubmit,
          onPressed: _submit,
          child: const Text('Sign In'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.reason != null && widget.reason!.isNotEmpty) ...[
            Text(
              widget.reason!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (savedItems.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: savedItems.map((item) {
                return ActionChip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.key_outlined, size: 15),
                  label: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => _fillFromSaved(item),
                );
              }).toList(growable: false),
            ),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _userCtrl,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Username',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _domainCtrl,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Domain',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passwordCtrl,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Password',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
