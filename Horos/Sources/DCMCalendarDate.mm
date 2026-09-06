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

#import "DCMCalendarDate.h"

#include <dcmtk/dcmdata/dcvrda.h>
#include <dcmtk/dcmdata/dcvrtm.h>
#include <dcmtk/dcmdata/dcvrdt.h>
#include <cmath>

@interface DCMCalendarDate ()
- (NSString *)calendarFormat;
- (void)setCalendarFormat:(NSString *)format;
- (instancetype)initWithString:(NSString *)description calendarFormat:(NSString *)format microseconds:(unsigned long)usecs;
@end

static const NSCalendarUnit DCMDateUnits = NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
    | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;

static NSCalendar *DCMGregorianCalendar(NSTimeZone *timeZone)
{
    NSCalendar *calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    calendar.timeZone = timeZone ?: [NSTimeZone defaultTimeZone];
    return calendar;
}

static OFString DCMDICOMDateValue(NSString *string)
{
    if (![string isKindOfClass:[NSString class]])
        return OFString();
    string = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    const char *ascii = [string cStringUsingEncoding:NSASCIIStringEncoding];
    return ascii ? OFString(ascii, string.length) : OFString();
}

static NSString *DCMFormatForDatePrecision(size_t digits)
{
    switch (digits)
    {
        case 4: return @"%Y";
        case 6: return @"%Y%m";
        case 8: return @"%Y%m%d";
        case 10: return @"%Y%m%d%H";
        case 12: return @"%Y%m%d%H%M";
        default: return @"%Y%m%d%H%M%S";
    }
}

static DCMCalendarDate *DCMDateFromOFValues(const OFDate &day, const OFTime &time,
                                         NSTimeZone *timeZone, NSString *format)
{
    // NSDate has no leap-second representation; do not silently move it to another day.
    if (!day.isValid() || day.getYear() == 0 || day.getYear() > 9999 || !time.isValid() || time.getSecond() >= 60)
        return nil;
    NSDateComponents *parts = [[[NSDateComponents alloc] init] autorelease];
    parts.year = day.getYear();
    parts.month = day.getMonth();
    parts.day = day.getDay();
    parts.hour = time.getHour();
    parts.minute = time.getMinute();
    parts.second = time.getIntSecond();
    NSCalendar *calendar = DCMGregorianCalendar(timeZone);
    NSDate *base = [calendar dateFromComponents:parts];
    if (!base)
        return nil;
    // DCMTK validates fields independently. Reject February 30 and DST gaps
    // instead of accepting Foundation's normalized date/time.
    NSDateComponents *actual = [calendar components:DCMDateUnits fromDate:base];
    if (actual.year != parts.year || actual.month != parts.month || actual.day != parts.day
        || actual.hour != parts.hour || actual.minute != parts.minute || actual.second != parts.second)
        return nil;
    DCMCalendarDate *date = [DCMCalendarDate dateWithTimeIntervalSinceReferenceDate:
        base.timeIntervalSinceReferenceDate + (time.getSecond() - time.getIntSecond())];
    [date setTimeZone:calendar.timeZone];
    [date setCalendarFormat:format];
    return date;
}

static BOOL DCMGetOFDateTime(NSDate *date, NSTimeZone *timeZone, OFDateTime &value)
{
    if (!date || !std::isfinite(date.timeIntervalSinceReferenceDate))
        return NO;
    NSTimeInterval seconds = date.timeIntervalSinceReferenceDate;
    NSTimeInterval wholeSeconds = std::floor(seconds);
    long microseconds = std::lround((seconds - wholeSeconds) * 1e6);
    if (microseconds == 1000000)
    {
        ++wholeSeconds;
        microseconds = 0;
    }
    NSDate *wholeDate = [NSDate dateWithTimeIntervalSinceReferenceDate:wholeSeconds];
    NSDateComponents *parts = [DCMGregorianCalendar(timeZone) components:DCMDateUnits fromDate:wholeDate];
    if (parts.year < 1 || parts.year > 9999)
        return NO;
    OFDate day((unsigned int)parts.year, (unsigned int)parts.month, (unsigned int)parts.day);
    OFTime time((unsigned int)parts.hour, (unsigned int)parts.minute, parts.second + microseconds / 1e6);
    value = OFDateTime(day, time);
    return value.isValid();
}

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


+ (id)dicomDate:(NSString *)string
{
    if (![string isKindOfClass:[NSString class]])
        return nil;
    if ([string rangeOfString:@"-"].location != NSNotFound)
        return [self queryDate:string];
    OFString value = DCMDICOMDateValue(string);
    NSString *format = value.size() == 10 ? @"%Y.%m.%d" : DCMFormatForDatePrecision(value.size());
    // Retain Horos' abbreviated year/month input in addition to standard DA.
    if (value.size() == 4) value += "0101";
    else if (value.size() == 6) value += "01";
    OFDate day;
    if (DcmDate::getOFDateFromString(value, day, OFTrue).bad())
        return nil;
    return DCMDateFromOFValues(day, OFTime(0, 0, 0), nil, format);
}

