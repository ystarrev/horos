/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#import "NSUserDefaults+OsiriX.h"
#import "N2Shell.h"
#import <Foundation/Foundation.h>
#import "BrowserController.h"
#import "NSScreen+N2.h"


@implementation NSUserDefaults (OsiriX)

#pragma mark General

NSString* const OsirixDateTimeFormatDefaultsKey = @"DBDateFormat2";

+(NSString*)dateTimeFormat {
	NSString* r = [NSUserDefaultsController.sharedUserDefaultsController stringForKey:OsirixDateTimeFormatDefaultsKey];
	if (!r) r = [[[[NSDateFormatter alloc] init] autorelease] dateFormat];
	return r;
}

+(NSDateFormatter*)dateTimeFormatter {
	static NSDateFormatter* formatter = NULL;
	if (!formatter)
		formatter = [[NSDateFormatter alloc] init];
	
	if (![formatter.dateFormat isEqual:[self dateTimeFormat]])
		formatter.dateFormat = [self dateTimeFormat];
	
	return formatter;
}

+(NSString*)formatDateTime:(NSDate*)date {
	return [self.dateTimeFormatter stringFromDate:date];
}

NSString* const OsirixDateFormatDefaultsKey = @"DBDateOfBirthFormat2";

+(NSString*)dateFormat {
	NSString* r = [NSUserDefaultsController.sharedUserDefaultsController stringForKey:OsirixDateFormatDefaultsKey];
	if (!r) r = [[[[NSDateFormatter alloc] init] autorelease] dateFormat];
	return r;
}

+(NSDateFormatter*)dateFormatter {
	static NSDateFormatter* formatter = NULL;
	if (!formatter)
		formatter = [[NSDateFormatter alloc] init];
	
	if (![formatter.dateFormat isEqual: [self dateFormat]])
		formatter.dateFormat = [self dateFormat];
	
	return formatter;
}

+(NSString*)formatDate:(NSDate*)date {
	return [self.dateFormatter stringFromDate:date];
}

NSString* const OsirixCanActivateDefaultDatabaseOnlyDefaultsKey = @"addNewIncomingFilesToDefaultDBOnly";

+(BOOL)canActivateOnlyDefaultDatabase {
	return [self.standardUserDefaults boolForKey:OsirixCanActivateDefaultDatabaseOnlyDefaultsKey];
}

+(BOOL)canActivateAnyLocalDatabase {
	return !self.canActivateOnlyDefaultDatabase;
}

#ifdef OSIRIX_VIEWER

NSString* const O2NonViewerScreensDefaultsKey = @"NonViewerScreens";

-(NSArray*)screensNotUsedForViewers {
    NSArray* nonIDs = [self arrayForKey:O2NonViewerScreensDefaultsKey];
    
    if (!nonIDs) { // the array doesn't exist, consider the ReserveScreenForDB default
        NSMutableArray* mnonIDs = [NSMutableArray array];
        
        switch ([self integerForKey:@"ReserveScreenForDB"]) {
            case 0: // all screens are used, the exclusion list is empty
                break;
            case 1: // all except DB, all screens are used but the tiling algorithm must consider the ReserveScreenForDB default and exclude the screen where the database currently is
                break;
            case 2: // main screen only
                for (NSScreen* screen in [NSScreen screens])
                    if (screen != [NSScreen mainScreen])
                        [mnonIDs addObject:[NSNumber numberWithUnsignedInteger:[screen screenNumber]]];
                [self setInteger:0 forKey:@"ReserveScreenForDB"];
                break;
        }
        
        [self setObject:mnonIDs forKey:O2NonViewerScreensDefaultsKey];
        
        nonIDs = mnonIDs;
    }
    
    NSMutableArray* screens = [[[NSScreen screens] mutableCopy] autorelease];
    for (NSInteger i = (long)screens.count-1; i >= 0; --i) {
        NSScreen* screen = [screens objectAtIndex:i];
        if (![nonIDs containsObject:[NSNumber numberWithUnsignedInteger:[screen screenNumber]]])
            [screens removeObjectAtIndex:i];
    }
    
    return screens;
}

