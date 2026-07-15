---
name: release-processreporter
description: Prepare and publish a production ProcessReporter macOS release. Use when asked to determine a release version, write verified release notes, update Xcode marketing/build versions, create an annotated Git tag, push a release, monitor the GitHub Release workflow, or diagnose a failed ProcessReporter release or Sparkle appcast.
---

# Release ProcessReporter

Produce one auditable release commit and annotated tag. Let GitHub Actions own the deterministic Apple Silicon arm64 build, distribution signing mode, DMG creation, Sparkle EdDSA appcast, and GitHub Release publication. Developer ID signing and notarization are preferred but optional until Apple credentials are available.

## Safety contract

- Read `AGENTS.md`, `.github/workflows/release.yml`, `ExportOptions.plist`, and the current Xcode build settings before acting.
- Require a clean working tree and `main` checked out at `origin/main` before changing versions.
- Treat an explicit request to release a named version as authorization to commit, tag, and atomically push. Otherwise, obtain confirmation before the external push.
- Never move, replace, force-push, or delete an existing tag. Never replace an existing public GitHub Release.
- Stop when the version is not strictly greater than the version inside the newest real distributed application. Do not trust GitHub's `latest` label alone; inspect semantic tags and release assets when history is inconsistent.
- Stop when notes contain claims that cannot be traced to source changes or verification evidence.
- Preserve unrelated user changes; do not use destructive restore/reset commands.

## One-time repository setup

The release job always requires this stable Sparkle key pair, either as repository secrets or in the protected GitHub `release` environment:

| Secret | Content |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | Fixed private key exported by Sparkle `generate_keys -x` |
| `SPARKLE_PUBLIC_ED_KEY` | Matching base64 public EdDSA key |

Generate the Sparkle pair once, back it up securely, and reuse it for every release. Never generate a new key in CI. This key pair does not require an Apple developer account.

Developer ID distribution uses the following optional, all-or-none group:

| Secret | Content |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `P12_PASSWORD` | Password for the `.p12` |
| `NOTARY_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` |
| `NOTARY_KEY_ID` | App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | App Store Connect issuer ID |

When all five Apple secrets are absent, the workflow publishes an ad-hoc-signed, unnotarized application and places a visible warning in both the GitHub Release and Sparkle notes. The warning must state that Gatekeeper and Accessibility approval may need to be granted again because ad-hoc identity is not stable across builds. In this mode, integration credentials remain in a permissions-restricted local credential journal; the first stable team-signed build migrates them to Keychain. When all five Apple secrets are present, the workflow automatically performs Developer ID signing and notarization. A partial Apple configuration is invalid and must stop the release. Protect `v*` tags from deletion or force updates.

Leave the repository or environment variable `REQUIRE_DEVELOPER_ID` unset (or set to `false`) while Apple credentials are unavailable. After the first Developer ID release, set it permanently to `true`; this prevents accidental credential deletion from silently downgrading later releases to ad-hoc signing.

## Release workflow

### 1. Establish the release boundary

1. Fetch tags and inspect `git status`, the current branch, `origin/main`, semantic tags, and GitHub Releases.
2. Inspect the actual version in the newest distributed app when tag history or `latest` is inconsistent.
3. Select a semantic version `X.Y.Z` strictly greater than the distributed version.
4. Confirm that no local/remote tag or public Release already uses `vX.Y.Z`.

### 2. Update deterministic versions

Run:

```bash
rtk proxy python3 .agents/skills/release-processreporter/scripts/set-release-version.py X.Y.Z
```

The script updates every Xcode configuration to `MARKETING_VERSION=X.Y.Z` and increments the unique positive `CURRENT_PROJECT_VERSION`.

### 3. Write evidence-based release notes

Create `.github/release-notes/vX.Y.Z.md` with this structure:

```markdown
# ProcessReporter vX.Y.Z

## Highlights

- User-visible outcome.

## Fixes and reliability

- Corrected behavior and affected boundary.

## Update notes

- Compatibility or configuration note, if required.
```

Derive statements from the committed diff since the relevant previous release. Prefer observable behavior over implementation details. Omit empty sections and speculative claims. Mention migrations, permission changes, removed compatibility, or required secret/configuration changes explicitly.

### 4. Verify before tagging

Run the repository's focused checks, at minimum:

```bash
rtk proxy bash scripts/setup_discord_sdk.sh
rtk proxy xcodebuild -project ProcessReporter.xcodeproj -scheme ProcessReporter -configuration Debug -destination 'generic/platform=macOS' build
rtk proxy xcodebuild -project ProcessReporter.xcodeproj -scheme ProcessReporter -configuration Release -destination 'generic/platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
rtk git diff --check
rtk proxy plutil -lint ProcessReporter/Info.plist ExportOptions.plist
```

Also run strict-concurrency and static-analysis checks when the release changes Swift runtime or data-flow code. The workflow runs `scripts/prepare_arm64_app.sh` after export because Sparkle's macOS binary framework contains multiple architecture slices even when the app target builds for arm64. Verify that Sparkle resolves to the reviewed version, every shipped executable and the Discord dylib are arm64-only after that preparation step, release notes are non-empty, and tag/project versions match.

### 5. Commit, tag, and atomically push

Review the complete diff. Then create one release commit and annotated tag:

```bash
rtk git add ProcessReporter.xcodeproj/project.pbxproj .github/release-notes/vX.Y.Z.md
rtk git commit -m "release: vX.Y.Z"
rtk git tag -a vX.Y.Z -m "ProcessReporter vX.Y.Z"
rtk git push --atomic origin main vX.Y.Z
```

Do not create the GitHub Release manually. The tag-triggered workflow selects Developer ID or ad-hoc distribution from the available Apple secrets, creates a hidden draft, validates the arm64-only application, generates an appcast whose DMG enclosure has a Sparkle EdDSA signature, publishes the release, and explicitly repairs GitHub's `latest` pointer. The Developer ID branch additionally validates the notarized application and DMG.

### 6. Monitor the real endpoint

Watch the `Release` Actions run through completion. Confirm all of the following before reporting success:

- The workflow concluded successfully.
- The Release is public, non-prerelease, and marked latest.
- The DMG, `appcast.xml`, checksum-covered Markdown notes, and `SHA256SUMS.txt` exist.
- The latest appcast references the new tag, marketing version, build number, and an EdDSA signature.
- The published notes accurately state whether the artifact is Developer ID notarized or ad-hoc signed.
- The asset URLs return successfully.

If Actions fails, preserve the immutable tag, report the failing stage and evidence, and fix forward with explicit user direction. Do not silently republish different bytes under an already public version.
