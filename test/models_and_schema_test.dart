import 'dart:convert';

import 'package:aer_rdp/models/connection_profile.dart';
import 'package:aer_rdp/models/profile_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileBundleV1 & ProfileValidator', () {
    test('roundtrips valid ConnectionProfile bundle without secrets', () {
      final profile = ConnectionProfile(
        id: 'p-1',
        name: 'Office PC',
        host: '10.0.0.10',
        port: 3390,
        username: 'aer',
        domain: 'CORP',
        authMode: AuthMode.saved,
        securityMode: SecurityMode.nla,
        displayConfig: const DisplayConfig(
          mode: DisplayMode.custom,
          width: 1920,
          height: 1080,
          scale: 1.5,
          orientationLock: OrientationLock.landscape,
        ),
        audioConfig: const AudioConfig(mode: AudioMode.local),
        inputConfig: const InputConfig(
          defaultMode: InputMode.pointer,
          swapButtons: true,
          textInputMode: TextInputMode.unicode,
        ),
        favorite: true,
        lastConnectedAt: DateTime.utc(2026, 11, 26, 12, 0, 0),
      );

      final bundle = ProfileBundleV1(profiles: <ConnectionProfile>[profile]);
      final jsonStr = bundle.toPrettyJson();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(decoded['version'], 1);
      final pMap = (decoded['profiles'] as List<dynamic>).first as Map<String, dynamic>;
      for (final secretKey in ProfileValidator.forbiddenSecretFields) {
        expect(pMap.containsKey(secretKey), isFalse);
      }

      final result = ProfileValidator.validateBundleJson(jsonStr);
      expect(result.isValid, isTrue, reason: result.errors.join('; '));
      expect(result.profiles, hasLength(1));
      final parsed = result.profiles.single;
      expect(parsed.id, 'p-1');
      expect(parsed.securityMode, SecurityMode.nla);
      expect(parsed.displayConfig.mode, DisplayMode.custom);
      expect(parsed.displayConfig.width, 1920);
      expect(parsed.inputConfig.swapButtons, isTrue);
      expect(parsed.inputConfig.textInputMode, TextInputMode.unicode);
    });

    test('rejects forbidden plaintext secret fields', () {
      const payload = '''
{
  "version": 1,
  "profiles": [
    {
      "id": "bad-sec",
      "name": "Leaky",
      "host": "10.0.0.1",
      "port": 3389,
      "username": "u",
      "domain": "",
      "password": "leaked_password",
      "authMode": "saved",
      "securityMode": "auto",
      "displayConfig": { "mode": "matchDevice", "width": 1280, "height": 720, "scale": 1.0, "orientationLock": "auto" },
      "audioConfig": { "mode": "local" },
      "inputConfig": { "defaultMode": "directTouch", "swapButtons": false, "textInputMode": "scancode" },
      "favorite": false,
      "lastConnectedAt": null
    }
  ]
}
''';
      final result = ProfileValidator.validateBundleJson(payload);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((e) => e.contains('plaintext secret')),
        isTrue,
      );
    });

    test('rejects version != 1, duplicate ids, bad port, and bad enums', () {
      const v2 = '{"version": 2, "profiles": []}';
      expect(ProfileValidator.validateBundleJson(v2).isValid, isFalse);

      const badFields = '''
{
  "version": 1,
  "profiles": [
    {
      "id": "dup",
      "name": "A",
      "host": "10.0.0.1",
      "port": 70000,
      "username": "u",
      "domain": "",
      "authMode": "prompt",
      "securityMode": "legacy_rdp",
      "displayConfig": { "mode": "custom", "width": 0, "height": 720, "scale": 9.0, "orientationLock": "auto" },
      "audioConfig": { "mode": "surround" },
      "inputConfig": { "defaultMode": "directTouch", "swapButtons": false, "textInputMode": "scancode" },
      "favorite": false,
      "lastConnectedAt": "not-a-date"
    },
    {
      "id": "dup",
      "name": "B",
      "host": "10.0.0.2",
      "port": 3389,
      "username": "u",
      "domain": "",
      "authMode": "prompt",
      "securityMode": "auto",
      "displayConfig": { "mode": "matchDevice", "width": 1280, "height": 720, "scale": 1.0, "orientationLock": "auto" },
      "audioConfig": { "mode": "local" },
      "inputConfig": { "defaultMode": "directTouch", "swapButtons": false, "textInputMode": "scancode" },
      "favorite": false,
      "lastConnectedAt": null
    }
  ]
}
''';
      final res = ProfileValidator.validateBundleJson(badFields);
      expect(res.isValid, isFalse);
      expect(res.errors.length, greaterThanOrEqualTo(5));
    });

    test(
        'accepts legacy v1 displayConfig without targetFps/bandwidthMode and roundtrips custom FPS & bandwidth',
        () {
      const legacyV1 = '''
{
  "version": 1,
  "profiles": [
    {
      "id": "legacy-1",
      "name": "Legacy",
      "host": "10.0.0.50",
      "port": 3389,
      "username": "aer",
      "domain": "",
      "authMode": "prompt",
      "securityMode": "auto",
      "displayConfig": { "mode": "matchDevice", "width": 1280, "height": 720, "scale": 1.0, "orientationLock": "auto" },
      "audioConfig": { "mode": "local" },
      "inputConfig": { "defaultMode": "directTouch", "swapButtons": false, "textInputMode": "scancode" },
      "favorite": false,
      "lastConnectedAt": null
    }
  ]
}
''';
      final legacyRes = ProfileValidator.validateBundleJson(legacyV1);
      expect(legacyRes.isValid, isTrue, reason: legacyRes.errors.join('; '));
      final legacyProfile = legacyRes.profiles.single;
      expect(legacyProfile.displayConfig.targetFps, 60);
      expect(legacyProfile.displayConfig.bandwidthMode, BandwidthMode.balanced);
      expect(legacyProfile.displayConfig.maxBandwidthMbps, 15);

      final customProfile = legacyProfile.copyWith(
        displayConfig: legacyProfile.displayConfig.copyWith(
          targetFps: 120,
          bandwidthMode: BandwidthMode.custom,
          maxBandwidthMbps: 35,
        ),
      );
      expect(
        customProfile.displayConfig.effectiveProtocolBandwidth,
        BandwidthMode.highQuality,
      );

      final roundtripJson =
          ProfileBundleV1(profiles: <ConnectionProfile>[customProfile])
              .toPrettyJson();
      final roundtripRes = ProfileValidator.validateBundleJson(roundtripJson);
      expect(roundtripRes.isValid, isTrue);
      expect(roundtripRes.profiles.single.displayConfig.targetFps, 120);
      expect(
        roundtripRes.profiles.single.displayConfig.bandwidthMode,
        BandwidthMode.custom,
      );
      expect(roundtripRes.profiles.single.displayConfig.maxBandwidthMbps, 35);

      const badFpsBw = '''
{
  "version": 1,
  "profiles": [
    {
      "id": "bad-fps",
      "name": "Bad",
      "host": "10.0.0.51",
      "port": 3389,
      "username": "",
      "domain": "",
      "authMode": "prompt",
      "securityMode": "auto",
      "displayConfig": { "mode": "matchDevice", "width": 1280, "height": 720, "scale": 1.0, "orientationLock": "auto", "targetFps": 240, "bandwidthMode": "custom", "maxBandwidthMbps": 0 },
      "audioConfig": { "mode": "local" },
      "inputConfig": { "defaultMode": "directTouch", "swapButtons": false, "textInputMode": "scancode" },
      "favorite": false,
      "lastConnectedAt": null
    }
  ]
}
''';
      final badRes = ProfileValidator.validateBundleJson(badFpsBw);
      expect(badRes.isValid, isFalse);
      expect(badRes.errors.length, 2);
    });
  });
}
