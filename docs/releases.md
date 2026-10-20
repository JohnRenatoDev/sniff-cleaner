# Build and distribute

`VERSION` is the release version; keep `ProductInfo.version` in sync. The current preview targets macOS 14+, with universal arm64 and x86_64 binaries. Runtime checks have been on Apple Silicon. Verify Intel execution separately on an Intel Mac or with Rosetta.

```sh
./script/test.sh
./script/test_scheduler.sh
./script/build_release.sh
```

The script builds both architectures from a temporary source copy, then packages the app, CLI and installer. It excludes personal build paths and local scan data from the packages. Outputs are in `outputs/release/<version>/`:

- `Sniff-<version>-macos.dmg`: Install Sniff.app with a nested verified app payload.
- `Sniff-<version>-macos.zip`: app for manual installation.
- `sniff-<version>-macos-cli.tar.gz`: standalone command and required localization resources.
- `SHA256SUMS`: hashes of the three downloads.
- `validation.json`: bundle, signature, architecture and packaged CLI checks.

The installer supports EN/PT/ES and optional CLI installation. It uses the shared dog animation and respects Reduce Motion. App updates are staged on the destination volume, and the copied app is checked before replacing an existing installation. If CLI installation fails, it attempts to restore the previous app. If recovery also fails, it preserves the previous app in the reported staging folder. No cleanup or shell profile edit runs during installation.

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
