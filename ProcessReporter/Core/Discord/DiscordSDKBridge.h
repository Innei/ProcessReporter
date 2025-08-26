//
//  DiscordSDKBridge.h
//  ProcessReporter
//
//  A lightweight Objective-C++ bridge for Discord Game SDK.
//  This header is safe to include even when the official SDK
//  is not linked; the implementation provides no-op behavior
//  when the SDK header is unavailable.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class DiscordSDKBridge;

@protocol DiscordSDKBridgeDelegate <NSObject>
- (void)discordSDKDidConnect:(DiscordSDKBridge *)bridge;
- (void)discordSDKDidDisconnect:(DiscordSDKBridge *)bridge
                          error:(NSError *_Nullable)error;
@end

@interface DiscordSDKBridge : NSObject

@property(nonatomic, assign) id<DiscordSDKBridgeDelegate> delegate;
@property(nonatomic, readonly) BOOL isConnected;

+ (instancetype)sharedInstance;

- (void)initializeWithApplicationId:(NSString *)applicationId;
- (void)setActivityWithDetails:(NSString *_Nullable)details
                         state:(NSString *_Nullable)state
                startTimestamp:(NSNumber *_Nullable)startTimestamp
                  endTimestamp:(NSNumber *_Nullable)endTimestamp
                 largeImageKey:(NSString *_Nullable)largeImageKey
                largeImageText:(NSString *_Nullable)largeImageText
                 smallImageKey:(NSString *_Nullable)smallImageKey
                smallImageText:(NSString *_Nullable)smallImageText;

// Enhanced API: supports up to 2 buttons. Each element is a dictionary
// with keys: @"label" and @"url".
- (void)setActivityWithDetails:(NSString *_Nullable)details
                         state:(NSString *_Nullable)state
                startTimestamp:(NSNumber *_Nullable)startTimestamp
                  endTimestamp:(NSNumber *_Nullable)endTimestamp
                 largeImageKey:(NSString *_Nullable)largeImageKey
                largeImageText:(NSString *_Nullable)largeImageText
                 smallImageKey:(NSString *_Nullable)smallImageKey
                smallImageText:(NSString *_Nullable)smallImageText
                        buttons:(NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable)buttons;
- (void)clearActivity;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
