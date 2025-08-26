# Discord Rich Presence Integration Design (Official SDK)

## Overview

This document outlines the design for integrating Discord Rich Presence functionality into ProcessReporter, allowing users to display their current process state or media playbook status on their Discord profile. 

**Final Approach**: Official Discord Game SDK with C++/Objective-C++ bridge to Swift, providing the most stable and feature-complete Rich Presence integration.

Note on assets feasibility: Discord Rich Presence does not support arbitrary external image URLs for activity assets. Large/small images must reference pre-uploaded Asset Keys in the Discord Developer Portal for the specific Application ID. Therefore, prior mention of “S3 uploaded icons as large image” is not technically feasible with the official SDK (nor typical RPC libraries). This design has been adjusted accordingly: we will use pre-uploaded asset keys (configurable), and fall back to branding-only images when a specific icon is not available.

## Architectural Analysis

### Existing Integration Pattern

Based on the analysis of existing integrations (MixSpace, S3, Slack), all integrations follow a consistent pattern:

1. **Extension-based Architecture**: Each integration implements `ReporterExtension` protocol
2. **Async/Sync Support**: Extensions provide both async and sync execution paths with 30-second timeout
3. **Configuration-driven**: Each integration has its own preferences data model and UI
4. **Error Isolation**: Failed extensions don't block other integrations
5. **Rate Limiting**: Built-in rate limiting for API calls (e.g., Slack has 10 requests/minute)

### Key Components Structure

```
ProcessReporter/Core/Reporter/
├── Reporter.swift                    # Central reporting engine
├── Reporter+Types.swift              # ReporterExtension protocol
├── Reporter+MixSpace.swift           # MixSpace integration
├── Reporter+Slack.swift              # Slack integration  
├── Reporter+S3.swift                 # S3 integration
└── Reporter+Discord.swift            # NEW: Discord integration
```

## Discord Rich Presence Requirements

### Technical Requirements

1. **Official Discord Game SDK Integration**: C++ library with Objective-C++/Swift bridge
2. **Rich Presence Features**:
   - Display current application/process name
   - Show media playback information (artist, track, duration)
   - Support custom images and assets (pre-uploaded Asset Keys + ProcessReporter branding)
   - Show elapsed time/timestamps
   - Support buttons (official SDK feature)

### API Constraints

- **Platform**: macOS x86_64 and Apple Silicon (universal binary support)
- **SDK**: Discord Game SDK 3.2.1+ (C++ library)
- **Communication**: Official Discord IPC handled by SDK
- **Authentication**: Discord Application ID only (no complex OAuth)
- **Dependencies**: 
  - Discord desktop client running
  - Discord Game SDK (`discord_game_sdk.dylib`)
  - C++/Objective-C++ bridge code
  - Swift 5.0+ (already met by ProcessReporter)
- **Rate Limits**: Handled by Discord SDK

## Component Architecture Design

### 1. Discord Reporter Extension

