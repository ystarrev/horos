#pragma once

#import <Foundation/Foundation.h>

// Modern entry points for Horos's existing keyed archives. Secure coding stays
// disabled because several long-lived archive classes still implement NSCoding
// rather than NSSecureCoding; this preserves their established wire format.
NS_INLINE NSData *HorosArchiveKeyedObject(id object, NSError **error)
{
    return [NSKeyedArchiver archivedDataWithRootObject:object
                                 requiringSecureCoding:NO
                                                 error:error];
}

NS_INLINE id HorosUnarchiveKeyedObject(NSData *data, NSError **error)
{
    if (data == nil)
        return nil;

    NSError *localError = nil;
    NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc]
        initForReadingFromData:data
        error:&localError] autorelease];
    unarchiver.requiresSecureCoding = NO;
    id object = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];

    if (error)
        *error = localError;
    return object;
}
