#include <CoreFoundation/CoreFoundation.h>

typedef enum {
    MRCommandPlay,
    MRCommandPause,
    MRCommandTogglePlayPause,
} MRCommand;

typedef void (^MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion)(Boolean isPlaying);
typedef void (^MRMediaRemoteGetNowPlayingInfoCompletion)(CFDictionaryRef information);
void MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingApplicationIsPlayingCompletion completion);
void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingInfoCompletion completion);
Boolean MRMediaRemoteSendCommand(MRCommand command, id userInfo);