```swift
// Reporter+Discord.swift
import Foundation

class DiscordReporterExtension: ReporterExtension {
    var name: String = "Discord"
    private var discordSDK: DiscordSDKBridge?
    private var isConnected = false
    
    var isEnabled: Bool {
        return PreferencesDataModel.shared.discordIntegration.value.isEnabled
    }
    
    func createReporterOptions() -> ReporterOptions {
        return ReporterOptions(
            onSend: { data in
                return await self.sendDiscordRichPresence(data: data)
            }
        )
    }
    
    private func initializeSDKIfNeeded() {
        guard discordSDK == nil, isEnabled else { return }
        
        let config = PreferencesDataModel.shared.discordIntegration.value
        guard !config.applicationId.isEmpty else { return }
        
        discordSDK = DiscordSDKBridge.shared()
        discordSDK?.delegate = self
        discordSDK?.initialize(withApplicationId: config.applicationId)
    }
}

extension DiscordReporterExtension: DiscordSDKBridgeDelegate {
    func discordSDKDidConnect(_ bridge: DiscordSDKBridge) {
        isConnected = true
        NSLog("[Discord] SDK Connected")
    }
    
    func discordSDKDidDisconnect(_ bridge: DiscordSDKBridge, error: Error?) {
        isConnected = false
        NSLog("[Discord] SDK Disconnected: \(error?.localizedDescription ?? "Unknown")")
    }
}

private func sendDiscordRichPresence(data: ReportModel) async -> Result<Void, ReporterError> {
    initializeRPCIfNeeded()
    
    guard let rpc = rpc, isConnected else {
        return .failure(.networkError("Discord client not connected"))
    }
    
    var presence = RichPresence()
    let config = PreferencesDataModel.shared.discordIntegration.value
    
    // Determine what to show based on priority and availability
    let shouldShowMedia = config.showMediaInfo && 
                         data.mediaName != nil && 
                         (config.prioritizeMedia || !config.showProcessInfo)
    
    if shouldShowMedia {
        // Media State Mapping
        presence.details = data.mediaName
        presence.state = data.artist
        
        // Add media timestamps
        if let duration = data.mediaDuration, let elapsed = data.mediaElapsedTime {
            let now = Date()
            presence.timestamps = RichPresence.Timestamps()
            presence.timestamps?.start = Int(now.timeIntervalSince1970 - elapsed)
            if duration > 0 {
                presence.timestamps?.end = Int(now.timeIntervalSince1970 + (duration - elapsed))
            }
        }
        
        // Large image: use a configured asset key (pre-uploaded in Discord Dev Portal)
        if !config.customLargeImageKey.isEmpty {
            presence.assets = RichPresence.Assets()
            presence.assets?.largeImage = config.customLargeImageKey
            presence.assets?.largeText = config.customLargeImageText.isEmpty ? data.mediaProcessName : config.customLargeImageText
        }
        
    } else if config.showProcessInfo && data.processName != nil {
        // Process State Mapping  
        presence.details = data.processName
        presence.state = data.windowTitle
        
        // Add process timestamp (elapsed time since start)
        if config.showTimestamps {
            presence.timestamps = RichPresence.Timestamps()
            presence.timestamps?.start = Int(Date().timeIntervalSince1970)
        }
        
        // Large image: use a configured asset key (pre-uploaded in Discord Dev Portal)
        if !config.customLargeImageKey.isEmpty {
            presence.assets = RichPresence.Assets()
            presence.assets?.largeImage = config.customLargeImageKey
            presence.assets?.largeText = config.customLargeImageText.isEmpty ? data.processName : config.customLargeImageText
        }
    }
    
    // Always add ProcessReporter branding as small image
    if presence.assets == nil {
        presence.assets = RichPresence.Assets()
    }
    presence.assets?.smallImage = config.brandSmallImageKey.isEmpty ? "processreporter" : config.brandSmallImageKey
    presence.assets?.smallText = "ProcessReporter"
    
    // Large image already handled above when building process/media presence
    
    rpc.setPresence(presence)
    return .success(())
}
```

### 2. Discord SDK Bridge (Objective-C++)

```objc
// DiscordSDKBridge.h
#import <Foundation/Foundation.h>

@class DiscordSDKBridge;

@protocol DiscordSDKBridgeDelegate <NSObject>
- (void)discordSDKDidConnect:(DiscordSDKBridge *)bridge;
- (void)discordSDKDidDisconnect:(DiscordSDKBridge *)bridge error:(NSError * _Nullable)error;
@end

@interface DiscordSDKBridge : NSObject

@property (nonatomic, weak) id<DiscordSDKBridgeDelegate> delegate;
@property (nonatomic, readonly) BOOL isConnected;

+ (instancetype)sharedInstance;

- (void)initializeWithApplicationId:(NSString *)applicationId;
- (void)setActivityWithDetails:(NSString * _Nullable)details
                         state:(NSString * _Nullable)state
                startTimestamp:(NSNumber * _Nullable)startTimestamp
                  endTimestamp:(NSNumber * _Nullable)endTimestamp
                 largeImageURL:(NSString * _Nullable)largeImageURL
                largeImageText:(NSString * _Nullable)largeImageText
                smallImageURL:(NSString * _Nullable)smallImageURL
               smallImageText:(NSString * _Nullable)smallImageText;
- (void)clearActivity;
- (void)shutdown;

@end
```

