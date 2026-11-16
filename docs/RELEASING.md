# Manual releases

1. Keep `VERSION`, `WineTouchBridgeVersion()`, and the build script's version values consistent.
2. Run `./scripts/build.sh` and `./scripts/test.sh` manually in a logged-in macOS GUI session.
3. Update [VALIDATION.md](VALIDATION.md) with the architectures and physical input actually tested.
4. Commit and tag the release source, for example `v0.1.0`.
5. Include [LICENSE](../LICENSE) with distributions. Create any source archive from the release tag.
6. Package an explicit file list; do not archive the entire `build/` directory or local logs.

Store release archives in `dist/`. A new binary needs its own validation.
