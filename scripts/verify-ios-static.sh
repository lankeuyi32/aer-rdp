#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [ -f "${HOME}/.aer-rdp-env.sh" ]; then
  # shellcheck disable=SC1091
  . "${HOME}/.aer-rdp-env.sh"
fi

echo "=== [1/6] Rust aarch64-apple-ios target & dependency audit ==="
INSTALLED_TARGETS="$(rustup target list --installed)"
printf '%s\n' "${INSTALLED_TARGETS}" | grep -Fxq "aarch64-apple-ios"

if command -v xcrun >/dev/null 2>&1; then
  cargo check --locked --target aarch64-apple-ios -p rdp-ffi
else
  echo "INFO: xcrun/iPhoneOS.sdk unavailable on $(uname -s); skipping native C-sysroot compile check (libz-sys/ring require macOS Xcode SDK) and verifying Cargo target graph."
  cargo tree --locked -p rdp-core --target aarch64-apple-ios >/dev/null
  cargo tree --locked -p rdp-ffi --target aarch64-apple-ios >/dev/null
  cargo metadata --locked --filter-platform aarch64-apple-ios --format-version 1 >/dev/null
fi

FFI_IOS_TREE="$(cargo tree --locked -p rdp-ffi --target aarch64-apple-ios)"
if printf '%s\n' "${FFI_IOS_TREE}" | grep -Eq '\b(aws-lc-sys|aws-lc-rs)\b'; then
  echo "ERROR: Forbidden aws-lc-sys / aws-lc-rs detected in aarch64-apple-ios tree" >&2
  exit 1
fi

if grep -rnE '\b(android|jni|UIKit|AVAudioSession|AudioTrack|oboe)\b' crates/rdp-core/src; then
  echo "ERROR: Platform-specific reference leaked into crates/rdp-core/src" >&2
  exit 1
fi

echo "=== [2/6] iOS build scripts, Podfile, xcconfig & Rust/FRB hooks ==="
for f in \
  "ios/Podfile" \
  "ios/Flutter/Debug.xcconfig" \
  "ios/Flutter/Release.xcconfig" \
  "ios/Scripts/build-rust-ios.sh" \
  "ios/Runner/Runner-Bridging-Header.h" \
  "ios/Runner/AudioEngineSink.swift" \
  "ios/Runner/AppDelegate.swift" \
  "docs/ipad-build-and-verify.md"
do
  if [ ! -s "$f" ]; then
    echo "ERROR: Missing or empty required M4 file: $f" >&2
    exit 1
  fi
done

test -x ios/Scripts/build-rust-ios.sh
sh -n ios/Scripts/build-rust-ios.sh
bash -n ios/Scripts/build-rust-ios.sh
grep -Fq "Pods-Runner.debug.xcconfig" ios/Flutter/Debug.xcconfig
grep -Fq "Pods-Runner.release.xcconfig" ios/Flutter/Release.xcconfig
grep -Fq "platform :ios, '15.0'" ios/Podfile
grep -Fq "IPHONEOS_DEPLOYMENT_TARGET" ios/Podfile
grep -Fq "dummy_method_to_enforce_bundling" crates/rdp-ffi/src/lib.rs
grep -Fq "dummy_method_to_enforce_bundling" ios/Runner/Runner-Bridging-Header.h
grep -Fq "dummy_method_to_enforce_bundling" ios/Runner/AppDelegate.swift
grep -Fq "ExternalLibrary.process(iKnowHowToUseIt: true)" lib/main.dart
grep -Fq "aarch64-apple-ios" docs/ipad-build-and-verify.md

python3 - <<'PY'
import pathlib
import re

lib_rs = pathlib.Path("crates/rdp-ffi/src/lib.rs").read_text(encoding="utf-8")
m = re.search(
    r"pub\s+extern\s+\"C\"\s+fn\s+dummy_method_to_enforce_bundling\s*\(\s*\)\s*->\s*usize\s*\{(.*?)\n\}",
    lib_rs,
    re.S,
)
assert m, "dummy_method_to_enforce_bundling function body not found in crates/rdp-ffi/src/lib.rs"
body = m.group(1)