```cpp
// DiscordSDKBridge.mm
#import "DiscordSDKBridge.h"
#include "discord.h"
#include <memory>
#include <string>

@interface DiscordSDKBridge ()
@property (nonatomic) std::unique_ptr<discord::Core> core;
@property (nonatomic) NSTimer *runCallbacksTimer;
@end

@implementation DiscordSDKBridge

+ (instancetype)sharedInstance {
    static DiscordSDKBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)initializeWithApplicationId:(NSString *)applicationId {
    // Initialize Discord SDK
    auto result = discord::Core::Create([applicationId longLongValue], DiscordCreateFlags_NoRequireDiscord, &_core);
    
    if (result == discord::Result::Ok) {
        // Set up event handlers
        _core->SetLogHook(discord::LogLevel::Debug, [](discord::LogLevel level, const char* message) {
            NSLog(@"[Discord SDK] %s", message);
        });
        
        // Start callback timer
        _runCallbacksTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                              target:self
                                                            selector:@selector(runCallbacks)
                                                            userInfo:nil
                                                             repeats:YES];
        
        _isConnected = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate discordSDKDidConnect:self];
        });
    } else {
        NSError *error = [NSError errorWithDomain:@"DiscordSDKError" 
                                             code:(NSInteger)result 
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize Discord SDK"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate discordSDKDidDisconnect:self error:error];
        });
    }
}

- (void)runCallbacks {
    if (_core) {
        _core->RunCallbacks();
    }
}

- (void)setActivityWithDetails:(NSString *)details
                         state:(NSString *)state
                startTimestamp:(NSNumber *)startTimestamp
                  endTimestamp:(NSNumber *)endTimestamp
                 largeImageURL:(NSString *)largeImageURL
                largeImageText:(NSString *)largeImageText
                smallImageURL:(NSString *)smallImageURL
               smallImageText:(NSString *)smallImageText {
    
    if (!_core || !_isConnected) return;
    
    discord::Activity activity{};
    
    if (details) {
        strcpy(activity.GetDetails(), [details UTF8String]);
    }
    if (state) {
        strcpy(activity.GetState(), [state UTF8String]);
    }
    
    // Set timestamps
    if (startTimestamp) {
        activity.GetTimestamps().SetStart([startTimestamp longLongValue]);
    }
    if (endTimestamp) {
        activity.GetTimestamps().SetEnd([endTimestamp longLongValue]);
    }
    
    // Set assets
    if (largeImageURL) {
        strcpy(activity.GetAssets().GetLargeImage(), [largeImageURL UTF8String]);
    }
    if (largeImageText) {
        strcpy(activity.GetAssets().GetLargeText(), [largeImageText UTF8String]);
    }
    if (smallImageURL) {
        strcpy(activity.GetAssets().GetSmallImage(), [smallImageURL UTF8String]);
    }
    if (smallImageText) {
        strcpy(activity.GetAssets().GetSmallText(), [smallImageText UTF8String]);
    }
    
    _core->ActivityManager().UpdateActivity(activity, [](discord::Result result) {
        if (result != discord::Result::Ok) {
            NSLog(@"[Discord SDK] Failed to update activity: %d", (int)result);
        }
    });
}

- (void)clearActivity {
    if (_core && _isConnected) {
        _core->ActivityManager().ClearActivity([](discord::Result result) {
            if (result == discord::Result::Ok) {
                NSLog(@"[Discord SDK] Activity cleared");
            }
        });
    }
}

- (void)shutdown {
    [_runCallbacksTimer invalidate];
    _runCallbacksTimer = nil;
    _core.reset();
    _isConnected = NO;
}

@end
```

