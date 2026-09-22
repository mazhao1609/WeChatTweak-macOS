// Created by Ma
#import "RecallEvent.h"
#include <charconv>

@implementation WTRecallEvent
+ (instancetype)eventWithXML:(NSString *)xml {
    if (!xml.length || xml.length > 1024 * 1024) return nil;
    // 群聊正文可带“发送者 ID:\n”封套；只移除完整首行，不能从任意正文中搜索 XML。
    if (![xml hasPrefix:@"<"]) {
        NSRange separator = [xml rangeOfString:@":\n"];
        if (separator.location != NSNotFound && separator.location > 0 && separator.location <= 512) {
            NSString *sender = [xml substringToIndex:separator.location];
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.@"] invertedSet];
            if ([sender rangeOfCharacterFromSet:invalid].location == NSNotFound) {
                xml = [xml substringFromIndex:NSMaxRange(separator)];
            }
        }
    }
    // 封套移除后仍严格解析完整 XML，不展开外部实体或接受普通聊天正文中的协议片段。
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithXMLString:xml
        options:NSXMLNodeLoadExternalEntitiesNever error:nil];
    if (!document || document.DTD) return nil;
    NSArray *nodes = [document nodesForXPath:@"/sysmsg[@type='revokemsg']/revokemsg" error:nil];
    if (nodes.count != 1) return nil;
    NSXMLElement *node = nodes.firstObject;
    NSArray *sessions = [node elementsForName:@"session"];
    NSArray *ids = [node elementsForName:@"newmsgid"];
    NSArray *replacements = [node elementsForName:@"replacemsg"];
    if (sessions.count != 1 || replacements.count < 1) return nil;
    // 新版群聊同步偶尔只带 msgid；优先使用协议中的 newmsgid，缺失时兼容 msgid。
    if (ids.count == 0) ids = [node elementsForName:@"msgid"];
    if (ids.count != 1) return nil;
    NSString *session = [[sessions.firstObject stringValue]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *replacement = nil;
    for (NSXMLElement *element in [replacements reverseObjectEnumerator]) {
        NSString *value = element.stringValue;
        if (value.length) {
            replacement = value;
            break;
        }
    }
    NSString *identifier = [[ids.firstObject stringValue]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!session.length || session.length > 512 || !replacement.length || replacement.length > 8192 || !identifier.length) return nil;
    const char *start = identifier.UTF8String;
    uint64_t value = 0;
    auto result = std::from_chars(start, start + strlen(start), value);
    if (result.ec != std::errc() || *result.ptr != '\0' || !value) return nil;
    WTRecallEvent *event = [WTRecallEvent new];
    event.session = session;
    event.replacement = replacement;
    event.serverID = value;
    return event;
}
@end
