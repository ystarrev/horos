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

#import "NSDate+N2.h"

@implementation NSDate (N2)

static NSCalendar *N2GregorianCalendar(NSTimeZone *timeZone)
{
    NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    calendar.timeZone = timeZone ?: [NSTimeZone defaultTimeZone];
    return calendar;
}

static NSString *N2UnicodeDateFormatForLegacyFormat(NSString *format)
{
    NSDictionary *knownFormats = @{
        @"%H%M%S": @"HHmmss",
        @"%Y%m%d": @"yyyyMMdd",
        @"%Y%m%d%H%M%S": @"yyyyMMddHHmmss",
        @"%Y%m%d-": @"yyyyMMdd-",
        @"-%Y%m%d": @"-yyyyMMdd",
        @"%Y%m%d-%Y%m%d": @"yyyyMMdd-yyyyMMdd",
        @"%Y-%m-%d-%H-%M-%S": @"yyyy-MM-dd-HH-mm-ss",
        @"%Y:%m:%d %H:%M:%S": @"yyyy:MM:dd HH:mm:ss",
        @"%z": @"xx",
        @"le %d.%m.%Y à %Hh%M": @"'le 'dd.MM.yyyy' à 'HH'h'mm"
    };
    NSString *knownFormat = [knownFormats objectForKey:format];
    if (knownFormat)
        return knownFormat;

    NSMutableString *converted = [format mutableCopy];
    [converted replaceOccurrencesOfString:@"%Y" withString:@"yyyy" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%y" withString:@"yy" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%m" withString:@"MM" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%d" withString:@"dd" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%H" withString:@"HH" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%M" withString:@"mm" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%S" withString:@"ss" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%a" withString:@"EEE" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%b" withString:@"MMM" options:0 range:NSMakeRange(0, converted.length)];
    [converted replaceOccurrencesOfString:@"%z" withString:@"xx" options:0 range:NSMakeRange(0, converted.length)];
    return [converted autorelease];
}

+(id)dateWithYYYYMMDD:(NSString*)datestr HHMMss:(NSString*)timestr
{
    NSString *normalizedDate = [datestr stringByReplacingOccurrencesOfString:@"." withString:@""];
    if (normalizedDate.length < 8)
        return nil;

    NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
    components.year = [[normalizedDate substringWithRange:NSMakeRange(0, 4)] integerValue];
    components.month = [[normalizedDate substringWithRange:NSMakeRange(4, 2)] integerValue];
    components.day = [[normalizedDate substringWithRange:NSMakeRange(6, 2)] integerValue];
    components.hour = timestr.length >= 2 ? [[timestr substringWithRange:NSMakeRange(0, 2)] integerValue] : 0;
    components.minute = timestr.length >= 4 ? [[timestr substringWithRange:NSMakeRange(2, 2)] integerValue] : 0;
    components.second = timestr.length >= 6 ? [[timestr substringWithRange:NSMakeRange(4, 2)] integerValue] : 0;
    components.timeZone = [NSTimeZone defaultTimeZone];

	NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
	return [calendar dateFromComponents:components];
}

+ (NSDate *)n2_dateWithYear:(NSInteger)year
                      month:(NSInteger)month
                        day:(NSInteger)day
                       hour:(NSInteger)hour
                     minute:(NSInteger)minute
                     second:(NSInteger)second
                   timeZone:(NSTimeZone *)timeZone
{
    NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
    components.year = year;
    components.month = month;
    components.day = day;
    components.hour = hour;
    components.minute = minute;
    components.second = second;
    components.timeZone = timeZone ?: [NSTimeZone defaultTimeZone];
    return [N2GregorianCalendar(components.timeZone) dateFromComponents:components];
}

- (NSDate *)n2_dateByAddingYears:(NSInteger)years
                          months:(NSInteger)months
                            days:(NSInteger)days
                           hours:(NSInteger)hours
                         minutes:(NSInteger)minutes
                         seconds:(NSInteger)seconds
{
    NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
    components.year = years;
    components.month = months;
    components.day = days;
    components.hour = hours;
    components.minute = minutes;
    components.second = seconds;
    return [N2GregorianCalendar(nil) dateByAddingComponents:components toDate:self options:0];
}

- (NSString *)n2_descriptionWithCalendarFormat:(NSString *)format
{
    return [self n2_descriptionWithCalendarFormat:format timeZone:nil locale:nil];
}

- (NSString *)n2_descriptionWithCalendarFormat:(NSString *)format
                                       timeZone:(NSTimeZone *)timeZone
                                          locale:(id)locale
{
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.calendar = N2GregorianCalendar(timeZone);
    formatter.timeZone = timeZone ?: [NSTimeZone defaultTimeZone];
    formatter.locale = [locale isKindOfClass:[NSLocale class]] ? locale : [NSLocale currentLocale];
    formatter.dateFormat = N2UnicodeDateFormatForLegacyFormat(format);
    return [formatter stringFromDate:self];
}

@end
