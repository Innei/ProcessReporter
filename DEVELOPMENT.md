# ProcessReporter Development Guide

ProcessReporter is a macOS menu-bar Presence synchronization application. Its central correctness boundary is the sanitized Presence snapshot: raw source data must pass through privacy policy before delivery, presentation, diagnostics, or persistence.

## Requirements

- Apple Silicon Mac (`arm64`); Intel build and release targets are intentionally unsupported.
- macOS 15.0 or later.
- Xcode 16.2 or later.
- Swift Package Manager dependencies resolved by Xcode.
- A signing identity for interactive Keychain and Accessibility testing.

Accessibility is optional at the product level and is required only for window-title capture. Application identity and media synchronization must remain usable without it.

## Build

```bash
xcodebuild \
  -project ProcessReporter.xcodeproj \
  -scheme ProcessReporter \
  -configuration Debug \
  -derivedDataPath /tmp/ProcessReporter-derived \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build
```

Run static analysis separately:

```bash
xcodebuild \
  -project ProcessReporter.xcodeproj \
  -scheme ProcessReporter \
  -configuration Debug \
  -derivedDataPath /tmp/ProcessReporter-analyze \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  analyze
```

## Ownership boundaries

```text
ProcessReporter/
├── Companion/
│   ├── Connection/            Non-secret metadata + protected Device Token adapter
│   ├── Domain/                Sanitized first-party Presence values
│   ├── LiveDesk/              Capability-gated heartbeat and lifecycle owner
│   ├── Protocol/              Versioned DTOs and the only seconds-to-ms mapper
│   └── Transport/             Authenticated HTTP and ordered device sequence
├── Core/
│   ├── Reporter/              Delivery orchestration and provider adapters
│   ├── Database/              SwiftData authority and value projections
│   ├── MediaInfoManager/      Media provider lifecycle
│   └── Utilities/             Monitoring, credentials, network, migrations
├── Presence/
│   ├── Assets/                S3-compatible icon hosting
│   ├── Capture/               AppKit capture adapters and pure sanitizers
│   ├── Domain/                UI and Sync Event value models
│   └── Policy/                Privacy rules and sanitized evaluation
├── Features/
│   ├── MenuBar/               Native status menu presentation
│   ├── Onboarding/            First-run Presence setup
│   └── Settings/              General, destinations, privacy, history, advanced
├── Preferences/DataModels/    Persisted compatibility models and relays
├── Windows/                   AppKit window ownership
└── AppDelegate.swift          Application lifecycle and bounded shutdown
```

AppKit owns the application, status item, native menu, and Settings window. SwiftUI owns Settings and onboarding content. Do not move lifecycle ownership into SwiftUI as part of a page-level change.

## Presence pipeline

```text
Source callbacks
    │
    ▼
Generation-scoped preparation
    │
    ▼
Privacy policy + legacy compatibility mapping
    │
    ▼
Sanitized ReportModel
    ├──> Menu-bar Current Presence
    ├──> Destination delivery
    └──> Versioned Sync Event envelope
```

The following invariants are mandatory:

1. A stale generation must not deliver or remain visible in History.
2. Offline recovery rebuilds a fresh snapshot; it does not replay a retained raw model.
3. Credential authority failure pauses sharing fail-closed.
4. S3 is an `AssetHostingService`, never a `ReporterExtension` or destination.
5. Provider payloads, endpoints, credentials, public asset URLs, and raw responses do not enter Sync History.
6. A destination output summary describes a successful final provider render only.
7. Companion Device Tokens exist only in protected credential memory and the Authorization header; they never enter a DTO, History, or diagnostics.
8. Every Companion v2 nullable key is encoded explicitly as JSON `null`; missing and cleared are not interchangeable.

## Companion Protocol v2 contract harness

