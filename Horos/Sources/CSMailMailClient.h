/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 =========================================================================*/

#import <Cocoa/Cocoa.h>

@interface CSMailMailClient : NSObject

+ (id)mailClient;
- (NSString *)name;
- (NSString *)version;
- (BOOL)deliverMessage:(NSString *)messageBody headers:(NSDictionary *)messageHeaders;

@end