### 3. Discord Activity Data Model

```swift
// DiscordActivity.swift (asset-key based, not external URLs)
struct DiscordActivity {
    var details: String?           // Upper text (song name, app name)
    var state: String?             // Lower text (artist, window title)
    var startTimestamp: Int64?     // Start time for elapsed time display
    var endTimestamp: Int64?       // End time for countdown display
    var largeImageKey: String?     // Pre-uploaded asset key in Discord app
    var largeImageText: String?    // Hover text for large image
    var smallImageKey: String?     // ProcessReporter branding asset key
    var smallImageText: String?    // Hover text for small image
    
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        
        if let details = details { dict["details"] = details }
        if let state = state { dict["state"] = state }
        
        // Timestamps
        var timestamps: [String: Int64] = [:]
        if let start = startTimestamp { timestamps["start"] = start }
        if let end = endTimestamp { timestamps["end"] = end }
        if !timestamps.isEmpty { dict["timestamps"] = timestamps }
        
        // Assets
        var assets: [String: String] = [:]
        if let largeImageKey = largeImageKey { assets["large_image"] = largeImageKey }
        if let largeImageText = largeImageText { assets["large_text"] = largeImageText }
        if let smallImageKey = smallImageKey { assets["small_image"] = smallImageKey }
        if let smallImageText = smallImageText { assets["small_text"] = smallImageText }
        if !assets.isEmpty { dict["assets"] = assets }
        
        return dict
    }
}

// PreferencesDataModel+Discord.swift
extension PreferencesDataModel {
    struct DiscordIntegration: DictionaryConvertible {
        var isEnabled: Bool = false
        var applicationId: String = ""  // Discord Application ID
        var showProcessInfo: Bool = true
        var showMediaInfo: Bool = true
        var prioritizeMedia: Bool = true  // Show media over process when both available
        var showTimestamps: Bool = true
        
        // Image Configuration (asset keys only)
        var customLargeImageKey: String = ""  // Pre-uploaded asset key in Discord Dev Portal
        var customLargeImageText: String = ""
        var brandSmallImageKey: String = "processreporter"  // ProcessReporter branding (small image asset key)
        
        // Future enhancements
        var enableButtons: Bool = false
        var buttonLabel: String = ""
        var buttonUrl: String = ""
    }
    
    static let discordIntegration = BehaviorRelay<DiscordIntegration>(value: .init())
}
```

### 4. State Mapping Strategy

#### Priority Logic
1. **Media First**: If `prioritizeMedia = true` and media is playing, show media info
2. **Process Fallback**: Show process info when no media or media not prioritized
3. **Combined Mode**: Future enhancement to show both

#### Process State Mapping
```swift
RichPresence.details = ReportModel.processName
RichPresence.state = ReportModel.windowTitle
RichPresence.timestamps.start = current_time (for "elapsed time")

// Large image: use configured asset key if set
RichPresence.assets.largeImage = customLargeImageKey
RichPresence.assets.largeText = ReportModel.processName
RichPresence.assets.smallImage = ProcessReporter_brand_icon_asset_key
RichPresence.assets.smallText = "ProcessReporter"
```

#### Media State Mapping
```swift
RichPresence.details = ReportModel.mediaName
RichPresence.state = ReportModel.artist
RichPresence.timestamps.start = current_time - elapsed_time
RichPresence.timestamps.end = current_time + (duration - elapsed_time)

// Large image: use configured asset key if set
RichPresence.assets.largeImage = customLargeImageKey
RichPresence.assets.largeText = ReportModel.mediaProcessName
RichPresence.assets.smallImage = configured_small_icon_asset_key or ProcessReporter_logo
RichPresence.assets.smallText = "ProcessReporter"
```

## Preferences UI Specification

### Discord Integration View Structure

