// Created by Ma
// 使用本地假消息服务验证拦截分支，不登录微信、不发送真实消息。
#include "../Runtime/WeChatTweakRuntime.mm"
#include <cassert>

// 只提供通知代理需要的公开字段，不向系统通知中心投递测试消息。
@interface WTTestNotification : NSObject
@property(nonatomic, strong) UNNotificationRequest *request;
@end
@implementation WTTestNotification
@end

@interface WTTestDelegate : NSObject <UNUserNotificationCenterDelegate>
@property(nonatomic) NSUInteger presentationCalls;
@end
@implementation WTTestDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
      willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    self.presentationCalls++;
    completionHandler(UNNotificationPresentationOptionSound);
}
@end

namespace {
int originalCalls = 0, insertCalls = 0, notifyCalls = 0, bannerCalls = 0;
bool fromSelf = false, missing = false, insertFails = false, returnsOriginal = false;
std::string own = "wxid_me";
std::string lastPrompt;
uint64_t lastNoticeID;
uint64_t expectedSortTime = 1700000000123ULL;
int (*originalTarget)(int);
__attribute__((noinline, aligned(16384))) int hookTarget(int value) {
    asm volatile("nop\nnop\nnop\nnop\n" ::: "memory");
    return value * 3;
}
int replacementTarget(int value) { return originalTarget(value) + 1; }

void initMessage(Message *m) {
    memset(m, 0, sizeof(*m));
    for (size_t offset : {0x18, 0x30, 0x130}) new (m->bytes + offset) std::string();
}
void destroyMessage(Message *m) {
    for (size_t offset : {0x18, 0x30, 0x130}) textField(m, offset).~basic_string();
}
OptionalMessage lookup(void *, const std::string *session, uint64_t id) {
    assert(*session == "test@chatroom" && id == 18446744073709551615ULL);
    OptionalMessage result{};
    if (missing) return result;
    auto *m = reinterpret_cast<Message *>(&result);
    initMessage(m);
    textField(m, 0x18) = fromSelf ? own : "wxid_friend";
    textField(m, 0x130) = "original text";
    setField<uint32_t>(m, 0xf4, 7);
    result.bytes[0x278] = 1;
    return result;
}
Message insert(void *, const Message *m) {
    ++insertCalls;
    assert(field<uint32_t>(m, 0xc) == 10000);
    assert(textField(m, 0x18) == "test@chatroom");
    assert(textField(m, 0x30) == own);
    assert(field<uint32_t>(m, 0xf4) == 0);
    assert(field<uint32_t>(m, 0x114) == 1700000000);
    assert(field<uint64_t>(m, 0x100) == expectedSortTime);
    lastPrompt = textField(m, 0x130);
    lastNoticeID = field<uint64_t>(m, 0xf8);
    Message result;
    initMessage(&result);
    textField(&result, 0x130) = returnsOriginal ? "original text" : lastPrompt;
    setField<uint32_t>(&result, 0xc, returnsOriginal ? 1 : 10000);
    setField<uint32_t>(&result, 0xf4, insertFails ? 0 : (returnsOriginal ? 7 : 42));
    return result;
}
const std::string &name(void *) { return own; }
void *account() {
    static void *table[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, reinterpret_cast<void *>(name)};
    static void **object = table;
    return &object;
}
NSString *xml(NSString *replacement = @"<![CDATA[小明撤回了一条消息]]>") {
    return [NSString stringWithFormat:@"<sysmsg type='revokemsg'><revokemsg><session>test@chatroom</session>"
        "<newmsgid>18446744073709551615</newmsgid><replacemsg>%@</replacemsg></revokemsg></sysmsg>", replacement];
}
void reset() {
    originalCalls = insertCalls = notifyCalls = bannerCalls = 0;
    fromSelf = missing = insertFails = returnsOriginal = false;
    expectedSortTime = 1700000000123ULL;
    completed = [NSMutableOrderedSet new];
    pending = [NSMutableSet new];
}
}

