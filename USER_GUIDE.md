# ProcessReporter User Guide

ProcessReporter is a personal macOS Presence synchronization utility. It shares a sanitized view of what is active now with destinations selected by the user. It is not a productivity tracker and does not calculate work time, rankings, or focus scores.

## Product Model

| Concept | Meaning |
| --- | --- |
| Presence | The current application, optional window title, and current media |
| Destination | MixSpace, Slack, or Discord |
| Application Icon Hosting | Optional S3-compatible storage used to create public icon URLs |
| Sync Event | A local audit record of one sanitized Presence delivery |

S3 is not a Presence destination. It is used on demand only when a destination can benefit from a public application icon URL.

## First Launch

The onboarding flow has five stages:

1. **Welcome** explains the Presence-only scope.
2. **Sources & Privacy** selects Applications, Window Titles, and Media Playback.
3. **Destination** configures MixSpace, Slack, or Discord. **Set Up Later** completes onboarding with sharing paused.
4. **Icon Hosting** appears when the selected destination can use a public icon URL. It is optional.
5. **Review** displays the final sanitized Presence and ready destinations.

Accessibility permission is required only for Window Titles. ProcessReporter requests it only after the user enables Window Titles and selects **Request Accessibility Access…**. Application identity remains available without Accessibility permission.

## Menu Bar

Select the menu bar icon to open the Presence popover.

| Area | Purpose |
| --- | --- |
| Global status | Shows setup required, paused, syncing, ready, degraded, or failed |
| Current Presence | Shows the sanitized application and media currently eligible for sharing |
| Destinations | Shows the latest result for MixSpace, Slack, and Discord |
| Inline notices | Explains network waiting, destination failures, or icon-hosting degradation |

Select **Current Presence** to open **Privacy & Rules** for the current application. Use the right-click menu for Settings, update checks, and Quit.

## Settings

### General

**Share Presence** is the global delivery switch. It can be enabled only after onboarding is complete and at least one valid destination is enabled.

Sources are independent:

- **Applications** shares foreground application identity.
- **Window Titles** includes the active title when Accessibility permission and privacy policy permit it. It is off by default on new installations.
- **Media Playback** shares the current title, artist, and media application.

General also reports Accessibility, media-provider, credential-storage, and Launch at Login state.

### Destinations

Presence destinations are listed separately from resources.

| Destination | Required configuration | Notes |
| --- | --- | --- |
| MixSpace | HTTP(S) endpoint and API token | May use optional public application icon URLs |
| Slack | Slack API token | Publishes a rendered profile status and supports conditional emoji rules |
| Discord | Discord Application ID | Publishes local Rich Presence through the Discord client |

**Application Icon Hosting** configures S3-compatible storage. It stores public icon URLs locally after successful upload and keeps a local queue of application identifiers whose uploads failed. **Retry Failed Uploads** retries that queue with the saved configuration; **Rebuild Cache** re-uploads the current icon for every cached application. Clearing the local icon cache also clears this queue, but never deletes remote objects.

Each detail page keeps an unsaved draft. **Test** uses that draft without saving it, and external-write tests require confirmation. Leaving a modified page offers Save, Discard, and Cancel.

Credentials are stored outside exported settings. Saved credentials are never displayed in plaintext; use **Replace** or **Remove** to change them.

### Privacy & Rules

Global defaults control whether Application Name, Window Title, and Media are shared or hidden. Application rules can override each field and may define a display alias.

Policy precedence is:

```text
General source off
    > Hide rule
    > Legacy mapping
    > Explicit display alias
```

Consequences:

- A disabled source cannot be re-enabled by an application rule.
- Hide always wins over an alias.
- Existing legacy Filter entries remain fail-closed Hide projections.
- Legacy Mappings remain available under **Advanced** and are not silently rewritten.

Removing an application rule also removes its legacy Hide projection and may allow the application to follow global defaults again. The confirmation dialog states this consequence.

### Sync History

Sync History is a local delivery audit, not an activity-analysis view. Each event can include:

- The sanitized application, allowed window title, and media fields.
- Per-destination result, duration, safe output summary, and normalized error.
- Independent Application Icon result.
- Event ID, timestamp, and trigger reason.

Search supports application names, aliases, and media titles. Events may be filtered by destination and aggregate result. **Copy Event as JSON** exports only the Inspector-visible, sanitized data.

ProcessReporter retains at most 5,000 Sync Events and removes the oldest first. Legacy records remain readable. A legacy `S3` success is shown as an asset result, never as a destination.

### Advanced

Advanced contains:

- Reporting interval, focus-change delivery, and incomplete-media behavior.
- Legacy Mappings.
- Sync History and icon-cache counts and clearing actions.
- Credential-free settings export and validated settings import.
- Application version and update availability.
- Sanitized diagnostics.
- **Reset Settings**, which preserves Sync History, icon cache, and protected credentials.
- **Erase All App Data**, which uses two confirmations and removes settings, local history, icon cache, and protected credential authority before returning to onboarding.

## Privacy and Security

ProcessReporter does not capture screenshots, record keystrokes, read file contents, or persist raw provider payloads. Local Sync Events do not contain credentials, authorization headers, endpoints, full provider responses, application icons, media artwork, or raw capture objects.

Window titles and media metadata may still be sensitive. Keep Window Titles disabled unless required, review **Current Presence**, and add application-specific Hide rules where appropriate.

## Backup and Restore

Use **Advanced > Backup & Restore**.

- Exported property lists exclude MixSpace, Slack, and S3 credentials.
- Import validates the complete settings snapshot before changing current settings.
- Historical exports that contain plaintext credentials require an explicit choice: restore them into protected local storage, import without those backup credentials, or cancel.
- Restored credentials and their imported endpoint or storage target are committed as one protected transaction before the settings become active.
- When backup credentials are not restored, credentials already protected on this Mac are retained only for an unchanged authority; affected integrations are otherwise disabled for review.

## Troubleshooting

### Window titles are unavailable

1. Enable **General > Window Titles**.
2. Select **Open System Settings…** under Accessibility, or use the explicit onboarding permission action.
3. Enable ProcessReporter in **Privacy & Security > Accessibility**.
4. Return to ProcessReporter; capability state refreshes when the window becomes active.

Application names continue to work without this permission.

### Sharing cannot be enabled

Confirm that:

- Onboarding is complete.
- At least one of MixSpace, Slack, or Discord is configured, valid, and enabled.
- Protected credential storage is ready.
- At least one source is enabled if a visible Presence is expected.

S3 configuration alone does not satisfy the destination requirement.

### Status says Waiting for Network

The popover retains the current sanitized presentation and displays a **Waiting for network** notice. The aggregate indicator becomes Degraded when a prior successful destination result exists, otherwise Error. No report is queued while offline; after connectivity returns, ProcessReporter captures and sanitizes the latest Presence again before delivery.

### Application icon upload fails

Open **Destinations > Application Icon Hosting** and review its S3-compatible configuration. Presence delivery may still succeed without the icon; Sync History records the event as degraded when appropriate.

### A destination fails

Open the event in **Sync History**. The Inspector displays a normalized, non-sensitive error code and safe summary. Provider response bodies and credentials are intentionally unavailable.
