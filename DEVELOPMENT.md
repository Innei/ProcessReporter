# ProcessReporter Development Guide

This guide provides comprehensive information for developers working on ProcessReporter, a macOS application that monitors and reports user activity.

## Table of Contents

1. [Development Environment Setup](#development-environment-setup)
2. [Code Organization and Conventions](#code-organization-and-conventions)
3. [Building and Debugging](#building-and-debugging)
4. [Testing Strategies](#testing-strategies)
5. [Common Development Tasks](#common-development-tasks)
6. [Performance Profiling](#performance-profiling)
7. [Release Process](#release-process)
8. [Troubleshooting Development Issues](#troubleshooting-development-issues)

## Development Environment Setup

### Prerequisites

- **macOS 15.0+** (Sequoia or later)
- **Xcode 15.0+** with Swift 5.9+
- **Swift Package Manager** (included with Xcode)
- **Git** for version control
- **CocoaPods** (optional, if migrating from older versions)

### Initial Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/ProcessReporter.git
   cd ProcessReporter
   ```

2. **Open in Xcode**
   ```bash
   open ProcessReporter.xcodeproj
   ```

3. **Configure signing**
   - Select the project in Xcode navigator
   - Go to "Signing & Capabilities" tab
   - Select your development team
   - Xcode will automatically manage provisioning profiles

4. **Grant permissions**
   - Build and run the app
   - Grant accessibility permissions when prompted
   - Enable screen recording if needed for window title capture

### LSP Integration (Optional)

For better code intelligence in editors like VS Code:

1. Install xcode-build-server:
   ```bash
   brew install xcode-build-server
   ```

2. Generate build server configuration:
   ```bash
   xcode-build-server config -workspace . -scheme ProcessReporter
   ```

## Code Organization and Conventions

### Project Structure

```
ProcessReporter/
├── main.swift                    # Application entry point
├── AppDelegate.swift            # App lifecycle management
├── Core/                        # Core business logic
│   ├── Reporter/               # Reporting system
│   ├── Database/              # Data persistence
│   ├── MediaInfoManager/      # Media tracking
│   └── Utilities/             # Helper classes
├── Preferences/                 # Settings UI
│   ├── Controllers/           # View controllers
│   ├── DataModels/           # Preference models
│   └── Views/                # Custom views
├── Extensions/                  # Swift extensions
├── Resources/                   # Assets and resources
└── Supporting Files/           # Info.plist, entitlements
```

### Coding Conventions

#### Swift Style Guide

1. **Naming**
   - Use descriptive names: `updateReportingInterval` not `updateRI`
   - Classes/Structs: PascalCase (`ReportModel`)
   - Methods/Variables: camelCase (`sendReport()`)
   - Constants: camelCase with `let` (`let maxRetryCount = 3`)

2. **Code Organization**
   ```swift
   class MyClass {
       // MARK: - Properties
       private let reporter: Reporter
       private var isRunning = false
       
       // MARK: - Initialization
       init(reporter: Reporter) {
           self.reporter = reporter
       }
       
       // MARK: - Public Methods
       func start() {
           // Implementation
       }
       
       // MARK: - Private Methods
       private func processData() {
           // Implementation
       }
   }
   ```

3. **Error Handling**
   ```swift
   enum ReporterError: LocalizedError {
       case networkUnavailable
       case invalidConfiguration
       
       var errorDescription: String? {
           switch self {
           case .networkUnavailable:
               return "Network connection is unavailable"
           case .invalidConfiguration:
               return "Reporter configuration is invalid"
           }
       }
   }
   ```

4. **Async/Await Pattern**
   ```swift
   func fetchData() async throws -> ReportModel {
       // Prefer async/await over completion handlers
       let data = try await networkClient.fetch()
       return ReportModel(from: data)
   }
   ```

#### File Organization

- Keep files under 500 lines
- One primary type per file
- Group related functionality using `// MARK: -` comments
- Place extensions in separate files when they're substantial

## Building and Debugging

### Building from Xcode

1. **Select scheme**: ProcessReporter
2. **Select destination**: My Mac
3. **Build**: ⌘B
4. **Run**: ⌘R

### Building from Command Line

```bash
# Debug build
xcodebuild -project ProcessReporter.xcodeproj \
           -scheme ProcessReporter \
           -configuration Debug \
           build

# Release build
xcodebuild -project ProcessReporter.xcodeproj \
           -scheme ProcessReporter \
           -configuration Release \
           build

# Archive for distribution
xcodebuild -project ProcessReporter.xcodeproj \
           -scheme ProcessReporter \
           -configuration Release \
           archive \
           -archivePath ./build/ProcessReporter.xcarchive
```

### Debugging Techniques

#### 1. Console Logging

```swift
// Use os_log for production logging
import os.log

private let logger = Logger(subsystem: "com.processreporter", category: "Reporter")

func debugMethod() {
    logger.debug("Starting report generation")
    logger.info("Report sent successfully")
    logger.error("Failed to send report: \(error)")
}
```

#### 2. Breakpoints

- **Conditional breakpoints**: Right-click breakpoint → Edit Breakpoint
- **Symbolic breakpoints**: Debug → Breakpoints → + → Symbolic Breakpoint
- **Exception breakpoints**: For catching thrown errors

#### 3. Debug Menu Items

Add debug menu items for testing:

```swift
#if DEBUG
menuItem.submenu?.addItem(NSMenuItem.separator())
menuItem.submenu?.addItem(NSMenuItem(
    title: "Debug: Trigger Report",
    action: #selector(debugTriggerReport),
    keyEquivalent: ""
))
#endif
```

#### 4. Environment Variables

Set in Xcode scheme editor:
- `PROCESSREPORTER_DEBUG=1` - Enable debug logging
- `PROCESSREPORTER_MOCK_DATA=1` - Use mock data sources

### Memory Debugging

1. **Enable Malloc Stack Logging**: Product → Scheme → Edit Scheme → Diagnostics
2. **Use Instruments**: Product → Profile → Leaks/Allocations
3. **Debug Memory Graph**: Debug bar → Debug Memory Graph button

## Testing Strategies

### Unit Testing

#### Test Structure

```swift
import XCTest
@testable import ProcessReporter

class ReporterTests: XCTestCase {
    var reporter: Reporter!
    
    override func setUp() {
        super.setUp()
        reporter = Reporter(configuration: .mock)
    }
    
    override func tearDown() {
        reporter = nil
        super.tearDown()
    }
    
    func testReportGeneration() async throws {
        // Given
        let mockData = createMockWindowInfo()
        
        // When
        let report = try await reporter.generateReport(from: mockData)
        
        // Then
        XCTAssertNotNil(report)
        XCTAssertEqual(report.applicationName, "TestApp")
    }
}
```

#### Mock Objects

```swift
class MockReporterExtension: ReporterExtension {
    var runCalled = false
    var lastReport: ReportModel?
    
    func canRun() -> Bool { true }
    
    func run(report: ReportModel) async throws {
        runCalled = true
        lastReport = report
    }
}
```

### Integration Testing

Test actual integrations with timeouts:

```swift
func testMixSpaceIntegration() async throws {
    let expectation = XCTestExpectation(description: "MixSpace report sent")
    
    let extension = MixSpaceExtension(config: testConfig)
    try await extension.run(report: testReport)
    
    expectation.fulfill()
    await fulfillment(of: [expectation], timeout: 10.0)
}
```

### UI Testing

```swift
class PreferencesUITests: XCTestCase {
    let app = XCUIApplication()
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }
    
    func testPreferencesWindow() {
        app.menuBarItems["ProcessReporter"].click()
        app.menuItems["Preferences..."].click()
        
        XCTAssertTrue(app.windows["Preferences"].exists)
    }
}
```

## Common Development Tasks

### Adding a New Reporter Extension

1. **Create extension class**:
```swift
// File: ProcessReporter/Core/Reporter/Extensions/MyServiceExtension.swift
class MyServiceExtension: ReporterExtension {
    private let apiKey: String
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func canRun() -> Bool {
        return !apiKey.isEmpty
    }
    
    func run(report: ReportModel) async throws {
        // Implement async reporting logic
    }
    
    func runSync(report: ReportModel) throws {
        // Implement sync reporting logic
    }
}
```

2. **Add to Reporter initialization**:
```swift
// In Reporter.swift
private func setupExtensions() {
    if let apiKey = preferences.myServiceApiKey {
        extensions.append(MyServiceExtension(apiKey: apiKey))
    }
}
```

3. **Create preferences UI**:
   - Add view controller in `Preferences/Controllers/`
   - Update `PreferencesWindowController` to include new tab
   - Add data model properties in `PreferencesDataModel`

### Modifying Window Tracking

1. **Update ApplicationMonitor**:
```swift
// Add new tracking capability
private func trackAdditionalInfo(_ app: NSRunningApplication) {
    // Implementation
}
```

2. **Extend FocusedWindowInfo**:
```swift
struct FocusedWindowInfo {
    // Existing properties...
    let additionalData: String? // New property
}
```

### Adding Menu Items

```swift
// In StatusItemManager.swift
private func createMenuItem(title: String, action: Selector?) -> NSMenuItem {
    let item = NSMenuItem(
        title: title,
        action: action,
        keyEquivalent: ""
    )
    item.target = self
    return item
}
```

### Database Schema Changes

1. **Update schema version** in `Database.swift`
2. **Add migration**:
```swift
private func migrateToVersion2() throws {
    try db.execute("""
        ALTER TABLE history 
        ADD COLUMN media_info TEXT
    """)
}
```

## Performance Profiling

### Using Instruments

1. **Time Profiler**:
   ```bash
   # Profile CPU usage
   Product → Profile → Time Profiler
   ```

2. **Allocations**:
   - Track memory allocations
   - Identify retain cycles
   - Monitor memory growth

3. **System Trace**:
   - Analyze system calls
   - Track file I/O
   - Monitor network activity

### Performance Best Practices

1. **Minimize main thread work**:
```swift
Task.detached(priority: .background) {
    let processedData = await self.processHeavyData()
    await MainActor.run {
        self.updateUI(with: processedData)
    }
}
```

2. **Cache expensive operations**:
```swift
private let imageCache = NSCache<NSString, NSImage>()

func getAppIcon(for bundleID: String) -> NSImage? {
    if let cached = imageCache.object(forKey: bundleID as NSString) {
        return cached
    }
    // Load and cache icon
}
```

3. **Batch database operations**:
```swift
try database.transaction { db in
    for record in records {
        try db.insert(record)
    }
}
```

## Release Process

### Pre-release Checklist

1. **Update version number**:
   - `Info.plist`: CFBundleShortVersionString
   - `Info.plist`: CFBundleVersion (build number)

2. **Test on clean system**:
   - Remove app support files
   - Test first-run experience
   - Verify permissions requests

3. **Update documentation**:
   - README.md with new features
   - CHANGELOG.md with version notes
   - API documentation if changed

### Building for Release

1. **Archive the app**:
   ```bash
   xcodebuild -project ProcessReporter.xcodeproj \
              -scheme ProcessReporter \
              -configuration Release \
              clean archive \
              -archivePath ./build/ProcessReporter.xcarchive
   ```

2. **Export for distribution**:
   ```bash
   xcodebuild -exportArchive \
              -archivePath ./build/ProcessReporter.xcarchive \
              -exportPath ./build \
              -exportOptionsPlist ExportOptions.plist
   ```

3. **Notarize the app**:
   ```bash
   xcrun notarytool submit ProcessReporter.zip \
                    --apple-id "your-apple-id" \
                    --team-id "your-team-id" \
                    --wait
   ```

4. **Staple the ticket**:
   ```bash
   xcrun stapler staple ProcessReporter.app
   ```

### Creating DMG

```bash
# Create DMG for distribution
create-dmg \
  --volname "ProcessReporter" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "ProcessReporter.app" 150 150 \
  --hide-extension "ProcessReporter.app" \
  --app-drop-link 450 150 \
  "ProcessReporter.dmg" \
  "build/"
```

## Troubleshooting Development Issues

### Common Issues and Solutions

#### 1. Accessibility Permissions

**Problem**: Window titles are nil
**Solution**:
- Check System Settings → Privacy & Security → Accessibility
- Remove and re-add ProcessReporter
- Restart the app

#### 2. Code Signing Issues

**Problem**: "ProcessReporter" can't be opened
**Solution**:
```bash
# Check code signature
codesign -dv --verbose=4 ProcessReporter.app

# Re-sign if needed
codesign --force --deep --sign "Developer ID" ProcessReporter.app
```

#### 3. Swift Package Resolution

**Problem**: Package resolution failed
**Solution**:
- File → Packages → Reset Package Caches
- Delete `~/Library/Developer/Xcode/DerivedData`
- Clean build folder: ⇧⌘K

#### 4. Database Errors

**Problem**: SQLite errors on startup
**Solution**:
```bash
# Check database integrity
sqlite3 ~/Library/Application\ Support/ProcessReporter/database.db "PRAGMA integrity_check;"

# Reset database (data loss!)
rm ~/Library/Application\ Support/ProcessReporter/database.db
```

### Debug Tips

1. **Enable verbose logging**:
```swift
UserDefaults.standard.set(true, forKey: "VerboseLogging")
```

2. **Check Console.app** for system logs:
   - Filter by "ProcessReporter"
   - Look for crash reports

3. **Use lldb commands**:
```
(lldb) po self.reporter.extensions
(lldb) expr self.isRunning = false
(lldb) thread backtrace
```

### Getting Help

- Check existing issues on GitHub
- Review code comments and documentation
- Use Xcode's documentation viewer: ⌥-click on symbols
- Profile the app to understand performance issues

---

For additional help or to report issues, please visit the project's issue tracker.