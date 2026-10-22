#import "ObjCCatch.h"

NSError * _Nullable YaprCatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return [NSError errorWithDomain:@"YaprAudio" code:1
                               userInfo:@{NSLocalizedDescriptionKey: reason, @"ExceptionName": exception.name}];
    }
}
