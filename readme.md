# ProcessReporter

[![macOS](https://img.shields.io/badge/macOS-15%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org/)
[![Xcode](https://img.shields.io/badge/Xcode-15%2B-blue.svg)](https://developer.apple.com/xcode/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A powerful macOS menu bar application that monitors and reports user activity, including focused applications, window titles, and media playback information.

## Features

- **Real-time Activity Monitoring**: Track focused applications and window titles
- **Media Playback Tracking**: Monitor currently playing media across the system
- **Multiple Integration Options**:
  - MixSpace integration
  - Amazon S3 storage
  - Slack notifications
- **Privacy-Focused**: Configurable filters and mapping rules to protect sensitive information
- **Menu Bar Interface**: Lightweight, always-accessible menu bar application
- **Activity History**: SQLite-based local storage with searchable history
- **Customizable Reporting**: Set reporting intervals and choose which data to track

## Installation

### Requirements

- macOS 15.0 (Sequoia) or later
- Accessibility permissions for window title access

### Download

1. Download the latest release from the [Releases](https://github.com/innei/ProcessReporter/releases) page
2. Open the downloaded `.dmg` file
3. Drag ProcessReporter to your Applications folder
4. Launch ProcessReporter from Applications

### First Launch

On first launch, ProcessReporter will:

1. Request accessibility permissions (required for window title access)
2. Add itself to the menu bar
3. Open the preferences window for initial configuration

## Configuration

### General Settings

Open preferences from the menu bar icon → Preferences (⌘,)

#### Reporting Options

- **Enable/Disable Reporting**: Toggle activity tracking on/off
- **Reporting Interval**: Set how often to send reports (default: 60 seconds)
- **Track Window Titles**: Enable/disable window title collection
- **Track Media Info**: Enable/disable media playback tracking

#### Privacy Settings

- **Idle Timeout**: Set inactivity threshold (default: 300 seconds)
- **Launch at Login**: Configure automatic startup

### Filters

Configure privacy filters to exclude sensitive applications or window titles:

1. Navigate to Preferences → Filters
2. Add applications to exclude from tracking
3. Set up keyword filters for window titles
4. Configure regex patterns for advanced filtering

### Integrations

#### MixSpace Integration

1. Go to Preferences → Integrations → MixSpace
2. Enter your MixSpace server URL
3. Provide API token
4. Test connection

#### S3 Integration

1. Go to Preferences → Integrations → S3
2. Configure:
   - AWS Access Key ID
   - AWS Secret Access Key
   - S3 Bucket Name
   - AWS Region
3. Test upload

#### Slack Integration

1. Go to Preferences → Integrations → Slack
2. Add your Slack webhook URL
3. Configure notification settings
4. Test notification

### Mapping Rules

Create custom mapping rules to transform application or window data:

1. Navigate to Preferences → Mapping
2. Add rules to rename applications
3. Set up window title transformations
4. Use regex for pattern-based mappings

## License

2025 © Innei, Released under the MIT License.

> [Personal Website](https://innei.in/) · GitHub [@Innei](https://github.com/innei/)