+ (id)dicomTime:(NSString *)string
{
    if (![string isKindOfClass:[NSString class]])
        return nil;
    if ([string rangeOfString:@"-"].location != NSNotFound)
        return [self queryDate:string];
    OFString value = DCMDICOMDateValue(string);
    OFTime time;
    if (!DcmTime::check(value.c_str(), value.size(), OFTrue)
        || DcmTime::getOFTimeFromString(value, time, OFTrue, 0).bad())
        return nil;
    size_t digits = value.find('.');
    if (digits == OFString_npos) digits = value.size();
    NSString *format = value.find(':') != OFString_npos ? @"%H:%M:%S"
        : digits == 2 ? @"%H" : digits == 4 ? @"%H%M" : @"%H%M%S";
    return DCMDateFromOFValues(OFDate(2001, 1, 1), time, nil, format);
}

+ (id)dicomDateTime:(NSString *)string
{
    OFString value = DCMDICOMDateValue(string);
    OFDateTime dateTime;
    if (!DcmDateTime::check(value.c_str(), value.size())
        || DcmDateTime::getOFDateTimeFromString(value, dateTime).bad())
        return nil;
    BOOL hasTimeZone = value.size() >= 9
        && (value[value.size() - 5] == '+' || value[value.size() - 5] == '-');
    NSTimeZone *timeZone = nil;
    if (hasTimeZone)
    {
        double offset;
        OFTime checkedZone;
        // DCMTK's date-only DT path does not report a rejected timezone assignment.
        if (DcmTime::getTimeZoneFromString(value.c_str() + value.size() - 5, 5, offset).bad()
            || !checkedZone.setTime(0, 0, 0, offset))
            return nil;
        timeZone = [NSTimeZone timeZoneForSecondsFromGMT:std::lround(offset * 3600)];
    }
    size_t digits = value.find('.');
    if (digits == OFString_npos) digits = value.size() - (hasTimeZone ? 5 : 0);
    // Use the explicit offset while constructing the instant, not afterwards.
    // With no offset, Foundation applies local DST rules for the date in question.
    return DCMDateFromOFValues(dateTime.getDate(), dateTime.getTime(), timeZone, DCMFormatForDatePrecision(digits));
}

+ (id)dicomDateWithDate:(NSDate *)date
{
    OFDateTime value;
    NSTimeZone *timeZone = [NSTimeZone defaultTimeZone];
    if (!DCMGetOFDateTime(date, timeZone, value))
        return nil;
    return DCMDateFromOFValues(value.getDate(), OFTime(0, 0, 0), timeZone, @"%Y%m%d");
}

+ (id)dicomTimeWithDate:(NSDate *)date
{
    OFDateTime value;
    NSTimeZone *timeZone = [NSTimeZone defaultTimeZone];
    if (!DCMGetOFDateTime(date, timeZone, value))
        return nil;
    return DCMDateFromOFValues(OFDate(2001, 1, 1), value.getTime(), timeZone, @"%H%M%S");
}

+ (id)dicomDateTimeWithDicomDate:(DCMCalendarDate *)date dicomTime:(DCMCalendarDate *)time
{
    if (!date || !time || date.isQuery || time.isQuery)
        return nil;
    OFDateTime dayValue, timeValue;
    if (!DCMGetOFDateTime(date, date.timeZone, dayValue) || !DCMGetOFDateTime(time, time.timeZone, timeValue))
        return nil;
    return DCMDateFromOFValues(dayValue.getDate(), timeValue.getTime(), date.timeZone, nil);
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

- (NSString *)dateString
{
    if (isQuery)
        return queryString;
    OFDateTime value;
    OFString result;
    if (!DCMGetOFDateTime(self, self.timeZone, value)
        || DcmDate::getDicomDateFromOFDate(value.getDate(), result).bad())
        return nil;
    return @(result.c_str());
}

- (NSString *)timeStringWithMilliseconds
{
    return [self timeString];
}

- (NSString *)timeString
{
    if (isQuery)
        return queryString;
    OFDateTime value;
    OFString result;
    if (!DCMGetOFDateTime(self, self.timeZone, value)
        || DcmTime::getDicomTimeFromOFTime(value.getTime(), result, OFTrue, OFTrue).bad())
        return nil;
    return @(result.c_str());
}

- (NSString *)dateTimeString:(BOOL)withTimeZone
{
    if (isQuery)
        return queryString;
    OFDateTime value;
    OFString result;
    if (!DCMGetOFDateTime(self, self.timeZone, value)
        || DcmDateTime::getDicomDateTimeFromOFDateTime(value, result, OFTrue, OFTrue, OFFalse).bad())
        return nil;
    NSString *string = @(result.c_str());
    // Keep Foundation's integer-minute offset formatting; OFTime truncates
    // some fractional-hour offsets by a minute when converting from double.
    return withTimeZone ? [string stringByAppendingString:[self descriptionWithCalendarFormat:@"%z"]] : string;
}

- (NSNumber *)dateAsNumber
{
    return @([[self dateString] intValue]);
}

- (NSNumber *)timeAsNumber
{
    if (isQuery)
        return @([queryString intValue]);
    NSDateComponents *parts = self.dateComponents;
    // The database contract is integral HHMMSS, not fractional seconds.
    return @(parts.hour * 10000 + parts.minute * 100 + parts.second);
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