Following the existing pattern in `IntegrationView.swift`:

```swift
// PreferencesIntegrationDiscordView.swift
class PreferencesIntegrationDiscordView: IntegrationView {
    
    // UI Components
    private lazy var enabledCheckbox: NSButton = { /* ... */ }()
    private lazy var applicationIdTextField: NSTextField = { /* ... */ }()
    private lazy var connectionStatusLabel: NSTextField = { /* ... */ }()
    
    // Content Settings
    private lazy var processInfoCheckbox: NSButton = { /* ... */ }()
    private lazy var mediaInfoCheckbox: NSButton = { /* ... */ }()
    private lazy var prioritizeMediaCheckbox: NSButton = { /* ... */ }()
    
    // Visual Settings
    private lazy var largeImageKeyTextField: NSTextField = { /* ... */ }()
    private lazy var largeImageTextTextField: NSTextField = { /* ... */ }()
    private lazy var showTimestampsCheckbox: NSButton = { /* ... */ }()
    
    func setupDiscordUI() {
        // Basic Settings Section
        createRow(leftView: NSTextField(labelWithString: "启用 Discord Rich Presence"), 
                 rightView: enabledCheckbox)
        
        createRow(leftView: NSTextField(labelWithString: "Application ID"), 
                 rightView: applicationIdTextField)
        createRowDescription(text: "从 Discord Developer Portal 获取的应用程序 ID (仅需要 Application ID，无需 Client Secret)")
        
        createRow(leftView: NSTextField(labelWithString: "连接状态"), 
                 rightView: connectionStatusLabel)
        
        // Content Settings Section
        createRowDescription(text: "内容设置")
        createRow(leftView: NSTextField(labelWithString: "显示应用信息"), 
                 rightView: processInfoCheckbox)
        createRow(leftView: NSTextField(labelWithString: "显示媒体信息"), 
                 rightView: mediaInfoCheckbox)
        createRow(leftView: NSTextField(labelWithString: "媒体优先"), 
                 rightView: prioritizeMediaCheckbox)
        createRowDescription(text: "启用时，播放媒体时优先显示媒体信息而不是应用信息")
        
        // Visual Settings Section
        createRowDescription(text: "视觉设置")
        
        createRow(leftView: NSTextField(labelWithString: "自定义大图标"), 
                 rightView: customLargeImageKeyTextField)
        createRow(leftView: NSTextField(labelWithString: "大图标文本"), 
                 rightView: customLargeImageTextTextField)
        createRowDescription(text: "需要在 Discord Developer Portal 中上传资源并使用其 Asset Key")
        
        createRow(leftView: NSTextField(labelWithString: "显示时间戳"), 
                 rightView: showTimestampsCheckbox)
    }
    
    private func updateConnectionStatus() {
        // Update based on Discord RPC connection state
        connectionStatusLabel.stringValue = isConnected ? "已连接" : "未连接"
        connectionStatusLabel.textColor = isConnected ? .systemGreen : .systemRed
    }
}
```

### Simplified Configuration Options

1. **Basic Settings**
   - ✅ Enable/Disable toggle
   - ✅ Discord Application ID (单个字段，简化配置)
   - ✅ Connection status indicator (实时显示连接状态)

2. **Content Settings**
   - ✅ Show process information checkbox
   - ✅ Show media information checkbox  
   - ✅ Prioritize media over process (新增：智能优先级)

3. **Visual Settings**
   - ✅ Custom large image key (覆盖 S3 图标，来自 Discord Developer Portal 资源)
   - ✅ Large image hover text
   - ✅ Show timestamps toggle  
   - ✅ ProcessReporter branding as small icon (自动添加品牌标识)
   - ❌ 移除手动小图标配置 (自动使用品牌标识)
   - ❌ 移除按钮配置 (第一版不实现)

## Implementation Phases

### Phase 1: Core Integration
1. Create `Reporter+Discord.swift` extension
2. Implement basic Discord SDK bridge
3. Add Discord integration to preferences data model
4. Basic rich presence updates (process name only)

