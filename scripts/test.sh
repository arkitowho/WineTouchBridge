#!/bin/bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 WineTouchBridge contributors
# See LICENSE for the full license text.

# Requires a logged-in macOS GUI session. Does not generate physical input.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
library="${1:-$root/build/libWineTouchBridge.dylib}"
if [[ ! -f "$library" ]]; then
    echo 'Missing compiled dylib. Run ./scripts/build.sh first, or pass its absolute path to test.sh.' >&2
    exit 1
fi
mkdir -p "$root/build/tests"
read -r -a architectures <<< "${ARCHS:-x86_64 arm64}"
for architecture in "${architectures[@]}"; do
    case "$architecture" in x86_64|arm64) ;; *) echo "Unsupported test architecture: $architecture" >&2; exit 1;; esac
    echo "Testing $architecture"
    xcrun clang -arch "$architecture" -fobjc-arc -fblocks -Wall -Wextra -Werror \
        -Wno-unused-parameter -mmacosx-version-min=15.0 \
        -I"$root/include" -framework Cocoa -framework CoreGraphics \
        "$root/tests/BridgeTests.m" -o "$root/build/tests/bridge-tests-$architecture"
    env -u WINE_TOUCH_BRIDGE_LOG \
        "$root/build/tests/bridge-tests-$architecture"
    # Also verify the actual dylib in a separate process, without calling Start.
    xcrun clang -arch "$architecture" -fobjc-arc -fblocks -Wall -Wextra -Werror \
        -mmacosx-version-min=15.0 -framework Cocoa \
        "$root/tests/LoadTests.m" -o "$root/build/tests/load-tests-$architecture"
    env -u WINE_TOUCH_BRIDGE_LOG \
        "$root/build/tests/load-tests-$architecture" "$library"
    env WINE_TOUCH_BRIDGE_LOG=/dev/null/cannot-create-log \
        "$root/build/tests/load-tests-$architecture" "$library"
done
