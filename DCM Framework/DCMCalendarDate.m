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

#import "DCMCalendarDate.h"//aTimeZone
#import "DCM.h"

static NSString *DCMUnicodeDateFormat(NSString *format)
{
	NSDictionary *formats = @{
		@"%Y": @"yyyy",
		@"%Y%m": @"yyyyMM",
		@"%Y%m%d": @"yyyyMMdd",
		@"%Y.%m.%d": @"yyyy.MM.dd",
		@"%H": @"HH",
		@"%H%M": @"HHmm",
		@"%H%M%S": @"HHmmss",
		@"%H:%M:%S": @"HH:mm:ss",
		@"%H%M%S.%F": @"HHmmss.SSSSSS",
		@"%Y%m%d%H": @"yyyyMMddHH",
		@"%Y%m%d%H%M": @"yyyyMMddHHmm",
		@"%Y%m%d%H%M%S": @"yyyyMMddHHmmss",
		@"%Y%m%d%H%M%S%z": @"yyyyMMddHHmmssxx",
		@"%z": @"xx"
	};
	return [formats objectForKey:format] ?: format;
}

static NSDateFormatter *DCMDateFormatter(NSString *format, NSTimeZone *timeZone)
{
	NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
	formatter.calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
	formatter.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
	formatter.timeZone = timeZone ?: [NSTimeZone defaultTimeZone];
	formatter.defaultDate = [NSDate dateWithTimeIntervalSinceReferenceDate:0];
	formatter.dateFormat = DCMUnicodeDateFormat(format);
	formatter.lenient = NO;
	return formatter;
}

@implementation DCMCalendarDate

+ (BOOL)supportsSecureCoding
{
	return YES;
}

+ (instancetype)date
{
	return [[[self alloc] initWithTimeIntervalSinceReferenceDate:[NSDate timeIntervalSinceReferenceDate]] autorelease];
}

+ (instancetype)dateWithTimeIntervalSinceNow:(NSTimeInterval)seconds
{
	return [[[self alloc] initWithTimeIntervalSinceReferenceDate:[NSDate timeIntervalSinceReferenceDate] + seconds] autorelease];
}

+ (instancetype)dateWithTimeIntervalSinceReferenceDate:(NSTimeInterval)seconds
{
	return [[[self alloc] initWithTimeIntervalSinceReferenceDate:seconds] autorelease];
}


+ (id)dicomDate:(NSString *)string{

	if( string == nil) 
		return nil;
		
	if ([string rangeOfString:@"-"].location == NSNotFound)
	{
		//format for DA is YYMMDD = @"%Y%m%d"
		if (DCMDEBUG)
			NSLog (@"date string: %@ intValue: %d", string,[string intValue] );
		NSString *format = @"%Y%m%d";
		if (string && [string intValue]) {
			if ([string length] == 10)
				format = @"%Y.%m.%d";
			else if ([string length] == 8)
				format = @"%Y%m%d";
			else if ([string length] == 6)
				format = @"%Y%m";
			else if ([string length] == 4)
				format = @"%Y";
			DCMCalendarDate *date = [[[DCMCalendarDate alloc] initWithString:string  calendarFormat:format] autorelease];
			[date setIsQuery:NO];
			[date setQueryString:nil];
			return date;
		}
		else
			return nil;
	}
	else
		return [DCMCalendarDate queryDate:string];
}
+ (id)dicomTime:(NSString *)string
{
	if( string == nil) 
		return nil;
		
	if ([string rangeOfString:@"-"].location == NSNotFound)
	{
		//format for TM is HHMMSS.ffffff = @"%H%M%S.%U";
			if (DCMDEBUG)
			NSLog (@"time string: %@", string);
		if (string  && [string intValue]) {
			NSArray *timeComponents = [string componentsSeparatedByString:@"."];
			NSString *firstComponent = [timeComponents objectAtIndex:0];
			NSString *format = @"%H%M%S";
			if ([firstComponent length] == 8)
				format = @"%H:%M:%S";
			if ([firstComponent length] == 6)
				format = @"%H%M%S";
			else if ([firstComponent length] == 4)
				format = @"%H%M";
			else if ([firstComponent length] == 2)
				format = @"%H";
            
            int useconds = 0;
			if ([timeComponents count] > 1)
				useconds = [[timeComponents objectAtIndex:1] intValue] * pow(10, 6 - [(NSString *)[timeComponents objectAtIndex:1] length]);
            
			DCMCalendarDate *date = [[[DCMCalendarDate alloc] initWithString:firstComponent calendarFormat:format microseconds: useconds] autorelease];
			
			[date setIsQuery:NO];
			[date setQueryString:nil];
			return date;
		}
		else
			return nil;
	}
	else
		return [DCMCalendarDate queryDate:string];
}

