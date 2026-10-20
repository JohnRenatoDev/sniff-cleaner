# Build and distribute

`VERSION` is the release version; keep `ProductInfo.version` in sync. The current preview targets macOS 14+, with universal arm64 and x86_64 binaries. Local runtime testing is on Apple Silicon; Intel execution requires an Intel Mac or Rosetta and is reported separately.

```sh
./script/test.sh
./script/test_scheduler.sh
./script/build_release.sh
```

The release script builds from a temporary copy of the source, creates both architectures and packages the app, CLI and native animated installer. Personal build paths, local scan state and screenshots are excluded. Outputs are in `outputs/release/<version>/`:

- `Sniff-<version>-macos.dmg`: Install Sniff.app with a nested verified app payload.
- `Sniff-<version>-macos.zip`: app for manual installation.
- `sniff-<version>-macos-cli.tar.gz`: standalone command and required localization resources.
- `SHA256SUMS`: hashes of the three downloads.
- `validation.json`: bundle, signature, architecture and packaged CLI checks.

The native installer uses the existing dog artwork and SwiftUI animation, respects Reduce Motion, offers EN/PT/ES and optional CLI installation, verifies the copied app and stages updates on the destination volume. If CLI installation fails, it attempts to restore the previous app. If recovery also fails, it preserves the previous app in the reported staging folder. No cleanup or shell profile edit runs during installation.

## Signing

With no signing identity configured, the build uses an **ad hoc** signature. This detects changes to the packaged files but does not establish an Apple developer identity. The preview is **not notarized**; publish it only with that limitation clearly stated.

For Developer ID distribution, set an existing keychain identity and notarytool profile:

```sh
SNIFF_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
SNIFF_NOTARY_PROFILE='your-existing-keychain-profile' \
./script/build_release.sh
```

The optional notarization step submits the DMG, waits for Apple's result and staples and validates its ticket. The ZIP and standalone CLI are separate downloads and are not stapled by that step. Do not describe them as notarized without their own verification. Never commit certificates, private keys or notarization credentials.

See [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [universal binaries](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary).

## Publish a preview

Create a prerelease from the reviewed commit and attach the DMG, ZIP, CLI archive and SHA256SUMS. Verify that the repository is private, the tag targets that commit and uploaded asset hashes match local files. CI builds and uploads validation artifacts; it does not publish releases or need signing secrets.
