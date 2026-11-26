import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../../models/profile_validator.dart';
import '../aer_keys.dart';

class QuickConnectResult {
  const QuickConnectResult({
    required this.profile,
    required this.password,
  });

  final ConnectionProfile profile;
  final String password;
}

class QuickConnectDialog extends StatefulWidget {
  const QuickConnectDialog({super.key});

  @override
  State<QuickConnectDialog> createState() => _QuickConnectDialogState();
}

class _QuickConnectDialogState extends State<QuickConnectDialog> {
  final TextEditingController _hostCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController(text: '3389');
  final TextEditingController _userCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();

  String? _errorMessage;

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
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
    final pw = _passwordCtrl.text;
    final profile = ConnectionProfile(
      id: 'quick-${DateTime.now().microsecondsSinceEpoch}',
      name: host,
      host: host,
      port: port,
      username: _userCtrl.text.trim(),
      authMode: pw.isNotEmpty ? AuthMode.saved : AuthMode.prompt,
    );

    Navigator.of(context).pop(
      QuickConnectResult(profile: profile, password: pw),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Quick Connect'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: AerKeys.profileFormHost,
                      controller: _hostCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Host',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: TextField(
                      key: AerKeys.profileFormPort,
                      controller: _portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: AerKeys.profileFormUser,
                controller: _userCtrl,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: AerKeys.profileFormPassword,
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: AerKeys.profileFormSave,
          onPressed: _connect,
          child: const Text('Connect'),
        ),
      ],
    );
  }
}