expected_frb_symbols = [
    "frb_get_rust_content_hash",
    "frb_pde_ffi_dispatcher_primary",
    "frb_pde_ffi_dispatcher_sync",
    "frb_dart_fn_deliver_output",
    "frbgen_aer_rdp_rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFfiSessionHandle",
    "frbgen_aer_rdp_rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerFfiSessionHandle",
    "frb_create_shutdown_callback",
    "frb_dart_opaque_dart2rust_encode",
    "frb_dart_opaque_drop_thread_box_persistent_handle",
    "frb_dart_opaque_rust2dart_decode",
    "frb_free_wire_sync_rust2dart_dco",
    "frb_free_wire_sync_rust2dart_sse",
    "frb_init_frb_dart_api_dl",
    "frb_rust_vec_u8_free",
    "frb_rust_vec_u8_new",
    "frb_rust_vec_u8_resize",
]
missing = [sym for sym in expected_frb_symbols if sym not in body]
assert not missing, f"Missing FRB symbols in dummy_method_to_enforce_bundling: {missing}"
print(f"Verified all {len(expected_frb_symbols)} FRB symbols in dummy_method_to_enforce_bundling().")
PY

echo "=== [3/6] iOS Swift AVAudioSession & MethodChannel contract ==="
SWIFT_ALL="$(cat ios/Runner/AudioEngineSink.swift ios/Runner/AppDelegate.swift)"
for needle in \
  "AVAudioSession" \
  ".playback" \
  "AVAudioEngine" \
  "AVAudioPlayerNode" \
  "interruptionNotification" \
  "routeChangeNotification" \
  "AVAudioEngineConfigurationChange" \
  "dev.aer.rdp/audio" \
  "FlutterImplicitEngineDelegate"
do
  if ! printf '%s' "${SWIFT_ALL}" | grep -Fq "${needle}"; then
    echo "ERROR: Missing required Swift hook '${needle}'" >&2
    exit 1
  fi
done

APP_DELEGATE_SWIFT="$(cat ios/Runner/AppDelegate.swift)"
for method_case in \
  'case "open":' \
  'case "writePcm":' \
  'case "pollPlayoutDelta":' \
  'case "pause":' \
  'case "resume":' \
  'case "close":'
do
  if ! printf '%s' "${APP_DELEGATE_SWIFT}" | grep -Fq "${method_case}"; then
    echo "ERROR: Missing exact MethodChannel handler '${method_case}' in ios/Runner/AppDelegate.swift" >&2
    exit 1
  fi
done

python3 - <<'PY'
import pathlib
import re

sink_swift = pathlib.Path("ios/Runner/AudioEngineSink.swift").read_text(encoding="utf-8")
m = re.search(r"func\s+prepareStopPlaybackLocked\s*\([^)]*\).*?\{(.*?)\n\s*\}", sink_swift, re.S)
assert m is not None, "prepareStopPlaybackLocked not found in ios/Runner/AudioEngineSink.swift"
body = m.group(1)
assert "playerNode?.stop()" not in body and "playerNode.stop()" not in body, (
    "prepareStopPlaybackLocked must not call playerNode.stop() while holding lock"
)
assert "engine?.pause()" not in body and "engine.pause()" not in body, (
    "prepareStopPlaybackLocked must not call engine.pause() while holding lock"
)
assert "setActive(" not in body, (
    "prepareStopPlaybackLocked must not call setActive() while holding lock"
)
print("Verified AudioEngineSink.swift lock-safe stop/pause and AppDelegate.swift MethodChannel cases.")
PY

echo "=== [4/6] Info.plist & project.pbxproj structural validation ==="
python3 - <<'PY'
import pathlib
import plistlib
import re

plist_path = pathlib.Path("ios/Runner/Info.plist")
with plist_path.open("rb") as fh:
    plist = plistlib.load(fh)

assert plist.get("UISupportsIndirectInputEvents") is True, "UISupportsIndirectInputEvents must be True"
assert plist.get("UIApplicationSupportsIndirectInputEvents") is True, "UIApplicationSupportsIndirectInputEvents must be True"
assert plist.get("UIRequiresFullScreen") is False, "UIRequiresFullScreen must be False"
assert "audio" in plist.get("UIBackgroundModes", []), "audio missing from UIBackgroundModes"
ipad_orientations = plist.get("UISupportedInterfaceOrientations~ipad", [])
assert len(ipad_orientations) == 4, f"Expected 4 iPad orientations, got {ipad_orientations}"
local_net = plist.get("NSLocalNetworkUsageDescription", "")
assert isinstance(local_net, str) and len(local_net.strip()) > 0, "NSLocalNetworkUsageDescription missing/empty"
serialized = str(plist)
assert "minSdk" not in serialized and "APPLICATION_ID" not in serialized, "Android keys leaked into Info.plist"