-(NSArray*)screensUsedForViewers {
    NSMutableArray* screens = [[[NSScreen screens] mutableCopy] autorelease];
    for (NSScreen* screen in [self screensNotUsedForViewers])
        [screens removeObject:screen];
    return screens;
}

-(BOOL)screenIsUsedForViewers:(NSScreen*)screen {
    return [[self screensUsedForViewers] containsObject:screen];
}

-(void)screen:(NSScreen*)screen setIsUsedForViewers:(BOOL)flag {
    NSMutableArray* a = [[[self arrayForKey:O2NonViewerScreensDefaultsKey] mutableCopy] autorelease];
    if (!a) a = [NSMutableArray array];

    if (!flag && [self screenIsUsedForViewers:screen])
        [a addObject:[NSNumber numberWithUnsignedInteger:screen.screenNumber]];
    if (flag && ![self screenIsUsedForViewers:screen])
        [a removeObject:[NSNumber numberWithUnsignedInteger:screen.screenNumber]];

    [self setObject:a forKey:O2NonViewerScreensDefaultsKey];
}


#endif

#pragma mark Bonjour Sharing

NSString* const OsirixBonjourSharingIsActiveDefaultsKey = @"bonjourSharing";
+(BOOL)bonjourSharingIsActive {
	return [NSUserDefaultsController.sharedUserDefaultsController boolForKey:OsirixBonjourSharingIsActiveDefaultsKey];
}

NSString* const OsirixBonjourSharingNameDefaultsKey = @"bonjourServiceName";
+(NSString*)bonjourSharingName {
	NSString* r = [NSUserDefaultsController.sharedUserDefaultsController stringForKey:OsirixBonjourSharingNameDefaultsKey];
	if (!r) r = [self defaultBonjourSharingName];
	return r;
}
+(NSString*)defaultBonjourSharingName {
	char s[_POSIX_HOST_NAME_MAX+1];
	gethostname(s, _POSIX_HOST_NAME_MAX);
	
	NSString* r = [NSString stringWithUTF8String:s];
	
	NSRange range = [r rangeOfString: @"."];
	if (range.location != NSNotFound)
		r = [r substringToIndex:range.location];
	
	return r;
}

NSString* const OsirixBonjourSharingIsPasswordProtectedDefaultsKey = @"bonjourPasswordProtected";
+(BOOL)bonjourSharingIsPasswordProtected {
	return [NSUserDefaultsController.sharedUserDefaultsController boolForKey:OsirixBonjourSharingIsPasswordProtectedDefaultsKey];
}

NSString* const OsirixBonjourSharingPasswordDefaultsKey = @"bonjourPassword";
+(NSString*)bonjourSharingPassword {
	return self.bonjourSharingIsPasswordProtected? [NSUserDefaultsController.sharedUserDefaultsController stringForKey:OsirixBonjourSharingPasswordDefaultsKey] : NULL;
}

// MARK: DICOM Communications

+ (NSString*)defaultAETitle;
{
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"STORESCPTLS"])
	{
		if ([[NSUserDefaults standardUserDefaults] boolForKey:@"STORESCP"]
			&& ![[NSUserDefaults standardUserDefaults] boolForKey:@"TLSStoreSCPAETITLEIsDefaultAET"])
		{
			return [[NSUserDefaults standardUserDefaults] stringForKey:@"AETITLE"];
		}
		return [[NSUserDefaults standardUserDefaults] stringForKey:@"TLSStoreSCPAETITLE"];
	}
	return [[NSUserDefaults standardUserDefaults] stringForKey:@"AETITLE"];
}

+ (int)defaultAEPort;
{
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"STORESCPTLS"])
	{
		if ([[NSUserDefaults standardUserDefaults] boolForKey:@"STORESCP"]
			&& ![[NSUserDefaults standardUserDefaults] boolForKey:@"TLSStoreSCPAETITLEIsDefaultAET"])
		{
			return [[[NSUserDefaults standardUserDefaults] stringForKey:@"AEPORT"] intValue];
		}
		return [[[NSUserDefaults standardUserDefaults] stringForKey:@"TLSStoreSCPAEPORT"] intValue];
	}
	return [[[NSUserDefaults standardUserDefaults] stringForKey:@"AEPORT"] intValue];
}

@end
