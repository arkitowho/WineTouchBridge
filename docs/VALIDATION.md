# Validation

Historical results: 2026-11-15, version 0.1.0.

- Automated tests passed 162 assertions in total across x86_64 and arm64.
- Wine interfaces and touch input were mocked; dylib loading and AppKit coordinate conversion ran directly.
- Physical touch in `winecfg` passed tap, drag, and release/re-tap with MetalSharp Wine 6.5 x86_64 (Wine 11.17).
- Real ARM64/FEX Wine and other display/input combinations remain unvalidated.

The current source cleanup has not been rebuilt or retested. The historical
assertion count does not describe the updated tests or establish XDR touch
acceptance for a new binary.