The repository has no test target, so the pure Companion domain and transport boundary has a standalone behavior harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  ProcessReporter/Companion/Domain/SanitizedPresenceSnapshot.swift \
  ProcessReporter/Companion/Domain/CompanionMediaSessionTracker.swift \
  ProcessReporter/Companion/Protocol/CompanionProtocolV2.swift \
  ProcessReporter/Companion/Protocol/CompanionCapabilityNegotiator.swift \
  ProcessReporter/Companion/Protocol/CompanionPresenceDTOMapper.swift \
  ProcessReporter/Companion/Transport/CompanionHTTPClient.swift \
  ProcessReporter/Companion/Transport/YohakuPresenceClient.swift \
  ProcessReporter/Companion/LiveDesk/CompanionPresenceAuthority.swift \
  scripts/test_companion_protocol_v2.swift \
  -o /tmp/test_companion_protocol_v2

/tmp/test_companion_protocol_v2
```

The harness validates observable wire behavior: explicit nulls, Unicode normalization, millisecond conversion, position clamping, resource-host rejection, required nullable response keys, capability negotiation, response request-ID correlation, durable concurrent sequence allocation, Authorization-only credentials, the fixed Companion version header on clear and replace, exact-request retry after an ambiguous transport failure, a deliberately early wake remaining behind the bounded cleanup task, bounded clear returning before its deadline, and schema or feature rejection selecting capability refresh rather than a blind degraded heartbeat.

The protected connection and application-only capture slice has a separate harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  ProcessReporter/Companion/Domain/SanitizedPresenceSnapshot.swift \
  ProcessReporter/Companion/Protocol/CompanionProtocolV2.swift \
  ProcessReporter/Companion/Protocol/CompanionCapabilityNegotiator.swift \
  ProcessReporter/Companion/Protocol/CompanionPresenceDTOMapper.swift \
  ProcessReporter/Companion/Transport/CompanionHTTPClient.swift \
  ProcessReporter/Companion/Connection/CompanionConnectionStore.swift \
  ProcessReporter/Companion/Connection/CompanionPairingClient.swift \
  ProcessReporter/Presence/Capture/CompanionApplicationPresenceSanitizer.swift \
  scripts/test_companion_connection_capture.swift \
  -o /tmp/test_companion_connection_capture

/tmp/test_companion_connection_capture
```

It verifies that protected storage and capabilities are checked before the one-time pairing code is consumed; feature-off, unsupported-schema, and outdated-client responses stop before claim with fixed local states; the code stays in the POST body; the global pairing error envelope retains only an allowlisted fixed code; the minted Token crosses directly into protected storage; pairing remains publicly disabled; disabled startup does not resolve the Device Token; a concurrent disable wins over an in-flight credential resolution; non-secret metadata contains no credential-shaped field or token value; explicit opt-in resolves the protected connection; removal clears both authorities; privacy-hidden applications become an idle snapshot; hidden window titles encode as `null`; and the first slice never fabricates media.

Media timing has a separate provider-level behavior harness:

```bash
xcrun swiftc -warnings-as-errors -strict-concurrency=complete \
  ProcessReporter/Core/MediaInfoManager/MediaInfo.swift \
  ProcessReporter/Core/MediaInfoManager/MediaInfoProvider.swift \
  ProcessReporter/Core/MediaInfoManager/AdaptiveMediaInfoProvider.swift \
  scripts/test_media_timing_semantics.swift \
  -o /tmp/test_media_timing_semantics

/tmp/test_media_timing_semantics
```

It verifies that unavailable timing remains `nil`, real zero remains `0`, enrichment fills only missing values, and a known duration clamps an out-of-range position.

## Settings mutations

Integration saves, imports, reset, and erase operations share `SettingsMutationCoordinator`. New mutation paths must use this coordinator so that a stale editor cannot reintroduce data after maintenance completes.

Credentials are persisted through `CredentialStore` transaction helpers. Persisted configuration excludes secret values. Editors must:

- keep a local draft;
- never refill a stored secret into a control;
- represent secret intent as keep, replace, or remove;
- validate before mutating relays;
- update the runtime relay only after credential persistence succeeds.

