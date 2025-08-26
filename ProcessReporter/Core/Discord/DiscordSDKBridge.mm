//
//  DiscordSDKBridge.mm
//  ProcessReporter
//
//  Conditional implementation:
//  - If the official Discord Game SDK header (discord.h) is available,
//    use it for full Rich Presence support.
//  - Otherwise, provide a safe no-op shim that simulates a connection
//    and logs calls so the app can build and run without the SDK.
//

#import "DiscordSDKBridge.h"
#import <Foundation/Foundation.h>

#if __has_include("discord.h")
#  include "discord.h"
#  define PR_HAS_DISCORD_SDK 1
#else
#  define PR_HAS_DISCORD_SDK 0
#endif

@interface DiscordSDKBridge () {
#if PR_HAS_DISCORD_SDK
    std::unique_ptr<discord::Core> _core;
#endif
}
@property (nonatomic) BOOL internalConnected;
@property (nonatomic, strong) NSTimer *runCallbacksTimer;
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

- (BOOL)isConnected { return self.internalConnected; }

- (void)initializeWithApplicationId:(NSString *)applicationId {
    if (applicationId.length == 0) {
        NSError *error = [NSError errorWithDomain:@"DiscordSDKError"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid Application ID"}];
        [self notifyDisconnected:error];
        return;
    }

#if PR_HAS_DISCORD_SDK
    discord::Core *rawCore{};
    auto result = discord::Core::Create([applicationId longLongValue], DiscordCreateFlags_NoRequireDiscord, &rawCore);
    if (result == discord::Result::Ok) {
        _core.reset(rawCore);
        _core->SetLogHook(discord::LogLevel::Debug, [](discord::LogLevel level, const char* message) {
            NSLog(@"[Discord SDK] %s", message);
        });

        self.runCallbacksTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                                  target:self
                                                                selector:@selector(runCallbacks)
                                                                userInfo:nil
                                                                 repeats:YES];
        self.internalConnected = YES;
        [self notifyConnected];
    } else {
        NSError *error = [NSError errorWithDomain:@"DiscordSDKError"
                                             code:(NSInteger)result
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize Discord SDK"}];
        [self notifyDisconnected:error];
    }
#else
    // No SDK available: simulate a connection so UI flow works
    self.internalConnected = YES;
    [self notifyConnected];
#endif
}

- (void)runCallbacks {
#if PR_HAS_DISCORD_SDK
    if (_core) { _core->RunCallbacks(); }
#endif
}

- (void)setActivityWithDetails:(NSString *)details
                         state:(NSString *)state
                startTimestamp:(NSNumber *)startTimestamp
                  endTimestamp:(NSNumber *)endTimestamp
                 largeImageKey:(NSString *)largeImageKey
                largeImageText:(NSString *)largeImageText
                 smallImageKey:(NSString *)smallImageKey
                smallImageText:(NSString *)smallImageText
{
    if (!self.internalConnected) return;

#if PR_HAS_DISCORD_SDK
    if (!_core) return;
    discord::Activity activity{};

    if (details) { strcpy(activity.GetDetails(), [details UTF8String]); }
    if (state) { strcpy(activity.GetState(), [state UTF8String]); }

    if (startTimestamp) { activity.GetTimestamps().SetStart([startTimestamp longLongValue]); }
    if (endTimestamp) { activity.GetTimestamps().SetEnd([endTimestamp longLongValue]); }

    if (largeImageKey) { strcpy(activity.GetAssets().GetLargeImage(), [largeImageKey UTF8String]); }
    if (largeImageText) { strcpy(activity.GetAssets().GetLargeText(), [largeImageText UTF8String]); }
    if (smallImageKey) { strcpy(activity.GetAssets().GetSmallImage(), [smallImageKey UTF8String]); }
    if (smallImageText) { strcpy(activity.GetAssets().GetSmallText(), [smallImageText UTF8String]); }

    _core->ActivityManager().UpdateActivity(activity, [](discord::Result result) {
        if (result != discord::Result::Ok) {
            NSLog(@"[Discord SDK] Failed to update activity: %d", (int)result);
        }
    });
#else
    NSLog(@"[Discord SDK Shim] setActivity details=%@ state=%@", details, state);
#endif
}

- (void)clearActivity {
    if (!self.internalConnected) return;
#if PR_HAS_DISCORD_SDK
    if (_core) {
        _core->ActivityManager().ClearActivity([](discord::Result result) {
            if (result == discord::Result::Ok) {
                NSLog(@"[Discord SDK] Activity cleared");
            }
        });
    }
#else
    NSLog(@"[Discord SDK Shim] clearActivity");
#endif
}

- (void)shutdown {
    [self.runCallbacksTimer invalidate];
    self.runCallbacksTimer = nil;
#if PR_HAS_DISCORD_SDK
    _core.reset();
#endif
    self.internalConnected = NO;
}

#pragma mark - Helpers

- (void)notifyConnected {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate discordSDKDidConnect:self];
    });
}

- (void)notifyDisconnected:(NSError *)error {
    self.internalConnected = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate discordSDKDidDisconnect:self error:error];
    });
}

@end

