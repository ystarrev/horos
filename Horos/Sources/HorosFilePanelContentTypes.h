#pragma once

#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_INLINE NSArray<UTType *> *HorosContentTypesForFilenameExtensions(NSArray<NSString *> *extensions)
{
    NSMutableArray<UTType *> *contentTypes = [NSMutableArray arrayWithCapacity:extensions.count];
    for (NSString *extension in extensions) {
        UTType *contentType = [UTType typeWithFilenameExtension:extension];
        [contentTypes addObject:contentType ?: UTTypeData];
    }
    return contentTypes;
}
