#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.aer-rdp-env.sh" ]; then
  . "$HOME/.aer-rdp-env.sh"
fi

if [ $# -gt 1 ]; then
  echo "Usage: $0 [--debug|--release]" >&2
  exit 1
fi

MODE="debug"
if [ "${1:-}" = "--release" ]; then
  MODE="release"
elif [ "${1:-}" = "--debug" ] || [ -z "${1:-}" ]; then
  MODE="debug"
else
  echo "Usage: $0 [--debug|--release]" >&2
  exit 1
fi

if [ "$MODE" = "release" ]; then
  ./scripts/build-rust-android.sh --release
else
  ./scripts/build-rust-android.sh
fi

flutter pub get
flutter analyze
flutter test
flutter build apk "--$MODE" --target-platform android-arm64,android-x64