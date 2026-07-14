//
//  DiscordSDKBridge.mm
//  ProcessReporter
//
//  Conditional implementation:
//  - If the official Discord Game SDK C API (ffi.h) is available,
//    use it for full Rich Presence support.
//  - Otherwise, provide a safe no-op shim that simulates a connection
//    and logs calls so the app can build and run without the SDK.
//

#import "DiscordSDKBridge.h"
#import <Foundation/Foundation.h>
#include <cstdint>
#include <cstring>

#ifndef DISCORD_DYNAMIC_LIB
#define DISCORD_DYNAMIC_LIB 1
#endif

#if __has_include("ffi.h")
#include "ffi.h"
#define PR_HAS_DISCORD_C 1
#elif __has_include("discord_game_sdk.h")
#include "discord_game_sdk.h"
#define PR_HAS_DISCORD_C 1
#else
#define PR_HAS_DISCORD_C 0
#endif

#define PR_HAS_DISCORD_CPP 0

static NSError *PRDiscordSDKError(NSInteger code, NSString *description) {
  return [NSError errorWithDomain:@"DiscordSDKError"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : description}];
}

@interface DiscordSDKBridge () {
#if PR_HAS_DISCORD_CPP
  std::unique_ptr<discord::Core> _core;
#elif PR_HAS_DISCORD_C
  struct IDiscordCore *_cCore;
#endif
}
@property(nonatomic) BOOL internalConnected;
@property(nonatomic, strong) NSTimer *runCallbacksTimer;
@property(nonatomic) NSUInteger pendingActivityUpdateIdentifier;
@property(nonatomic) NSUInteger nextActivityUpdateIdentifier;
@property(nonatomic, strong) NSTimer *activityUpdateTimeoutTimer;
- (NSUInteger)beginActivityUpdate;
- (void)finishActivityUpdateWithError:(NSError *_Nullable)error
                           identifier:(NSUInteger)identifier;
- (void)handleRuntimeDisconnectWithError:(NSError *)error;
@end

#if PR_HAS_DISCORD_C
static void PRDiscordActivityUpdateCallback(void *callbackData,
                                            enum EDiscordResult result) {
  NSUInteger identifier = (NSUInteger)(uintptr_t)callbackData;
  NSError *error = nil;
  if (result != DiscordResult_Ok) {
    error = PRDiscordSDKError(
        (NSInteger)result,
        [NSString stringWithFormat:@"Discord rejected the activity update (%d)",
                                   (int)result]);
  }
  DiscordSDKBridge *bridge = [DiscordSDKBridge sharedInstance];
  if (result == DiscordResult_ServiceUnavailable ||
      result == DiscordResult_InternalError ||
      result == DiscordResult_NotRunning) {
    [bridge handleRuntimeDisconnectWithError:error];
  } else {
    [bridge finishActivityUpdateWithError:error identifier:identifier];
  }
}
#endif

@implementation DiscordSDKBridge

+ (instancetype)sharedInstance {
  static DiscordSDKBridge *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[self alloc] init];
  });
  return instance;
}

+ (BOOL)isSDKAvailable {
  return PR_HAS_DISCORD_CPP || PR_HAS_DISCORD_C;
}

- (BOOL)isConnected {
  return self.internalConnected;
}

- (NSUInteger)beginActivityUpdate {
  NSUInteger previousIdentifier = self.pendingActivityUpdateIdentifier;
  if (previousIdentifier != 0) {
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-3, @"Discord activity update was superseded")
                             identifier:previousIdentifier];
  }

  self.nextActivityUpdateIdentifier += 1;
  if (self.nextActivityUpdateIdentifier == 0) {
    self.nextActivityUpdateIdentifier = 1;
  }
  NSUInteger identifier = self.nextActivityUpdateIdentifier;
  self.pendingActivityUpdateIdentifier = identifier;
  [self.activityUpdateTimeoutTimer invalidate];
  self.activityUpdateTimeoutTimer =
      [NSTimer scheduledTimerWithTimeInterval:5.0
                                       target:self
                                     selector:@selector(activityUpdateDidTimeout:)
                                     userInfo:@(identifier)
                                      repeats:NO];
  return identifier;
}

