#import "NSDate+N2.h"
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

#import "NSString+N2.h"
#import "NSData+N2.h"
#import "NSMutableString+N2.h"
#include <cmath>
#include <sys/stat.h>
#include <CommonCrypto/CommonDigest.h>


NSString* N2NonNullString(NSString* s) {
	return s? s : @"";
}

@implementation NSString (N2)

- (NSString *)stringByTruncatingToLength:(NSInteger)theWidth
{
	NSInteger stringLength = [self length];
	NSInteger stringMiddle = (theWidth - 3) / 2;
	
	NSMutableString *retString = [NSMutableString string];

	if (stringLength > theWidth) 
	{
		for (NSInteger i = 0; i <= stringMiddle; i++) 
			[retString appendString:[self substringWithRange:NSMakeRange(i, 1)]];
		
		[retString appendString:@"..."];

		for (NSInteger i = (stringLength - stringMiddle); i < stringLength; i++) 
			[retString appendString:[self substringWithRange:NSMakeRange(i, 1)]];

		return retString;
	}

	else return self;
}

+(NSString*)timeString:(NSTimeInterval)time {
	return [self timeString:time maxUnits:1];
}

+(NSString*)timeString:(NSTimeInterval)time maxUnits:(NSInteger)maxUnits {
    NSInteger unitCount = MAX(1, MIN(3, maxUnits));
    time = std::isfinite(time) ? MAX(0.0, std::floor(time)) : 0.0;

    // Keep the old truncation of omitted units instead of rounding the estimate up.
    if (unitCount == 1 && time >= 60.0) {
        double unitSeconds = time >= 3600.0 ? 3600.0 : 60.0;
        time = std::floor(time / unitSeconds) * unitSeconds;
    } else if (unitCount == 2 && time >= 3600.0 && std::fmod(time, 3600.0) >= 60.0) {
        time = std::floor(time / 60.0) * 60.0;
    }

    NSDateComponentsFormatter *formatter = [[[NSDateComponentsFormatter alloc] init] autorelease];
    formatter.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
    formatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
    formatter.maximumUnitCount = unitCount;
    formatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorDropAll;
    formatter.allowsFractionalUnits = NO;
    return [formatter stringFromTimeInterval:time] ?: @"";
}

-(NSString*)ASCIIString {
	return [[[NSString alloc] initWithData:[self dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES] encoding:NSASCIIStringEncoding] autorelease];
}

-(BOOL)contains:(NSString*)str {
	return [self rangeOfString:str options:NSLiteralSearch].location != NSNotFound;
}

-(NSString*)stringByPrefixingLinesWithString:(NSString*)prefix {
	NSMutableArray* lines = [[[self componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] mutableCopy] autorelease];
	if ([[lines lastObject] isEqualToString:@""]) [lines removeLastObject];
	return [NSString stringWithFormat:@"%@%@\n", prefix, [lines componentsJoinedByString:[NSString stringWithFormat:@"\n%@", prefix]]];
}

+(NSString*)stringByRepeatingString:(NSString*)string times:(NSUInteger)times {
	NSMutableString* ret = [[NSMutableString alloc] initWithCapacity:[string length]*times];
	for (NSUInteger i = 0; i < times; ++i)
		[ret appendString:string];
	return [ret autorelease];
}

-(NSString*)suspendedString {
	NSUInteger dotsCount = 0;
	for (NSInteger i = [self length]-1; i >= 0; --i)
		if ([self characterAtIndex:i] == '.')
			++dotsCount;
		else break;
	if (dotsCount >= 3) return self;
	return [self stringByAppendingString:[NSString stringByRepeatingString:@"." times:3-dotsCount]];
}

-(NSRange)range {
	return NSMakeRange(0, self.length);
}

#pragma mark SymLinksAndAliases
// from http://cocoawithlove.com/2010/02/resolving-path-containing-mixture-of.html

- (NSString *)stringByConditionallyResolvingSymlink
{
    // Get the path that the symlink points to
    NSString *symlinkPath =
	[[NSFileManager defaultManager]
	 destinationOfSymbolicLinkAtPath:self
	 error:NULL];
    if (!symlinkPath)
    {
        return nil;
    }
    if (![symlinkPath hasPrefix:@"/"])
    {
        // For relative path symlinks (common case), resolve the relative
        // components
        symlinkPath =
		[[self stringByDeletingLastPathComponent]
		 stringByAppendingPathComponent:symlinkPath];
        symlinkPath = [symlinkPath stringByStandardizingPath];
    }
    return symlinkPath;
}

- (NSString *)stringByConditionallyResolvingAlias
{
    NSString *resolvedPath = nil;
    CFURLRef	url = CFURLCreateWithFileSystemPath(NULL, (CFStringRef)self, kCFURLPOSIXPathStyle, NO);
    if (url != NULL)
    {
        CFDataRef bd = CFURLCreateBookmarkDataFromFile(NULL, url, NULL);
        if (bd) {
            CFURLRef r = CFURLCreateByResolvingBookmarkData(NULL, bd, kCFBookmarkResolutionWithoutUIMask, NULL, NULL, NULL, NULL);
            if (r) {
                resolvedPath = CFBridgingRelease(CFURLCopyFileSystemPath(r, kCFURLPOSIXPathStyle));
                CFRelease(r);
            }
            
            CFRelease(bd);
        }
        
        CFRelease(url);
    }
    
    return resolvedPath;
}

