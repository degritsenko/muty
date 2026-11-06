#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test.sh
MUTY_TEST_PTY=1 bash scripts/test-integration.sh
for script in scripts/*.sh; do bash -n "$script"; done
git diff --check
bash scripts/build-app.sh
plutil -lint dist/muty.app/Contents/Info.plist
codesign --verify --deep --strict dist/muty.app
printf '%s\n' 'Automated gate passed. GUI/sleep-wake/Keychain-denial acceptance is separate; see docs/stability-results.md.'
