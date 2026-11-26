import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/connection_profile.dart';
import '../../models/session_models.dart';
import '../../services/audio_sink_controller.dart';
import '../../services/cert_trust_store.dart';
import '../../services/rdp_session_client.dart';
import '../../services/scancode_mapper.dart';
import '../aer_keys.dart';
import 'auth_prompt_dialog.dart';
import 'cert_trust_dialog.dart';
import 'command_bar_pill.dart';
import 'session_canvas.dart';
import 'special_key_bar.dart';
import 'viewport_controller.dart';

class SessionPage extends StatefulWidget {
  const SessionPage({
    super.key,
    required this.profile,
    required this.controller,
    required this.certTrustStore,
    required this.onEnded,
    this.onDisconnected,
    this.initialAudioFormat,
    this.initialWidth,
    this.initialHeight,
    this.onAttached,
    this.audioSinkController,
  });

  final ConnectionProfile profile;
  final RdpSessionController controller;
  final CertTrustStore certTrustStore;
  final VoidCallback onEnded;
  final void Function(String reason, bool clean)? onDisconnected;
  final AudioStreamOpenedEvent? initialAudioFormat;
  final int? initialWidth;
  final int? initialHeight;
  final VoidCallback? onAttached;
  final AudioSinkController? audioSinkController;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage>
    with WidgetsBindingObserver
    implements TextInputClient {
  late final ViewportController _viewportController;
  late final AudioSinkController _audioSink;
  final FocusNode _focusNode = FocusNode(debugLabel: 'session_keyboard_focus');

  StreamSubscription<RdpSessionEvent>? _eventSub;
  late SessionState _sessionState;
  CursorState? _cursorState;
  int _frameRevision = 0;

  late InputMode _inputMode;
  bool _keyboardVisible = false;
  bool _muted = false;

  final Set<StickyModifier> _stickyModifiers = <StickyModifier>{};
  final Set<ScancodeSpec> _heldPhysicalKeys = <ScancodeSpec>{};
  TextInputConnection? _textInputConnection;
  TextEditingValue _currentEditingValue = TextEditingValue.empty;
  String _lastCommittedText = '';

  bool _certDialogOpen = false;
  bool _authDialogOpen = false;
  bool _endedCalled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_applyOrientationLock());
    final int initW = widget.initialWidth ?? widget.profile.displayConfig.width;
    final int initH = widget.initialHeight ?? widget.profile.displayConfig.height;
    _sessionState = SessionState.active(
      width: initW,
      height: initH,
    );
    _viewportController = ViewportController(
      remoteWidth: initW,
      remoteHeight: initH,
    );
    _audioSink = widget.audioSinkController ?? AudioSinkController();
    _inputMode = widget.profile.inputConfig.defaultMode;
    _eventSub = widget.controller.events.listen(_onSessionEvent);
    widget.onAttached?.call();
    final initAudio = widget.initialAudioFormat;
    if (initAudio != null && widget.profile.audioConfig.mode == AudioMode.local) {
      unawaited(
        _audioSink.start(
          session: widget.controller,
          sampleRate: initAudio.sampleRate,
          channels: initAudio.channels,
          bitsPerSample: initAudio.bitsPerSample,
        ),
      );
    }
  }

  @override
  void didUpdateWidget(covariant SessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profile.displayConfig.orientationLock !=
        oldWidget.profile.displayConfig.orientationLock) {
      unawaited(_applyOrientationLock());
    }
    final initAudio = widget.initialAudioFormat;
    if (initAudio != null &&
        initAudio != oldWidget.initialAudioFormat &&
        widget.profile.audioConfig.mode == AudioMode.local &&
        !_audioSink.isRunning) {
      unawaited(
        _audioSink.start(
          session: widget.controller,
          sampleRate: initAudio.sampleRate,
          channels: initAudio.channels,
          bitsPerSample: initAudio.bitsPerSample,
        ),
      );
    }
  }

  Future<void> _applyOrientationLock() {
    final List<DeviceOrientation> orientations =
        switch (widget.profile.displayConfig.orientationLock) {
      OrientationLock.landscape => const <DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
      OrientationLock.portrait => const <DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
      OrientationLock.auto => const <DeviceOrientation>[],
    };
    return SystemChrome.setPreferredOrientations(orientations);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
    );
    _eventSub?.cancel();
    _closeTextInput();
    unawaited(_releaseAllKeysAndModifiers());
    unawaited(_audioSink.stop());
    _focusNode.dispose();
    _viewportController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_releaseAllKeysAndModifiers());
      unawaited(_audioSink.onAppPaused());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_audioSink.onAppResumed());
    }
  }

  void _finishSession({String reason = '', bool clean = true}) {
    if (_endedCalled) return;
    _endedCalled = true;
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
    );
    _closeTextInput();
    unawaited(_releaseAllKeysAndModifiers());
    unawaited(_audioSink.stop());
    if (mounted) {
      if (widget.onDisconnected != null) {
        widget.onDisconnected!(reason, clean);
      } else {
        widget.onEnded();
      }
    }
  }

  void _onSessionEvent(RdpSessionEvent event) {
    if (!mounted) return;
    switch (event) {
      case SessionStateChangedEvent(:final state):
        setState(() {
          _sessionState = state;
        });
        switch (state.phase) {
          case SessionPhase.certPrompt:
            final cert = state.certInfo;
            if (cert != null && !_certDialogOpen) {
              _showCertPrompt(cert);
            }
          case SessionPhase.authPrompt:
            if (!_authDialogOpen) {
              _showAuthPrompt(state.authReason);
            }
          case SessionPhase.active:
            _viewportController.setRemoteSize(state.width, state.height);
            setState(() => _frameRevision++);
          case SessionPhase.disconnected:
            _finishSession(
              reason: state.disconnectReason,
              clean: state.cleanDisconnect,
            );
          case SessionPhase.connecting:
          case SessionPhase.reactivating:
            break;
        }
      case FrameUpdatedEvent():
        setState(() {
          _frameRevision++;
        });
      case CursorUpdatedEvent(:final cursor):
        setState(() {
          _cursorState = cursor;
        });
      case AudioStreamOpenedEvent(
          :final sampleRate,
          :final channels,
          :final bitsPerSample
        ):
        if (widget.profile.audioConfig.mode == AudioMode.local) {
          unawaited(
            _audioSink.start(
              session: widget.controller,
              sampleRate: sampleRate,
              channels: channels,
              bitsPerSample: bitsPerSample,
            ),
          );
        }
      case AudioVolumeChangedEvent():
        break;
    }
  }

  Future<void> _showCertPrompt(CertInfo cert) async {
    _certDialogOpen = true;
    final decision = await showDialog<CertTrustDecision>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => CertTrustDialog(
        host: widget.profile.host,
        port: widget.profile.port,
        cert: cert,
        onDecision: (d) => Navigator.of(ctx).pop(d),
      ),
    );
    _certDialogOpen = false;
    final effective = decision ?? CertTrustDecision.reject;
    if (effective == CertTrustDecision.trustAlways) {
      await widget.certTrustStore.trustFingerprint(
        widget.profile.host,
        widget.profile.port,
        cert.sha256Hex,
      );
    }
    await widget.controller.submitCertDecision(effective);
  }

  Future<void> _showAuthPrompt(String? reason) async {
    _authDialogOpen = true;
    final creds = await showDialog<AuthCredentials>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AuthPromptDialog(
        initialUsername: widget.profile.username,
        initialDomain: widget.profile.domain,
        reason: reason,
        onSubmit: (c) => Navigator.of(ctx).pop(c),
        onCancel: () => Navigator.of(ctx).pop(null),
      ),
    );
    _authDialogOpen = false;
    if (creds == null) {
      await _disconnect();
      return;
    }
    await widget.controller.submitCredentials(creds);
  }

  Future<void> _disconnect() async {
    _closeTextInput();
    await _releaseAllKeysAndModifiers();
    await _audioSink.stop();
    await widget.controller.disconnect();
    _finishSession();
  }

  Future<void> _releaseAllKeysAndModifiers() async {
    final held = _heldPhysicalKeys.toList(growable: false);
    _heldPhysicalKeys.clear();
    for (final spec in held) {
      await widget.controller.sendScancode(
        code: spec.code,
        extended: spec.extended,
        down: false,
      );
    }
    await _releaseStickyModifiers();
  }

  Future<void> _releaseStickyModifiers() async {
    if (_stickyModifiers.isEmpty) return;
    final mods = _stickyModifiers.toList(growable: false);
    if (mounted) {
      setState(() => _stickyModifiers.clear());
    } else {
      _stickyModifiers.clear();
    }
    for (final mod in mods) {
      await widget.controller.sendScancode(
        code: mod.scancode.code,
        extended: mod.scancode.extended,
        down: false,
      );
    }
  }

  Future<void> _toggleStickyModifier(StickyModifier mod) async {
    final bool nowSelected = !_stickyModifiers.contains(mod);
    setState(() {
      if (nowSelected) {
        _stickyModifiers.add(mod);
      } else {
        _stickyModifiers.remove(mod);
      }
    });
    await widget.controller.sendScancode(
      code: mod.scancode.code,
      extended: mod.scancode.extended,
      down: nowSelected,
    );
  }

  Future<void> _sendSpecialKey(ScancodeSpec spec) async {
    await widget.controller.sendScancode(
      code: spec.code,
      extended: spec.extended,
      down: true,
    );
    await widget.controller.sendScancode(
      code: spec.code,
      extended: spec.extended,
      down: false,
    );
    await _releaseStickyModifiers();
  }

  Future<void> _sendCtrlAltDel() async {
    const ctrl = ScancodeSpec(0x1D);
    const alt = ScancodeSpec(0x38);
    const del = ScancodeSpec(0x53, extended: true);
    for (final k in <ScancodeSpec>[ctrl, alt, del]) {
      await widget.controller.sendScancode(
        code: k.code,
        extended: k.extended,
        down: true,
      );
    }
    for (final k in <ScancodeSpec>[del, alt, ctrl]) {
      await widget.controller.sendScancode(
        code: k.code,
        extended: k.extended,
        down: false,
      );
    }
    await _releaseStickyModifiers();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final spec = ScancodeMapper.mapKeyEvent(event);
    if (spec == null) {
      return KeyEventResult.ignored;
    }
    final isDown = event is KeyDownEvent || event is KeyRepeatEvent;
    final isUp = event is KeyUpEvent;
    if (!isDown && !isUp) {
      return KeyEventResult.ignored;
    }

    if (isDown) {
      _heldPhysicalKeys.add(spec);
    } else {
      _heldPhysicalKeys.remove(spec);
    }

    unawaited(
      widget.controller.sendScancode(
        code: spec.code,
        extended: spec.extended,
        down: isDown,
      ),
    );

    if (isUp && !ScancodeMapper.isModifierKey(event.logicalKey)) {
      unawaited(_releaseStickyModifiers());
    }
    return KeyEventResult.handled;
  }

  void _toggleKeyboard() {
    setState(() {
      _keyboardVisible = !_keyboardVisible;
    });
    if (_keyboardVisible) {
      _openTextInput();
    } else {
      _closeTextInput();
    }
  }

  void _openTextInput() {
    if (_textInputConnection != null && _textInputConnection!.attached) {
      _textInputConnection!.show();
      return;
    }
    _lastCommittedText = '';
    _currentEditingValue = TextEditingValue.empty;
    final conn = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.text,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: true,
      ),
    );
    _textInputConnection = conn;
    conn.show();
    conn.setEditingState(_currentEditingValue);
  }

  void _closeTextInput() {
    _textInputConnection?.close();
    _textInputConnection = null;
    _lastCommittedText = '';
    _currentEditingValue = TextEditingValue.empty;
  }

  @override
  TextEditingValue? get currentTextEditingValue => _currentEditingValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentEditingValue = value;
    final List<int> oldRunes = _lastCommittedText.runes.toList(growable: false);
    final List<int> newRunes = value.text.runes.toList(growable: false);
    final int minLen =
        oldRunes.length < newRunes.length ? oldRunes.length : newRunes.length;
    int prefixLen = 0;
    while (prefixLen < minLen && oldRunes[prefixLen] == newRunes[prefixLen]) {
      prefixLen++;
    }
    final int deletedCount = oldRunes.length - prefixLen;
    final List<int> addedRunes = newRunes.sublist(prefixLen);
    _lastCommittedText = value.text;

    for (int i = 0; i < deletedCount; i++) {
      unawaited(
        widget.controller.sendScancode(code: 0x0E, extended: false, down: true),
      );
      unawaited(
        widget.controller.sendScancode(code: 0x0E, extended: false, down: false),
      );
    }

    if (addedRunes.isNotEmpty) {
      final bool useScancode =
          widget.profile.inputConfig.textInputMode == TextInputMode.scancode;
      if (useScancode) {
        final bool shiftSticky = _stickyModifiers.contains(StickyModifier.shift);
        for (final int rune in addedRunes) {
          final mapped = ScancodeMapper.mapAsciiChar(rune);
          if (mapped != null) {
            if (mapped.shift && !shiftSticky) {
              unawaited(
                widget.controller
                    .sendScancode(code: 0x2A, extended: false, down: true),
              );
            }
            unawaited(
              widget.controller.sendScancode(
                code: mapped.spec.code,
                extended: mapped.spec.extended,
                down: true,
              ),
            );
            unawaited(
              widget.controller.sendScancode(
                code: mapped.spec.code,
                extended: mapped.spec.extended,
                down: false,
              ),
            );
            if (mapped.shift && !shiftSticky) {
              unawaited(
                widget.controller
                    .sendScancode(code: 0x2A, extended: false, down: false),
              );
            }
          } else {
            final String ch = String.fromCharCode(rune);
            for (final int unit in ScancodeMapper.encodeTextToUtf16Units(ch)) {
              unawaited(widget.controller.sendUnicode(codeUnit: unit, down: true));
              unawaited(widget.controller.sendUnicode(codeUnit: unit, down: false));
            }
          }
        }
      } else {
        final String addedText = String.fromCharCodes(addedRunes);
        for (final int unit
            in ScancodeMapper.encodeTextToUtf16Units(addedText)) {
          unawaited(widget.controller.sendUnicode(codeUnit: unit, down: true));
          unawaited(widget.controller.sendUnicode(codeUnit: unit, down: false));
        }
      }
    }

    if (deletedCount > 0 || addedRunes.isNotEmpty) {
      unawaited(_releaseStickyModifiers());
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline ||
        action == TextInputAction.done ||
        action == TextInputAction.send) {
      unawaited(_sendSpecialKey(const ScancodeSpec(0x1C)));
    }
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _textInputConnection = null;
  }

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void showToolbar() {}

  @override
  void performSelector(String selectorName) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  bool onFocusReceived() => false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: AerKeys.sessionPage,
      backgroundColor: const Color(0xFF111318),
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onFocusChange: (hasFocus) {
          if (!hasFocus) {
            unawaited(_releaseAllKeysAndModifiers());
          }
        },
        onKeyEvent: _handleKeyEvent,
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      children: [
                        SessionCanvas(
                          controller: widget.controller,
                          viewportController: _viewportController,
                          inputMode: _inputMode,
                          swapButtons: widget.profile.inputConfig.swapButtons,
                          cursorState: _cursorState,
                          frameRevision: _frameRevision,
                          onPointerDownFocus: () {
                            if (!_focusNode.hasFocus) {
                              _focusNode.requestFocus();
                            }
                          },
                        ),
                        if (_sessionState.phase == SessionPhase.connecting ||
                            _sessionState.phase == SessionPhase.reactivating)
                          Positioned(
                            bottom: 12,
                            left: 12,
                            child: Chip(
                              avatar: const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                              label: Text(
                                _sessionState.phase == SessionPhase.reactivating
                                    ? 'Reconnecting display...'
                                    : 'Connecting...',
                              ),
                            ),
                          ),
                        CommandBarPill(
                          areaSize: constraints.biggest,
                          inputMode: _inputMode,
                          keyboardVisible: _keyboardVisible,
                          muted: _muted,
                          onDisconnect: () => unawaited(_disconnect()),
                          onToggleInputMode: () {
                            setState(() {
                              _inputMode = _inputMode == InputMode.directTouch
                                  ? InputMode.pointer
                                  : InputMode.directTouch;
                            });
                          },
                          onToggleKeyboard: _toggleKeyboard,
                          onToggleMute: () {
                            setState(() => _muted = !_muted);
                            unawaited(_audioSink.setMuted(_muted));
                          },
                          onResetZoom: _viewportController.reset,
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (_keyboardVisible)
                SpecialKeyBar(
                  activeModifiers: _stickyModifiers,
                  onToggleModifier: (m) => unawaited(_toggleStickyModifier(m)),
                  onPressSpecialKey: (s) => unawaited(_sendSpecialKey(s)),
                  onCtrlAltDel: () => unawaited(_sendCtrlAltDel()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
