#pragma once

#import <AVFoundation/AVFoundation.h>

NS_INLINE NSArray<AVAssetTrack *> *HorosLoadAssetTracks(AVAsset *asset,
                                                         AVMediaType mediaType,
                                                         NSError **outError)
{
    if (asset == nil)
        return nil;

    NSCondition *condition = [[NSCondition alloc] init];
    __block NSArray<AVAssetTrack *> *tracks = nil;
    __block NSError *loadError = nil;
    __block BOOL finished = NO;

    [condition lock];
    [asset loadTracksWithMediaType:mediaType completionHandler:^(NSArray<AVAssetTrack *> *loadedTracks, NSError *error) {
        [condition lock];
        tracks = [loadedTracks copy];
        loadError = [error retain];
        finished = YES;
        [condition signal];
        [condition unlock];
    }];

    while (!finished)
        [condition wait];
    [condition unlock];
    [condition release];

    if (outError)
        *outError = [loadError autorelease];
    else
        [loadError release];

    return [tracks autorelease];
}

NS_INLINE void HorosFinishAssetWriter(AVAssetWriter *writer)
{
    if (writer == nil)
        return;

    NSCondition *condition = [[NSCondition alloc] init];
    __block BOOL finished = NO;

    [condition lock];
    [writer finishWritingWithCompletionHandler:^{
        [condition lock];
        finished = YES;
        [condition signal];
        [condition unlock];
    }];

    while (!finished)
        [condition wait];
    [condition unlock];
    [condition release];
}
