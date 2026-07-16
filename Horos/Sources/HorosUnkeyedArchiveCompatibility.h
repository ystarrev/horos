#pragma once

#import <Foundation/Foundation.h>

// Horos and OsiriX used Foundation's unkeyed archive format for ROI files,
// ROI DICOM SR payloads, pasteboard data, and Bonjour database messages.
// Keyed archives are a different wire format, so these calls remain isolated
// here until those external formats can be versioned.
NS_INLINE NSData *HorosArchiveUnkeyedObject(id object)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *data = [NSArchiver archivedDataWithRootObject:object];
#pragma clang diagnostic pop
    return data;
}

NS_INLINE id HorosUnarchiveUnkeyedObject(NSData *data)
{
    if (data == nil)
        return nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    id object = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
    return object;
}

NS_INLINE id HorosUnarchiveUnkeyedObjectFromFile(NSString *path)
{
    if (path.length == 0)
        return nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    id object = [NSUnarchiver unarchiveObjectWithFile:path];
#pragma clang diagnostic pop
    return object;
}

NS_INLINE BOOL HorosArchiveUnkeyedObjectToFile(id object, NSString *path)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL archived = [NSArchiver archiveRootObject:object toFile:path];
#pragma clang diagnostic pop
    return archived;
}
