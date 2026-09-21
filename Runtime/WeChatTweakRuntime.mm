// Created by Ma
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import "RecallEvent.h"
#import "RecallNotification.h"
#import <os/log.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dobby.h>
#include <string>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <exception>

namespace {
// 以下布局仅对应 4.1.15.20 / 270100 的 arm64 核心库；载入前必须校验 UUID 和指令。
struct alignas(8) Message { unsigned char bytes[0x278]; };
struct alignas(8) OptionalMessage { unsigned char bytes[0x280]; };
static_assert(sizeof(std::string) == 24);
static_assert(sizeof(Message) == 0x278);

struct NativeAPI {
    bool (*handleRevoke)(void *, const Message *);
    OptionalMessage (*lookupMessage)(void *, const std::string *, uint64_t);
    void (*messageInit)(Message *);
    void (*messageDestroy)(Message *);
    void (*setMessageType)(Message *, uint32_t);
    void (*refreshMessage)(Message *);
    Message (*addLocalMessage)(void *, const Message *);
    void (*notifyAdded)(void *, const Message *);
    void *(*accountService)();
} api;

std::mutex dedupMutex;
NSMutableOrderedSet<NSString *> *completed;
NSMutableSet<NSString *> *pending;
bool notificationsEnabled = true;
bool installed = false;
constexpr const char *cacheKey = "WeChatTweak.Revokes270100";

os_log_t runtimeLog() {
    static os_log_t log = os_log_create("com.wechattweak.runtime", "recall");
    return log;
}

template<typename T> T field(const Message *message, size_t offset) {
    T value;
    memcpy(&value, message->bytes + offset, sizeof(value));
    return value;
}
template<typename T> void setField(Message *message, size_t offset, T value) {
    memcpy(message->bytes + offset, &value, sizeof(value));
}
std::string &textField(Message *message, size_t offset) {
    return *reinterpret_cast<std::string *>(message->bytes + offset);
}
const std::string &textField(const Message *message, size_t offset) {
    return *reinterpret_cast<const std::string *>(message->bytes + offset);
}
NSString *toNSString(const std::string &value) {
    if (value.size() > 1024 * 1024) return nil;
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
}

struct OwnedMessage {
    Message value;
    bool initialized = false;
    ~OwnedMessage() { if (initialized) api.messageDestroy(&value); }
};

void postNotification(NSString *body, NSString *identifier) {
    if (!notificationsEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
            // 沿用微信已有授权；拒绝授权时记录状态，便于区分入库与系统通知问题。
            if (settings.authorizationStatus != UNAuthorizationStatusAuthorized &&
                settings.authorizationStatus != UNAuthorizationStatusProvisional) {
                os_log_error(runtimeLog(), "系统通知未授权，状态=%ld", (long)settings.authorizationStatus);
                return;
            }
            UNMutableNotificationContent *content = [UNMutableNotificationContent new];
            content.title = @"微信";
            content.body = body;
            content.userInfo = @{WTRecallNotificationKey: @YES};
            UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
            [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
                if (error) os_log_error(runtimeLog(), "系统通知提交失败，错误码=%ld", (long)error.code);
                else os_log_info(runtimeLog(), "撤回系统通知已提交");
            }];
        }];
    });
}

// 通知与数据库写入独立，测试可替换投递函数而不产生真实通知。
void (*notify)(NSString *, NSString *) = postNotification;