- (void)activityUpdateDidTimeout:(NSTimer *)timer {
  NSUInteger identifier = [timer.userInfo unsignedIntegerValue];
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-4, @"Discord activity update timed out")
                           identifier:identifier];
}

- (void)finishActivityUpdateWithError:(NSError *)error
                           identifier:(NSUInteger)identifier {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self finishActivityUpdateWithError:error identifier:identifier];
    });
    return;
  }
  if (identifier == 0 || self.pendingActivityUpdateIdentifier != identifier)
    return;

  self.pendingActivityUpdateIdentifier = 0;
  [self.activityUpdateTimeoutTimer invalidate];
  self.activityUpdateTimeoutTimer = nil;
  [self.delegate discordSDK:self didCompleteActivityUpdateWithError:error];
}

- (void)handleRuntimeDisconnectWithError:(NSError *)error {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self handleRuntimeDisconnectWithError:error];
    });
    return;
  }

  [self.runCallbacksTimer invalidate];
  self.runCallbacksTimer = nil;
  self.internalConnected = NO;
#if PR_HAS_DISCORD_CPP
  discord::Core *failedCore = _core.release();
  if (failedCore != nullptr) {
    dispatch_async(dispatch_get_main_queue(), ^{
      delete failedCore;
    });
  }
#elif PR_HAS_DISCORD_C
  struct IDiscordCore *failedCore = _cCore;
  _cCore = nullptr;
  if (failedCore != nullptr) {
    dispatch_async(dispatch_get_main_queue(), ^{
      failedCore->destroy(failedCore);
    });
  }
#endif
  [self notifyDisconnected:error];
}

- (void)initializeWithApplicationId:(NSString *)applicationId {

  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-5, @"Discord client was reinitialized")
                           identifier:pendingIdentifier];

  [self.runCallbacksTimer invalidate];
  self.runCallbacksTimer = nil;
  self.internalConnected = NO;

  if (applicationId.length == 0) {
    NSError *error =
        [NSError errorWithDomain:@"DiscordSDKError"
                            code:-1
                        userInfo:@{
                          NSLocalizedDescriptionKey : @"Invalid Application ID"
                        }];
    [self notifyDisconnected:error];
    return;
  }

#if PR_HAS_DISCORD_CPP
  _core.reset();
  discord::Core *rawCore{};
  auto result =
      discord::Core::Create([applicationId longLongValue],
                            DiscordCreateFlags_NoRequireDiscord, &rawCore);
  if (result == discord::Result::Ok) {
    _core.reset(rawCore);
    _core->SetLogHook(discord::LogLevel::Debug,
                      [](discord::LogLevel level, const char *message) {
                        NSLog(@"[Discord SDK] %s", message);
                      });

    self.runCallbacksTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                         target:self
                                       selector:@selector(runCallbacks)
                                       userInfo:nil
                                        repeats:YES];
    self.internalConnected = YES;
    [self notifyConnected];
  } else {
    NSError *error = [NSError
        errorWithDomain:@"DiscordSDKError"
                   code:(NSInteger)result
               userInfo:@{
                 NSLocalizedDescriptionKey : @"Failed to initialize Discord SDK"
               }];
    [self notifyDisconnected:error];
  }
#elif PR_HAS_DISCORD_C
  // C API path
  if (_cCore) {
    _cCore->destroy(_cCore);
    _cCore = NULL;
  }

  struct DiscordCreateParams params;
  DiscordCreateParamsSetDefault(&params);
  params.client_id = [applicationId longLongValue];
  params.flags = DiscordCreateFlags_NoRequireDiscord;

  enum EDiscordResult result = DiscordCreate(DISCORD_VERSION, &params, &_cCore);
  if (result == DiscordResult_Ok && _cCore) {
    self.runCallbacksTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                         target:self
                                       selector:@selector(runCallbacks)
                                       userInfo:nil
                                        repeats:YES];
    self.internalConnected = YES;
    [self notifyConnected];
  } else {
    NSError *error = [NSError
        errorWithDomain:@"DiscordSDKError"
                   code:(NSInteger)result
               userInfo:@{
                 NSLocalizedDescriptionKey : @"Failed to initialize Discord SDK"
               }];
    [self notifyDisconnected:error];
  }
