/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 =========================================================================*/

#import "Mailer.h"

@implementation Mailer

- (void)runScript:(NSString *)txt
{
    NSLog(@"Email scripting is disabled.");
}

- (BOOL)sendMail:(NSString *)richBody to:(NSString *)to subject:(NSString *)subject isMIME:(BOOL)isMIME name:(NSString *)client sendNow:(BOOL)sendWithoutUserReview image:(NSString*)imagePath
{
    NSLog(@"Email export is disabled: Mail integration has been removed.");
    return NO;
}

@end
