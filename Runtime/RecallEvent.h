// Created by Ma
#import <Foundation/Foundation.h>

@interface WTRecallEvent : NSObject
@property(copy) NSString *session;
@property(copy) NSString *replacement;
@property uint64_t serverID;
+ (instancetype)eventWithXML:(NSString *)xml;
@end
