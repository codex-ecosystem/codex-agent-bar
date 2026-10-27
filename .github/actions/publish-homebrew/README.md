# Homebrew releases

Every stable release automatically publishes `codex-agent-bar` to [codex-ecosystem/homebrew-tap](https://github.com/codex-ecosystem/homebrew-tap). Do not edit the tap's version, checksum, or download URL by hand.

The release workflow calls the local `.github/actions/publish-homebrew` composite action. The action owns Node.js setup, tests, token creation, cask publishing, and verification. Both it and the publishing-check workflow reuse `.github/actions/test-homebrew`.

## Release sequence

1. The release job builds, signs, and uploads the DMG, then downloads the published asset to verify its SHA-256 against the local build.
2. After the release job succeeds, `actions/create-github-app-token` creates a short-lived installation token restricted to the tap's contents.
3. `.github/actions/publish-homebrew/release.mts prepare` initializes a missing cask automatically, skips identical or older releases, and prevents replacing an existing version with a different DMG.
4. For an existing older cask, the TypeScript-based `mislav/bump-homebrew-formula-action` updates its version, download URL, and SHA-256 directly on `main` without a pull request.
5. `.github/actions/publish-homebrew/release.mts finalize` verifies the published metadata, synchronizes packaging details from `.github/actions/publish-homebrew/template.rb.in`, and reads the remote file back to verify the result.

Homebrew jobs are serialized. Prereleases do not update the stable tap, and publishing errors fail the workflow. No version edits, checksum calculation, or PR merges are required by maintainers.

## Credentials

The dedicated `codex-ecosystem-homebrew-release` GitHub App is installed only on `codex-ecosystem/homebrew-tap`, with Contents read/write and mandatory Metadata read access. Its Client ID and private key are stored in this repository's `HOMEBREW_APP_CLIENT_ID` and `HOMEBREW_APP_PRIVATE_KEY` Actions secrets.

The workflow checks these credentials before building stable releases. The installation token is created only for the Homebrew job and revoked when the job finishes. The default `GITHUB_TOKEN` accesses this repository and its release assets; no personal access token or SSH deployment key is required.

## Package metadata

Change `.github/actions/publish-homebrew/template.rb.in` when the app bundle name, platform requirements, or uninstall paths change. Its release placeholders and packaging details are propagated automatically. The template currently matches the arm64-only app and macOS 13 deployment target.

Run the publishing checks with Node.js 24 or later:

```sh
node --test .github/actions/publish-homebrew/release.test.mts
```

The tests use a simulated GitHub Contents API, without modifying GitHub or creating a release. They cover bootstrapping, update routing, idempotency, downgrade protection, checksum immutability, template synchronization, and failed or incomplete publishing.
