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
bool fromSelf = false, missing = false, insertFails = false, returnsOriginal = false, fallbackLookup = false;
std::string own = "wxid_me";
std::string lastPrompt;
uint64_t lastNoticeID;
uint64_t expectedSortTime = 1700000000123ULL;
int (*originalTarget)(int);
int diagnosticForwardCalls = 0;
void *expectedSignal;
const MessageBatch *expectedBatch;
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
    assert(id == 18446744073709551615ULL);
    OptionalMessage result{};
    if (missing || (fallbackLookup && *session == "test@chatroom")) return result;
    assert(*session == (fallbackLookup ? "fallback@chatroom" : "test@chatroom"));
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
NSString *xmlWithMsgID() {
    return @"<sysmsg type='revokemsg'><revokemsg><session>test@chatroom</session>"
            "<msgid>18446744073709551615</msgid><replacemsg>小明撤回了一条消息</replacemsg></revokemsg></sysmsg>";
}
void reset() {
    originalCalls = insertCalls = notifyCalls = bannerCalls = 0;
    fromSelf = missing = insertFails = returnsOriginal = fallbackLookup = false;
    expectedSortTime = 1700000000123ULL;
    completed = [NSMutableOrderedSet new];
    pending = [NSMutableSet new];
}

void testMessageDiagnostics() {
    OwnedMessage message;
    initMessage(&message.value);
    message.initialized = true;
    textField(&message.value, 0x18) = "wxid_friend";
    textField(&message.value, 0x30) = own;
    textField(&message.value, 0x130) = "ordinary message";
    setField<uint32_t>(&message.value, 0xc, 1);
    setField<uint32_t>(&message.value, 0xf4, 10);
    setField<uint64_t>(&message.value, 0xf8, 123);
    MessageBatch batch{&message.value, &message.value + 1, &message.value + 1};
    expectedSignal = &message;
    expectedBatch = &batch;
    api.emitMessageEvent = [](void *signal, const MessageBatch *messages) {
        assert(signal == expectedSignal && messages == expectedBatch);
        ++diagnosticForwardCalls;
    };
    // 单条与批量入口投递相同消息时使用同一匿名编号，原始事件仍各转发一次。
    Message before = message.value;
    dispatchMessageEvent(expectedSignal, &batch, 0x305d1d4);
    dispatchMessageEvent(expectedSignal, &batch, 0x307d738);
    assert(diagnosticForwardCalls == 2 && diagnosticMessages.size() == 1);
    auto first = diagnosticMessages.begin()->second;
    assert(first.occurrences == 2 && first.firstLocalID == 10);
    assert(memcmp(&before, &message.value, sizeof(Message)) == 0);
    // 相同服务端 ID 却有不同本地 ID 时保留该差异，不抑制任何消息。
    setField<uint32_t>(&message.value, 0xf4, 11);
    dispatchMessageEvent(expectedSignal, &batch, 0x30aa000);
    auto repeated = diagnosticMessages.begin()->second;
    assert(diagnosticForwardCalls == 3 && repeated.token == first.token && repeated.occurrences == 3);
    assert(repeated.firstLocalID != field<uint32_t>(&message.value, 0xf4));
    // 图片正文和文字相同也不作为去重依据，不同服务端 ID 必须分配不同编号。
    setField<uint32_t>(&message.value, 0xc, 3);
    setField<uint64_t>(&message.value, 0xf8, 124);
    auto image = observeAddedMessage(expectedSignal, &message.value);
    assert(image.token != first.token && image.occurrences == 1);
    assert(observeAddedMessage(expectedSignal, &message.value).occurrences == 2);
    auto otherAccount = observeAddedMessage(nullptr, &message.value);
    assert(otherAccount.token != image.token);
    // 同一模板的更新事件不计为新增，空批次和未知布局也必须正常转发。
    size_t count = diagnosticMessages.size();
    dispatchMessageEvent(expectedSignal, &batch, 0x3080850);
    assert(diagnosticMessages.size() == count && diagnosticForwardCalls == 4);
    batch.end = batch.begin;
    dispatchMessageEvent(expectedSignal, &batch, 0x307d738);
    batch.end = reinterpret_cast<const Message *>(reinterpret_cast<uintptr_t>(batch.begin) + 1);
    dispatchMessageEvent(expectedSignal, &batch, 0x307d738);
    assert(diagnosticForwardCalls == 6 && diagnosticMessages.size() == count);
    coreImageSlide = 0x100000000;
    assert(addedEventSource(coreImageSlide + 0x307d738));
    assert(!addedEventSource(coreImageSlide + 0x3080850));
    coreImageSlide = 0;
    // 无服务端 ID 时按本地 ID 观察；系统提示不进入普通消息诊断。
    setField<uint64_t>(&message.value, 0xf8, 0);
    auto local = observeAddedMessage(expectedSignal, &message.value);
    assert(local.token && observeAddedMessage(expectedSignal, &message.value).token == local.token);
    setField<uint32_t>(&message.value, 0xf4, 0);
    assert(!observeAddedMessage(expectedSignal, &message.value).token);
    setField<uint64_t>(&message.value, 0xf8, 125);
    setField<uint32_t>(&message.value, 0xc, 10000);
    assert(!observeAddedMessage(expectedSignal, &message.value).token);
    // 长时间开启也只保留有限条内存记录。
    setField<uint32_t>(&message.value, 0xc, 1);
    for (uint64_t id = 1000; id < 1000 + diagnosticCapacity + 1; ++id) {
        setField<uint64_t>(&message.value, 0xf8, id);
        observeAddedMessage(expectedSignal, &message.value);
    }
    assert(diagnosticMessages.size() == diagnosticCapacity && diagnosticOrder.size() == diagnosticCapacity);
}
}

