import 'dart:io';

import 'package:aer_rdp/models/connection_profile.dart';
import 'package:aer_rdp/services/cert_trust_store.dart';
import 'package:aer_rdp/services/credential_vault.dart';
import 'package:aer_rdp/services/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileStore', () {
    test('persists atomically, sorts favorites & recents, and searches safely',
        () async {
      final tmp = await Directory.systemTemp.createTemp('aer_rdp_profile_test_');
      addTearDown(() => tmp.delete(recursive: true));

      final store = ProfileStore(directoryProvider: () async => tmp);
      await store.load();
      expect(store.profiles, isEmpty);

      await store.upsert(
        const ConnectionProfile(id: '1', name: 'Zebra', host: '10.0.0.1'),
      );
      await store.upsert(
        ConnectionProfile(
          id: '2',
          name: 'Alpha Recent',
          host: '10.0.0.2',
          lastConnectedAt: DateTime.utc(2026, 11, 26, 10, 0),
        ),
      );
      await store.upsert(
        const ConnectionProfile(
          id: '3',
          name: 'Beta Fav',
          host: '10.0.0.3',
          favorite: true,
        ),
      );

      expect(
        store.profiles.map((p) => p.id).toList(),
        <String>['3', '2', '1'],
      );
      expect(store.search('.*+?[]()'), isEmpty);
      expect(store.search('alpha').map((p) => p.id), <String>['2']);

      final reloaded = ProfileStore(directoryProvider: () async => tmp);
      await reloaded.load();
      expect(reloaded.profiles, hasLength(3));
      expect(reloaded.byId('3')?.favorite, isTrue);

      await reloaded.delete('1');
      expect(reloaded.byId('1'), isNull);
    });

    test('backs up corrupted JSON file and initializes cleanly', () async {
      final tmp = await Directory.systemTemp.createTemp('aer_rdp_corrupt_test_');
      addTearDown(() => tmp.delete(recursive: true));

      final jsonFile = File('${tmp.path}${Platform.pathSeparator}profiles_v1.json');
      await jsonFile.writeAsString('{corrupt json');

      final store = ProfileStore(directoryProvider: () async => tmp);
      await store.load();
      expect(store.profiles, isEmpty);
      final files = await tmp.list().toList();
      expect(files.any((f) => f.path.contains('.corrupt.')), isTrue);
    });
  });

  group('CredentialVault & CertTrustStore', () {
    test('CredentialVault saves, loads, and deletes secrets in memory',
        () async {
      final vault = CredentialVault.inMemory();
      expect(await vault.loadPassword('p1'), isNull);
      await vault.savePassword('p1', 's3cr3t');
      expect(await vault.loadPassword('p1'), 's3cr3t');
      await vault.deletePassword('p1');
      expect(await vault.loadPassword('p1'), isNull);
    });

    test('CertTrustStore normalizes pins, persists, and clears', () async {
      final tmp = await Directory.systemTemp.createTemp('aer_rdp_cert_test_');
      addTearDown(() => tmp.delete(recursive: true));

      const fp =
          'A1:B2:C3:D4:E5:F6:07:18:29:3A:4B:5C:6D:7E:8F:90:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00';
      final store = CertTrustStore(directoryProvider: () async => tmp);
      await store.load();
      await store.trustFingerprint('Example.COM', 3389, 'sha256:$fp');

      final reloaded = CertTrustStore(directoryProvider: () async => tmp);
      await reloaded.load();
      expect(
        reloaded.getPinnedFingerprint('example.com', 3389),
        'a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00',
      );
      await reloaded.clearFingerprint('example.com', 3389);
      expect(reloaded.getPinnedFingerprint('example.com', 3389), isNull);
    });
  });
}