+ (id)dicomDateTime:(NSString *)string
{
	if( string == nil) 
		return nil;
    
    if (DCMDEBUG)
        NSLog (@"date time string: %@", string);
    
    if (string.length) {
        NSArray *timeComponents = [string componentsSeparatedByString:@"."];
        NSString *format = nil;
//        int length = (int)[string length];
        
        if( timeComponents.count > 2)
            NSLog( @"****** DICOM DateTime invalid format: %@", string);
        
        switch ([(NSString *)[timeComponents objectAtIndex:0] length]) {
            case 19:format = @"%Y%m%d%H%M%S%z";
                break;
            case 14:format = @"%Y%m%d%H%M%S";
                break;
            case 12:format = @"%Y%m%d%H%M";
                break;
            case 10:format = @"%Y%m%d%H";
                break;
            case 8:format = @"%Y%m%d";
                break;
            case 6:format = @"%Y%m";
                break;
            case 4:format = @"%Y";
                break;
                
            default: format = @"%Y%m%d%H%M%S";
                NSLog( @"****** DICOM DateTime invalid format ? %@", string);
                break;
        }
        
        NSTimeZone *tz = nil;
        int useconds = 0;
        if ([timeComponents count] > 1) {
            NSString *timeZone = nil;
            NSString *usecondsString = nil;
            
            if( [[timeComponents objectAtIndex:1] rangeOfString: @"+"].location != NSNotFound)
            {
                usecondsString = [[timeComponents objectAtIndex:1] substringToIndex: [[timeComponents objectAtIndex:1] rangeOfString: @"+"].location];
                timeZone = [[timeComponents objectAtIndex:1] substringFromIndex: [[timeComponents objectAtIndex:1] rangeOfString: @"+"].location];
            }
            else if( [[timeComponents objectAtIndex:1] rangeOfString: @"-"].location != NSNotFound)
            {
                usecondsString = [[timeComponents objectAtIndex:1] substringToIndex: [[timeComponents objectAtIndex:1] rangeOfString: @"-"].location];
                timeZone = [[timeComponents objectAtIndex:1] substringFromIndex: [[timeComponents objectAtIndex:1] rangeOfString: @"-"].location];
            }
            else
            {
                usecondsString = [timeComponents objectAtIndex:1];
                timeZone = nil;
            }
            
            if( timeZone.length) {
                int tzHours = [[timeZone substringToIndex:3] intValue];
                int tzMinutes = [[timeZone substringFromIndex:3] intValue];
                if (tzHours < 0)
                    tzMinutes = -tzMinutes;
                tz = [NSTimeZone timeZoneForSecondsFromGMT:(tzHours * 3600) + (tzMinutes * 60)];
            }
            
            useconds = [usecondsString intValue] * pow(10, 6 - usecondsString.length);
        }
        
        DCMCalendarDate *date = [[[DCMCalendarDate alloc] initWithString:[timeComponents objectAtIndex:0] calendarFormat:format microseconds: useconds] autorelease];
        if( tz)
            [date setTimeZone: tz];
        
        [date setIsQuery:NO];
        [date setQueryString:nil];
        
        return date;
    }
    else
        return nil;
		
}

+ (id)dicomDateWithDate:(NSDate *)date
{
	NSString *dateString = [DCMDateFormatter(@"%Y%m%d", nil) stringFromDate:date];
	return [DCMCalendarDate dicomDate:dateString];
}
	
+ (id)dicomTimeWithDate:(NSDate *)date
{
	NSString *dateString = [DCMDateFormatter(@"%H%M%S", nil) stringFromDate:date];
	return [DCMCalendarDate dicomTime:dateString];
}

+ (id)dicomDateTimeWithDicomDate:(DCMCalendarDate*)date dicomTime:(DCMCalendarDate*)time
{
	if (date == nil || time == nil)
		return nil;
	
	DCMCalendarDate *dateTime = [[[DCMCalendarDate alloc] initWithYear:date.yearOfCommonEra month:date.monthOfYear day:date.dayOfMonth
				hour:time.hourOfDay minute:time.minuteOfHour second:time.secondOfMinute timeZone:date.timeZone] autorelease];
	
	[dateTime setIsQuery:NO];
	[dateTime setQueryString:nil];
	return dateTime;
}
	
