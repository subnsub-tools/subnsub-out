#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Keeps AVFAudio's Objective-C exceptions inside Objective-C, before returning to Swift.
BOOL QYStartAudioCapture(AVAudioEngine *engine, AVAudioFormat *format,
                        AVAudioNodeTapBlock tap, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
