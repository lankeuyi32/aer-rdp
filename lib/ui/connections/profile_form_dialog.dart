import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../../models/profile_validator.dart';
import '../../models/saved_credential.dart';
import '../../services/cert_trust_store.dart';
import '../../services/credential_vault.dart';
import '../../services/saved_credential_store.dart';
import '../aer_keys.dart';
import '../common/adaptive_dialog.dart';
import 'credential_vault_dialog.dart';

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
    this.savedCredentialStore,
  });

  final ConnectionProfile? existing;
  final CredentialVault? credentialVault;
  final CertTrustStore? certTrustStore;
  final SavedCredentialStore? savedCredentialStore;

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
  late final TextEditingController _customFpsCtrl;
  late final TextEditingController _bandwidthMbpsCtrl;

  static const List<int> _presetFpsOptions = <int>[30, 60, 120, -1];

  late SecurityMode _securityMode;
  late AudioMode _audioMode;
  late InputMode _inputMode;
  late DisplayMode _displayMode;
  late OrientationLock _orientationLock;
  late int _selectedFpsChip;
  late BandwidthMode _bandwidthMode;
  late TextInputMode _textInputMode;
  late bool _swapButtons;
  String? _selectedCredentialId;
  bool _obscurePassword = true;

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
    final int initialFps = existing?.displayConfig.targetFps ?? 60;
    _selectedFpsChip =
        const <int>[30, 60, 120].contains(initialFps) ? initialFps : -1;
    _customFpsCtrl = TextEditingController(text: '$initialFps');
    _bandwidthMbpsCtrl = TextEditingController(
      text: '${existing?.displayConfig.maxBandwidthMbps ?? 15}',
    );

    _securityMode = existing?.securityMode ?? SecurityMode.auto;
    _audioMode = existing?.audioConfig.mode ?? AudioMode.local;
    _inputMode = existing?.inputConfig.defaultMode ?? InputMode.directTouch;
    _displayMode = existing?.displayConfig.mode ?? DisplayMode.matchDevice;
    _orientationLock =
        existing?.displayConfig.orientationLock ?? OrientationLock.auto;
    _bandwidthMode =
        existing?.displayConfig.bandwidthMode ?? BandwidthMode.balanced;
    _textInputMode =
        existing?.inputConfig.textInputMode ?? TextInputMode.scancode;
    _swapButtons = existing?.inputConfig.swapButtons ?? false;
    _selectedCredentialId = existing?.credentialId;

    widget.savedCredentialStore?.addListener(_onVaultStoreChanged);

    if (existing != null) {
      _refreshPinnedState(existing.host, existing.port);
      if (existing.credentialId == null &&
          existing.authMode == AuthMode.saved &&
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

  void _onVaultStoreChanged() {
    if (!mounted) return;
    if (_selectedCredentialId != null &&
        widget.savedCredentialStore?.byId(_selectedCredentialId) == null) {
      _selectedCredentialId = null;
    }
    setState(() {});
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
    widget.savedCredentialStore?.removeListener(_onVaultStoreChanged);
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _domainCtrl.dispose();
    _passwordCtrl.dispose();
    _widthCtrl.dispose();
    _heightCtrl.dispose();
    _scaleCtrl.dispose();
    _customFpsCtrl.dispose();
    _bandwidthMbpsCtrl.dispose();
    super.dispose();
  }

  Future<void> _openManageVault() async {
    final vaultStore = widget.savedCredentialStore;
    final vault = widget.credentialVault;
    if (vaultStore == null || vault == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => CredentialVaultDialog(
        savedCredentialStore: vaultStore,
        credentialVault: vault,
        certTrustStore: widget.certTrustStore,
      ),
    );
  }

  void _selectSavedCredential(SavedCredential? cred) {
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
      setState(() => _errorMessage = '请填写有效的主机地址或 IP');
      return;
    }

    final port = ProfileValidator.parseValidPort(_portCtrl.text);
    if (port == null) {
      setState(() => _errorMessage = '端口号必须在 1 到 65535 之间');
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
          () => _errorMessage = '自定义宽高必须在 1 到 16384 之间',
        );
        return;
      }
      if (parsedS == null) {
        setState(
          () => _errorMessage = '缩放倍率必须在 0.25 到 8.0 之间',
        );
        return;
      }
      width = parsedW;
      height = parsedH;
      scale = parsedS;
    }

    final int targetFps;
    if (_selectedFpsChip == -1) {
      final parsedFps = ProfileValidator.parseValidFps(_customFpsCtrl.text);
      if (parsedFps == null) {
        setState(
          () => _errorMessage = '帧率必须在 15 到 120 FPS 之间',
        );
        return;
      }
      targetFps = parsedFps;
    } else {
      targetFps = _selectedFpsChip;
    }

    int maxBandwidthMbps =
        widget.existing?.displayConfig.maxBandwidthMbps ?? 15;
    if (_bandwidthMode == BandwidthMode.custom) {
      final parsedBw =
          ProfileValidator.parseValidBandwidthMbps(_bandwidthMbpsCtrl.text);
      if (parsedBw == null) {
        setState(
          () => _errorMessage = '最大带宽必须在 1 到 200 Mbps 之间',
        );
        return;
      }
      maxBandwidthMbps = parsedBw;
    }

    final trimmedHost = _hostCtrl.text.trim();
    final trimmedName = _nameCtrl.text.trim();
    final bool boundVaultCred = _selectedCredentialId != null;
    final String password = boundVaultCred ? '' : _passwordCtrl.text;
    final existing = widget.existing;
    final bool preserveSavedPassword = !boundVaultCred &&
        existing != null &&
        existing.credentialId == null &&
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
      credentialId: _selectedCredentialId,
      authMode: (boundVaultCred || password.isNotEmpty || preserveSavedPassword)
          ? AuthMode.saved
          : AuthMode.prompt,
      securityMode: _securityMode,
      displayConfig: DisplayConfig(
        mode: _displayMode,
        width: width,
        height: height,
        scale: scale,
        orientationLock: _orientationLock,
        targetFps: targetFps,
        bandwidthMode: _bandwidthMode,
        maxBandwidthMbps: maxBandwidthMbps,
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

  static String _zhAudio(AudioMode m) => switch (m) {
        AudioMode.local => '本机播放',
        AudioMode.remote => '电脑播放',
        AudioMode.off => '静音关闭',
      };

  static String _zhInput(InputMode m) => switch (m) {
        InputMode.directTouch => '触控直点',
        InputMode.pointer => '鼠标指针',
      };

  static String _zhDisplay(DisplayMode m) => switch (m) {
        DisplayMode.matchDevice => '自适应全屏',
        DisplayMode.custom => '自定义分辨率',
      };

  static String _zhOrientation(OrientationLock o) => switch (o) {
        OrientationLock.auto => '跟随系统',
        OrientationLock.landscape => '强制横屏',
        OrientationLock.portrait => '强制竖屏',
      };

  static String _zhSecurity(SecurityMode s) => switch (s) {
        SecurityMode.auto => '自动协商',
        SecurityMode.nla => 'NLA 认证',
        SecurityMode.tls => 'TLS 加密',
      };

  static String _zhTextMode(TextInputMode t) => switch (t) {
        TextInputMode.scancode => '按键扫描码',
        TextInputMode.unicode => '字符直输',
      };

  static String _zhFpsChip(int fps) => fps == -1 ? '自定义帧率' : '$fps FPS';

  static String _zhBandwidth(BandwidthMode b) => switch (b) {
        BandwidthMode.balanced => '均衡流畅',
        BandwidthMode.highQuality => '原画高码率',
        BandwidthMode.lowBandwidth => '省流极速',
        BandwidthMode.custom => '自定义带宽',
      };

  InputDecoration _uniformInputDecoration(
    ColorScheme cs, {
    required String label,
    String? hint,
    String? helper,
    Widget? suffixIcon,
  }) {
    final borderRadius = BorderRadius.circular(10);
    final idleSide = BorderSide(
      color: cs.outlineVariant.withValues(alpha: 0.65),
    );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      isDense: true,
      filled: true,
      fillColor: cs.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      labelStyle: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
      hintStyle: TextStyle(
        fontSize: 12.5,
        color: cs.onSurfaceVariant.withValues(alpha: 0.65),
      ),
      border: OutlineInputBorder(
        borderRadius: borderRadius,
        borderSide: idleSide,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: borderRadius,
        borderSide: idleSide,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: borderRadius,
        borderSide: BorderSide(color: cs.primary, width: 1.5),
      ),
      suffixIcon: suffixIcon,
    );
  }

  /// Uniform rounded section container (`surfaceContainerLow`) so every group
  /// shares the exact same background tone and padding.
  Widget _buildSectionGroup({
    required ColorScheme cs,
    required ThemeData theme,
    required IconData icon,
    required String title,
    Widget? trailing,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: cs.onSurface,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  /// Strictly equal-width grid selector where every cell shares the exact same
  /// `cs.surface` / `cs.primaryContainer` palette and 10px radius as inputs.
  Widget _buildAlignedOptionGrid<T>({
    Key? fieldKey,
    required ColorScheme cs,
    required ThemeData theme,
    required String label,
    required List<T> values,
    required T selected,
    required int columns,
    required String Function(T) labelOf,
    required ValueChanged<T> onChanged,
  }) {
    final rows = <Widget>[];
    for (int i = 0; i < values.length; i += columns) {
      final rowItems = values.skip(i).take(columns).toList(growable: false);
      final int padCount = columns - rowItems.length;
      if (rows.isNotEmpty) {
        rows.add(const SizedBox(height: 6));
      }
      rows.add(
        Row(
          children: [
            for (int j = 0; j < rowItems.length; j++) ...[
              if (j > 0) const SizedBox(width: 6),
              Expanded(
                child: _buildOptionCell(
                  cs: cs,
                  label: labelOf(rowItems[j]),
                  selected: rowItems[j] == selected,
                  onTap: () => onChanged(rowItems[j]),
                ),
              ),
            ],
            for (int p = 0; p < padCount; p++) ...[
              const SizedBox(width: 6),
              const Expanded(child: SizedBox.shrink()),
            ],
          ],
        ),
      );
    }

    return Column(
      key: fieldKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        ...rows,
      ],
    );
  }

  Widget _buildOptionCell({
    required ColorScheme cs,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? cs.primaryContainer : cs.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected
              ? cs.primary
              : cs.outlineVariant.withValues(alpha: 0.65),
          width: selected ? 1.3 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? cs.onPrimaryContainer : cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final vaultStore = widget.savedCredentialStore;
    final savedItems = vaultStore?.items ?? const <SavedCredential>[];
    final selectedVaultItem = vaultStore?.byId(_selectedCredentialId);
    final bool usingVaultCred = _selectedCredentialId != null;

    return AdaptiveDialogShell(
      maxWidth: 480,
      heightFactor: 0.72,
      title: Text(isEdit ? '编辑远程设备' : '添加远程设备'),
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
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bool ultraNarrow = constraints.maxWidth < 250;
          final int threeCol = ultraNarrow ? 2 : 3;

          final hostField = TextField(
            key: AerKeys.profileFormHost,
            controller: _hostCtrl,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: _uniformInputDecoration(
              cs,
              label: '主机地址 / IP',
              hint: '例如 192.168.1.10',
            ),
          );
          final portField = TextField(
            key: AerKeys.profileFormPort,
            controller: _portCtrl,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            decoration: _uniformInputDecoration(cs, label: '端口'),
          );
          final nameField = TextField(
            key: AerKeys.profileFormName,
            controller: _nameCtrl,
            textInputAction: TextInputAction.next,
            decoration: _uniformInputDecoration(
              cs,
              label: '显示名称 (选填)',
              hint: '留空默认使用主机地址',
            ),
          );
          final userField = TextField(
            key: AerKeys.profileFormUser,
            controller: _userCtrl,
            textInputAction: TextInputAction.next,
            decoration: _uniformInputDecoration(cs, label: '用户名'),
          );
          final domainField = TextField(
            key: AerKeys.profileFormDomain,
            controller: _domainCtrl,
            textInputAction: TextInputAction.next,
            decoration: _uniformInputDecoration(cs, label: '域 (选填)'),
          );
          final passwordField = TextField(
            key: AerKeys.profileFormPassword,
            controller: _passwordCtrl,
            obscureText: _obscurePassword,
            onChanged: (_) => _passwordTouched = true,
            decoration: _uniformInputDecoration(
              cs,
              label: '密码 (选填)',
              hint: (isEdit &&
                      widget.existing?.authMode == AuthMode.saved &&
                      !_passwordLoaded)
                  ? '已保存密码'
                  : '留空则在连接时询问',
              suffixIcon: IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
          );
          final widthField = TextField(
            controller: _widthCtrl,
            keyboardType: TextInputType.number,
            decoration: _uniformInputDecoration(cs, label: '宽度'),
          );
          final heightField = TextField(
            controller: _heightCtrl,
            keyboardType: TextInputType.number,
            decoration: _uniformInputDecoration(cs, label: '高度'),
          );
          final scaleField = TextField(
            controller: _scaleCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _uniformInputDecoration(cs, label: '缩放'),
          );
          final customFpsField = TextField(
            key: AerKeys.profileFormCustomFps,
            controller: _customFpsCtrl,
            keyboardType: TextInputType.number,
            decoration: _uniformInputDecoration(
              cs,
              label: '自定义帧率 (15-120 FPS)',
            ),
          );
          final bandwidthMbpsField = TextField(
            key: AerKeys.profileFormBandwidthMbps,
            controller: _bandwidthMbpsCtrl,
            keyboardType: TextInputType.number,
            decoration: _uniformInputDecoration(
              cs,
              label: '最大带宽上限 (1-200 Mbps)',
              helper: '≤5M 省流 · 6-19M 均衡 · ≥20M 原画',
            ),
          );

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_errorMessage != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: cs.onErrorContainer,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),

              // 1. 连接主机
              _buildSectionGroup(
                cs: cs,
                theme: theme,
                icon: Icons.dns_outlined,
                title: '连接地址',
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: hostField),
                      const SizedBox(width: 8),
                      Expanded(flex: 3, child: portField),
                    ],
                  ),
                  const SizedBox(height: 8),
                  nameField,
                ],
              ),
              const SizedBox(height: 10),

              // 2. 登录凭据
              _buildSectionGroup(
                cs: cs,
                theme: theme,
                icon: Icons.key_outlined,
                title: '登录认证',
                trailing: (vaultStore != null && widget.credentialVault != null)
                    ? InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _openManageVault,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Text(
                            '管理凭据库',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                            ),
                          ),
                        ),
                      )
                    : null,
                children: [
                  if (savedItems.isNotEmpty) ...[
                    _buildAlignedOptionGrid<String?>(
                      fieldKey: AerKeys.profileFormCredentialSelector,
                      cs: cs,
                      theme: theme,
                      label: '选用已保存凭据',
                      values: <String?>[
                        null,
                        ...savedItems.map((e) => e.id),
                      ],
                      selected: _selectedCredentialId,
                      columns: 2,
                      labelOf: (id) => id == null
                          ? '单独输入'
                          : (vaultStore?.byId(id)?.name ?? '凭据'),
                      onChanged: (id) => _selectSavedCredential(
                        id == null ? null : vaultStore?.byId(id),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (ultraNarrow) ...[
                    userField,
                    const SizedBox(height: 8),
                    domainField,
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: userField),
                        const SizedBox(width: 8),
                        Expanded(child: domainField),
                      ],
                    ),
                  if (usingVaultCred && selectedVaultItem != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.65),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: cs.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '已绑定「${selectedVaultItem.name}」，密码连接时自动读取',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    passwordField,
                  ],
                ],
              ),
              const SizedBox(height: 10),

              // 3. 画面与画质
              _buildSectionGroup(
                cs: cs,
                theme: theme,
                icon: Icons.display_settings_outlined,
                title: '显示与画质',
                children: [
                  _buildAlignedOptionGrid<DisplayMode>(
                    cs: cs,
                    theme: theme,
                    label: '显示分辨率',
                    values: DisplayMode.values,
                    selected: _displayMode,
                    columns: 2,
                    labelOf: _zhDisplay,
                    onChanged: (v) => setState(() => _displayMode = v),
                  ),
                  if (_displayMode == DisplayMode.custom) ...[
                    const SizedBox(height: 8),
                    if (ultraNarrow) ...[
                      Row(
                        children: [
                          Expanded(child: widthField),
                          const SizedBox(width: 6),
                          Expanded(child: heightField),
                        ],
                      ),
                      const SizedBox(height: 6),
                      scaleField,
                    ] else
                      Row(
                        children: [
                          Expanded(child: widthField),
                          const SizedBox(width: 6),
                          Expanded(child: heightField),
                          const SizedBox(width: 6),
                          Expanded(child: scaleField),
                        ],
                      ),
                  ],
                  const SizedBox(height: 10),
                  _buildAlignedOptionGrid<int>(
                    fieldKey: AerKeys.profileFormFps,
                    cs: cs,
                    theme: theme,
                    label: '目标帧率',
                    values: _presetFpsOptions,
                    selected: _selectedFpsChip,
                    columns: 2,
                    labelOf: _zhFpsChip,
                    onChanged: (v) => setState(() {
                      _selectedFpsChip = v;
                      if (v != -1) {
                        _customFpsCtrl.text = '$v';
                      }
                    }),
                  ),
                  if (_selectedFpsChip == -1) ...[
                    const SizedBox(height: 8),
                    customFpsField,
                  ],
                  const SizedBox(height: 10),
                  _buildAlignedOptionGrid<BandwidthMode>(
                    fieldKey: AerKeys.profileFormBandwidth,
                    cs: cs,
                    theme: theme,
                    label: '画质与带宽',
                    values: BandwidthMode.values,
                    selected: _bandwidthMode,
                    columns: 2,
                    labelOf: _zhBandwidth,
                    onChanged: (v) => setState(() => _bandwidthMode = v),
                  ),
                  if (_bandwidthMode == BandwidthMode.custom) ...[
                    const SizedBox(height: 8),
                    bandwidthMbpsField,
                  ],
                  const SizedBox(height: 10),
                  _buildAlignedOptionGrid<OrientationLock>(
                    cs: cs,
                    theme: theme,
                    label: '屏幕方向',
                    values: OrientationLock.values,
                    selected: _orientationLock,
                    columns: threeCol,
                    labelOf: _zhOrientation,
                    onChanged: (v) => setState(() => _orientationLock = v),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 4. 操控、声音与协议
              _buildSectionGroup(
                cs: cs,
                theme: theme,
                icon: Icons.tune_outlined,
                title: '操控与高级',
                children: [
                  _buildAlignedOptionGrid<InputMode>(
                    fieldKey: AerKeys.profileFormInputMode,
                    cs: cs,
                    theme: theme,
                    label: '默认操控模式',
                    values: InputMode.values,
                    selected: _inputMode,
                    columns: 2,
                    labelOf: _zhInput,
                    onChanged: (v) => setState(() => _inputMode = v),
                  ),
                  const SizedBox(height: 10),
                  _buildAlignedOptionGrid<AudioMode>(
                    fieldKey: AerKeys.profileFormAudio,
                    cs: cs,
                    theme: theme,
                    label: '声音输出',
                    values: AudioMode.values,
                    selected: _audioMode,
                    columns: threeCol,
                    labelOf: _zhAudio,
                    onChanged: (v) => setState(() => _audioMode = v),
                  ),
                  const SizedBox(height: 10),
                  _buildAlignedOptionGrid<SecurityMode>(
                    fieldKey: AerKeys.profileFormSecurity,
                    cs: cs,
                    theme: theme,
                    label: '安全认证协议',
                    values: SecurityMode.values,
                    selected: _securityMode,
                    columns: threeCol,
                    labelOf: _zhSecurity,
                    onChanged: (v) => setState(() => _securityMode = v),
                  ),
                  const SizedBox(height: 10),
                  _buildAlignedOptionGrid<TextInputMode>(
                    cs: cs,
                    theme: theme,
                    label: '键盘输入编码',
                    values: TextInputMode.values,
                    selected: _textInputMode,
                    columns: 2,
                    labelOf: _zhTextMode,
                    onChanged: (v) => setState(() => _textInputMode = v),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.65),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '鼠标左右键互换',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                        Transform.scale(
                          scale: 0.85,
                          alignment: Alignment.centerRight,
                          child: Switch(
                            value: _swapButtons,
                            onChanged: (v) => setState(() => _swapButtons = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isEdit && _hasPinnedCert) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: cs.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: _clearCertTrust,
                      icon: const Icon(Icons.gpp_maybe_outlined, size: 18),
                      label: const Text('清除已信任的服务器证书'),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
