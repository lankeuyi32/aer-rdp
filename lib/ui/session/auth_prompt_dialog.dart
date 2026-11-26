import 'package:material_ui/material_ui.dart';

import '../../models/session_models.dart';
import '../aer_keys.dart';

class AuthPromptDialog extends StatefulWidget {
  const AuthPromptDialog({
    super.key,
    required this.initialUsername,
    required this.initialDomain,
    this.reason,
    required this.onSubmit,
    required this.onCancel,
  });

  final String initialUsername;
  final String initialDomain;
  final String? reason;
  final ValueChanged<AuthCredentials> onSubmit;
  final VoidCallback onCancel;

  @override
  State<AuthPromptDialog> createState() => _AuthPromptDialogState();
}

class _AuthPromptDialogState extends State<AuthPromptDialog> {
  late final TextEditingController _userCtrl;
  late final TextEditingController _domainCtrl;
  final TextEditingController _passwordCtrl = TextEditingController();

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
    return AlertDialog(
      key: AerKeys.authPromptDialog,
      title: const Text('Remote Credentials'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
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
              TextField(
                controller: _userCtrl,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _domainCtrl,
                decoration: const InputDecoration(
                  labelText: 'Domain',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _passwordCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
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
    );
  }
}
