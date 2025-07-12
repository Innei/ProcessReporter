# ProcessReporter API Documentation

This document provides comprehensive API documentation for extending ProcessReporter with custom integrations and understanding the core interfaces.

## Table of Contents

1. [ReporterExtension Protocol](#reporterextension-protocol)
2. [Core API Interfaces](#core-api-interfaces)
   - [MediaInfoProvider Protocol](#mediainfoprovider-protocol)
   - [ApplicationMonitor](#applicationmonitor)
3. [Data Models](#data-models)
   - [ReportModel](#reportmodel)
   - [FocusedWindowInfo](#focusedwindowinfo)
   - [MediaInfo](#mediainfo)
4. [Integration API Examples](#integration-api-examples)
   - [MixSpace Integration](#mixspace-integration)
   - [S3 Integration](#s3-integration)
   - [Slack Integration](#slack-integration)
5. [Creating Custom Extensions](#creating-custom-extensions)

## ReporterExtension Protocol

The `ReporterExtension` protocol is the primary interface for creating custom integrations with ProcessReporter.

### Protocol Definition

```swift
protocol ReporterExtension {
    /// The unique name identifier for this extension
    var name: String { get }
    
    /// Whether this extension is currently enabled
    var isEnabled: Bool { get }
    
    /// Register this extension with the reporter
    /// - Parameter reporter: The Reporter instance to register with
    func register(to reporter: Reporter) async
    
    /// Unregister this extension from the reporter
    /// - Parameter reporter: The Reporter instance to unregister from
    func unregister(from reporter: Reporter) async
    
    /// Create reporter options for this extension
    /// - Returns: ReporterOptions containing the send handler
    func createReporterOptions() -> ReporterOptions
}
```

### Default Implementation

The protocol provides default implementations for `register` and `unregister`:

```swift
extension ReporterExtension {
    func register(to reporter: Reporter) async {
        await reporter.register(name: name, options: createReporterOptions())
    }
    
    func unregister(from reporter: Reporter) async {
        await reporter.unregister(name: name)
    }
}
```

### ReporterOptions

```swift
struct ReporterOptions {
    /// Async handler for sending report data
    /// - Parameter data: The ReportModel containing activity data
    /// - Returns: Result indicating success or ReporterError
    let onSend: (_ data: ReportModel) async -> Result<Void, ReporterError>
}
```

### ReporterError

```swift
enum ReporterError: Error {
    case networkError(String)
    case cancelled(message: String)
    case unknown(message: String, successIntegrations: [String])
    case ratelimitExceeded(message: String)
    case ignored // Used when extension is disabled
    case databaseError(String)
}
```

## Core API Interfaces

### MediaInfoProvider Protocol

The `MediaInfoProvider` protocol defines the interface for media information sources.

```swift
protocol MediaInfoProvider {
    /// Start monitoring playback changes
    /// - Parameter callback: Closure called when media playback state changes
    func startMonitoring(callback: @escaping MediaInfoManager.PlaybackStateChangedCallback)
    
    /// Stop monitoring playback changes
    func stopMonitoring()
    
    /// Get current media information
    /// - Returns: MediaInfo if media is playing, nil otherwise
    func getMediaInfo() -> MediaInfo?
}
```

#### MediaInfoManager

The `MediaInfoManager` provides a static interface for media monitoring:

```swift
public class MediaInfoManager {
    /// Start monitoring system-wide media playback changes
    /// - Parameter callback: Called when media playback state changes
    public static func startMonitoringPlaybackChanges(
        callback: @escaping (MediaInfo) -> Void
    )
    
    /// Stop monitoring playback changes
    public static func stopMonitoringPlaybackChanges()
    
    /// Get current media information
    /// - Returns: Current MediaInfo if media is playing
    public static func getMediaInfo() -> MediaInfo?
}
```

### ApplicationMonitor

The `ApplicationMonitor` singleton monitors application focus and window changes.

```swift
class ApplicationMonitor {
    /// Shared singleton instance
    static let shared = ApplicationMonitor()
    
    /// Callback for mouse click events
    var onMouseClicked: ((MouseClickInfo) -> Void)?
    
    /// Callback for window focus changes
    var onWindowFocusChanged: ((FocusedWindowInfo) -> Void)?
    
    /// Check if accessibility permissions are enabled
    /// - Returns: true if accessibility is enabled
    func isAccessibilityEnabled() -> Bool
    
    /// Get information about the currently focused window
    /// - Returns: FocusedWindowInfo if available
    func getFocusedWindowInfo() -> FocusedWindowInfo?
    
    /// Start monitoring mouse click events
    func startMouseMonitoring()
    
    /// Stop monitoring mouse click events
    func stopMouseMonitoring()
    
    /// Start monitoring window focus changes
    func startWindowFocusMonitoring()
    
    /// Stop monitoring window focus changes
    func stopWindowFocusMonitoring()
}
```

## Data Models

### ReportModel

The `ReportModel` is the central data structure containing all activity information sent to integrations.

```swift
@Model
class ReportModel {
    /// Unique identifier
    var id: UUID
    
    /// Process/Application information
    var processName: String?
    var windowTitle: String?
    
    /// Media information
    var artist: String?
    var mediaName: String?
    var mediaProcessName: String?
    var mediaDuration: Double?
    var mediaElapsedTime: Double?
    var mediaImageData: Data? // Base64 decoded image data
    
    /// Timestamp of the report
    var timeStamp: Date
    
    /// List of integrations this report was sent to
    var integrations: [String]
    
    /// Raw data structures (transient)
    @Transient var mediaInfoRaw: MediaInfo?
    @Transient var processInfoRaw: FocusedWindowInfo?
    
    /// Set media information from MediaInfo
    func setMediaInfo(_ mediaInfo: MediaInfo)
    
    /// Set process information from FocusedWindowInfo
    func setProcessInfo(_ processInfo: FocusedWindowInfo)
}
```

#### Computed Properties

```swift
extension ReportModel {
    /// Whether this report contains media information
    var hasMediaInfo: Bool
    
    /// Whether this report contains process information
    var hasProcessInfo: Bool
    
    /// Display name (media name or process name)
    var displayName: String
    
    /// Subtitle (artist or window title)
    var subtitle: String?
}
```

### FocusedWindowInfo

Represents information about the currently focused application window.

```swift
struct FocusedWindowInfo {
    /// Application name (e.g., "Safari", "Xcode")
    var appName: String
    
    /// Application icon
    var icon: NSImage?
    
    /// Bundle identifier (e.g., "com.apple.Safari")
    var applicationIdentifier: String
    
    /// Window title (requires accessibility permissions)
    var title: String?
}
```

### MediaInfo

Contains information about currently playing media.

```swift
public struct MediaInfo {
    /// Track/song name
    let name: String?
    
    /// Artist name
    let artist: String?
    
    /// Album name
    let album: String?
    
    /// Album artwork as base64 string
    let image: String?
    
    /// Total duration in seconds
    let duration: Double
    
    /// Current playback position in seconds
    let elapsedTime: Double
    
    /// Process ID of the media player
    let processID: Int
    
    /// Process name (e.g., "Music", "Spotify")
    var processName: String
    
    /// Executable path of the media player
    let executablePath: String
    
    /// Whether media is currently playing
    let playing: Bool
    
    /// Bundle identifier of the media player
    let applicationIdentifier: String?
}
```

## Integration API Examples

### MixSpace Integration

The MixSpace integration sends activity data to a MixSpace instance.

```swift
class MixSpaceReporterExtension: ReporterExtension {
    var name: String = "MixSpace"
    
    var isEnabled: Bool {
        return PreferencesDataModel.shared.mixSpaceIntegration.value.isEnabled
    }
    
    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions(
            onSend: { data in
                if !self.isEnabled {
                    return .failure(.ignored)
                }
                
                // Create payload
                let payload = MixSpaceDataPayload(
                    process: ProcessInfo(
                        iconUrl: iconUrl,
                        description: description,
                        name: data.processName
                    ),
                    media: MediaInfo(
                        artist: data.artist,
                        title: data.mediaName,
                        duration: data.mediaDuration,
                        elapsedTime: data.mediaElapsedTime,
                        processName: data.mediaProcessName
                    ),
                    key: apiToken
                )
                
                // Send HTTP request
                let response = try await AF.request(
                    endpoint,
                    method: method,
                    parameters: payload,
                    encoder: JSONParameterEncoder.default
                )
                .validate()
                .serializingData()
                .value
                
                return .success(())
            }
        )
    }
}
```

### S3 Integration

The S3 integration uploads activity data to an S3-compatible storage service.

```swift
class S3ReporterExtension: ReporterExtension {
    var name: String = "S3"
    
    var isEnabled: Bool {
        return PreferencesDataModel.shared.s3Integration.value.isEnabled
    }
    
    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions(
            onSend: { data in
                // Implementation uploads JSON data to S3
                // Uses AWS SDK or compatible S3 client
                // Configurable bucket, region, and credentials
            }
        )
    }
}
```

### Slack Integration

The Slack integration posts activity updates to a Slack channel.

```swift
class SlackReporterExtension: ReporterExtension {
    var name: String = "Slack"
    
    var isEnabled: Bool {
        return PreferencesDataModel.shared.slackIntegration.value.isEnabled
    }
    
    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions(
            onSend: { data in
                // Implementation sends formatted message to Slack webhook
                // Includes activity summary and optional media information
            }
        )
    }
}
```

## Creating Custom Extensions

### Step 1: Create Extension Class

Create a new class conforming to `ReporterExtension`:

```swift
import Foundation

class MyCustomReporterExtension: ReporterExtension {
    var name: String = "MyCustomIntegration"
    
    var isEnabled: Bool {
        // Read from preferences or configuration
        return PreferencesDataModel.shared.myCustomIntegration.value.isEnabled
    }
    
    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions(
            onSend: { data in
                await self.sendData(data)
            }
        )
    }
    
    private func sendData(_ data: ReportModel) async -> Result<Void, ReporterError> {
        // Implementation here
        do {
            // 1. Extract needed data from ReportModel
            let processInfo = data.processName ?? "Unknown"
            let windowTitle = data.windowTitle
            let mediaInfo = data.hasMediaInfo ? 
                "\(data.mediaName ?? "") by \(data.artist ?? "")" : nil
            
            // 2. Format and send to your service
            try await sendToMyService(
                process: processInfo,
                window: windowTitle,
                media: mediaInfo,
                timestamp: data.timeStamp
            )
            
            return .success(())
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }
}
```

### Step 2: Add Configuration

Add configuration properties to `PreferencesDataModel`:

```swift
// In PreferencesDataModel+Integrations.swift
extension PreferencesDataModel {
    struct MyCustomIntegration: Codable {
        var isEnabled: Bool = false
        var apiEndpoint: String = ""
        var apiKey: String = ""
        // Add other configuration fields
    }
    
    @Observable(key: "myCustomIntegration")
    static var myCustomIntegration = MyCustomIntegration()
}
```

### Step 3: Register Extension

Register your extension in `Reporter.initializeExtensions()`:

```swift
private func initializeExtensions() {
    let extensions: [ReporterExtension] = [
        MixSpaceReporterExtension(),
        S3ReporterExtension(),
        SlackReporterExtension(),
        MyCustomReporterExtension(), // Add your extension here
    ]
    
    for ext in extensions {
        registerExtension(ext)
    }
}
```

### Step 4: Create Preferences UI (Optional)

Create a view controller for configuration in the Preferences window:

```swift
class MyCustomIntegrationViewController: NSViewController {
    // UI elements for configuration
    @IBOutlet weak var enabledCheckbox: NSButton!
    @IBOutlet weak var endpointTextField: NSTextField!
    @IBOutlet weak var apiKeyTextField: NSSecureTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        loadConfiguration()
    }
    
    private func loadConfiguration() {
        let config = PreferencesDataModel.shared.myCustomIntegration.value
        enabledCheckbox.state = config.isEnabled ? .on : .off
        endpointTextField.stringValue = config.apiEndpoint
        apiKeyTextField.stringValue = config.apiKey
    }
    
    @IBAction func saveConfiguration(_ sender: Any) {
        var config = PreferencesDataModel.shared.myCustomIntegration.value
        config.isEnabled = enabledCheckbox.state == .on
        config.apiEndpoint = endpointTextField.stringValue
        config.apiKey = apiKeyTextField.stringValue
        
        PreferencesDataModel.shared.myCustomIntegration.value = config
        AppDelegate.shared.savePreferences()
    }
}
```

### Best Practices

1. **Error Handling**: Always return appropriate `ReporterError` types
   - Use `.ignored` when the extension is disabled
   - Use `.networkError()` for connectivity issues
   - Use `.ratelimitExceeded()` when hitting API limits

2. **Async Operations**: The `onSend` handler is async, use it for:
   - Network requests
   - File I/O operations
   - Database operations

3. **Configuration**: Store sensitive data securely:
   ```swift
   // Use Keychain for API keys
   KeychainHelper.save(key: "myservice_api_key", value: apiKey)
   ```

4. **Rate Limiting**: Implement rate limiting if needed:
   ```swift
   private var lastSentTime: Date?
   private let minInterval: TimeInterval = 60 // 1 minute
   
   func sendData(_ data: ReportModel) async -> Result<Void, ReporterError> {
       if let lastTime = lastSentTime,
          Date().timeIntervalSince(lastTime) < minInterval {
           return .failure(.ratelimitExceeded("Too many requests"))
       }
       // ... send data ...
       lastSentTime = Date()
   }
   ```

5. **Data Privacy**: Be mindful of user privacy:
   - Don't send sensitive window titles
   - Allow users to configure what data is sent
   - Implement data filtering/redaction if needed

### Testing Your Extension

1. **Unit Testing**:
   ```swift
   func testExtensionSendsData() async {
       let extension = MyCustomReporterExtension()
       let options = extension.createReporterOptions()
       
       let testData = ReportModel(
           windowInfo: FocusedWindowInfo(
               appName: "TestApp",
               icon: nil,
               applicationIdentifier: "com.test.app"
           ),
           integrations: [],
           mediaInfo: nil
       )
       
       let result = await options.onSend(testData)
       XCTAssertTrue(result.isSuccess)
   }
   ```

2. **Integration Testing**:
   - Test with real Reporter instance
   - Verify data is sent correctly
   - Test error scenarios

3. **Manual Testing**:
   - Enable extension in preferences
   - Monitor console logs for errors
   - Verify data appears in your service

### Debugging

Enable debug logging in your extension:

```swift
private func log(_ message: String) {
    #if DEBUG
    NSLog("[MyCustomIntegration] \(message)")
    #endif
}
```

Monitor the Reporter's status updates:
- Check the menu bar icon for sync status
- Look for errors in Console.app
- Use breakpoints in your `onSend` handler