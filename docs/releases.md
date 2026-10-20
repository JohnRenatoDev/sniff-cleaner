# Build and distribute

`VERSION` is the release version; keep `ProductInfo.version` in sync. The current preview targets macOS 14+, with universal arm64 and x86_64 binaries. Runtime checks have been on Apple Silicon. Verify Intel execution separately on an Intel Mac or with Rosetta.

```sh
./script/test.sh
./script/test_scheduler.sh
./script/build_release.sh
```

The script builds both architectures from a temporary source copy, then packages the app and CLI. It excludes personal build paths and local scan data from the packages. Outputs are in `outputs/release/<version>/`:

- `Sniff-<version>-macos.dmg`: Sniff.app and a shortcut to Applications, arranged for drag-and-drop installation.
- `Sniff-<version>-macos.zip`: app for manual installation.
- `sniff-<version>-macos-cli.tar.gz`: standalone command and required localization resources.
- `SHA256SUMS`: hashes of the three downloads.
- `validation.json`: bundle, signature, architecture and packaged CLI checks.

The DMG opens in Finder with two icons and an arrow. Drag Sniff to Applications, eject the image and open the copied app. It does not launch a setup program, run a cleanup or configure the CLI. The [CLI reference](cli.md) covers the optional command link.

The release script creates an isolated `work/dmg-tools` Python environment and installs the pinned tools in `script/dmg-requirements.txt`. These are packaging tools only; the app has no third-party runtime dependencies. `dmgbuild` writes Finder's layout metadata without GUI scripting. See its [settings reference](https://dmgbuild.readthedocs.io/en/latest/settings.html).

Validation mounts the finished DMG read-only, checks that its only visible entries are Sniff.app and Applications, verifies the saved icon positions and copies the app into an exclusive temporary fixture to check its signature and CLI. It never copies to the real Applications folder.

## Signing

Without a signing identity, the build uses an ad hoc signature. The signature can detect changes to packaged files; it does not identify an Apple developer. This preview is not notarized. State that limitation when publishing it.

For Developer ID distribution, set an existing keychain identity and notarytool profile:

```sh
SNIFF_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
SNIFF_NOTARY_PROFILE='your-existing-keychain-profile' \
./script/build_release.sh
```

The optional notarization step submits the DMG, waits for Apple's result and staples and validates its ticket. The ZIP and standalone CLI are separate downloads and are not stapled by that step. Check those downloads separately before describing them as notarized. Never commit certificates, private keys or notarization credentials.

See [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [universal binaries](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary).

## Publish a preview

Create a prerelease from the reviewed commit and attach the DMG, ZIP, CLI archive and SHA256SUMS. After publishing, check repository privacy, the tag's commit and the uploaded file hashes. CI builds and uploads validation artifacts; it does not publish releases or need signing secrets.