#else
  NSError *error =
      [NSError errorWithDomain:@"DiscordSDKError"
                          code:-2
                      userInfo:@{
                        NSLocalizedDescriptionKey : @"Discord SDK is unavailable"
                      }];
  [self notifyDisconnected:error];
#endif
}

- (void)runCallbacks {
#if PR_HAS_DISCORD_CPP
  if (_core) {
    discord::Core *core = _core.get();
    discord::Result result = core->RunCallbacks();
    if (self.internalConnected && result != discord::Result::Ok) {
      [self handleRuntimeDisconnectWithError:PRDiscordSDKError(
                                                 (NSInteger)result,
                                                 @"Discord callback processing failed")];
    }
  }
#elif PR_HAS_DISCORD_C
  if (_cCore) {
    struct IDiscordCore *core = _cCore;
    enum EDiscordResult result = core->run_callbacks(core);
    if (self.internalConnected && result != DiscordResult_Ok) {
      [self handleRuntimeDisconnectWithError:PRDiscordSDKError(
                                                 (NSInteger)result,
                                                 @"Discord callback processing failed")];
    }
  }
#endif
}

- (void)setActivityWithDetails:(NSString *)details
                         state:(NSString *)state
                startTimestamp:(NSNumber *)startTimestamp
                  endTimestamp:(NSNumber *)endTimestamp
                 largeImageKey:(NSString *)largeImageKey
                largeImageText:(NSString *)largeImageText
                 smallImageKey:(NSString *)smallImageKey
                smallImageText:(NSString *)smallImageText {
  // For backward compatibility, forward to the enhanced API without buttons
  [self setActivityWithDetails:details
                         state:state
                   activityType:nil
                startTimestamp:startTimestamp
                  endTimestamp:endTimestamp
                 largeImageKey:largeImageKey
                largeImageText:largeImageText
                 smallImageKey:smallImageKey
                smallImageText:smallImageText
                        buttons:nil];
}

- (void)setActivityWithDetails:(NSString *)details
                         state:(NSString *)state
                startTimestamp:(NSNumber *)startTimestamp
                  endTimestamp:(NSNumber *)endTimestamp
                 largeImageKey:(NSString *)largeImageKey
                largeImageText:(NSString *)largeImageText
                 smallImageKey:(NSString *)smallImageKey
                smallImageText:(NSString *)smallImageText
                        buttons:(NSArray<NSDictionary<NSString *, NSString *> *> *)buttons {
  [self setActivityWithDetails:details
                         state:state
                   activityType:nil
                startTimestamp:startTimestamp
                  endTimestamp:endTimestamp
                 largeImageKey:largeImageKey
                largeImageText:largeImageText
                 smallImageKey:smallImageKey
                smallImageText:smallImageText
                        buttons:buttons];
}

- (void)setActivityWithDetails:(NSString *)details
                         state:(NSString *)state
                   activityType:(NSNumber *)activityType
                startTimestamp:(NSNumber *)startTimestamp
                  endTimestamp:(NSNumber *)endTimestamp
                 largeImageKey:(NSString *)largeImageKey
                largeImageText:(NSString *)largeImageText
                 smallImageKey:(NSString *)smallImageKey
                smallImageText:(NSString *)smallImageText
                        buttons:(NSArray<NSDictionary<NSString *, NSString *> *> *)buttons {
  NSUInteger requestIdentifier = [self beginActivityUpdate];
  if (!self.internalConnected) {
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-6, @"Discord client is not connected")
                             identifier:requestIdentifier];
    return;
  }
