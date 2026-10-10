# Release packaging

Development bundles keep the existing signing behavior. Distribution uses a separate,
versioned Developer ID path with secure timestamps, hardened runtime, notarization,
stapling, Gatekeeper assessment and a SHA-256 of the final archive.

On macOS, with a Developer ID Application identity in the keychain and a configured
`notarytool` profile:

```sh
APP_VERSION=0.2.0 BUILD_NUMBER=1 \
  SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  NOTARY_PROFILE=DeathRaceRelease make release
```

Set `NOTARY_KEYCHAIN` if the notary profile lives in a custom keychain. `build/` contains the
versioned zip, checksum and notarization result. A rejected submission stops the workflow;
it never produces a successful release through an ad-hoc signature fallback.

The `release` GitHub workflow runs for numeric `vX.Y.Z` tags or manual dispatch of an
existing tag. Configure these environment secrets in the repository's `release` environment:

- `APPLE_DEVELOPER_ID_P12_BASE64`: exported Developer ID certificate and private key.
- `APPLE_DEVELOPER_ID_P12_PASSWORD`: the export password.
- `APPLE_NOTARY_PRIVATE_KEY`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`: App Store
  Connect API credentials accepted by notarytool.

CI imports credentials into a temporary keychain, deletes it on exit, uploads the stapled
artifact and creates a **draft** GitHub release. Publishing remains a separate decision
after [MAC-ACCEPTANCE.md](MAC-ACCEPTANCE.md) passes. No certificate or real notarization
result is available from Linux verification alone. Existing notarized release drafts need
their artifact/acceptance evidence reviewed before publication.
