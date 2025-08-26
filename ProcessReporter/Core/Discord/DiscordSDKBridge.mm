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
#include <cstring>

#ifndef DISCORD_DYNAMIC_LIB
#define DISCORD_DYNAMIC_LIB 1
#endif

#if __has_include("ffi.h")
#include "ffi.h"
#define PR_HAS_DISCORD_C 1
#else
#define PR_HAS_DISCORD_C 0
#endif

#define PR_HAS_DISCORD_CPP 0

@interface DiscordSDKBridge () {
#if PR_HAS_DISCORD_CPP
  std::unique_ptr<discord::Core> _core;
#elif PR_HAS_DISCORD_C
  struct IDiscordCore *_cCore;
#endif
}
@property(nonatomic) BOOL internalConnected;
@property(nonatomic, strong) NSTimer *runCallbacksTimer;
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

- (BOOL)isConnected {
  return self.internalConnected;
}

- (void)initializeWithApplicationId:(NSString *)applicationId {
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
  // No SDK available: simulate a connection so UI flow works
  self.internalConnected = YES;
  [self notifyConnected];
#endif
}

- (void)runCallbacks {
#if PR_HAS_DISCORD_CPP
  if (_core) {
    _core->RunCallbacks();
  }
#elif PR_HAS_DISCORD_C
  if (_cCore) {
    _cCore->run_callbacks(_cCore);
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
  if (!self.internalConnected)
    return;
#if PR_HAS_DISCORD_CPP
  if (!_core)
    return;
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

  if (startTimestamp) {
    activity.GetTimestamps().SetStart([startTimestamp longLongValue]);
  }
  if (endTimestamp) {
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

  _core->ActivityManager().UpdateActivity(activity, [](discord::Result result) {
    if (result != discord::Result::Ok) {
      NSLog(@"[Discord SDK] Failed to update activity: %d", (int)result);
    }
  });
#elif PR_HAS_DISCORD_C
  if (!_cCore)
    return;

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

  if (startTimestamp) {
    activity.timestamps.start = [startTimestamp longLongValue];
  }
  if (endTimestamp) {
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

  _cCore->get_activity_manager(_cCore)->update_activity(
      _cCore->get_activity_manager(_cCore), &activity, NULL, NULL);
#else
  if (buttons && buttons.count > 0) {
    NSLog(@"[Discord SDK Shim] setActivity details=%@ state=%@ buttons=%@", details,
          state, buttons);
  } else {
    NSLog(@"[Discord SDK Shim] setActivity details=%@ state=%@", details, state);
  }
#endif
}

- (void)clearActivity {
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

- (void)shutdown {
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