pbx_text = pathlib.Path("ios/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")

# Check balanced {} and () outside quoted strings & /* ... */ comments
def check_balanced(text: str) -> None:
    stack = []
    i = 0
    n = len(text)
    in_dq = False
    in_comment = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_comment:
            if ch == "*" and nxt == "/":
                in_comment = False
                i += 2
                continue
            i += 1
            continue
        if in_dq:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_dq = False
            i += 1
            continue
        if ch == "/" and nxt == "*":
            in_comment = True
            i += 2
            continue
        if ch == '"':
            in_dq = True
            i += 1
            continue
        if ch in "{(":
            stack.append(ch)
        elif ch in "})":
            assert stack, f"Unmatched closing {ch} at offset {i}"
            top = stack.pop()
            expected = "{" if ch == "}" else "("
            assert top == expected, f"Mismatched {top} vs {ch} at offset {i}"
        i += 1
    assert not in_dq, "Unterminated double-quoted string in project.pbxproj"
    assert not in_comment, "Unterminated comment in project.pbxproj"
    assert not stack, f"Unclosed delimiters in project.pbxproj: {stack}"

check_balanced(pbx_text)
assert 'TARGETED_DEVICE_FAMILY = "1,2";' in pbx_text, "TARGETED_DEVICE_FAMILY = 1,2 missing"
assert pbx_text.count("IPHONEOS_DEPLOYMENT_TARGET = 15.0;") >= 3, "IPHONEOS_DEPLOYMENT_TARGET = 15.0 missing"
assert pbx_text.count('SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";') >= 2, "Profile/Release SUPPORTED_PLATFORMS must allow iphonesimulator"
assert "-Wl,-force_load,$(BUILT_PRODUCTS_DIR)/librdp_ffi.a" in pbx_text, "-force_load librdp_ffi.a missing"
assert "build-rust-ios.sh" in pbx_text, "Build Rust FFI script phase missing"

# Verify Runner target configurations (Debug, Release, Profile)
runner_cfg_list_m = re.search(
    r"97C147051CF9000F007C117D /\* Build configuration list for PBXNativeTarget \"Runner\" \*/ = \{.*?buildConfigurations = \((.*?)\);",
    pbx_text,
    re.S,
)
assert runner_cfg_list_m, "Runner buildConfigurationList missing"
runner_cfg_ids = re.findall(r"\b([0-9A-F]{24})\b", runner_cfg_list_m.group(1))
assert len(runner_cfg_ids) == 3, f"Expected 3 Runner configurations, found {runner_cfg_ids}"
for cfg_id in runner_cfg_ids:
    cfg_m = re.search(
        rf"{cfg_id} /\* (Debug|Release|Profile) \*/ = \{{(.*?)\n\t\t\}};",
        pbx_text,
        re.S,
    )
    assert cfg_m, f"XCBuildConfiguration block missing for Runner config {cfg_id}"
    cfg_name, cfg_body = cfg_m.group(1), cfg_m.group(2)
    assert 'SWIFT_OBJC_BRIDGING_HEADER = "Runner/Runner-Bridging-Header.h";' in cfg_body, (
        f"Runner {cfg_name} missing SWIFT_OBJC_BRIDGING_HEADER"
    )
    assert "DEAD_CODE_STRIPPING = NO;" in cfg_body, (
        f"Runner {cfg_name} missing DEAD_CODE_STRIPPING = NO;"
    )
    assert 'STRIP_STYLE = "non-global";' in cfg_body, (
        f'Runner {cfg_name} missing STRIP_STYLE = "non-global";'
    )
    assert '"-Wl,-force_load,$(BUILT_PRODUCTS_DIR)/librdp_ffi.a"' in cfg_body, (
        f"Runner {cfg_name} missing -force_load librdp_ffi.a in OTHER_LDFLAGS"
    )

# Verify AudioEngineSink.swift in PBXFileReference, PBXBuildFile, PBXGroup, PBXSourcesBuildPhase
file_ref_m = re.search(r"([0-9A-F]{24}) /\* AudioEngineSink\.swift \*/ = \{\s*isa = PBXFileReference;", pbx_text)
assert file_ref_m, "AudioEngineSink.swift PBXFileReference missing"
file_ref_id = file_ref_m.group(1)