+ (id)queryDate:(NSString *)query{
	DCMCalendarDate *date = [[[DCMCalendarDate alloc] init] autorelease];
	[date setIsQuery:YES];
	[date setQueryString:query];
	return date;
}


+ (id)dateWithYear:(NSInteger)year month:(NSUInteger)month day:(NSUInteger)day hour:(NSUInteger)hour minute:(NSUInteger)minute second:(NSUInteger)second timeZone:(NSTimeZone *)aTimeZone{
	DCMCalendarDate *date = [[[DCMCalendarDate alloc] initWithYear:year month:month day:day hour:hour minute:minute second:second timeZone:aTimeZone] autorelease];
    
	[date setIsQuery:NO];
	[date setQueryString:nil];
	return date;
}

//------------------------------------------------------------------------------------------------------------------------------------
#pragma mark•

- (id)init
{
	return [self initWithTimeIntervalSinceReferenceDate:0];
}

- (id)initWithTimeIntervalSinceReferenceDate:(NSTimeInterval)seconds
{
	self = [super init];
	if (self) {
		_timeIntervalSinceReferenceDate = seconds;
		_timeZone = [[NSTimeZone defaultTimeZone] retain];
	}
	return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self) {
		_timeIntervalSinceReferenceDate = [super timeIntervalSinceReferenceDate];
		_timeZone = [[NSTimeZone defaultTimeZone] retain];

		if (coder.allowsKeyedCoding) {
			NSString *calendarFormat = [coder decodeObjectOfClass:[NSString class] forKey:@"DCMCalendarFormat"];
			NSTimeZone *timeZone = [coder decodeObjectOfClass:[NSTimeZone class] forKey:@"DCMTimeZone"];
			NSString *decodedQueryString = [coder decodeObjectOfClass:[NSString class] forKey:@"DCMQueryString"];
			_calendarFormat = [calendarFormat copy];
			[self setTimeZone:timeZone];
			queryString = [decodedQueryString copy];
			isQuery = [coder decodeBoolForKey:@"DCMIsQuery"];
		}
	}
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];

	// NSArchiver payloads written by old Horos only contained the inherited
	// date value. Keep that unkeyed representation unchanged.
	if (coder.allowsKeyedCoding) {
		[coder encodeObject:_calendarFormat forKey:@"DCMCalendarFormat"];
		[coder encodeObject:_timeZone forKey:@"DCMTimeZone"];
		[coder encodeObject:queryString forKey:@"DCMQueryString"];
		[coder encodeBool:isQuery forKey:@"DCMIsQuery"];
	}
}

- (NSTimeInterval)timeIntervalSinceReferenceDate
{
	return _timeIntervalSinceReferenceDate;
}

- (id)initWithString:(NSString *)description calendarFormat:(NSString *)format
{
	return [self initWithString:description calendarFormat:format microseconds:0];
}

- (id) initWithString:(NSString *)description calendarFormat:(NSString *)format microseconds: (unsigned long) usecs
{
	NSDate *date = [DCMDateFormatter(format, nil) dateFromString:description];
	if (date == nil) {
		[self release];
		return nil;
	}

	self = [self initWithTimeIntervalSinceReferenceDate:date.timeIntervalSinceReferenceDate + ((NSTimeInterval)usecs / 1e6)];
	if (self)
		_calendarFormat = [format copy];
	return self;
}

- (id)initWithYear:(NSInteger)year month:(NSUInteger)month day:(NSUInteger)day hour:(NSUInteger)hour minute:(NSUInteger)minute second:(NSUInteger)second timeZone:(NSTimeZone *)timeZone
{
	NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
	components.year = year;
	components.month = month;
	components.day = day;
	components.hour = hour;
	components.minute = minute;
	components.second = second;
	components.timeZone = timeZone ?: [NSTimeZone defaultTimeZone];
	NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
	calendar.timeZone = components.timeZone;
	NSDate *date = [calendar dateFromComponents:components];
	if (date == nil) {
		[self release];
		return nil;
	}

	self = [self initWithTimeIntervalSinceReferenceDate:date.timeIntervalSinceReferenceDate];
	if (self)
		[self setTimeZone:components.timeZone];
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
	DCMCalendarDate *date = [[[self class] allocWithZone:zone] initWithTimeIntervalSinceReferenceDate:self.timeIntervalSinceReferenceDate];
	date->_calendarFormat = [_calendarFormat copy];
	[date setTimeZone:_timeZone];
	date->isQuery = isQuery;
	date->queryString = [queryString copy];
	return date;
}

