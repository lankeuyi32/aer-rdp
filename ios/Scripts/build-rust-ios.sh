#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ -f "${HOME}/.cargo/env" ]; then
  # shellcheck disable=SC1091
  . "${HOME}/.cargo/env"
fi
export PATH="${HOME}/.cargo/bin:${PATH}"

XCFRAMEWORK_MODE=0
PROFILE_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --xcframework)
      XCFRAMEWORK_MODE=1
      ;;
    --debug)
      PROFILE_OVERRIDE="debug"
      ;;
    --release)
      PROFILE_OVERRIDE="release"
      ;;
    -h|--help)
      cat <<'EOF'
Usage: build-rust-ios.sh [--xcframework] [--debug|--release]

When invoked from Xcode, reads PLATFORM_NAME, CONFIGURATION, ARCHS, and BUILT_PRODUCTS_DIR.
When invoked with --xcframework, builds both aarch64-apple-ios and aarch64-apple-ios-sim
static libraries and packages ios/Frameworks/RdpFfi.xcframework.
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ -n "${PROFILE_OVERRIDE}" ]; then
  BUILD_PROFILE="${PROFILE_OVERRIDE}"
else
  case "${CONFIGURATION:-Debug}" in
    Release*|release*|Profile*|profile*)
      BUILD_PROFILE="release"
      ;;
    *)
      BUILD_PROFILE="debug"
      ;;
  esac
fi

build_rust_target() {
  target_triple="$1"
  if [ "${BUILD_PROFILE}" = "release" ]; then
    cargo build --locked --release --target "${target_triple}" -p rdp-ffi
  else
    cargo build --locked --target "${target_triple}" -p rdp-ffi
  fi
}

cd "${REPO_ROOT}"

if [ "${XCFRAMEWORK_MODE}" -eq 1 ]; then
  echo "Building rdp-ffi (${BUILD_PROFILE}) for aarch64-apple-ios and aarch64-apple-ios-sim..."
  build_rust_target "aarch64-apple-ios"
  build_rust_target "aarch64-apple-ios-sim"

  FRAMEWORKS_DIR="${REPO_ROOT}/ios/Frameworks"
  INCLUDE_DIR="${FRAMEWORKS_DIR}/include"
  XCFRAMEWORK_OUT="${FRAMEWORKS_DIR}/RdpFfi.xcframework"

  mkdir -p "${INCLUDE_DIR}"
  cat > "${INCLUDE_DIR}/rdp_ffi.h" <<'EOF'
#pragma once
#include <stddef.h>

size_t dummy_method_to_enforce_bundling(void);
EOF

  rm -rf "${XCFRAMEWORK_OUT}"
  xcodebuild -create-xcframework \
    -library "${REPO_ROOT}/target/aarch64-apple-ios/${BUILD_PROFILE}/librdp_ffi.a" \
    -headers "${INCLUDE_DIR}" \
    -library "${REPO_ROOT}/target/aarch64-apple-ios-sim/${BUILD_PROFILE}/librdp_ffi.a" \
    -headers "${INCLUDE_DIR}" \
    -output "${XCFRAMEWORK_OUT}"

  echo "Created ${XCFRAMEWORK_OUT}"
  exit 0
fi

case "${PLATFORM_NAME:-iphoneos}" in
  iphonesimulator)
    case "${ARCHS:-}" in
      x86_64)
        RUST_TARGET="x86_64-apple-ios"
        ;;
      *x86_64*)
        if [ "$(uname -m)" = "x86_64" ]; then
          RUST_TARGET="x86_64-apple-ios"
        else
          RUST_TARGET="aarch64-apple-ios-sim"
        fi
        ;;
      *)
        RUST_TARGET="aarch64-apple-ios-sim"
        ;;
    esac
    ;;
  iphoneos|*)
    RUST_TARGET="aarch64-apple-ios"
    ;;
esac

echo "Building rdp-ffi (${BUILD_PROFILE}) for ${RUST_TARGET}..."
build_rust_target "${RUST_TARGET}"

SRC_LIB="${REPO_ROOT}/target/${RUST_TARGET}/${BUILD_PROFILE}/librdp_ffi.a"
DEST_DIR="${BUILT_PRODUCTS_DIR:-${REPO_ROOT}/ios/Frameworks}"
mkdir -p "${DEST_DIR}"
cp -f "${SRC_LIB}" "${DEST_DIR}/librdp_ffi.a"

echo "Copied ${SRC_LIB} -> ${DEST_DIR}/librdp_ffi.a"
