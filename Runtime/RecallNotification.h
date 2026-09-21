// Created by Ma
#import <UserNotifications/UserNotifications.h>

FOUNDATION_EXPORT NSString *const WTRecallNotificationKey;
FOUNDATION_EXPORT void WTInstallRecallNotificationDelegate(void);

@interface WTRecallNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@property(nonatomic, weak) id<UNUserNotificationCenterDelegate> originalDelegate;
@end
