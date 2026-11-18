#import "AudioCapture.h"

BOOL QYStartAudioCapture(AVAudioEngine *engine, AVAudioFormat *format,
                        AVAudioNodeTapBlock tap, NSError **error) {
    BOOL installed = NO;
    @try {
        [engine.inputNode installTapOnBus:0 bufferSize:4096 format:format block:tap];
        installed = YES;
        [engine prepare];
        if ([engine startAndReturnError:error]) return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"local.hopo.qingyan.audio" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"Cannot start the microphone. Check the permission, the input device and other apps that are recording.",
                NSDebugDescriptionErrorKey: exception.reason ?: exception.name
            }];
        }
    }
    [engine stop];
    if (installed) [engine.inputNode removeTapOnBus:0];
    return NO;
}