#if PR_HAS_DISCORD_CPP
  if (!_core) {
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-6, @"Discord client is not connected")
                             identifier:requestIdentifier];
    return;
  }
  discord::Activity activity{};

  if (details) {
    char *buf = const_cast<char *>(activity.GetDetails());
    const char *src = [details UTF8String];
    std::strncpy(buf, src, 127);
    buf[127] = '\0';
  }
  if (state) {
    char *buf = const_cast<char *>(activity.GetState());
    const char *src = [state UTF8String];
    std::strncpy(buf, src, 127);
    buf[127] = '\0';
  }
  if (activityType != nil) {
    activity.SetType(static_cast<discord::ActivityType>([activityType intValue]));
  }

  if (startTimestamp != nil) {
    activity.GetTimestamps().SetStart([startTimestamp longLongValue]);
  }
  if (endTimestamp != nil) {
    activity.GetTimestamps().SetEnd([endTimestamp longLongValue]);
  }

  if (largeImageKey) {
    char *buf = const_cast<char *>(activity.GetAssets().GetLargeImage());
    const char *src = [largeImageKey UTF8String];
    std::strncpy(buf, src, 127);
    buf[127] = '\0';
  }
  if (largeImageText) {
    char *buf = const_cast<char *>(activity.GetAssets().GetLargeText());
    const char *src = [largeImageText UTF8String];
    std::strncpy(buf, src, 127);
    buf[127] = '\0';
  }
  if (smallImageKey) {
    char *buf = const_cast<char *>(activity.GetAssets().GetSmallImage());
    const char *src = [smallImageKey UTF8String];
    std::strncpy(buf, src, 127);
    buf[127] = '\0';
  }
  if (smallImageText) {
    char *buf = const_cast<char *>(activity.GetAssets().GetSmallText());
    const char *src = [smallImageText UTF8String];
    std::strncpy(buf, src, 127);
    buf[127] = '\0';
  }

  __weak DiscordSDKBridge *weakSelf = self;
  _core->ActivityManager().UpdateActivity(activity, [weakSelf, requestIdentifier](discord::Result result) {
    NSError *error = nil;
    if (result != discord::Result::Ok) {
      error = PRDiscordSDKError(
          (NSInteger)result,
          [NSString stringWithFormat:@"Discord rejected the activity update (%d)",
                                     (int)result]);
    }
    [weakSelf finishActivityUpdateWithError:error identifier:requestIdentifier];
  });
#elif PR_HAS_DISCORD_C
  if (!_cCore) {
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-6, @"Discord client is not connected")
                             identifier:requestIdentifier];
    return;
  }

  struct DiscordActivity activity;
  memset(&activity, 0, sizeof(activity));

  if (details && details.length > 0) {
    const char *src = [details UTF8String];
    if (src) {
      strncpy(activity.details, src, sizeof(activity.details) - 1);
      activity.details[sizeof(activity.details) - 1] = '\0';
    }
  }

  if (state && state.length > 0) {
    const char *src = [state UTF8String];
    if (src) {
      strncpy(activity.state, src, sizeof(activity.state) - 1);
      activity.state[sizeof(activity.state) - 1] = '\0';
    }
  }

  if (activityType != nil) {
    activity.type = (enum EDiscordActivityType)[activityType intValue];
  }

  if (startTimestamp != nil) {
    activity.timestamps.start = [startTimestamp longLongValue];
  }
  if (endTimestamp != nil) {
    activity.timestamps.end = [endTimestamp longLongValue];
  }

  if (largeImageKey && largeImageKey.length > 0) {
    const char *src = [largeImageKey UTF8String];
    if (src) {
      strncpy(activity.assets.large_image, src,
              sizeof(activity.assets.large_image) - 1);
      activity.assets.large_image[sizeof(activity.assets.large_image) - 1] =
          '\0';
    }
  }

  if (largeImageText && largeImageText.length > 0) {
    const char *src = [largeImageText UTF8String];
    if (src) {
      strncpy(activity.assets.large_text, src,
              sizeof(activity.assets.large_text) - 1);
      activity.assets.large_text[sizeof(activity.assets.large_text) - 1] = '\0';
    }
  }

  if (smallImageKey && smallImageKey.length > 0) {
    const char *src = [smallImageKey UTF8String];
    if (src) {
      strncpy(activity.assets.small_image, src,
              sizeof(activity.assets.small_image) - 1);
      activity.assets.small_image[sizeof(activity.assets.small_image) - 1] =
          '\0';
    }
  }

  if (smallImageText && smallImageText.length > 0) {
    const char *src = [smallImageText UTF8String];
    if (src) {
      strncpy(activity.assets.small_text, src,
              sizeof(activity.assets.small_text) - 1);
      activity.assets.small_text[sizeof(activity.assets.small_text) - 1] = '\0';
    }
  }

