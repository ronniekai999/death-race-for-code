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

## Beta builds

A beta needs no Apple credentials and no acceptance pass: it is for finding what the pass
would. The `beta` workflow builds the release configuration, signs it ad-hoc, smoke-tests the
bundle, and publishes a GitHub **prerelease** with the zip, its SHA-256 and install steps
pointing at [BETA.md](BETA.md). From the Actions tab, run **beta** on `main` with a tag such as
`v0.1.0-beta.1`; the tag is created on that commit. Pushing the tag does the same. The bundle
reports the tag's version, with the workflow's run number as its build, in About.

Cut betas from a commit that macOS CI has passed: the beta workflow checks the bundle, not the
test suite. Increment the beta number for each new build. A re-run of an existing tag rebuilds
that tag's commit and replaces its files. Beta tags never start the notarized release workflow.
