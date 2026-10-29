#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# XCTest ships with full Xcode, not a standalone Command Line Tools install.
if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift test --package-path "$PROJECT_DIR" "$@"