build_file_m = re.search(
    rf"([0-9A-F]{{24}}) /\* AudioEngineSink\.swift in Sources \*/ = \{{\s*isa = PBXBuildFile; fileRef = {file_ref_id}",
    pbx_text,
)
assert build_file_m, "AudioEngineSink.swift PBXBuildFile missing"
build_file_id = build_file_m.group(1)

sources_m = re.search(
    r"97C146EA1CF9000F007C117D /\* Sources \*/ = \{.*?files = \((.*?)\);",
    pbx_text,
    re.S,
)
assert sources_m and build_file_id in sources_m.group(1), "AudioEngineSink.swift missing from Runner PBXSourcesBuildPhase"

runner_group_m = re.search(
    r"97C146F01CF9000F007C117D /\* Runner \*/ = \{.*?children = \((.*?)\);",
    pbx_text,
    re.S,
)
assert runner_group_m and file_ref_id in runner_group_m.group(1), "AudioEngineSink.swift missing from Runner PBXGroup"

runner_phases_m = re.search(
    r"97C146ED1CF9000F007C117D /\* Runner \*/ = \{.*?buildPhases = \((.*?)\);",
    pbx_text,
    re.S,
)
assert runner_phases_m, "Runner buildPhases missing"
phases_body = runner_phases_m.group(1)
rust_phase_m = re.search(r"([0-9A-F]{24}) /\* Build Rust FFI \*/ = \{\s*isa = PBXShellScriptBuildPhase;", pbx_text)
assert rust_phase_m, "Build Rust FFI PBXShellScriptBuildPhase missing"
rust_phase_id = rust_phase_m.group(1)
assert rust_phase_id in phases_body, "Build Rust FFI missing from Runner buildPhases"
assert phases_body.index(rust_phase_id) < phases_body.index("97C146EA1CF9000F007C117D"), "Build Rust FFI must run before Sources"

# Check no dangling object IDs in fileRef / files / children / buildPhases / buildConfigurations
defined_ids = set(re.findall(r"^\s*([0-9A-F]{24})(?:\s+/\*.*?\*/)?\s*=\s*\{", pbx_text, re.M))
for ref in re.findall(r"fileRef\s*=\s*([0-9A-F]{24})", pbx_text):
    assert ref in defined_ids, f"Dangling fileRef {ref}"
for block_key in ("files", "children", "buildPhases", "buildConfigurations"):
    for blk in re.findall(rf"{block_key}\s*=\s*\((.*?)\);", pbx_text, re.S):
        for ref in re.findall(r"\b([0-9A-F]{24})\b", blk):
            assert ref in defined_ids, f"Dangling {block_key} ref {ref}"

print("Info.plist and project.pbxproj structural validation passed.")
PY

echo "=== [5/6] Material UI hygiene & 31 canonical AerKeys check ==="
if grep -rn "package:flutter/material.dart" lib/ test/; then
  echo "ERROR: Forbidden package:flutter/material.dart import found" >&2
  exit 1
fi

python3 - <<'PY'
import pathlib

aer_keys_text = pathlib.Path("lib/ui/aer_keys.dart").read_text(encoding="utf-8")
expected_keys = [
    "connection_center_page",
    "add_profile_button",
    "quick_connect_button",
    "profile_search_field",
    "import_profiles_button",
    "export_profiles_button",
    "profile_form_name",
    "profile_form_host",
    "profile_form_port",
    "profile_form_user",
    "profile_form_domain",
    "profile_form_password",
    "profile_form_security",
    "profile_form_audio",
    "profile_form_input_mode",
    "profile_form_save",
    "cert_trust_dialog",
    "cert_trust_once",
    "cert_trust_always",
    "cert_reject",
    "auth_prompt_dialog",
    "auth_prompt_submit",
    "session_page",
    "session_canvas",
    "command_bar_pill",
    "command_bar_disconnect",
    "command_bar_input_mode",
    "command_bar_keyboard",
    "command_bar_mute",
    "command_bar_zoom_reset",
    "special_key_bar",
]
for k in expected_keys:
    assert f"'{k}'" in aer_keys_text, f"Missing canonical AerKey '{k}' in lib/ui/aer_keys.dart"
print(f"Verified all {len(expected_keys)} canonical AerKeys and 0 flutter/material.dart imports.")
PY

echo "=== [6/6] flutter analyze && flutter test ==="
flutter analyze
flutter test

echo "=== iOS STATIC VERIFICATION PASSED ==="
