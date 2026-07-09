/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 =========================================================================*/

#import "CSMailMailClient.h"

@implementation CSMailMailClient

+ (id)mailClient
{
#if __has_feature(objc_arc)
    return [[CSMailMailClient alloc] init];
#else
    return [[[CSMailMailClient alloc] init] autorelease];
#endif
}

- (NSString *)name
{
    return @"Email";
}

- (NSString *)version
{
    return @"1.0.0";
}

- (BOOL)deliverMessage:(NSString *)messageBody headers:(NSDictionary *)messageHeaders
{
    NSLog(@"Email delivery is disabled: Mail integration has been removed.");
    return NO;
}

@end
