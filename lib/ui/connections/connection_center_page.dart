import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../../models/profile_validator.dart';
import '../../services/cert_trust_store.dart';
import '../../services/credential_vault.dart';
import '../../services/profile_store.dart';
import '../aer_keys.dart';
import 'profile_form_dialog.dart';
import 'quick_connect_dialog.dart';

typedef ConnectProfileCallback = void Function(
  ConnectionProfile profile, {
  String? explicitPassword,
  required bool ephemeral,
});

class ConnectionCenterPage extends StatefulWidget {
  const ConnectionCenterPage({
    super.key,
    required this.profileStore,
    required this.credentialVault,
    required this.certTrustStore,
    required this.engineStatus,
    required this.onConnect,
  });

  final ProfileStore profileStore;
  final CredentialVault credentialVault;
  final CertTrustStore certTrustStore;
  final String engineStatus;
  final ConnectProfileCallback onConnect;

  @override
  State<ConnectionCenterPage> createState() => _ConnectionCenterPageState();
}

class _ConnectionCenterPageState extends State<ConnectionCenterPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String? _selectedProfileId;
  String? _expandedCardId;
  String? _exportedJsonPreview;

  @override
  void initState() {
    super.initState();
    widget.profileStore.addListener(_onStoreChanged);
    widget.certTrustStore.addListener(_onStoreChanged);
  }

  @override
  void didUpdateWidget(covariant ConnectionCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profileStore != widget.profileStore) {
      oldWidget.profileStore.removeListener(_onStoreChanged);
      widget.profileStore.addListener(_onStoreChanged);
    }
    if (oldWidget.certTrustStore != widget.certTrustStore) {
      oldWidget.certTrustStore.removeListener(_onStoreChanged);
      widget.certTrustStore.addListener(_onStoreChanged);
    }
  }

  @override
  void dispose() {
    widget.profileStore.removeListener(_onStoreChanged);
    widget.certTrustStore.removeListener(_onStoreChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openAddProfile() async {
    final res = await showDialog<ProfileFormResult>(
      context: context,
      builder: (_) => ProfileFormDialog(
        credentialVault: widget.credentialVault,
        certTrustStore: widget.certTrustStore,
      ),
    );
    if (res == null) return;
    await widget.profileStore.upsert(res.profile);
    if (res.password.isNotEmpty) {
      await widget.credentialVault.savePassword(res.profile.id, res.password);
    } else if (!res.preserveSavedPassword) {
      await widget.credentialVault.deletePassword(res.profile.id);
    }
    if (mounted) {
      setState(() => _selectedProfileId = res.profile.id);
    }
  }

  Future<void> _openEditProfile(ConnectionProfile profile) async {
    final res = await showDialog<ProfileFormResult>(
      context: context,
      builder: (_) => ProfileFormDialog(
        existing: profile,
        credentialVault: widget.credentialVault,
        certTrustStore: widget.certTrustStore,
      ),
    );
    if (res == null) return;
    await widget.profileStore.upsert(res.profile);
    if (res.password.isNotEmpty) {
      await widget.credentialVault.savePassword(res.profile.id, res.password);
    } else if (!res.preserveSavedPassword) {
      await widget.credentialVault.deletePassword(res.profile.id);
    }
  }

  Future<void> _deleteProfile(ConnectionProfile profile) async {
    await widget.profileStore.delete(profile.id);
    await widget.credentialVault.deletePassword(profile.id);
    if (!mounted) return;
    setState(() {
      if (_selectedProfileId == profile.id) {
        _selectedProfileId = null;
      }
      if (_expandedCardId == profile.id) {
        _expandedCardId = null;
      }
    });
  }

  Future<void> _openQuickConnect() async {
    final res = await showDialog<QuickConnectResult>(
      context: context,
      builder: (_) => const QuickConnectDialog(),
    );
    if (res == null) return;
    widget.onConnect(
      res.profile,
      explicitPassword: res.password,
      ephemeral: true,
    );
  }

  Future<void> _exportProfiles() async {
    final jsonText = widget.profileStore.exportBundleJson();
    setState(() {
      _exportedJsonPreview = jsonText;
    });
    try {
      await Clipboard.setData(ClipboardData(text: jsonText));
    } catch (_) {
      // Clipboard may be unavailable in headless tests.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Exported profiles JSON (no secrets)')),
    );
  }

  Future<void> _openImportDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ImportProfilesDialog(
        onImport: (raw) => widget.profileStore.importBundleJson(raw),
        onErrorSnackBar: (errMsg) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(errMsg)),
            );
          }
        },
      ),
    );
  }

  Widget _buildProfileTile(ConnectionProfile profile, bool selected) {
    final bool expanded = _expandedCardId == profile.id;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: selected ? 2 : 0.5,
      child: InkWell(
        onTap: () => widget.onConnect(profile, ephemeral: false),
        onLongPress: () {
          setState(() {
            _expandedCardId = expanded ? null : profile.id;
            _selectedProfileId = profile.id;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.desktop_windows_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${profile.host}:${profile.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      profile.favorite ? Icons.star : Icons.star_border,
                    ),
                    tooltip: 'Favorite',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        widget.profileStore.toggleFavorite(profile.id),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openEditProfile(profile),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Delete',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _deleteProfile(profile),
                  ),
                ],
              ),
              if (expanded)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () =>
                            widget.onConnect(profile, ephemeral: false),
                        child: const Text('Connect'),
                      ),
                      TextButton(
                        onPressed: () => _openEditProfile(profile),
                        child: const Text('Edit'),
                      ),
                      TextButton(
                        onPressed: () => _deleteProfile(profile),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListPane(List<ConnectionProfile> filtered) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            key: AerKeys.profileSearchField,
            controller: _searchCtrl,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search profiles',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _searchQuery = v),
          ),
        ),
        if (_exportedJsonPreview != null)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Exported JSON (no secrets)',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () =>
                            setState(() => _exportedJsonPreview = null),
                      ),
                    ],
                  ),
                  SelectableText(
                    _exportedJsonPreview!,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.desktop_windows_outlined, size: 52),
                        const SizedBox(height: 12),
                        Text(
                          widget.engineStatus,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (ctx, idx) {
                    final p = filtered[idx];
                    return _buildProfileTile(p, p.id == _selectedProfileId);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDetailPane(ConnectionProfile? selected) {
    if (selected == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tune, size: 48),
            const SizedBox(height: 12),
            Text(
              'Select or add a connection profile',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    final isPinned = widget.certTrustStore
            .getPinnedFingerprint(selected.host, selected.port) !=
        null;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Connection Details',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text('Endpoint: ${selected.host}:${selected.port}'),
          Text('Security: ${selected.securityMode.label}'),
          Text('Audio: ${selected.audioConfig.mode.label}'),
          Text('Input: ${selected.inputConfig.defaultMode.label}'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => widget.onConnect(selected, ephemeral: false),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Connect'),
              ),
              if (isPinned)
                OutlinedButton(
                  onPressed: () => widget.certTrustStore
                      .clearFingerprint(selected.host, selected.port),
                  child: const Text('Clear Trust'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.profileStore.search(_searchQuery);
    ConnectionProfile? selected;
    if (filtered.isNotEmpty) {
      selected = filtered.firstWhere(
        (p) => p.id == _selectedProfileId,
        orElse: () => filtered.first,
      );
    }

    return Scaffold(
      key: AerKeys.connectionCenterPage,
      appBar: AppBar(
        title: const Text('aer-rdp'),
        actions: [
          IconButton(
            key: AerKeys.quickConnectButton,
            icon: const Icon(Icons.bolt),
            tooltip: 'Quick Connect',
            onPressed: _openQuickConnect,
          ),
          IconButton(
            key: AerKeys.importProfilesButton,
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Import JSON',
            onPressed: _openImportDialog,
          ),
          IconButton(
            key: AerKeys.exportProfilesButton,
            icon: const Icon(Icons.file_download_outlined),
            tooltip: 'Export JSON',
            onPressed: _exportProfiles,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: AerKeys.addProfileButton,
        onPressed: _openAddProfile,
        tooltip: 'Add Profile',
        child: const Icon(Icons.add),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 720) {
            return Row(
              children: [
                Expanded(flex: 5, child: _buildListPane(filtered)),
                const VerticalDivider(width: 1),
                Expanded(flex: 6, child: _buildDetailPane(selected)),
              ],
            );
          }
          return _buildListPane(filtered);
        },
      ),
    );
  }
}

class _ImportProfilesDialog extends StatefulWidget {
  const _ImportProfilesDialog({
    required this.onImport,
    required this.onErrorSnackBar,
  });

  final Future<ProfileBundleValidationResult> Function(String raw) onImport;
  final ValueChanged<String> onErrorSnackBar;

  @override
  State<_ImportProfilesDialog> createState() => _ImportProfilesDialogState();
}

class _ImportProfilesDialogState extends State<_ImportProfilesDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _dialogError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final res = await widget.onImport(_controller.text);
    if (!res.isValid) {
      final errMsg = 'Invalid JSON: ${res.errors.first}';
      if (mounted) {
        setState(() => _dialogError = errMsg);
      }
      widget.onErrorSnackBar(errMsg);
      return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import Profiles (JSON v1)'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_dialogError != null) ...[
                Text(
                  _dialogError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: _controller,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Profile Bundle JSON',
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
          onPressed: _submit,
          child: const Text('Import'),
        ),
      ],
    );
  }
}
