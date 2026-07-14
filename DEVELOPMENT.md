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
- **Xcode 16.2+**
- **Swift Package Manager** (included with Xcode)
- **Git** for version control

### Initial Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/Innei/ProcessReporter.git
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

The persistence layer uses SwiftData, not handwritten SQLite migrations.

1. Preserve the existing `VersionedSchema` as the source schema.
2. Add a new `VersionedSchema` with a strictly newer `versionIdentifier`.
3. Append both schemas to `MigrationPlan.schemas` and add an explicit
   lightweight or custom `MigrationStage`.
4. Verify migration using a copied store from the previous released version
   and assert user-visible history, icon records, and row counts.
5. Propagate migration failures to the user while preserving the original
   store. Never use store deletion as a migration fallback.

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

Production releases are prepared by the repository-local
`$release-processreporter` skill in
`.agents/skills/release-processreporter/SKILL.md`.

The skill performs the human- and source-aware work:

1. Establish the real previous release and select a strictly newer semantic version.
2. Update `MARKETING_VERSION` and the monotonic `CURRENT_PROJECT_VERSION`.
3. Write evidence-based notes at `.github/release-notes/vX.Y.Z.md`.
4. Run Debug, universal Release, strict-concurrency, and metadata checks.
5. Create a release commit and annotated tag, then atomically push both.

The tag-triggered `.github/workflows/release.yml` performs the deterministic
distribution work: universal archiving, distribution signing, DMG creation,
Sparkle EdDSA appcast generation, checksums, and draft-to-public GitHub Release
publication. The workflow publishes only after every validation passes and
explicitly marks the new release as GitHub `latest`.

Apple credentials are optional. If all five Developer ID and notarization
secrets are absent, the workflow produces an ad-hoc-signed, unnotarized release
and adds a visible warning to its GitHub and Sparkle release notes. Since the
ad-hoc identity is not stable across builds, macOS may require Gatekeeper and
Accessibility approval again. Integration credentials remain in a
permissions-restricted local credential journal in this mode and are migrated
to Keychain by the first stable team-signed build.
If all five are present, the same workflow automatically signs, notarizes, and
staples the application and DMG. A partial Apple configuration is rejected.
Leave `REQUIRE_DEVELOPER_ID` unset or `false` for the current no-certificate
phase. After the first Developer ID release, set this GitHub variable permanently
to `true` so missing Apple credentials fail instead of silently downgrading the
release to ad-hoc signing.

The matching `SPARKLE_PRIVATE_KEY` and `SPARKLE_PUBLIC_ED_KEY` secrets remain
mandatory in both modes. They do not require an Apple developer account and
protect the authenticity of automatic updates. Generate this pair once, store
it securely, and never rotate it as part of a routine release.

Do not create or replace release assets manually. Configure secrets accessible
to the GitHub `release` job as listed in the release skill before pushing the
first production tag.

Stable team-signed builds store integration credentials in the macOS Keychain.
Ad-hoc builds retain them in a private Application Support credential journal
because their signing identity is not stable enough for durable Keychain ACL
access. Settings exports intentionally omit Slack, MixSpace, and S3 credentials;
importing such a backup preserves the credentials already stored on the current
Mac. The first stable team-signed build migrates journaled and legacy
local-preference values into a versioned Keychain service.

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
codesign --verify --deep --strict --verbose=2 ProcessReporter.app
```

Do not repair a production artifact with `codesign --deep`. Rebuild it through
the Release workflow so Xcode signs nested Sparkle components in the correct
order, then notarizes and staples the final application and DMG.

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
# Inspect a copy; the application intentionally preserves the original store.
cp -a ~/Library/Application\ Support/dev.innei.ProcessReporterV2/db.store* /tmp/
sqlite3 /tmp/db.store "PRAGMA integrity_check;"
```

The live SwiftData store is
`~/Library/Application Support/dev.innei.ProcessReporterV2/db.store` with
possible sidecar files. Do not delete it as a generic recovery step. Preserve
the complete store set and diagnose the reported initialization error first.

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
