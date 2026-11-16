#!/bin/bash

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 WineTouchBridge contributors
# See LICENSE for the full license text.

set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
out="$root/build"
mkdir -p "$out"
IFS=' ' read -r -a archs <<< "${ARCHS:-x86_64 arm64}"
flags=()
for arch in "${archs[@]}"; do
    case "$arch" in x86_64|arm64) flags+=(-arch "$arch");;
        *) echo "Unsupported host architecture: $arch" >&2; exit 1;; esac
done
xcrun clang "${flags[@]}" -dynamiclib -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -fvisibility=hidden -mmacosx-version-min=15.0 \
    -framework Cocoa -framework CoreGraphics \
    -install_name @rpath/libWineTouchBridge.dylib \
    -current_version 0.1.0 -compatibility_version 0.1.0 \
    "$root/src/WineTouchBridge.m" -o "$out/libWineTouchBridge.dylib.new"
codesign --force --sign - "$out/libWineTouchBridge.dylib.new"
mv -f "$out/libWineTouchBridge.dylib.new" "$out/libWineTouchBridge.dylib"
/usr/bin/python3 - "$root" <<'PY'
import hashlib,json,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]);lib=root/'build/libWineTouchBridge.dylib'
manifest=root/'build/build-manifest.json'
previous=json.loads(manifest.read_text()) if manifest.exists() else {}
sha=lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
data={'name':'WineTouchBridge','version':'0.1.0','activation':'automatic on library load',
      'requires_enable_argument':False,'requires_log_environment':False,
      'architectures':subprocess.check_output(['lipo','-archs',str(lib)],text=True).split(),
      'minimum_macos':'15.0','source_sha256':sha(root/'src/WineTouchBridge.m'),
      'library_sha256':sha(lib),'requires_wine_source':False,'runtime_dependencies':['Cocoa','CoreGraphics'],
      'wine_private_interfaces':['WineWindow','wineController','handleMouseButton:','handleMouseMove:'],
      'physical_touch_acceptance_for_this_build':None}
if previous.get('library_sha256') == data['library_sha256']:
    data['physical_touch_acceptance_for_this_build']=previous.get('physical_touch_acceptance_for_this_build')
manifest.write_text(json.dumps(data,indent=2)+'\n')
PY
echo "Built: $out/libWineTouchBridge.dylib"
lipo -archs "$out/libWineTouchBridge.dylib"
