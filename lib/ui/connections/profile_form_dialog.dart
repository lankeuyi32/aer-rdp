import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../../models/profile_validator.dart';
import '../../services/cert_trust_store.dart';
import '../../services/credential_vault.dart';
import '../aer_keys.dart';

class ProfileFormResult {
  const ProfileFormResult({
    required this.profile,
    required this.password,
    this.preserveSavedPassword = false,
  });

  final ConnectionProfile profile;
  final String password;
  final bool preserveSavedPassword;
}

class ProfileFormDialog extends StatefulWidget {
  const ProfileFormDialog({
    super.key,
    this.existing,
    this.credentialVault,
    this.certTrustStore,
  });

  final ConnectionProfile? existing;
  final CredentialVault? credentialVault;
  final CertTrustStore? certTrustStore;

  @override
  State<ProfileFormDialog> createState() => _ProfileFormDialogState();
}

class _ProfileFormDialogState extends State<ProfileFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _domainCtrl;
  late final TextEditingController _passwordCtrl;
  late final TextEditingController _widthCtrl;
  late final TextEditingController _heightCtrl;
  late final TextEditingController _scaleCtrl;

  late SecurityMode _securityMode;
  late AudioMode _audioMode;
  late InputMode _inputMode;
  late DisplayMode _displayMode;
  late OrientationLock _orientationLock;
  late TextInputMode _textInputMode;
  late bool _swapButtons;

  String? _errorMessage;
  bool _hasPinnedCert = false;
  bool _passwordLoaded = false;
  bool _passwordTouched = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameCtrl = TextEditingController(text: existing?.name ?? '');
    _hostCtrl = TextEditingController(text: existing?.host ?? '');
    _portCtrl = TextEditingController(text: '${existing?.port ?? 3389}');
    _userCtrl = TextEditingController(text: existing?.username ?? '');
    _domainCtrl = TextEditingController(text: existing?.domain ?? '');
    _passwordCtrl = TextEditingController();
    _widthCtrl = TextEditingController(
      text: '${existing?.displayConfig.width ?? 1280}',
    );
    _heightCtrl = TextEditingController(
      text: '${existing?.displayConfig.height ?? 720}',
    );
    _scaleCtrl = TextEditingController(
      text: '${existing?.displayConfig.scale ?? 1.0}',
    );

    _securityMode = existing?.securityMode ?? SecurityMode.auto;
    _audioMode = existing?.audioConfig.mode ?? AudioMode.local;
    _inputMode = existing?.inputConfig.defaultMode ?? InputMode.directTouch;
    _displayMode = existing?.displayConfig.mode ?? DisplayMode.matchDevice;
    _orientationLock =
        existing?.displayConfig.orientationLock ?? OrientationLock.auto;
    _textInputMode =
        existing?.inputConfig.textInputMode ?? TextInputMode.scancode;
    _swapButtons = existing?.inputConfig.swapButtons ?? false;

    if (existing != null) {
      _refreshPinnedState(existing.host, existing.port);
      if (existing.authMode == AuthMode.saved &&
          widget.credentialVault != null) {
        widget.credentialVault!.loadPassword(existing.id).then((pw) {
          if (!mounted) return;
          setState(() {
            _passwordLoaded = pw != null;
          });
          if (pw != null && !_passwordTouched && _passwordCtrl.text.isEmpty) {
            _passwordCtrl.text = pw;
          }
        });
      }
    }
  }

  void _refreshPinnedState(String host, int port) {
    final store = widget.certTrustStore;
    if (store == null || host.trim().isEmpty) {
      _hasPinnedCert = false;
      return;
    }
    _hasPinnedCert = store.getPinnedFingerprint(host, port) != null;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _domainCtrl.dispose();
    _passwordCtrl.dispose();
    _widthCtrl.dispose();
    _heightCtrl.dispose();
    _scaleCtrl.dispose();
    super.dispose();
  }

  Future<void> _clearCertTrust() async {
    final store = widget.certTrustStore;
    if (store == null) return;
    final host = _hostCtrl.text.trim();
    final port = ProfileValidator.parseValidPort(_portCtrl.text) ??
        widget.existing?.port ??
        3389;
    if (host.isEmpty) return;
    await store.clearFingerprint(host, port);
    if (mounted) {
      setState(() {
        _hasPinnedCert = false;
      });
    }
  }

  void _submit() {
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

    int width = widget.existing?.displayConfig.width ?? 1280;
    int height = widget.existing?.displayConfig.height ?? 720;
    double scale = widget.existing?.displayConfig.scale ?? 1.0;

    if (_displayMode == DisplayMode.custom) {
      final parsedW = ProfileValidator.parseValidDimension(_widthCtrl.text);
      final parsedH = ProfileValidator.parseValidDimension(_heightCtrl.text);
      final parsedS = ProfileValidator.parseValidScale(_scaleCtrl.text);
      if (parsedW == null || parsedH == null) {
        setState(
          () => _errorMessage = 'Width and height must be between 1 and 16384',
        );
        return;
      }
      if (parsedS == null) {
        setState(
          () => _errorMessage = 'Scale must be between 0.25 and 8.0',
        );
        return;
      }
      width = parsedW;
      height = parsedH;
      scale = parsedS;
    }

    final trimmedHost = _hostCtrl.text.trim();
    final trimmedName = _nameCtrl.text.trim();
    final password = _passwordCtrl.text;
    final existing = widget.existing;
    final bool preserveSavedPassword = existing != null &&
        existing.authMode == AuthMode.saved &&
        !_passwordTouched &&
        password.isEmpty &&
        !_passwordLoaded;
    final profile = ConnectionProfile(
      id: existing?.id ?? 'prof-${DateTime.now().microsecondsSinceEpoch}',
      name: trimmedName.isEmpty ? trimmedHost : trimmedName,
      host: trimmedHost,
      port: port,
      username: _userCtrl.text.trim(),
      domain: _domainCtrl.text.trim(),
      authMode: (password.isNotEmpty || preserveSavedPassword)
          ? AuthMode.saved
          : AuthMode.prompt,
      securityMode: _securityMode,
      displayConfig: DisplayConfig(
        mode: _displayMode,
        width: width,
        height: height,
        scale: scale,
        orientationLock: _orientationLock,
      ),
      audioConfig: AudioConfig(mode: _audioMode),
      inputConfig: InputConfig(
        defaultMode: _inputMode,
        swapButtons: _swapButtons,
        textInputMode: _textInputMode,
      ),
      favorite: existing?.favorite ?? false,
      lastConnectedAt: existing?.lastConnectedAt,
    );

    Navigator.of(context).pop(
      ProfileFormResult(
        profile: profile,
        password: password,
        preserveSavedPassword: preserveSavedPassword,
      ),
    );
  }

  Widget _buildChipGroup<T>({
    required Key fieldKey,
    required String label,
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
    required ValueChanged<T> onChanged,
  }) {
    return Column(
      key: fieldKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: values.map((v) {
            return ChoiceChip(
              label: Text(labelOf(v)),
              selected: v == selected,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onChanged(v),
            );
          }).toList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit Connection' : 'New Connection'),
      content: SizedBox(
        width: 480,
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
                const SizedBox(height: 6),
              ],
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: AerKeys.profileFormName,
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: AerKeys.profileFormHost,
                      controller: _hostCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Host',
                        isDense: true,
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
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: AerKeys.profileFormUser,
                      controller: _userCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: AerKeys.profileFormDomain,
                      controller: _domainCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Domain',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: AerKeys.profileFormPassword,
                      controller: _passwordCtrl,
                      obscureText: true,
                      onChanged: (_) => _passwordTouched = true,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        hintText: (isEdit &&
                                widget.existing?.authMode == AuthMode.saved &&
                                !_passwordLoaded)
                            ? 'Saved'
                            : null,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  _buildChipGroup<SecurityMode>(
                    fieldKey: AerKeys.profileFormSecurity,
                    label: 'Security',
                    values: SecurityMode.values,
                    selected: _securityMode,
                    labelOf: (m) => m.label,
                    onChanged: (v) => setState(() => _securityMode = v),
                  ),
                  _buildChipGroup<AudioMode>(
                    fieldKey: AerKeys.profileFormAudio,
                    label: 'Audio',
                    values: AudioMode.values,
                    selected: _audioMode,
                    labelOf: (m) => m.label,
                    onChanged: (v) => setState(() => _audioMode = v),
                  ),
                  _buildChipGroup<InputMode>(
                    fieldKey: AerKeys.profileFormInputMode,
                    label: 'Input Mode',
                    values: InputMode.values,
                    selected: _inputMode,
                    labelOf: (m) => m.label,
                    onChanged: (v) => setState(() => _inputMode = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ...DisplayMode.values.map((mode) {
                    return ChoiceChip(
                      label: Text(mode.label),
                      selected: _displayMode == mode,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _displayMode = mode),
                    );
                  }),
                  FilterChip(
                    label: const Text('Swap Buttons'),
                    selected: _swapButtons,
                    visualDensity: VisualDensity.compact,
                    onSelected: (v) => setState(() => _swapButtons = v),
                  ),
                ],
              ),
              if (_displayMode == DisplayMode.custom) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _widthCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Width',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _heightCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Height',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _scaleCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Scale',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<OrientationLock>(
                      initialValue: _orientationLock,
                      decoration: const InputDecoration(
                        labelText: 'Orientation',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: OrientationLock.values
                          .map(
                            (o) => DropdownMenuItem<OrientationLock>(
                              value: o,
                              child: Text(o.label),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _orientationLock = v);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<TextInputMode>(
                      initialValue: _textInputMode,
                      decoration: const InputDecoration(
                        labelText: 'Keyboard',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: TextInputMode.values
                          .map(
                            (t) => DropdownMenuItem<TextInputMode>(
                              value: t,
                              child: Text(t.label),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _textInputMode = v);
                      },
                    ),
                  ),
                ],
              ),
              if (isEdit && _hasPinnedCert) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _clearCertTrust,
                    icon: const Icon(Icons.gpp_maybe_outlined),
                    label: const Text('Clear Trust'),
                  ),
                ),
              ],
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
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