Settings export intentionally excludes MixSpace, Slack, and S3 credentials. Import must parse and validate a complete staged snapshot before changing any live preference. Legacy plaintext credentials require explicit user consent and must be aggregated into one `CredentialStore.apply` transaction with their redacted integration preferences; do not persist each integration independently.

## Persistence

`DataStore` is the only component that should interact with SwiftData models. Cross-actor consumers receive value types such as `ReportValue`, `SyncEventValue`, and `IconValue`.

Sync Events are stored in a versioned Codable envelope within the existing report compatibility field. The decoder must continue to distinguish:

- modern structured events;
- legacy integration-name arrays;
- unreadable legacy payloads.

Do not fabricate failure details for legacy events. Do not change the SwiftData schema merely to change presentation.

## Adding a Presence destination

1. Add a stable `PresenceDestinationID` and user-facing metadata.
2. Implement `ReporterExtension` and return `ReporterOptions` with the correct asset capability.
3. Render the provider payload only from the sanitized `ReportModel`.
4. Return a normalized delivery result and a safe output summary for successful delivery.
5. Implement remote-state cleanup when the provider retains Presence.
6. Add a native destination draft editor with validation, test, save, credential replacement/removal, and dirty-navigation protection.
7. Add destination status to the menu bar and Sync History filters.
8. Verify partial success, total failure, cancellation, offline recovery, pause, sleep, and termination.

Do not add S3-compatible storage through this path. Asset hosting belongs under `Presence/Assets` and is resolved only when a destination advertises an icon URL capability.

## Verification

The project currently has no dedicated test target. Changes therefore require focused runtime and migration checks in addition to a strict build.

Prefer behavior-oriented tests when a test target is introduced. Avoid tests that merely restate constant tables, enum cases, or object literals.

Minimum validation for a material change:

| Change | Required evidence |
| --- | --- |
| Privacy or mapping | Sanitized preview and delivered snapshot agree; Hide overrides Alias |
| Destination | Draft test, successful delivery, normalized failure, and safe History output |
| Asset hosting | Optional and required capability paths; fallback remains destination-specific |
| Migration | Fresh install plus each prior schema boundary in isolated defaults |
| Credentials | Keychain success, unavailable authority, replacement, removal, and export exclusion |
| Lifecycle | Pause, sleep/wake, offline/recovery, and bounded termination cleanup |
| Settings UI | Minimum window size, keyboard navigation, VoiceOver labels, and dirty draft handling |

## Isolated runtime testing

Never smoke-test migrations against the installed application’s bundle identifier or Application Support directory. Build with a unique identifier and launch with an isolated home:

```bash
xcodebuild \
  -project ProcessReporter.xcodeproj \
  -scheme ProcessReporter \
  -configuration Debug \
  -derivedDataPath /tmp/ProcessReporter-isolated \
  PRODUCT_BUNDLE_IDENTIFIER=dev.example.ProcessReporter.smoketest \
  CODE_SIGNING_ALLOWED=NO \
  build

CFFIXED_USER_HOME=/tmp/processreporter-smoketest-home \
  /tmp/ProcessReporter-isolated/Build/Products/Debug/ProcessReporter_DEV.app/Contents/MacOS/ProcessReporter_DEV
```

Use a new identifier for every migration fixture when `cfprefsd` caching could invalidate the result.

## Release

Production publication requires signing, notarization, a valid Sparkle feed, and an EdDSA public key. Use the repository release procedure rather than ad hoc archive commands. A build without valid Sparkle metadata intentionally disables update checks.

The release workflow runs `scripts/prepare_arm64_app.sh` after export. This removes Intel slices from precompiled dependencies such as Sparkle and re-signs nested code from the inside out before notarization or DMG creation. A plain Xcode arm64 build is not sufficient evidence that every embedded binary is arm64-only.

## Documentation

When behavior changes, update the closest user and architecture references:

- `PRESENCE_PRODUCT_UI_SPEC.md` for product decisions and acceptance criteria;
- `USER_GUIDE.md` for user workflows;
- `ARCHITECTURE.md` for runtime ownership and invariants;
- `API.md` for internal extension contracts;
- `readme.md` for the public product boundary.
