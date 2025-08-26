# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ProcessReporter is a macOS application that monitors and reports user activity, including focused applications, window titles, and media playback information. The application runs in the menu bar and can report activity to various services like MixSpace, S3, and Slack.

## Build and Development Commands

### Building and Running
```bash
# Open the project in Xcode
open ProcessReporter.xcodeproj

# Build from command line (if needed)
xcodebuild -project ProcessReporter.xcodeproj -scheme ProcessReporter -configuration Debug build

# The app requires Xcode 15+ and macOS 15+ to build and run
```

### Development Setup
- The project uses xcode-build-server for LSP integration (configured in buildServer.json)
- Dependencies are managed through Swift Package Manager (Package.swift)

## Architecture Overview

### Core Components Structure

1. **Reporter System** (`ProcessReporter/Core/Reporter/`)
   - `Reporter.swift`: Central reporting engine that manages the reporting lifecycle
   - `ReporterExtension.swift`: Protocol for creating reporting extensions
   - Extensions support async/sync operations with 30-second timeout
   - Built-in extensions: MixSpace, S3, Slack

2. **Application Monitoring** (`ProcessReporter/Core/Utilities/`)
   - `ApplicationMonitor.swift`: Monitors focused window changes and mouse clicks
   - Uses NSWorkspace notifications and CGEvent tap for tracking
   - Requires accessibility permissions to read window titles

3. **Media Tracking** (`ProcessReporter/Core/MediaInfoManager/`)
   - `MediaInfoManager.swift`: Monitors system-wide media playback
   - `MediaInfo.swift`: Data model for media information
   - Integrates with macOS media APIs to capture currently playing media

4. **Database Layer** (`ProcessReporter/Core/Database/`)
   - SQLite-based persistence using `Database.swift`
   - Stores application history and report data
   - Thread-safe operations with proper error handling

5. **Preferences System** (`ProcessReporter/Preferences/`)
   - MVC architecture with separate controllers for each preference pane
   - Preference panes: General, Filters, Integrations, Mapping
   - `PreferencesDataModel.swift`: Central data model for all preferences

### Key Design Patterns

1. **Extension Architecture**: Reporter extensions allow modular integration with external services
2. **Reactive Programming**: Uses RxSwift for state management and event handling
3. **MVC Pattern**: Preferences system follows MVC with clear separation of concerns
4. **Singleton Pattern**: Used for managers like Reporter, MediaInfoManager, and ApplicationMonitor

### Data Flow

1. ApplicationMonitor detects window/app changes → Creates FocusedWindowInfo
2. MediaInfoManager tracks media playback → Creates MediaInfo
3. Reporter combines data → Creates ReportModel
4. Reporter extensions process ReportModel → Send to external services

### Important Files and Their Roles

- `main.swift`: Application entry point, sets up menu structure
- `AppDelegate.swift`: Manages app lifecycle, permissions, and initialization
- `StatusItemManager.swift`: Handles menu bar UI and user interactions
- `ReportModel.swift`: Central data structure containing all activity information

### Integration Points

When adding new integrations:
1. Create a new class conforming to `ReporterExtension` protocol
2. Implement required methods: `canRun()`, `run()`, `runSync()` 
3. Add to Reporter's extension list in initialization
4. Create preferences UI in Integrations pane if needed

### Common Development Tasks

When modifying reporting behavior:
- Check `Reporter.swift` for the main reporting loop
- Extensions are processed sequentially with error isolation
- Failed extensions don't block other extensions

When working with preferences:
- Each preference pane has its own ViewController in `Preferences/`
- Data models are in `Preferences/Data/`
- Use `AppDelegate.savePreferences()` to persist changes

When debugging window tracking:
- Check accessibility permissions in System Settings
- Use `ApplicationMonitor`'s logging for window change events
- Window titles may be nil if permissions are insufficient

### Security Considerations

- The app requires accessibility permissions to read window titles
- Handle sensitive information carefully in reports
- Integration credentials should be stored securely in UserDefaults
- Be mindful of user privacy when implementing new features