int main() {
    @autoreleasepool {
        WTRecallEvent *event = [WTRecallEvent eventWithXML:xml()];
        assert(event.serverID == UINT64_MAX);
        assert([event.replacement isEqualToString:@"小明撤回了一条消息"]);
        assert([WTRecallEvent eventWithXML:xmlWithMsgID()].serverID == UINT64_MAX);
        NSString *groupXML = [@"wxid_friend:\n" stringByAppendingString:xml(@"<![CDATA[\"Ma\"撤回了一条消息]]>")];
        WTRecallEvent *groupEvent = [WTRecallEvent eventWithXML:groupXML];
        assert(groupEvent.serverID == UINT64_MAX);
        assert([groupEvent.session isEqualToString:@"test@chatroom"]);
        assert([groupEvent.replacement isEqualToString:@"\"Ma\"撤回了一条消息"]);
        // 只接受协议封套；普通正文、DTD 和嵌套协议不得被当成撤回事件。
        assert(![WTRecallEvent eventWithXML:[@"ordinary text:\n" stringByAppendingString:xml()]]);
        assert(![WTRecallEvent eventWithXML:[@"wxid_friend:\nordinary text\n" stringByAppendingString:xml()]]);
        assert((![WTRecallEvent eventWithXML:[@"<wrapper>" stringByAppendingFormat:@"%@</wrapper>", xml()]]));
        assert(![WTRecallEvent eventWithXML:[@"wxid_friend:\n<!DOCTYPE sysmsg>" stringByAppendingString:xml()]]);
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
        // 模拟真实群聊封套：旧解析器会调用原函数删除消息；新实现只插入一条独立提示。
        reset();
        textField(&incoming.value, 0x130) = groupXML.UTF8String;
        textField(&incoming.value, 0x18) = "test@chatroom";
        assert(handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 0 && insertCalls == 1 && notifyCalls == 1 && bannerCalls == 1);
        assert(lastPrompt == "[已拦截] \"Ma\"撤回了一条消息");
        // 同一事件改用无封套形式重放，也不能重复提示或删除原消息。
        textField(&incoming.value, 0x130) = xml().UTF8String;
        assert(handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 0 && insertCalls == 1 && bannerCalls == 1);
        reset(); fromSelf = true;
        textField(&incoming.value, 0x130) = groupXML.UTF8String;
        assert(!handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 1 && insertCalls == 0 && bannerCalls == 0);
        textField(&incoming.value, 0x130) = xml().UTF8String;
        textField(&incoming.value, 0x18).clear();
        reset(); fromSelf = true;
        assert(!handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 1 && insertCalls == 0 && bannerCalls == 0);
        reset(); missing = true;
        assert(!handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 1 && insertCalls == 0);
        // 群聊同步路径可能把可查询会话放在撤回消息对象字段中。
        reset(); fallbackLookup = true;
        textField(&incoming.value, 0x18) = "fallback@chatroom";
        assert(handleRevoke(nullptr, &incoming.value));
        assert(originalCalls == 0 && insertCalls == 1 && notifyCalls == 1);
        textField(&incoming.value, 0x18).clear();
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
        // 普通文字和图片不会插入消息或再次发送新增通知；每次只调用一次原函数。
        for (uint32_t type : {1U, 3U}) {
            reset();
            setField<uint32_t>(&incoming.value, 0xc, type);
            textField(&incoming.value, 0x130) = type == 1 ? "ordinary text" : "<msg><img/></msg>";
            Message before = incoming.value;
            assert(!handleRevoke(nullptr, &incoming.value));
            assert(originalCalls == 1 && insertCalls == 0 && notifyCalls == 0 && bannerCalls == 0);
            assert(memcmp(&before, &incoming.value, sizeof(Message)) == 0);
        }
        testMessageDiagnostics();
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
        puts("Runtime tests passed: XML, group sender prefix, preservation, self-revoke, missing message, deduplication, insertion failure.");
        puts("Dobby hook / trampoline / restore passed.");
        puts("Notification foreground banner and host delegate forwarding passed.");
        puts("Message diagnostics: identity, local ID changes, forwarding, event filtering and bounded cache passed.");
    }
}
