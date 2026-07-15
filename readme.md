# ProcessReporter

[![macOS](https://img.shields.io/badge/macOS-15%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

ProcessReporter is a personal macOS Presence synchronization utility. It publishes a privacy-sanitized snapshot of the foreground application and current media to destinations selected by the user.

It is not a productivity tracker: it does not calculate work time, rankings, focus scores, or behavioral analytics.

## Product model

```text
Application / Media Sources
            │
            ▼
  Privacy Rules + Mappings
            │
            ▼
   Sanitized Presence Snapshot
       ┌────┼─────────┐
       ▼    ▼         ▼
  MixSpace Slack   Discord
       │
       ▼
Optional public application icon URL
       │
       ▼
S3-compatible Application Icon Hosting
```

S3-compatible storage is asset infrastructure, not a Presence destination. A hosting failure may degrade an icon enhancement, but it must not block destinations that can receive Presence without a public icon URL.

## Features

- Menu-bar-first Current Presence and destination health.
- Application, optional window-title, and media sources.
- Global privacy defaults plus per-application Share, Hide, and Alias rules.
- MixSpace, Slack, and Discord Presence destinations.
- Optional S3-compatible application icon hosting with a local URL cache.
- Local Sync History containing sanitized snapshots and normalized delivery results.
- Keychain-backed destination credentials with explicit replacement and removal.
- Versioned settings migration and credential-free settings backup.

## Requirements

- macOS 15.0 or later.
- Accessibility permission only when window titles are enabled.
- The optional media helper when media playback synchronization is enabled.
- At least one configured and enabled Presence destination before sharing can start.

## Installation

1. Download the latest build from [Releases](https://github.com/innei/ProcessReporter/releases).
2. Open the disk image and move ProcessReporter to Applications.
3. Launch ProcessReporter and complete Presence Setup.
4. Configure at least one destination; enable window-title access only if required.

## Settings

| Section | Purpose |
| --- | --- |
| General | Sharing, sources, permissions, media helper, and launch behavior |
| Destinations | MixSpace, Slack, Discord, and optional Application Icon Hosting |
| Privacy & Rules | Global privacy defaults and application-specific behavior |
| Sync History | Local audit of sanitized delivery attempts |
| Advanced | Reporting engine, mappings, storage, backup, updates, and diagnostics |

The menu bar popover is the primary operational interface. Settings is intended for configuration and audit rather than continuous activity browsing.

## Development

```bash
xcodebuild \
  -project ProcessReporter.xcodeproj \
  -scheme ProcessReporter \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  build
```

See [ARCHITECTURE.md](ARCHITECTURE.md), [DEVELOPMENT.md](DEVELOPMENT.md), and [USER_GUIDE.md](USER_GUIDE.md) for additional detail.

## License

2025 © Innei. Released under the [MIT License](LICENSE).

[Personal website](https://innei.in/) · GitHub [@Innei](https://github.com/innei/)