### Phase 2: Enhanced Features
1. Media information integration
2. Custom images and assets support
3. Timestamp and elapsed time display
4. Error handling and rate limiting

### Phase 3: UI and Polish
1. Complete preferences UI implementation
2. Status indicators and connection feedback
3. Custom buttons support
4. Testing and optimization

## Technical Considerations

### Asset Handling Notes
- Image assets for Rich Presence must be uploaded in the Discord Developer Portal for the target Application ID.
- External URLs (e.g., S3) cannot be referenced directly by the official SDK.
- Recommended: provide a configurable large image asset key and use a fixed small branding asset key.

### Discord Rich Presence Image Requirements
- **Large Image**: Pre-uploaded Asset Key (configurable). If not configured, omit or use a default branding asset.
- **Small Image**: Fixed ProcessReporter branding asset key (configurable).
- **Image Formats**: Assets are managed by Discord and referenced by key; external URLs are not supported by the official SDK.

### Dependencies
- Discord Game SDK (official) and ObjC++ bridge
- Discord Desktop Client running
  
Note: If we later choose a pure Swift approach, we can swap the bridge to a Swift RPC client, but the asset URL limitation still applies.

### Error Handling
- Discord client connection status monitoring
- S3 icon URL availability fallback
- Invalid Application ID validation
- RPC communication failures
- Graceful degradation when icons unavailable

### Performance
- 缓存 RPC 连接状态避免重复初始化
- 智能检测 presence 变化，避免重复更新
- 异步获取 S3 图标 URL，不阻塞主线程
- 适当的更新频率控制

### Security
- Discord Application ID 验证（数字格式）
- S3 图标 URL 安全性（已通过现有 S3 集成验证）
- 用户输入内容过滤和长度限制

## Integration Points

### Reporter System Integration
```swift
// In Reporter.swift initializeExtensions()
private func initializeExtensions() {
    let extensions: [ReporterExtension] = [
        MixSpaceReporterExtension(),
        S3ReporterExtension(),
        SlackReporterExtension(),
        DiscordReporterExtension(),  // NEW
    ]
    
    for ext in extensions {
        registerExtension(ext)
    }
}
```

### Preferences Integration
```swift
// In PreferencesDataModel.swift
extension PreferencesDataModel {
    private func subscribeGeneralSettingsChanged() {
        // Add Discord integration to settings subscription
        let d4 = Observable.combineLatest(
            preferences.mixSpaceIntegration,
            preferences.s3Integration,
            preferences.slackIntegration,
            preferences.discordIntegration  // NEW
        ).subscribe { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.updateExtensions()
            }
        }
        
        disposers.append(d4)
    }
}
```

### Menu Integration
Add Discord status to status item menu following existing pattern in `StatusItemManager.swift`.

## Testing Strategy

1. **Unit Tests**: Test Discord SDK bridge functionality
2. **Integration Tests**: Test with actual Discord client
3. **UI Tests**: Verify preferences interface behavior
4. **Performance Tests**: Monitor SDK call frequency and responsiveness
5. **Error Scenario Tests**: Test offline/error conditions

## Future Enhancements

1. **Advanced Rich Presence**
   - Party information for collaborative apps
   - Join/spectate functionality for supported applications
   - Custom activity types beyond "Playing"

2. **Smart Detection**
   - Automatic application icon detection
   - Context-aware activity descriptions
   - Time-based presence rules

3. **User Experience**
   - Rich presence preview in preferences
   - One-click Discord app setup
   - Activity templates and presets

## Implementation Guide (Revised - Swift Only)

