#pragma once

#import <Foundation/Foundation.h>

NS_INLINE NSArray<NSString *> *HorosMountedRemovableVolumePaths(void)
{
    NSArray<NSURLResourceKey> *keys = @[NSURLVolumeIsRemovableKey];
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager]
        mountedVolumeURLsIncludingResourceValuesForKeys:keys
        options:NSVolumeEnumerationSkipHiddenVolumes];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSNumber *isRemovable = nil;
        [url getResourceValue:&isRemovable forKey:NSURLVolumeIsRemovableKey error:nil];
        if (isRemovable.boolValue && url.path.length)
            [paths addObject:url.path];
    }
    return paths;
}
