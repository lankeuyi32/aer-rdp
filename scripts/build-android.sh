#!/usr/bin/env bash
set -euo pipefail

if [ -f "$HOME/.aer-rdp-env.sh" ]; then
  . "$HOME/.aer-rdp-env.sh"
fi

./scripts/build-rust-android.sh "$@"
flutter pub get
flutter analyze
flutter test
flutter build apk --debug