#if defined(DISCORD_SDK_HAS_BUTTONS) && DISCORD_SDK_HAS_BUTTONS
  // Buttons (up to 2) — requires newer Discord C SDK with buttons fields
  if (buttons && buttons.count > 0) {
    int count = (int)MIN((NSUInteger)2, buttons.count);
    for (int i = 0; i < count; i++) {
      NSDictionary *btn = buttons[i];
      NSString *label = btn[@"label"] ?: @"";
      NSString *url = btn[@"url"] ?: @"";
      const char *labelC = [label UTF8String];
      const char *urlC = [url UTF8String];
      if (labelC) {
        strncpy(activity.buttons[i].label, labelC,
                sizeof(activity.buttons[i].label) - 1);
        activity.buttons[i].label[sizeof(activity.buttons[i].label) - 1] = '\0';
      }
      if (urlC) {
        strncpy(activity.buttons[i].url, urlC,
                sizeof(activity.buttons[i].url) - 1);
        activity.buttons[i].url[sizeof(activity.buttons[i].url) - 1] = '\0';
      }
    }
    activity.button_count = count;
  }
#else
  // Older SDK without buttons: ignore silently
  (void)buttons;
#endif

  IDiscordActivityManager *activityManager =
      _cCore->get_activity_manager(_cCore);
  if (!activityManager) {
    [self finishActivityUpdateWithError:
              PRDiscordSDKError(-7, @"Discord activity manager is unavailable")
                             identifier:requestIdentifier];
    return;
  }
  activityManager->update_activity(activityManager, &activity,
                                   (void *)(uintptr_t)requestIdentifier,
                                   PRDiscordActivityUpdateCallback);
#else
  if (buttons && buttons.count > 0) {
    NSLog(@"[Discord SDK Shim] setActivity details=%@ state=%@ type=%@ buttons=%@", details,
          state, activityType, buttons);
  } else {
    NSLog(@"[Discord SDK Shim] setActivity details=%@ state=%@ type=%@", details, state, activityType);
  }
  [self finishActivityUpdateWithError:nil identifier:requestIdentifier];
#endif
}

- (void)clearActivity {
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-8, @"Discord activity was cleared")
                           identifier:pendingIdentifier];
  if (!self.internalConnected)
    return;
#if PR_HAS_DISCORD_CPP
  if (_core) {
    _core->ActivityManager().ClearActivity([](discord::Result result) {
      if (result == discord::Result::Ok) {
        NSLog(@"[Discord SDK] Activity cleared");
      }
    });
  }
#elif PR_HAS_DISCORD_C
  if (_cCore) {
    IDiscordActivityManager *mgr = _cCore->get_activity_manager(_cCore);
    if (mgr) {
      mgr->clear_activity(mgr, nullptr, nullptr);
    }
  }
#else
  NSLog(@"[Discord SDK Shim] clearActivity");
#endif
}

- (void)cancelPendingActivityUpdate {
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-10, @"Discord activity update was cancelled")
                           identifier:pendingIdentifier];
}

- (void)shutdown {
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  [self finishActivityUpdateWithError:
            PRDiscordSDKError(-9, @"Discord client was shut down")
                           identifier:pendingIdentifier];
  [self.runCallbacksTimer invalidate];
  self.runCallbacksTimer = nil;
#if PR_HAS_DISCORD_CPP
  _core.reset();
#elif PR_HAS_DISCORD_C
  if (_cCore) {
    _cCore->destroy(_cCore);
    _cCore = nullptr;
  }
#endif
  self.internalConnected = NO;
}

#pragma mark - Helpers

- (void)notifyConnected {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self notifyConnected];
    });
    return;
  }
  [self.delegate discordSDKDidConnect:self];
}

- (void)notifyDisconnected:(NSError *)error {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self notifyDisconnected:error];
    });
    return;
  }
  self.internalConnected = NO;
  NSUInteger pendingIdentifier = self.pendingActivityUpdateIdentifier;
  [self finishActivityUpdateWithError:error identifier:pendingIdentifier];
  [self.delegate discordSDKDidDisconnect:self error:error];
}

@end