- (NSString *)calendarFormat { return _calendarFormat; }

- (void)setCalendarFormat:(NSString *)format
{
	if (_calendarFormat == format)
		return;
	[_calendarFormat release];
	_calendarFormat = [format copy];
}

- (NSTimeZone *)timeZone { return _timeZone; }

- (void)setTimeZone:(NSTimeZone *)timeZone
{
	if (_timeZone == timeZone)
		return;
	[_timeZone release];
	_timeZone = [timeZone ?: [NSTimeZone defaultTimeZone] retain];
}

- (NSDateComponents *)dateComponents
{
	NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
	calendar.timeZone = self.timeZone;
	return [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond) fromDate:self];
}

- (NSInteger)yearOfCommonEra { return self.dateComponents.year; }
- (NSInteger)monthOfYear { return self.dateComponents.month; }
- (NSInteger)dayOfMonth { return self.dateComponents.day; }
- (NSInteger)hourOfDay { return self.dateComponents.hour; }
- (NSInteger)minuteOfHour { return self.dateComponents.minute; }
- (NSInteger)secondOfMinute { return self.dateComponents.second; }

- (NSString *)descriptionWithCalendarFormat:(NSString *)format
{
	return [DCMDateFormatter(format, self.timeZone) stringFromDate:self];
}

- (NSString *)dateString{
	if (isQuery)
		return queryString;
	NSString *format = @"%Y%m%d";
	return [self descriptionWithCalendarFormat:format];
}

- (NSString *)timeStringWithMilliseconds{
	if (isQuery)
		return queryString;
	NSString *format = @"%H%M%S.%F";
	return [self descriptionWithCalendarFormat:format];
}

- (NSString *)timeString {
	if (isQuery)
		return queryString;
	NSString *format = @"%H%M%S";
	NSString *time =  [self descriptionWithCalendarFormat:format];
    
    NSTimeInterval ti = self.timeIntervalSinceReferenceDate;
    NSTimeInterval useconds = ti - (unsigned long)ti;
    time = [time stringByAppendingFormat: @".%0000006ld", (unsigned long) (useconds * 1e6)];
    
	return [NSString stringWithFormat:@"%@", time];
}

- (NSString *)dateTimeString:(BOOL)withTimeZone{
	if (isQuery)
		return queryString;
	NSString *format = @"%Y%m%d%H%M%S";
	NSString *time =  [self descriptionWithCalendarFormat:format];
    
    NSTimeInterval ti = self.timeIntervalSinceReferenceDate;
    NSTimeInterval useconds = ti - (unsigned long)ti;
    time = [time stringByAppendingFormat: @".%0000006ld", (unsigned long) (useconds * 1e6)];
    
	if (!withTimeZone)
		return time;
	else {
		NSString *tz = [self descriptionWithCalendarFormat:@"%z"];
		return [NSString stringWithFormat:@"%@%@", time,tz];
	}
}

- (NSNumber *)dateAsNumber{
	return [NSNumber numberWithInt:[[self dateString] intValue]];
}
- (NSNumber *)timeAsNumber{
	return [NSNumber numberWithInt:[[self timeString] floatValue]];
}


//------------------------------------------------------------------------------------------------------------------------------------
#pragma mark•

- (BOOL)isQuery{
	return isQuery;
}

- (NSString *)queryString{
	return queryString;
}

- (void)dealloc{
	[_calendarFormat release];
	[_timeZone release];
	[queryString release];
	[super dealloc];
}

- (void)setIsQuery:(BOOL)query{
	isQuery = query;
}
- (void)setQueryString:(NSString *)query{
	[queryString release];
	queryString = [query retain];
}

- (NSString *)description{
	if (isQuery)
		return queryString;
	if ([[self calendarFormat] isEqualToString:@"%H:%M:%S"] ||
			[[self calendarFormat] isEqualToString:@"%H%M%S"] ||
			[[self calendarFormat] isEqualToString:@"%H%M"] ||
			[[self calendarFormat] isEqualToString:@"%H"]) 
		return [self timeString];
    
	return [super description];
}

@end
