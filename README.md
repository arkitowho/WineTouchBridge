# WineTouchBridge

A macOS library that forwards XDR touch input through AppKit to Wine as
single-finger mouse events. It starts automatically when loaded into Wine.

## Build

Requires macOS 15+ and Xcode Command Line Tools. Build manually:

```sh
./scripts/build.sh
```

Produces `build/libWineTouchBridge.dylib` for x86_64 and arm64. You can also
use `Build.command` in Finder.

## Use

Load the library inside the Wine process and keep it loaded until exit:

```c
#include <dlfcn.h>

void *bridge = dlopen("/absolute/path/libWineTouchBridge.dylib", RTLD_NOW | RTLD_LOCAL);
```

The library must match the Wine host architecture. Input must reach AppKit as
direct-touch events; compatibility depends on Wine's private mouse interfaces.
The bridge provides single-finger mouse emulation.

## Test

Run manually in a logged-in macOS GUI session:

```sh
ARCHS="$(uname -m)" ./scripts/test.sh
```

See [validation](docs/VALIDATION.md) and [manual releases](docs/RELEASING.md).

## License

[MIT](LICENSE).
