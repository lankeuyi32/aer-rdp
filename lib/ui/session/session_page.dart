import 'dart:async';
import 'dart:math' as math;

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
  static const MethodChannel _displayChannel =
      MethodChannel('dev.aer.rdp/display');

  late final ViewportController _viewportController;
  late final AudioSinkController _audioSink;
  final FocusNode _focusNode = FocusNode(debugLabel: 'session_keyboard_focus');

  StreamSubscription<RdpSessionEvent>? _eventSub;
  late SessionState _sessionState;
  CursorState? _cursorState;
  int _frameRevision = 0;
  int _touchResetEpoch = 0;

  late InputMode _inputMode;
  bool _keyboardVisible = false;
  bool _imeActuallyOpened = false;
  bool _shortcutTrayExpanded = false;
  bool _muted = false;

  String? _hudBannerText;
  Timer? _hudBannerTimer;

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
    unawaited(_applyImmersiveMode());
    unawaited(_applyOrientationLock());
    unawaited(_applyPreferredFrameRate(widget.profile.displayConfig.targetFps));
    final int initW =
        widget.initialWidth ?? widget.profile.displayConfig.width;
    final int initH =
        widget.initialHeight ?? widget.profile.displayConfig.height;
    _sessionState = SessionState.active(
      width: initW,
      height: initH,
    );
    _viewportController = ViewportController(
      remoteWidth: initW,
      remoteHeight: initH,
    );
    _viewportController.addListener(_onViewportStateChanged);
    _audioSink = widget.audioSinkController ?? AudioSinkController();
    _inputMode = widget.profile.inputConfig.defaultMode;
    _eventSub = widget.controller.events.listen(_onSessionEvent);
    widget.onAttached?.call();
    if (widget.profile.audioConfig.mode != AudioMode.local) {
      unawaited(
        _logDisplay(
          'Session audio disabled on client: profile audioMode=${widget.profile.audioConfig.mode.jsonValue}',
        ),
      );
    }
    final initAudio = widget.initialAudioFormat;
    if (initAudio != null &&
        widget.profile.audioConfig.mode == AudioMode.local) {
      unawaited(
        _logDisplay(
          'AudioStreamOpened(initial) rate=${initAudio.sampleRate} ch=${initAudio.channels} bits=${initAudio.bitsPerSample}',
        ),
      );
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

  void _onViewportStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _applyImmersiveMode() {
    return SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _restoreSystemUiMode() {
    return SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _applyPreferredFrameRate(int fps) async {
    try {
      await _displayChannel.invokeMethod<void>(
        'setPreferredFrameRate',
        <String, Object?>{'fps': fps},
      );
    } on MissingPluginException {
      // Non-Android / widget tests.
    } catch (_) {}
  }

  Future<void> _logDisplay(String message) async {
    try {
      await _displayChannel.invokeMethod<void>(
        'log',
        <String, Object?>{'message': message},
      );
    } on MissingPluginException {
      // Non-Android / widget tests.
    } catch (_) {}
  }

  void _showHudBanner(String message) {
    _hudBannerTimer?.cancel();
    setState(() {
      _hudBannerText = message;
    });
    _hudBannerTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() {
          _hudBannerText = null;
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant SessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profile.displayConfig.orientationLock !=
        oldWidget.profile.displayConfig.orientationLock) {
      unawaited(_applyOrientationLock());
    }
    if (widget.profile.displayConfig.targetFps !=
        oldWidget.profile.displayConfig.targetFps) {
      unawaited(
        _applyPreferredFrameRate(widget.profile.displayConfig.targetFps),
      );
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
    _hudBannerTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_applyPreferredFrameRate(0));
    unawaited(_restoreSystemUiMode());
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]),
    );
    _eventSub?.cancel();
    _closeTextInput();
    unawaited(_releaseAllKeysAndModifiers());
    unawaited(_audioSink.stop());
    _focusNode.dispose();
    _viewportController.removeListener(_onViewportStateChanged);
    _viewportController.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final double bottomInsetPx = views.first.viewInsets.bottom;
    if (bottomInsetPx > 80.0) {
      _imeActuallyOpened = true;
    } else if (_keyboardVisible && _imeActuallyOpened && bottomInsetPx <= 10.0) {
      // Soft keyboard was dismissed via Android Back gesture or IME hide button.
      _imeActuallyOpened = false;
      _closeTextInput();
      setState(() {
        _keyboardVisible = false;
        _touchResetEpoch++;
      });
      if (!_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
      unawaited(_applyImmersiveMode());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      if (mounted) {
        setState(() => _touchResetEpoch++);
      }
      unawaited(_releaseAllKeysAndModifiers());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (mounted) {
        setState(() => _touchResetEpoch++);
      }
      unawaited(_releaseAllKeysAndModifiers());
      unawaited(_audioSink.onAppPaused());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_applyImmersiveMode());
      unawaited(
        _applyPreferredFrameRate(widget.profile.displayConfig.targetFps),
      );
      unawaited(_audioSink.onAppResumed());
    }
  }

  void _finishSession({String reason = '', bool clean = true}) {
    if (_endedCalled) return;
    _endedCalled = true;
    unawaited(_applyPreferredFrameRate(0));
    unawaited(_restoreSystemUiMode());
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
        unawaited(
          _logDisplay(
            'AudioStreamOpened(event) rate=$sampleRate ch=$channels bits=$bitsPerSample mode=${widget.profile.audioConfig.mode.jsonValue}',
          ),
        );
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

  Future<void> _sendKeyCombo(List<ScancodeSpec> keys) async {
    for (final k in keys) {
      await widget.controller.sendScancode(
        code: k.code,
        extended: k.extended,
        down: true,
      );
    }
    for (final k in keys.reversed) {
      await widget.controller.sendScancode(
        code: k.code,
        extended: k.extended,
        down: false,
      );
    }
    await _releaseStickyModifiers();
  }

  Future<void> _sendCtrlAltDel() => _sendKeyCombo(const <ScancodeSpec>[
        ScancodeSpec(0x1D),
        ScancodeSpec(0x38),
        ScancodeSpec(0x53, extended: true),
      ]);

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
    final bool next = !_keyboardVisible;
    setState(() {
      _keyboardVisible = next;
      _touchResetEpoch++;
    });
    if (next) {
      _imeActuallyOpened = false;
      _openTextInput();
    } else {
      _imeActuallyOpened = false;
      _closeTextInput();
      if (!_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
      unawaited(_applyImmersiveMode());
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
        widget.controller
            .sendScancode(code: 0x0E, extended: false, down: false),
      );
    }

    if (addedRunes.isNotEmpty) {
      final bool useScancode =
          widget.profile.inputConfig.textInputMode == TextInputMode.scancode;
      if (useScancode) {
        final bool shiftSticky =
            _stickyModifiers.contains(StickyModifier.shift);
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
              unawaited(
                  widget.controller.sendUnicode(codeUnit: unit, down: true));
              unawaited(
                  widget.controller.sendUnicode(codeUnit: unit, down: false));
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
    _imeActuallyOpened = false;
    if (_keyboardVisible && mounted) {
      setState(() {
        _keyboardVisible = false;
        _touchResetEpoch++;
      });
      if (!_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
      unawaited(_applyImmersiveMode());
    }
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

  void _handleResetOrFill() {
    if (_viewportController.zoom > 1.01 ||
        _viewportController.panOffset != Offset.zero) {
      _viewportController.reset();
      _showHudBanner('已重置画面缩放');
    } else {
      _viewportController.toggleStretchToFill();
      _showHudBanner(
        _viewportController.stretchToFill ? '显示：铺满全屏（无黑边）' : '显示：等比例适应',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final EdgeInsets safePadding = MediaQuery.viewPaddingOf(context);
    final double imeBottom = MediaQuery.viewInsetsOf(context).bottom;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_shortcutTrayExpanded) {
          setState(() {
            _shortcutTrayExpanded = false;
            _touchResetEpoch++;
          });
        } else if (_keyboardVisible) {
          _imeActuallyOpened = false;
          _closeTextInput();
          setState(() {
            _keyboardVisible = false;
            _touchResetEpoch++;
          });
          if (!_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
          unawaited(_applyImmersiveMode());
        } else {
          _showHudBanner('请使用悬浮菜单中的红色挂断键退出远程会话');
        }
      },
      child: Scaffold(
        key: AerKeys.sessionPage,
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onFocusChange: (hasFocus) {
            if (!hasFocus) {
              unawaited(_releaseAllKeysAndModifiers());
            }
          },
          onKeyEvent: _handleKeyEvent,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double restingBarHeight =
                  SpecialKeyBar.barHeight + safePadding.bottom;
              final double trayExtraHeight = _shortcutTrayExpanded
                  ? SpecialKeyBar.expandedPanelHeight
                  : 0.0;
              final double activeBottomOverlay = SpecialKeyBar.barHeight +
                  trayExtraHeight +
                  (imeBottom > 0 ? imeBottom : safePadding.bottom);
              final double canvasImeObstruction = (imeBottom > 0
                      ? math.max(0.0, imeBottom - safePadding.bottom)
                      : 0.0) +
                  trayExtraHeight;

              return Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    bottom: restingBarHeight,
                    child: SessionCanvas(
                      controller: widget.controller,
                      viewportController: _viewportController,
                      inputMode: _inputMode,
                      swapButtons: widget.profile.inputConfig.swapButtons,
                      cursorState: _cursorState,
                      frameRevision: _frameRevision,
                      touchResetEpoch: _touchResetEpoch,
                      bottomObstruction: canvasImeObstruction,
                      targetFps: widget.profile.displayConfig.targetFps,
                      customMaxBandwidthMbps:
                          widget.profile.displayConfig.bandwidthMode ==
                                  BandwidthMode.custom
                              ? widget.profile.displayConfig.maxBandwidthMbps
                              : null,
                      onPointerDownFocus: () {
                        if (_shortcutTrayExpanded) {
                          setState(() {
                            _shortcutTrayExpanded = false;
                            _touchResetEpoch++;
                          });
                        }
                        if (!_keyboardVisible && !_focusNode.hasFocus) {
                          _focusNode.requestFocus();
                        }
                      },
                    ),
                  ),
                  if (_sessionState.phase == SessionPhase.connecting ||
                      _sessionState.phase == SessionPhase.reactivating)
                    Positioned(
                      bottom: activeBottomOverlay + 12,
                      left: 16,
                      child: Chip(
                        avatar: const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        label: Text(
                          _sessionState.phase == SessionPhase.reactivating
                              ? 'Reconnecting display...'
                              : 'Connecting...',
                        ),
                      ),
                    ),
                  if (_hudBannerText != null)
                    Positioned(
                      bottom: activeBottomOverlay + 14,
                      left: 24,
                      right: 24,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xCC1E1F24),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _hudBannerText!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  CommandBarPill(
                    areaSize: Size(
                      constraints.maxWidth,
                      math.max(80.0, constraints.maxHeight - activeBottomOverlay),
                    ),
                    safePadding: safePadding.copyWith(bottom: 0),
                    inputMode: _inputMode,
                    keyboardVisible: _keyboardVisible,
                    muted: _muted,
                    stretchToFill: _viewportController.stretchToFill,
                    onDisconnect: () => unawaited(_disconnect()),
                    onToggleInputMode: () {
                      setState(() {
                        _inputMode = _inputMode == InputMode.directTouch
                            ? InputMode.pointer
                            : InputMode.directTouch;
                        _touchResetEpoch++;
                      });
                      _showHudBanner(
                        _inputMode == InputMode.pointer
                            ? '鼠标指针模式：单指滑动移鼠 · 单击左键 · 双指点按右键'
                            : '触控直点模式：点哪按哪 · 双指滚动与缩放',
                      );
                    },
                    onToggleKeyboard: _toggleKeyboard,
                    onToggleMute: () {
                      if (widget.profile.audioConfig.mode != AudioMode.local) {
                        _showHudBanner(
                          '当前连接未开启本机播放，请在设备设置中将声音改为「本机播放」',
                        );
                        return;
                      }
                      setState(() => _muted = !_muted);
                      unawaited(_audioSink.setMuted(_muted));
                      _showHudBanner(_muted ? '已静音远程音频' : '已开启远程音频');
                    },
                    onResetZoom: _handleResetOrFill,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: imeBottom > 0 ? imeBottom : 0.0,
                    child: SpecialKeyBar(
                      activeModifiers: _stickyModifiers,
                      keyboardVisible: _keyboardVisible,
                      expanded: _shortcutTrayExpanded,
                      bottomSafeInset:
                          imeBottom > 0 ? 0.0 : safePadding.bottom,
                      onToggleModifier: (m) =>
                          unawaited(_toggleStickyModifier(m)),
                      onPressSpecialKey: (s) =>
                          unawaited(_sendSpecialKey(s)),
                      onCtrlAltDel: () => unawaited(_sendCtrlAltDel()),
                      onSendCombo: (combo) => unawaited(_sendKeyCombo(combo)),
                      onToggleKeyboard: _toggleKeyboard,
                      onToggleExpanded: () {
                        setState(() {
                          _shortcutTrayExpanded = !_shortcutTrayExpanded;
                          _touchResetEpoch++;
                        });
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