bool handleRevoke(void *service, const Message *incoming) {
    @autoreleasepool {
        WTRecallEvent *event = [WTRecallEvent eventWithXML:toNSString(textField(incoming, 0x130))];
        if (!event) return api.handleRevoke(service, incoming);
        const std::string session(event.session.UTF8String);
        OptionalMessage found = api.lookupMessage(service, &session, event.serverID);
        if (found.bytes[0x278] != 1) return api.handleRevoke(service, incoming);
        OwnedMessage original;
        memcpy(&original.value, found.bytes, sizeof(Message));
        original.initialized = true;

        void *account = api.accountService();
        if (!account) return api.handleRevoke(service, incoming);
        // 该版本虚表第 5 项返回当前账号名的 const std::string 引用。
        auto accountName = reinterpret_cast<const std::string &(*)(void *)>((*static_cast<void ***>(account))[5]);
        const std::string &ownName = accountName(account);
        if (textField(&original.value, 0x18) == ownName) return api.handleRevoke(service, incoming);

        NSString *key = [NSString stringWithFormat:@"%@|%@|%llu", toNSString(ownName), event.session,
                         static_cast<unsigned long long>(event.serverID)];
        {
            std::lock_guard<std::mutex> lock(dedupMutex);
            if ([completed containsObject:key] || [pending containsObject:key]) return true;
            [pending addObject:key];
        }
        NSString *body = [@"[已拦截] " stringByAppendingString:event.replacement];
        try {
        @try {
            // 单独创建系统消息，绝不把原消息更新成撤回提示，也不执行删除流程。
            OwnedMessage prompt;
            api.messageInit(&prompt.value);
            prompt.initialized = true;
            api.setMessageType(&prompt.value, 10000);
            textField(&prompt.value, 0x18) = session;
            textField(&prompt.value, 0x30) = ownName;
            textField(&prompt.value, 0x130) = body.UTF8String;
            setField<uint32_t>(&prompt.value, 0x118, 4);
            uint32_t createdAt = field<uint32_t>(incoming, 0x114);
            if (!createdAt) createdAt = field<uint32_t>(&original.value, 0x114);
            setField<uint32_t>(&prompt.value, 0x114, createdAt);
            // 0x100 是毫秒排序时间；仅设置秒级时间会把提示排到错误位置。
            uint64_t sortTime = field<uint64_t>(incoming, 0x100);
            setField<uint64_t>(&prompt.value, 0x100, sortTime ? sortTime : uint64_t(createdAt) * 1000);
            setField<uint32_t>(&prompt.value, 0x128, field<uint32_t>(incoming, 0x128));
            // 使用撤回事件自己的服务端 ID，避免与保留的原消息发生唯一键冲突。
            uint64_t noticeID = field<uint64_t>(incoming, 0xf8);
            setField<uint64_t>(&prompt.value, 0xf8, noticeID == event.serverID ? 0 : noticeID);
            api.refreshMessage(&prompt.value);
            OwnedMessage saved;
            // 此入口开启自动分配本地 ID；0x30c5ddc 保留传入 ID，不适合新建提示。
            saved.value = api.addLocalMessage(service, &prompt.value);
            saved.initialized = true;
            uint32_t localID = field<uint32_t>(&saved.value, 0xf4);
            bool matches = field<uint32_t>(&saved.value, 0xc) == 10000 &&
                           textField(&saved.value, 0x130) == textField(&prompt.value, 0x130);
            if (localID && localID != field<uint32_t>(&original.value, 0xf4) && matches) {
                // 新提示走新增消息通知，不能复用删除/替换原消息的撤回事件。
                api.notifyAdded(service, &saved.value);
                os_log_info(runtimeLog(), "撤回提示已新增，localID=%u", localID);
            } else {
                os_log_error(runtimeLog(), "撤回提示入库结果无效，localID=%u type=%u contentMatches=%d",
                             localID, field<uint32_t>(&saved.value, 0xc), matches);
            }
        } @catch (NSException *exception) {
            os_log_error(runtimeLog(), "已保留原消息，提示异常：%{public}@", exception.name);
        }
        } catch (...) {
            // 原生数据库异常不能让已识别的对方撤回继续执行删除。
            os_log_error(runtimeLog(), "已保留原消息，原生消息接口抛出异常");
        }
        {
            std::lock_guard<std::mutex> lock(dedupMutex);
            [pending removeObject:key];
            // 入库结果异常也不重试同一事件，避免已写入但未返回 ID 时重复创建记录。
            [completed addObject:key];
            while (completed.count > 2048) [completed removeObjectAtIndex:0];
            [[NSUserDefaults standardUserDefaults] setObject:completed.array forKey:@(cacheKey)];
        }
        notify(body, [@"WeChatTweak." stringByAppendingString:key]);
        return true;
    }
}

bool parseHex(NSString *text, uint64_t &result) {
    if (![text isKindOfClass:NSString.class] || !text.length) return false;
    const char *start = text.UTF8String;
    char *end = nullptr;
    result = strtoull(start, &end, 16);
    return end != start && *end == '\0';
}

