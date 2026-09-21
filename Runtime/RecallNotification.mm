// Created by Ma
#import "RecallNotification.h"
#import <objc/runtime.h>

NSString *const WTRecallNotificationKey = @"WeChatTweakRecall";

static BOOL isRecall(UNNotification *notification) {
    return [notification.request.identifier hasPrefix:@"WeChatTweak."] &&
           [notification.request.content.userInfo[WTRecallNotificationKey] isEqual:@YES];
}

@implementation WTRecallNotificationDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    id delegate = self.originalDelegate;
    return [delegate respondsToSelector:selector] ? delegate : [super forwardingTargetForSelector:selector];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
      willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    // 只为本插件的撤回通知显示前台横幅，普通微信通知仍由原代理决定。
    id<UNUserNotificationCenterDelegate> delegate = self.originalDelegate;
    if (isRecall(notification)) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
    } else if ([delegate respondsToSelector:_cmd]) {
        [delegate userNotificationCenter:center willPresentNotification:notification
                               withCompletionHandler:completionHandler];
    } else {
        completionHandler(UNNotificationPresentationOptionNone);
    }
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
        withCompletionHandler:(void (^)(void))completionHandler {
    // 插件通知没有微信私有跳转参数，不把它交给微信的消息跳转解析器。
    id<UNUserNotificationCenterDelegate> delegate = self.originalDelegate;
    if (!isRecall(response.notification) && [delegate respondsToSelector:_cmd]) {
        [delegate userNotificationCenter:center didReceiveNotificationResponse:response
                               withCompletionHandler:completionHandler];
    } else {
        completionHandler();
    }
}
@end

static WTRecallNotificationDelegate *recallDelegate;
static __weak UNUserNotificationCenter *recallCenter;
static void (*originalSetDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);

static void setDelegate(id center, SEL selector, id<UNUserNotificationCenterDelegate> delegate) {
    // 微信可能在登录后重新设置代理，保留这一变更并继续转发它的通知。
    if (center == recallCenter && delegate != recallDelegate) {
        recallDelegate.originalDelegate = delegate;
        delegate = recallDelegate;
    }
    originalSetDelegate(center, selector, delegate);
}

void WTInstallRecallNotificationDelegate(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
        Method method = class_getInstanceMethod(UNUserNotificationCenter.class, @selector(setDelegate:));
        if (!method) return;
        recallDelegate = [WTRecallNotificationDelegate new];
        recallDelegate.originalDelegate = center.delegate;
        recallCenter = center;
        originalSetDelegate = reinterpret_cast<decltype(originalSetDelegate)>(
            method_setImplementation(method, reinterpret_cast<IMP>(setDelegate)));
        originalSetDelegate(center, @selector(setDelegate:), recallDelegate);
    });
}
