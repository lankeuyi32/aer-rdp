import 'dart:typed_data';

import 'connection_profile.dart';

enum CertTrustDecision {
  trustOnce,
  trustAlways,
  reject,
}

class CertInfo {
  const CertInfo({
    required this.sha256Hex,
    this.subjectCn,
    this.sanEntries = const <String>[],
    this.issuer = '',
    this.notBefore = '',
    this.notAfter = '',
    Uint8List? derBytes,
    this.expectedSha256Hex,
  }) : derBytes = derBytes ?? const <int>[];

  final String sha256Hex;
  final String? subjectCn;
  final List<String> sanEntries;
  final String issuer;
  final String notBefore;
  final String notAfter;
  final List<int> derBytes;
  final String? expectedSha256Hex;

  bool get isMismatch =>
      expectedSha256Hex != null &&
      expectedSha256Hex!.isNotEmpty &&
      expectedSha256Hex!.toLowerCase() != sha256Hex.toLowerCase();
}

class AuthCredentials {
  const AuthCredentials({
    required this.username,
    this.domain,
    required this.password,
  });

  final String username;
  final String? domain;
  final String password;
}

class ConnectRequest {
  const ConnectRequest({
    required this.profile,
    this.initialCredentials,
    this.pinnedCertSha256,
    this.effectiveWidth = 1280,
    this.effectiveHeight = 720,
    this.effectiveScaleFactor = 100,
    this.effectiveBandwidthMode,
    this.clientName = 'aer-rdp',
  });

  final ConnectionProfile profile;
  final AuthCredentials? initialCredentials;
  final String? pinnedCertSha256;
  final int effectiveWidth;
  final int effectiveHeight;
  final int effectiveScaleFactor;
  final BandwidthMode? effectiveBandwidthMode;
  final String clientName;

  BandwidthMode get resolvedBandwidthMode =>
      effectiveBandwidthMode ?? profile.displayConfig.effectiveProtocolBandwidth;
}

enum SessionPhase {
  connecting,
  certPrompt,
  authPrompt,
  active,
  reactivating,
  disconnected,
}

class SessionState {
  const SessionState._({
    required this.phase,
    this.certInfo,
    this.authReason,
    this.width = 0,
    this.height = 0,
    this.disconnectReason = '',
    this.cleanDisconnect = false,
  });

  const SessionState.connecting() : this._(phase: SessionPhase.connecting);

  const SessionState.certPrompt(CertInfo cert)
      : this._(phase: SessionPhase.certPrompt, certInfo: cert);

  const SessionState.authPrompt({String? reason})
      : this._(phase: SessionPhase.authPrompt, authReason: reason);

  const SessionState.active({required int width, required int height})
      : this._(phase: SessionPhase.active, width: width, height: height);

  const SessionState.reactivating() : this._(phase: SessionPhase.reactivating);

  const SessionState.disconnected({
    required String reason,
    required bool clean,
  }) : this._(
          phase: SessionPhase.disconnected,
          disconnectReason: reason,
          cleanDisconnect: clean,
        );

  final SessionPhase phase;
  final CertInfo? certInfo;
  final String? authReason;
  final int width;
  final int height;
  final String disconnectReason;
  final bool cleanDisconnect;
}

class FramePatch {
  const FramePatch({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.fbWidth,
    required this.fbHeight,
    required this.isFullFrame,
    required this.rgbaBytes,
  });

  final int x;
  final int y;
  final int w;
  final int h;
  final int fbWidth;
  final int fbHeight;
  final bool isFullFrame;
  final Uint8List rgbaBytes;
}

class CursorState {
  const CursorState({
    this.x = 0,
    this.y = 0,
    this.visible = true,
    this.hotspotX = 0,
    this.hotspotY = 0,
    this.width = 0,
    this.height = 0,
    this.rgbaPixels,
  });

  final int x;
  final int y;
  final bool visible;
  final int hotspotX;
  final int hotspotY;
  final int width;
  final int height;
  final Uint8List? rgbaPixels;
}

class AudioStats {
  const AudioStats({
    this.pcmBytes,
    this.framesRead = 0,
    this.queuedMs = 0,
    this.driftMs = 0,
    this.drops = 0,
    this.underruns = 0,
    this.waveConfirmsSent = 0,
    this.sampleRate = 48000,
    this.channels = 2,
    this.bitsPerSample = 16,
  });

  final Uint8List? pcmBytes;
  final int framesRead;
  final int queuedMs;
  final int driftMs;
  final int drops;
  final int underruns;
  final int waveConfirmsSent;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
}

sealed class RdpSessionEvent {
  const RdpSessionEvent();
}

class SessionStateChangedEvent extends RdpSessionEvent {
  const SessionStateChangedEvent(this.state);
  final SessionState state;
}

class FrameUpdatedEvent extends RdpSessionEvent {
  const FrameUpdatedEvent({
    required this.dirtyX,
    required this.dirtyY,
    required this.dirtyW,
    required this.dirtyH,
    required this.width,
    required this.height,
    required this.frameSync,
    required this.presentationMs,
  });

  final int dirtyX;
  final int dirtyY;
  final int dirtyW;
  final int dirtyH;
  final int width;
  final int height;
  final bool frameSync;
  final int presentationMs;
}

class CursorUpdatedEvent extends RdpSessionEvent {
  const CursorUpdatedEvent(this.cursor);
  final CursorState cursor;
}

class AudioStreamOpenedEvent extends RdpSessionEvent {
  const AudioStreamOpenedEvent({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;
}

class AudioVolumeChangedEvent extends RdpSessionEvent {
  const AudioVolumeChangedEvent({required this.left, required this.right});
  final int left;
  final int right;
}

abstract final class RdpPointerButtons {
  static const int none = 0x00;
  static const int left = 0x01;
  static const int right = 0x02;
  static const int middle = 0x04;
  static const int x1 = 0x08;
  static const int x2 = 0x10;
}
