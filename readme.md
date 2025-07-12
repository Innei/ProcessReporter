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

## Development

### Prerequisites

- Xcode 15.0 or later
- macOS 15.0 SDK
- Swift 5.9+

### Setup

1. Clone the repository:

```bash
git clone https://github.com/yourusername/ProcessReporter.git
cd ProcessReporter
```

2. Open in Xcode:

```bash
open ProcessReporter.xcodeproj
```

3. Build and run:
   - Select the ProcessReporter scheme
   - Press ⌘R to build and run

### Architecture

The project follows a modular architecture:

```
ProcessReporter/
├── Core/
│   ├── Reporter/          # Main reporting engine
│   ├── Database/          # SQLite persistence
│   ├── MediaInfoManager/  # Media tracking
│   └── Utilities/         # Application monitoring
├── Preferences/           # Settings UI (MVC)
├── Extensions/            # Reporter extensions
└── Resources/             # Assets and configs
```

### Creating Custom Extensions

To add a new integration:

1. Create a new class conforming to `ReporterExtension`:

```swift
import Foundation

class MyCustomExtension: ReporterExtension {
    var name: String { "My Custom Integration" }
    var requireAsync: Bool { true }

    func canRun() -> Bool {
        // Check if extension is configured
        return UserDefaults.standard.bool(forKey: "MyCustomEnabled")
    }

    func run(data: ReportModel) async throws {
        // Implement your integration logic
        // This method has a 30-second timeout
    }

    func runSync(data: ReportModel) throws {
        // Optional synchronous implementation
    }
}
```

2. Register the extension in `Reporter.swift`:

```swift
extensions.append(MyCustomExtension())
```

3. Add preference UI in the Integrations pane

### Building for Distribution

```bash
# Create a release build
xcodebuild -project ProcessReporter.xcodeproj \
           -scheme ProcessReporter \
           -configuration Release \
           -archivePath ./build/ProcessReporter.xcarchive \
           archive

# Export for distribution
xcodebuild -exportArchive \
           -archivePath ./build/ProcessReporter.xcarchive \
           -exportPath ./build \
           -exportOptionsPlist ExportOptions.plist
```

## API Documentation

### ReportModel Structure

```swift
struct ReportModel {
    let timestamp: Date
    let application: ApplicationInfo?
    let windowTitle: String?
    let mediaInfo: MediaInfo?
    let idleTime: TimeInterval
    let isIdle: Bool
}
```

### Extension Protocol

```swift
protocol ReporterExtension {
    var name: String { get }
    var requireAsync: Bool { get }
    func canRun() -> Bool
    func run(data: ReportModel) async throws
    func runSync(data: ReportModel) throws
}
```

## Troubleshooting

### Common Issues

#### ProcessReporter doesn't track window titles

- Ensure accessibility permissions are granted in System Settings → Privacy & Security → Accessibility
- Restart the application after granting permissions

#### Reports aren't being sent

1. Check the menu bar icon color (should be green when active)
2. Verify integration settings in Preferences
3. Check Console.app for error logs
4. Test individual integrations using the "Test" button

#### High CPU usage

- Reduce reporting frequency in General settings
- Disable media tracking if not needed
- Check for runaway regex patterns in filters

## Contributing

We welcome contributions! Please follow these guidelines:

### Reporting Issues

1. Check existing issues first
2. Include macOS version and ProcessReporter version
3. Provide steps to reproduce
4. Include relevant logs if possible

### Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Commit changes: `git commit -am 'Add your feature'`
4. Push to branch: `git push origin feature/your-feature`
5. Submit a pull request

### Code Style

- Follow Swift API Design Guidelines
- Use SwiftLint for code consistency
- Add tests for new features
- Update documentation as needed

### Testing

Run tests before submitting:

```bash
xcodebuild test -project ProcessReporter.xcodeproj \
                -scheme ProcessReporter \
                -destination 'platform=macOS'
```

## Privacy & Security

ProcessReporter takes privacy seriously:

- All data is processed locally by default
- Network communication only occurs with configured integrations
- Window titles can be filtered or disabled entirely
- No telemetry or analytics are collected
- Source code is open for audit

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with Swift and SwiftUI
- Uses RxSwift for reactive programming
- SQLite for local data persistence
- Inspired by productivity tracking needs

## Support

- **Documentation**: [Wiki](https://github.com/yourusername/ProcessReporter/wiki)
- **Issues**: [GitHub Issues](https://github.com/yourusername/ProcessReporter/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/ProcessReporter/discussions)
- **Email**: support@processreporter.app

---

Made with ❤️ for the macOS community
