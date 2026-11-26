import 'package:aer_rdp/main.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Canonical semantic ValueKeys defined in PROJECT.md § Interface Contracts (d).
abstract final class AerKeys {
  static const ValueKey<String> connectionCenterPage =
      ValueKey<String>('connection_center_page');
  static const ValueKey<String> addProfileButton =
      ValueKey<String>('add_profile_button');
  static const ValueKey<String> quickConnectButton =
      ValueKey<String>('quick_connect_button');
  static const ValueKey<String> profileSearchField =
      ValueKey<String>('profile_search_field');
  static const ValueKey<String> importProfilesButton =
      ValueKey<String>('import_profiles_button');
  static const ValueKey<String> exportProfilesButton =
      ValueKey<String>('export_profiles_button');

  static const ValueKey<String> profileFormName =
      ValueKey<String>('profile_form_name');
  static const ValueKey<String> profileFormHost =
      ValueKey<String>('profile_form_host');
  static const ValueKey<String> profileFormPort =
      ValueKey<String>('profile_form_port');
  static const ValueKey<String> profileFormUser =
      ValueKey<String>('profile_form_user');
  static const ValueKey<String> profileFormDomain =
      ValueKey<String>('profile_form_domain');
  static const ValueKey<String> profileFormPassword =
      ValueKey<String>('profile_form_password');
  static const ValueKey<String> profileFormSecurity =
      ValueKey<String>('profile_form_security');
  static const ValueKey<String> profileFormAudio =
      ValueKey<String>('profile_form_audio');
  static const ValueKey<String> profileFormInputMode =
      ValueKey<String>('profile_form_input_mode');
  static const ValueKey<String> profileFormSave =
      ValueKey<String>('profile_form_save');

  static const ValueKey<String> certTrustDialog =
      ValueKey<String>('cert_trust_dialog');
  static const ValueKey<String> certTrustOnce =
      ValueKey<String>('cert_trust_once');
  static const ValueKey<String> certTrustAlways =
      ValueKey<String>('cert_trust_always');
  static const ValueKey<String> certReject = ValueKey<String>('cert_reject');
  static const ValueKey<String> authPromptDialog =
      ValueKey<String>('auth_prompt_dialog');
  static const ValueKey<String> authPromptSubmit =
      ValueKey<String>('auth_prompt_submit');

  static const ValueKey<String> sessionPage = ValueKey<String>('session_page');
  static const ValueKey<String> sessionCanvas =
      ValueKey<String>('session_canvas');
  static const ValueKey<String> commandBarPill =
      ValueKey<String>('command_bar_pill');
  static const ValueKey<String> commandBarDisconnect =
      ValueKey<String>('command_bar_disconnect');
  static const ValueKey<String> commandBarInputMode =
      ValueKey<String>('command_bar_input_mode');
  static const ValueKey<String> commandBarKeyboard =
      ValueKey<String>('command_bar_keyboard');
  static const ValueKey<String> commandBarMute =
      ValueKey<String>('command_bar_mute');
  static const ValueKey<String> commandBarZoomReset =
      ValueKey<String>('command_bar_zoom_reset');
  static const ValueKey<String> specialKeyBar =
      ValueKey<String>('special_key_bar');
}