int main() {
    @autoreleasepool {
        WTRecallEvent *event = [WTRecallEvent eventWithXML:xml()];
        assert(event.serverID == UINT64_MAX);
        assert([event.replacement isEqualToString:@"小明撤回了一条消息"]);
        assert([[WTRecallEvent eventWithXML:xml(@"A &amp; B 撤回了一条消息")].replacement hasPrefix:@"A & B"]);
        assert(![WTRecallEvent eventWithXML:[xml() stringByReplacingOccurrencesOfString:@"18446744073709551615" withString:@"18446744073709551616"]]);
        assert(![WTRecallEvent eventWithXML:@"<sysmsg type='other'/>"]);
        assert(![WTRecallEvent eventWithXML:@"<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///not-read'>]><x>&x;</x>"]);
        api.handleRevoke = [](void *, const Message *) { ++originalCalls; return false; };
        api.lookupMessage = lookup;
        api.messageInit = initMessage;
        api.messageDestroy = destroyMessage;
        api.setMessageType = [](Message *m, uint32_t type) { setField(m, 0xc, type); };
        api.refreshMessage = [](Message *) {};
        api.addLocalMessage = insert;
        api.notifyAdded = [](void *, const Message *message) {
            assert(field<uint32_t>(message, 0xf4) == 42);
            assert(field<uint32_t>(message, 0xc) == 10000);
            ++notifyCalls;
        };
        notify = [](NSString *, NSString *) { ++bannerCalls; };
        api.accountService = account;
        notificationsEnabled = false;
        OwnedMessage incoming;
        initMessage(&incoming.value);
        incoming.initialized = true;
        textField(&incoming.value, 0x130) = xml().UTF8String;
        setField<uint64_t>(&incoming.value, 0xf8, 9876);
        setField<uint32_t>(&incoming.value, 0x114, 1700000000);
        setField<uint64_t>(&incoming.value, 0x100, 1700000000123ULL);
        reset();
        assert(handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 0 && insertCalls == 1 && notifyCalls == 1 && bannerCalls == 1);
        assert(lastPrompt == "[已拦截] 小明撤回了一条消息" && lastNoticeID == 9876);
        assert(handleRevoke(nullptr, &incoming.value));
        assert(insertCalls == 1 && bannerCalls == 1);
        reset(); fromSelf = true;
        assert(!handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 1 && insertCalls == 0 && bannerCalls == 0);
        reset(); missing = true;
        assert(!handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 1 && insertCalls == 0);
        reset(); insertFails = true;
        assert(handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 0 && insertCalls == 1 && notifyCalls == 0 && completed.count == 1 && bannerCalls == 1);
        insertFails = false;
        assert(handleRevoke(nullptr, &incoming.value));
        assert(insertCalls == 1 && notifyCalls == 0 && bannerCalls == 1);
        // 数据库若返回已有原消息，不向界面再发布一次原消息。
        reset(); returnsOriginal = true;
        assert(handleRevoke(nullptr, &incoming.value));
        assert(insertCalls == 1 && notifyCalls == 0 && bannerCalls == 1);
        reset();
        // 无毫秒时间时使用秒级时间补齐；撤回事件 ID 与原消息冲突时使用本地消息 ID。
        expectedSortTime = 1700000000000ULL;
        setField<uint64_t>(&incoming.value, 0x100, 0);
        setField<uint64_t>(&incoming.value, 0xf8, UINT64_MAX);
        assert(handleRevoke(nullptr, &incoming.value));
        assert(lastNoticeID == 0 && notifyCalls == 1);
        reset();
        textField(&incoming.value, 0x130) = "<sysmsg type='other'/>";
        assert(!handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 1 && insertCalls == 0);
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@(cacheKey)];
        WTRecallNotificationDelegate *proxy = [WTRecallNotificationDelegate new];
        WTTestDelegate *host = [WTTestDelegate new];
        proxy.originalDelegate = host;
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.userInfo = @{WTRecallNotificationKey: @YES};
        WTTestNotification *notification = [WTTestNotification new];
        UNUserNotificationCenter *testCenter = (UNUserNotificationCenter *)[NSObject new];
        notification.request = [UNNotificationRequest requestWithIdentifier:@"WeChatTweak.test" content:content trigger:nil];
        __block NSUInteger completionCalls = 0;
        [proxy userNotificationCenter:testCenter willPresentNotification:(UNNotification *)notification
                withCompletionHandler:^(UNNotificationPresentationOptions options) {
            ++completionCalls;
            assert(options & UNNotificationPresentationOptionBanner);
        }];
        assert(completionCalls == 1 && host.presentationCalls == 0);
        notification.request = [UNNotificationRequest requestWithIdentifier:@"host.test" content:content trigger:nil];
        [proxy userNotificationCenter:testCenter willPresentNotification:(UNNotification *)notification
                withCompletionHandler:^(UNNotificationPresentationOptions options) {
            ++completionCalls;
            assert(options == UNNotificationPresentationOptionSound);
        }];
        assert(completionCalls == 2 && host.presentationCalls == 1);
        proxy.originalDelegate = nil;
        [proxy userNotificationCenter:testCenter willPresentNotification:(UNNotification *)notification
                withCompletionHandler:^(UNNotificationPresentationOptions options) {
            ++completionCalls;
            assert(options == UNNotificationPresentationOptionNone);
        }];
        assert(completionCalls == 3);
        // 验证本机 macOS 上的指令重定位和恢复，不附加到微信进程。
        int (*volatile target)(int) = hookTarget;
        assert(target(7) == 21);
        assert(DobbyHook(reinterpret_cast<void *>(hookTarget), reinterpret_cast<void *>(replacementTarget),
                         reinterpret_cast<void **>(&originalTarget)) == 0);
        assert(target(7) == 22);
        assert(DobbyDestroy(reinterpret_cast<void *>(hookTarget)) == 0);
        assert(target(7) == 21);
        puts("Runtime tests passed: XML, preservation, self-revoke, missing message, deduplication, insertion failure.");
        puts("Dobby hook / trampoline / restore passed.");
        puts("Notification foreground banner and host delegate forwarding passed.");
    }
}
