# Validation

Version 0.1.0 was built and tested on 2026-11-17 (macOS 27.2).

- Universal dylib: x86_64 and arm64; signature verification passed.
- Both architectures passed 156 assertions in total for lifecycle behavior, loading, and AppKit coordinates.
- Wine interfaces and touch input were mocked; tests ran in the logged-in GUI session.
- Historical physical touch in `winecfg` passed tap, drag, and release/re-tap on 2026-11-15 with MetalSharp Wine 6.5 x86_64 (Wine 11.17).
- Physical touch was not rerun for this release; real ARM64/FEX Wine and other display/input combinations remain unvalidated.
