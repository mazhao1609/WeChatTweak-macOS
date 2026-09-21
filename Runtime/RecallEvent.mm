// Created by Ma
#import "RecallEvent.h"
#include <charconv>

@implementation WTRecallEvent
+ (instancetype)eventWithXML:(NSString *)xml {
    if (!xml.length || xml.length > 1024 * 1024) return nil;
    // 只解析撤回协议节点，不展开外部实体，也不通过截取字符串猜测 XML。
    NSXMLDocument *document = [[NSXMLDocument alloc] initWithXMLString:xml
        options:NSXMLNodeLoadExternalEntitiesNever error:nil];
    if (!document || document.DTD) return nil;
    NSArray *nodes = [document nodesForXPath:@"/sysmsg[@type='revokemsg']/revokemsg" error:nil];
    if (nodes.count != 1) return nil;
    NSXMLElement *node = nodes.firstObject;
    NSArray *sessions = [node elementsForName:@"session"];
    NSArray *ids = [node elementsForName:@"newmsgid"];
    NSArray *replacements = [node elementsForName:@"replacemsg"];
    if (sessions.count != 1 || ids.count != 1 || replacements.count != 1) return nil;
    NSString *session = [sessions.firstObject stringValue];
    NSString *replacement = [replacements.firstObject stringValue];
    NSString *identifier = [ids.firstObject stringValue];
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