//- (NSString *)stringByIterativelyResolvingSymlinkOrAlias BUG this creates an infinite loop..... Finding source code on the internet is not always a good solution...
// http://cocoawithlove.com/2010/02/resolving-path-containing-mixture-of.html
// -stringByIterativelyResolvingSymlinkOrAlias method will fall into endless loop if a symbolic link points to a (grand)parent folder...
//{
//    NSString *path = self;
//    NSString *aliasTarget = nil;
//    struct stat fileInfo;
//    
//    // Use lstat to determine if the file is a directory or symlink
//    if (lstat([[NSFileManager defaultManager]
//			   fileSystemRepresentationWithPath:path], &fileInfo) < 0)
//    {
//        // doesn't exist, just return it
//		return self;
//    }
//    
//    // While the file is a symlink or resolves as an alias, keep iterating.
//    while (S_ISLNK(fileInfo.st_mode) ||
//		   (!S_ISDIR(fileInfo.st_mode) &&
//            (aliasTarget = [path stringByConditionallyResolvingAlias]) != nil))
//    {
//        if (S_ISLNK(fileInfo.st_mode))
//        {
//            // Resolve the symlink component in the path
//            NSString *symlinkPath = [path stringByConditionallyResolvingSymlink];
//            if (!symlinkPath)
//            {
//                return nil;
//            }
//            path = symlinkPath;
//        }
//        else
//        {
//            // Or use the resolved alias result
//            path = aliasTarget;
//        }
//		
//        // Use lstat again to prepare for the next iteration
//        if (lstat([[NSFileManager defaultManager]
//				   fileSystemRepresentationWithPath:path], &fileInfo) < 0)
//        {
//            path = nil;
//            continue;
//        }
//    }
//    
//    return path;
//}

//-(NSString*)resolvedPathString {
//	NSString* path = [self stringByExpandingTildeInPath];
//	
//	// Break into components.
//	NSArray *pathComponents = [path pathComponents];
//	
//	// First component ("/") needs no resolution; we only need to handle subsequent components.
//	NSString *resolvedPath = [pathComponents objectAtIndex:0];
//	pathComponents = [pathComponents subarrayWithRange:NSMakeRange(1, [pathComponents count] - 1)];
//	
//	// Process all remaining components.
//	for (NSString *component in pathComponents)
//	{
//		if ([component isEqualToString:@".."])
//			resolvedPath = [resolvedPath stringByDeletingLastPathComponent];
//		else {
//			resolvedPath = [resolvedPath stringByAppendingPathComponent:component];
////			resolvedPath = [resolvedPath stringByIterativelyResolvingSymlinkOrAlias];
//		}
//		
//		if (!resolvedPath) {
//			return nil;
//		}
//	}
//	
//	return resolvedPath;
//}

-(NSString*)stringByComposingPathWithString:(NSString*)rel {
	NSURL* baseurl = [NSURL URLWithString: [self characterAtIndex:0] == '/' ? self : [NSString stringWithFormat:@"/%@", self] ];
	NSURL* url = [NSURL URLWithString:rel relativeToURL:baseurl];
	return [self characterAtIndex:0] == '/' ? url.path : [url.path substringFromIndex:1];
}

-(NSArray*)componentsWithLength:(NSUInteger)len {
	const CGFloat nf = ((CGFloat)self.length)/len;
	const NSUInteger n = ceilf(nf);
	
	NSMutableArray* r = [NSMutableArray arrayWithCapacity:n];
	for (NSUInteger i = 0; i < n; ++i)
		[r addObject:[self substringWithRange:NSMakeRange(i*len, i!=n-1? len : self.length-i*len)]];
	return r;
}

-(BOOL)isEmail { // from DHValidation
    return [[NSPredicate predicateWithFormat:@"SELF MATCHES %@", @"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,6}"] evaluateWithObject:self];
}

-(void)splitStringAtCharacterFromSet:(NSCharacterSet*)charset intoChunks:(NSString**)part1 :(NSString**)part2 separator:(unichar*)separator {
	NSInteger i = [self rangeOfCharacterFromSet:charset].location;
	if (i != NSNotFound) {
		if (part1) *part1 = [self substringToIndex:i];
		if (separator) *separator = [self characterAtIndex:i];
		if (part2) *part2 = [self substringFromIndex:i+1];
	} else {
		if (part1) *part1 = self;
		if (separator) *separator = 0;
		if (part2) *part2 = nil;
	}
}

-(NSString*)md5 {
	return [[(NSData*)[NSData dataWithBytesNoCopy:(void*)self.UTF8String length:strlen(self.UTF8String) freeWhenDone:NO] md5] hex];
}

@end

@implementation NSAttributedString (N2)

-(NSRange)range {
	return NSMakeRange(0, self.length);
}

@end
