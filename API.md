# ProcessReporter Internal API Guide

This document describes the internal contracts used to capture, sanitize, deliver, and audit Presence. These types are application-internal; ProcessReporter does not currently expose a binary plugin ABI.

## Reporter extensions

`ReporterExtension` represents a Presence destination. S3-compatible storage does not conform to this protocol because it is asset infrastructure.

```swift
@MainActor
protocol ReporterExtension {
    var name: String { get }
    var isEnabled: Bool { get }

    func register(to reporter: Reporter)
    func unregister(from reporter: Reporter)
    func clearReportedState()
    func waitForPendingCleanup(
        until deadline: ContinuousClock.Instant
    ) async
    func createReporterOptions() -> ReporterOptions
}
```

| Member | Responsibility |
| --- | --- |
| `register` | Install the destination’s generation-scoped send handler |
| `unregister` | Remove the handler and clear retained remote Presence when applicable |
| `clearReportedState` | Cancel or supersede pending publication and clear retained state |
| `waitForPendingCleanup` | Participate in bounded termination cleanup |
| `createReporterOptions` | Declare asset requirements and return the delivery callback |

Default implementations register and unregister by name, perform no remote cleanup, and return immediately from the cleanup wait.

## Reporter options and receipts

```swift
struct ReporterOptions {
    let priority: Int
    let assetCapability: PresenceAssetCapability
    let onSend: @MainActor @Sendable (
        _ data: ReportModel,
        _ assetResolution: PresenceAssetResolution
    ) async -> ReporterDeliveryResult
}

struct ReporterDeliveryReceipt: Sendable {
    let outputSummary: SyncOutputSummary
}

typealias ReporterDeliveryResult = Result<
    ReporterDeliveryReceipt,
    ReporterError
>
```

`data` is already sanitized. A destination must not recover raw source values through another subsystem. A successful receipt contains a safe summary derived from the final provider render. It must not contain credentials, endpoints, authorization headers, public asset URLs, button URLs, or raw responses.

Failed and skipped deliveries do not persist an output summary.

## Asset capability

```swift
enum PresenceAssetCapability {
    case unsupported
    case optionalPublicURL
    case requiredPublicURL
}
```

| Capability | Behavior |
| --- | --- |
| `unsupported` | Destination starts without waiting for icon hosting |
| `optionalPublicURL` | Resolve once; failure degrades the asset but does not block text Presence |
| `requiredPublicURL` | Delivery may be skipped or fail when no public URL can be supplied |

The Reporter resolves one shared asset result for the current delivery generation. Each destination receives `.notRequested` when it declares no asset support.

## Asset hosting

```swift
protocol AssetHostingService: Sendable {
    func resolveApplicationIcon(
        for report: ReportModel,
        capability: PresenceAssetCapability
    ) async -> PresenceAssetResolution
}
```

`S3AssetHostingService` is the production implementation. It stores icon URL records through `DataStore`, keeps upload fingerprints in the local icon-cache authority, and records failed application identifiers in a credential-free local retry queue. `retryFailedUploads()` retries queued applications; `rebuildCachedIcons()` reloads installed application icons for current cache records and uploads them again. It is not registered in the destination mapping and never creates a delivery result.

`PresenceAssetResolution` distinguishes not requested, not configured, cached, uploaded, and failed outcomes. Only the in-memory delivery path may consume the public URL; persisted Sync Events retain a normalized asset status without the URL.

## Delivery errors

```swift
enum ReporterError: Error, Sendable {
    case networkError(String)
    case cancelled(message: String)
    case unknown(message: String, successIntegrations: [String])
    case ratelimitExceeded(message: String)
    case ignored
    case databaseError(String)
}
```

Provider-specific error text may be used for immediate diagnostics, but History persists only the normalized `persistenceCode` and safe `persistenceMessage` projections.

`ignored` represents a destination-specific no-op and is stored as skipped, not succeeded.

## Sanitized report model

`ReportModel` is the internal bridge between source capture and destination rendering. Its scalar fields are sanitized before `ReporterOptions.onSend` is called.

Relevant values include:

```swift
@Model
final class ReportModel {
    var id: UUID
    var processName: String?
    var windowTitle: String?
    var artist: String?
    var mediaName: String?
    var mediaProcessName: String?
    var mediaDuration: Double?
    var mediaElapsedTime: Double?
    var timeStamp: Date
    var integrationsData: Data?

    @Transient var processInfoRaw: FocusedWindowInfo?
    @Transient var mediaInfoRaw: MediaInfo?
}
```

The properties named `processInfoRaw` and `mediaInfoRaw` are transient capture structures. They must not be serialized into History or exported. By the time a destination receives the model, these structures have already been filtered and rewritten to match the sanitized scalar snapshot.

## Privacy policy

`PresencePrivacyEvaluator` combines:

1. source switches from General;
2. global `PresencePrivacyDefaults`;
3. application-specific `ApplicationPresenceRule` values;
4. fail-closed legacy filter projections.

Legacy name and identifier mappings execute after privacy visibility decisions. Explicit application aliases then override mapped display names. Hide always has final priority.

Consumers that need a preview should use the same ordering and sanitized source values; they must not implement a raw-snapshot preview.

## Sync Event persistence

The existing report compatibility field stores a versioned Codable envelope:

```swift
struct StoredSyncEventPayload: Codable, Sendable {
    let trigger: SyncEventTrigger
    let assetResult: SyncAssetResult
    let deliveryResults: [SyncDeliveryResult]
}
```

Each `SyncDeliveryResult` contains:

- stable destination ID and display name;
- succeeded, failed, or skipped status;
- start and finish timestamps;
- a successful safe output summary, when available;
- normalized error code and message for failures.

The decoder returns one of three compatibility states:

| State | Meaning |
| --- | --- |
| Modern | Versioned structured payload decoded successfully |
| Legacy | Historical integration-name array; no fabricated failure detail |
| Unreadable | Scalar sanitized snapshot remains available; payload metadata is unknown |

`DataStore.fetchSyncEvents` returns value projections only. A privacy-stale event is quarantined before physical deletion and excluded from queries until deletion succeeds.

## Source providers

`ApplicationMonitor` supplies focused application identity and optional window information. Accessibility is requested only by explicit user action.

`MediaInfoManager` owns the selected media provider and playback-change lifecycle. The Reporter stops media monitoring when the Media source is disabled, during sleep, and during disposal.

Source callbacks are generation-scoped. Network recovery requests a fresh capture rather than replaying a retained report.

## Settings and credentials

Destination configuration values are held by relays in `PreferencesDataModel`. Secret values are hydrated from `CredentialStore` before Reporter creation.

All integration saves and maintenance operations use `SettingsMutationCoordinator`. Credential changes are persisted before the corresponding runtime relay is updated.

Credential editors use an explicit intent:

```swift
enum DestinationCredentialIntent {
    case unchanged
    case replace
    case remove
}
```

An unchanged credential is never copied into the editor. Export dictionaries omit all credential fields.

## Adding a destination

An implementation is complete only when it provides:

1. a stable `PresenceDestinationID`;
2. a `ReporterExtension` with normalized errors and cleanup semantics;
3. a final-payload-derived safe delivery receipt;
4. an explicit asset capability;
5. native draft, test, save, and credential interactions in Settings;
6. menu-bar and History presentation;
7. verification for cancellation, partial failure, offline recovery, pause, sleep, and termination.

If the component only uploads or resolves application icons, implement `AssetHostingService` instead.
