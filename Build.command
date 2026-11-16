#!/bin/bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 WineTouchBridge contributors
# See LICENSE for the full license text.

set -uo pipefail
root="$(cd -- "$(dirname -- "$0")" && pwd)"
bash "$root/scripts/build.sh"
result=$?
read -r -p 'Press Return to close.' ignored
exit "$result"