Future<void> pumpAerRdpApp(
  WidgetTester tester, {
  Size? surfaceSize,
}) async {
  if (surfaceSize != null) {
    await tester.binding.setSurfaceSize(surfaceSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  await tester.pumpWidget(const AerRdpApp());
  await tester.pumpAndSettle();
  expect(find.byKey(AerKeys.connectionCenterPage), findsOneWidget);
}

Future<void> createProfileViaForm(
  WidgetTester tester, {
  required String name,
  required String host,
  String port = '3389',
  String username = 'aer',
  String domain = '',
  String password = '',
}) async {
  await tester.tap(find.byKey(AerKeys.addProfileButton));
  await tester.pumpAndSettle();

  await tester.enterText(find.byKey(AerKeys.profileFormName), name);
  await tester.enterText(find.byKey(AerKeys.profileFormHost), host);
  await tester.enterText(find.byKey(AerKeys.profileFormPort), port);
  await tester.enterText(find.byKey(AerKeys.profileFormUser), username);
  if (domain.isNotEmpty) {
    await tester.enterText(find.byKey(AerKeys.profileFormDomain), domain);
  }
  if (password.isNotEmpty) {
    await tester.enterText(find.byKey(AerKeys.profileFormPassword), password);
  }
  await tester.tap(find.byKey(AerKeys.profileFormSave));
  await tester.pumpAndSettle();
}

Future<void> enterSessionHandlingPrompts(
  WidgetTester tester, {
  String? profileName,
  String password = 'testpass',
  bool trustAlways = false,
}) async {
  if (profileName != null) {
    await tester.tap(find.text(profileName));
    await tester.pumpAndSettle();
  }
  if (find.byKey(AerKeys.certTrustDialog).evaluate().isNotEmpty) {
    await tester.tap(
      find.byKey(trustAlways ? AerKeys.certTrustAlways : AerKeys.certTrustOnce),
    );
    await tester.pumpAndSettle();
  }
  if (find.byKey(AerKeys.authPromptDialog).evaluate().isNotEmpty) {
    final Finder pwdFields = find.descendant(
      of: find.byKey(AerKeys.authPromptDialog),
      matching: find.byType(TextField),
    );
    if (pwdFields.evaluate().isNotEmpty) {
      await tester.enterText(pwdFields.last, password);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(AerKeys.authPromptSubmit));
    await tester.pumpAndSettle();
  }
  if (find.byKey(AerKeys.certTrustDialog).evaluate().isNotEmpty) {
    await tester.tap(
      find.byKey(trustAlways ? AerKeys.certTrustAlways : AerKeys.certTrustOnce),
    );
    await tester.pumpAndSettle();
  }
  expect(find.byKey(AerKeys.sessionPage), findsOneWidget);
}

Future<void> selectProfileOption(
  WidgetTester tester,
  ValueKey<String> fieldKey,
  List<String> candidates,
) async {
  final Finder field = find.byKey(fieldKey);
  expect(field, findsOneWidget);
  for (final String label in candidates) {
    final Finder inline = find.descendant(
      of: field,
      matching: find.text(label),
    );
    if (inline.evaluate().isNotEmpty) {
      await tester.tap(inline.first);
      await tester.pumpAndSettle();
      return;
    }
  }
  await tester.tap(field);
  await tester.pumpAndSettle();
  for (final String label in candidates) {
    final Finder menuOpt = find.text(label);
    if (menuOpt.evaluate().isNotEmpty) {
      await tester.tap(menuOpt.last);
      await tester.pumpAndSettle();
      return;
    }
  }
}

Future<void> openProfileEditForm(
  WidgetTester tester,
  String profileName,
) async {
  final Finder editOutline = find.byIcon(Icons.edit_outlined);
  final Finder editSolid = find.byIcon(Icons.edit);
  if (editOutline.evaluate().isNotEmpty) {
    await tester.tap(editOutline.first);
    await tester.pumpAndSettle();
  } else if (editSolid.evaluate().isNotEmpty) {
    await tester.tap(editSolid.first);
    await tester.pumpAndSettle();
  } else {
    await tester.longPress(find.text(profileName));
    await tester.pumpAndSettle();
    if (find.text('Edit').evaluate().isNotEmpty) {
      await tester.tap(find.text('Edit').first);
      await tester.pumpAndSettle();
    } else if (find.byIcon(Icons.edit_outlined).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await tester.pumpAndSettle();
    } else if (find.byIcon(Icons.edit).evaluate().isNotEmpty) {
      await tester.tap(find.byIcon(Icons.edit).first);
      await tester.pumpAndSettle();
    }
  }
  expect(find.byKey(AerKeys.profileFormName), findsOneWidget);
}

Future<void> submitImportJsonIfDialogShown(
  WidgetTester tester,
  String jsonPayload,
) async {
  final Finder dialogFields = find.descendant(
    of: find.byType(Dialog),
    matching: find.byType(TextField),
  );
  if (dialogFields.evaluate().isNotEmpty) {
    await tester.enterText(dialogFields.first, jsonPayload);
    await tester.pumpAndSettle();
    for (final String btn in <String>['Import', 'OK', 'Confirm', 'Save']) {
      final Finder f = find.descendant(
        of: find.byType(Dialog),
        matching: find.text(btn),
      );
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.last);
        await tester.pumpAndSettle();
        return;
      }
    }
  }
}

Future<void> openCommandBarAndTap(
  WidgetTester tester,
  ValueKey<String> buttonKey,
) async {
  if (find.byKey(buttonKey).evaluate().isEmpty) {
    await tester.tap(find.byKey(AerKeys.commandBarPill));
    await tester.pumpAndSettle();
  }
  expect(find.byKey(buttonKey), findsOneWidget);
  await tester.tap(find.byKey(buttonKey));
  await tester.pumpAndSettle();
}

Future<void> simulatePinchZoom(
  WidgetTester tester,
  Finder target, {
  double scaleFactor = 2.0,
}) async {
  final Offset center = tester.getCenter(target);
  final TestGesture g1 = await tester.startGesture(
    center - const Offset(30, 0),
    kind: PointerDeviceKind.touch,
  );
  final TestGesture g2 = await tester.startGesture(
    center + const Offset(30, 0),
    kind: PointerDeviceKind.touch,
  );
  final double delta = 30.0 * (scaleFactor - 1.0);
  await g1.moveBy(Offset(-delta, 0));
  await g2.moveBy(Offset(delta, 0));
  await tester.pump();
  await g1.up();
  await g2.up();
  await tester.pumpAndSettle();
}

Future<void> sendPhysicalKeyChord(
  WidgetTester tester,
  List<LogicalKeyboardKey> keys,
) async {
  for (final LogicalKeyboardKey key in keys) {
    await tester.sendKeyDownEvent(key);
    await tester.pump();
  }
  for (final LogicalKeyboardKey key in keys.reversed) {
    await tester.sendKeyUpEvent(key);
    await tester.pump();
  }
}

void expectNoOverflowErrors(WidgetTester tester) {
  final Object? exception = tester.takeException();
  expect(exception, isNull, reason: 'Unexpected layout/render exception: $exception');
}
