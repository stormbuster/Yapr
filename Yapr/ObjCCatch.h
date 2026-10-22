#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, returning nil, or an NSError describing the Objective-C exception it raised. AVAudioEngine reports
/// some failures (a tap format that no longer matches the device, a device that vanished) by raising exceptions,
/// which Swift cannot catch; uncaught, AppKit swallows them and the app is left half-broken.
NSError * _Nullable YaprCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