void install(const mach_header *header, intptr_t slide) {
    if (installed || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return;
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle.bundleIdentifier isEqualToString:@"com.tencent.xinWeChat"] ||
            ![[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqualToString:@"270100"]) return;
        // 与安装器一致，从资源目录读取配置，避免把 JSON 当作嵌套代码签名。
        NSString *directory = bundle.resourcePath;
        NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"WeChatTweakProfile.json"]];
        NSDictionary *profile = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![profile isKindOfClass:NSDictionary.class] || ![profile[@"version"] isEqualToString:@"270100"]) return;

        const auto *h = reinterpret_cast<const mach_header_64 *>(header);
        const auto *command = reinterpret_cast<const load_command *>(h + 1);
        NSString *uuid = nil;
        uintptr_t textStart = 0, textEnd = 0;
        for (uint32_t i = 0; i < h->ncmds; ++i) {
            if (command->cmd == LC_UUID) {
                const auto *id = reinterpret_cast<const uuid_command *>(command);
                uuid = [[NSUUID alloc] initWithUUIDBytes:id->uuid].UUIDString;
            }
            if (command->cmd == LC_SEGMENT_64) {
                const auto *segment = reinterpret_cast<const segment_command_64 *>(command);
                if (strcmp(segment->segname, "__TEXT") == 0) {
                    textStart = segment->vmaddr + slide;
                    textEnd = textStart + segment->vmsize;
                }
            }
            command = reinterpret_cast<const load_command *>(reinterpret_cast<const char *>(command) + command->cmdsize);
        }
        if (![uuid isEqualToString:@"0B9929BB-E55E-3513-B439-32375760BCA2"] || ![uuid isEqualToString:profile[@"uuid"]]) return;
        NSDictionary *functions = profile[@"functions"];
        if (![functions isKindOfClass:NSDictionary.class]) return;
        std::unordered_map<std::string, void *> addresses;
        NSArray *names = @[@"handleRevoke", @"lookupMessage", @"messageInit", @"messageDestroy", @"setMessageType",
                           @"refreshMessage", @"addLocalMessage", @"notifyAdded", @"accountService"];
        for (NSString *name in names) {
            NSDictionary *entry = functions[name];
            if (![entry isKindOfClass:NSDictionary.class]) return;
            uint64_t address;
            NSString *expected = entry[@"expected"];
            if (!parseHex(entry[@"addr"], address) || ![expected isKindOfClass:NSString.class] ||
                expected.length != 32 || address > UINTPTR_MAX - static_cast<uintptr_t>(slide)) return;
            auto target = static_cast<uintptr_t>(address + slide);
            if (target < textStart || target > textEnd - 16) return;
            for (NSUInteger i = 0; i < 16; ++i) {
                uint64_t byte;
                if (!parseHex([expected substringWithRange:NSMakeRange(i * 2, 2)], byte) ||
                    reinterpret_cast<const uint8_t *>(target)[i] != byte) {
                    os_log_error(runtimeLog(), "函数校验失败：%{public}@", name);
                    return;
                }
            }
            addresses[name.UTF8String] = reinterpret_cast<void *>(target);
        }
        #define WT_BIND(name) api.name = reinterpret_cast<decltype(api.name)>(addresses[#name])
        WT_BIND(lookupMessage); WT_BIND(messageInit); WT_BIND(messageDestroy); WT_BIND(setMessageType);
        WT_BIND(refreshMessage); WT_BIND(addLocalMessage); WT_BIND(notifyAdded); WT_BIND(accountService);
        #undef WT_BIND
        NSArray *history = [[NSUserDefaults standardUserDefaults] arrayForKey:@(cacheKey)] ?: @[];
        completed = [NSMutableOrderedSet orderedSetWithArray:history];
        pending = [NSMutableSet new];
        NSData *settingsData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"WeChatTweakSettings.json"]];
        NSDictionary *settings = settingsData ? [NSJSONSerialization JSONObjectWithData:settingsData options:0 error:nil] : nil;
        notificationsEnabled = ![settings[@"notifications"] isEqualToString:@"off"];
        if (notificationsEnabled) WTInstallRecallNotificationDelegate();
        int result = DobbyHook(addresses["handleRevoke"], reinterpret_cast<void *>(handleRevoke),
                               reinterpret_cast<void **>(&api.handleRevoke));
        installed = result == 0;
        os_log_info(runtimeLog(), "270100 arm64 撤回插件 v2 加载结果=%d", installed);
    }
}

void imageAdded(const mach_header *header, intptr_t slide) {
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return;
    const auto *h = reinterpret_cast<const mach_header_64 *>(header);
    const auto *command = reinterpret_cast<const load_command *>(h + 1);
    // 只排队处理已确认的核心库，避免其他短生命周期动态库卸载后访问悬空 header。
    const uint8_t expectedUUID[16] = {0x0b, 0x99, 0x29, 0xbb, 0xe5, 0x5e, 0x35, 0x13,
                                     0xb4, 0x39, 0x32, 0x37, 0x57, 0x60, 0xbc, 0xa2};
    bool matches = false;
    for (uint32_t i = 0; i < h->ncmds; ++i) {
        if (command->cmd == LC_UUID) {
            matches = memcmp(reinterpret_cast<const uuid_command *>(command)->uuid, expectedUUID, 16) == 0;
            break;
        }
        command = reinterpret_cast<const load_command *>(reinterpret_cast<const char *>(command) + command->cmdsize);
    }
    if (!matches) return;
    // 离开 dyld 锁后再使用 Foundation 并安装 hook，避免在加载回调中递归加载系统库。
    dispatch_async(dispatch_get_main_queue(), ^{ install(header, slide); });
}
}

__attribute__((constructor)) static void startWeChatTweak() {
    _dyld_register_func_for_add_image(imageAdded);
}