### Step 1: Setup Discord Application
1. Visit [Discord Developer Portal](https://discord.com/developers/applications)
2. Create new application or use existing one
3. Copy the **Application ID** (这是唯一需要的凭据)
4. (Optional) Upload custom assets in Rich Presence → Art Assets section
5. Name your application assets with memorable keys like "logo", "icon" etc.

### Step 2: Add Discord Game SDK
1. Download Discord Game SDK from: `https://dl-game-sdk.discordapp.net/latest/discord_game_sdk.zip`
2. Add SDK files to Xcode project:
   ```
   ProcessReporter/Frameworks/DiscordSDK/
   ├── discord.h                    # C++ header
   ├── discord_game_sdk.dylib       # macOS x86_64 library
   └── discord_game_sdk_arm64.dylib # macOS ARM64 library (universal binary)
   ```
3. Link dynamic library in Build Phases → Link Binary With Libraries
4. Set up library search paths and ensure both architectures are supported

### Step 3: Create SDK Bridge
1. Create `DiscordSDKBridge.h` (Objective-C header)
2. Create `DiscordSDKBridge.mm` (Objective-C++ implementation)
3. Implement Discord SDK lifecycle management
4. Handle activity updates and callbacks
5. Provide clean Swift-compatible interface

### Step 4: Implement Reporter Extension
1. Create `Reporter+Discord.swift` with `DiscordReporterExtension` class
2. Use `DiscordSDKBridge` for all SDK communication
3. Implement rich presence data mapping logic (process vs media priority)
4. Integrate S3 icon URLs for large images
5. Add proper error handling and connection status tracking

### Step 5: Add Data Models
1. Update `PreferencesDataModel+Discord.swift` with Discord preferences
2. Implement `DictionaryConvertible` protocol for persistence
3. Add RxSwift BehaviorRelay for reactive updates
4. Include validation for Application ID format (numeric string)

### Step 6: Create Preferences UI
1. Create `PreferencesIntegrationDiscordView.swift` following existing patterns
2. Implement connection status indicator with real-time updates
3. Add form validation and user feedback
4. Test all UI interactions and data binding

### Step 7: Integration Points
1. Add Discord extension to `Reporter.swift` initialization
2. Include Discord preferences in settings subscription
3. Update status item menu to show Discord status (optional)
4. Add proper cleanup in app termination

### Step 8: Testing and Validation
1. Test with Discord client running and stopped
2. Test both x86_64 and Apple Silicon architectures
3. Verify rich presence appears correctly in Discord profile
4. Test all configuration options and edge cases
5. Performance testing with frequent updates

### Implementation Files (Official SDK)

```
ProcessReporter/Frameworks/DiscordSDK/
├── discord.h                           # Discord Game SDK C++ header
├── discord_game_sdk.dylib              # macOS x86_64 library
└── discord_game_sdk_arm64.dylib        # macOS Apple Silicon library

ProcessReporter/Core/Discord/
├── DiscordSDKBridge.h                  # Objective-C header
└── DiscordSDKBridge.mm                 # Objective-C++ implementation

ProcessReporter/Core/Reporter/
└── Reporter+Discord.swift              # Discord integration extension

ProcessReporter/Preferences/
├── DataModels/
│   └── PreferencesDataModel+Discord.swift   # Discord preferences model
└── Views/
    └── PreferencesIntegrationDiscordView.swift # Discord preferences UI
```

### Required Dependencies
- ✅ **Official Discord Game SDK** (C++ library with official support)
- ✅ Universal binary support (x86_64 + Apple Silicon)
- ✅ Objective-C++/Swift bridge (mature, stable interop)
- ✅ Existing ProcessReporter frameworks (RxSwift, SnapKit for UI)
- ✅ macOS 11.0+ (Discord SDK requirement)
- ✅ Swift 5.0+ (already supported by ProcessReporter)
- ✅ Direct S3 icon integration via existing `DataStore.shared.iconURL()` API
- ✅ Full Discord Rich Presence feature support (including buttons)
- ✅ Robust error handling and edge case management by official SDK
- ✅ Future compatibility with Discord updates

This design provides a comprehensive foundation for implementing Discord Rich Presence integration while maintaining consistency with the existing ProcessReporter architecture and user experience patterns.
