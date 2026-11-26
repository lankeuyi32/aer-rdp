import 'package:material_ui/material_ui.dart';

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
