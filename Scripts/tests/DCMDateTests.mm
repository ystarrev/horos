// Standalone runtime harness, not an app target. Run against a newly built
// DCM.framework only after build approval. Uses synthetic values and in-memory
// data containers; never opens patient data or modifies persistent preferences.
#import <Foundation/Foundation.h>
#import "DCMCalendarDate.h"
#import "DCMDataContainer.h"
#import "DCMTransferSyntax.h"
#include <cmath>

static void Check(BOOL condition, NSString *message)
{
    if (!condition)
    {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

static DCMCalendarDate *Parse(NSString *kind, NSString *input)
{
    if ([kind isEqual:@"DA"]) return [DCMCalendarDate dicomDate:input];
    if ([kind isEqual:@"TM"]) return [DCMCalendarDate dicomTime:input];
    return [DCMCalendarDate dicomDateTime:input];
}

static NSString *Format(NSString *kind, DCMCalendarDate *date)
{
    if ([kind isEqual:@"DA"]) return date.dateString;
    if ([kind isEqual:@"TM"]) return date.timeString;
    return [date dateTimeString:YES];
}

static DCMDataContainer *Container(NSString *input)
{
    return [DCMDataContainer dataContainerWithData:[input dataUsingEncoding:NSASCIIStringEncoding]
                                  transferSyntax:[DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        Check(argc == 2, @"Usage: DCMDateTests dcm_dates_baseline.json");
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        Check(data != nil, @"Read date fixtures");
        NSDictionary *fixtures = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        Check(fixtures != nil, @"Parse date fixtures");
        NSTimeZone *originalZone = [[NSTimeZone defaultTimeZone] retain];
        NSTimeZone *utc = [NSTimeZone timeZoneForSecondsFromGMT:0];
        @try
        {
            for (NSDictionary *test in fixtures[@"valid"])
            {
                [NSTimeZone setDefaultTimeZone:test[@"zone"] ? [NSTimeZone timeZoneWithName:test[@"zone"]] : utc];
                DCMCalendarDate *date = Parse(test[@"kind"], test[@"input"]);
                Check(date != nil && !date.isQuery, test.description);
                Check([Format(test[@"kind"], date) isEqual:test[@"output"]], test.description);
                DCMCalendarDate *copy = [[date copy] autorelease];
                Check([copy isEqual:date] && [Format(test[@"kind"], copy) isEqual:test[@"output"]], @"Copy date/zone");
                if (test[@"utc"])
                {
                    [copy setTimeZone:utc];
                    Check([[copy dateTimeString:NO] isEqual:test[@"utc"]], test.description);
                }
            }
            [NSTimeZone setDefaultTimeZone:utc];
            for (NSString *kind in fixtures[@"invalid"])
            {
                for (NSString *input in fixtures[@"invalid"][kind])
                    Check(Parse(kind, input) == nil, [NSString stringWithFormat:@"Reject %@ %@", kind, input]);
                Check(Parse(kind, nil) == nil, @"Reject nil input");
            }
            for (NSString *kind in fixtures[@"ranges"])
                for (NSString *input in fixtures[@"ranges"][kind])
                {
                    DCMCalendarDate *query = Parse(kind, input);
                    Check(query.isQuery && [query.queryString isEqual:input], @"Query range is unchanged");
                    Check([Format(kind, query) isEqual:input], @"Query serialization");
                    DCMCalendarDate *copy = [[query copy] autorelease];
                    Check(copy.isQuery && [copy.queryString isEqual:input], @"Copy query range");
                }
            Check([[[DCMCalendarDate queryDate:@""] dateString] isEqual:@""], @"Empty matching key");

            DCMCalendarDate *time = [DCMCalendarDate dicomTime:@"235959.999999"];
            Check(time.timeAsNumber.intValue == 235959, @"Numeric time never rounds into the next minute");
            Check([time.timeStringWithMilliseconds isEqual:time.timeString], @"Six-digit fractional serialization");
            DCMCalendarDate *combined = [DCMCalendarDate dicomDateTimeWithDicomDate:[DCMCalendarDate dicomDate:@"19991231"] dicomTime:time];
            Check([[combined dateTimeString:NO] isEqual:@"19991231235959.999999"], @"Combine DA/TM without losing fraction");
            Check([[[DCMCalendarDate dicomTimeWithDate:combined] timeString] isEqual:@"235959.999999"], @"NSDate conversion keeps fraction");
            Check([DCMCalendarDate dicomDateWithDate:nil] == nil && [DCMCalendarDate dicomTimeWithDate:nil] == nil, @"Missing source date");
            Check([DCMCalendarDate dicomDateTimeWithDicomDate:combined dicomTime:nil] == nil, @"Missing time");
            DCMCalendarDate *negative = [DCMCalendarDate dateWithTimeIntervalSinceReferenceDate:-0.25];
            Check([negative.timeString isEqual:@"235959.750000"], @"Fraction before reference date");
            Check([[negative dateTimeString:NO] isEqual:@"20001231235959.750000"], @"DT before reference date");
            DCMCalendarDate *carry = [DCMCalendarDate dateWithTimeIntervalSinceReferenceDate:59.9999996];
            Check([carry.timeString isEqual:@"000100.000000"], @"Microsecond rounding carries seconds");

            [NSTimeZone setDefaultTimeZone:[NSTimeZone timeZoneWithName:@"America/Edmonton"]];
            Check([DCMCalendarDate dicomDateTime:@"20260308023000"] == nil, @"Reject nonexistent local DST time");
            Check([DCMCalendarDate dicomDateTime:@"20260308023000-0700"] != nil, @"Explicit offset is independent of local DST");
            [NSTimeZone setDefaultTimeZone:utc];

            DCMDataContainer *container = Container(@"000000\\123456.123456");
            NSArray *times = [container nextTimesWithLength:(int)container.length];
            Check(times.count == 2 && [[times[0] timeString] isEqual:@"000000.000000"]
                && [[times[1] timeString] isEqual:@"123456.123456"], @"Midnight first in multi-valued TM");
            Check(container.position == container.length, @"Advance past all time values");
            container = Container(@"000000");
            Check([[(DCMCalendarDate *)[container nextTimeWithLength:6] timeString] isEqual:@"000000.000000"], @"Single TM");
            container = Container(@"20240229");
            Check([[(DCMCalendarDate *)[container nextDate] dateString] isEqual:@"20240229"], @"Single DA");
            container = Container(@"20240229123456.123456-0030");
            DCMCalendarDate *parsed = (DCMCalendarDate *)[container nextDateTimeWithLength:(int)container.length];
            [parsed setTimeZone:utc];
            Check([[parsed dateTimeString:NO] isEqual:@"20240229130456.123456"], @"Single DT uses explicit offset");

            dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
                @autoreleasepool
                {
                    DCMCalendarDate *date = [DCMCalendarDate dicomDateTime:@"20240229123456.123456-0700"];
                    Check([[date dateTimeString:YES] isEqual:@"20240229123456.123456-0700"], @"Concurrent date conversion");
                }
            });
            printf("DCM date runtime tests passed.\n");
        }
        @finally
        {
            [NSTimeZone setDefaultTimeZone:originalZone];
            [originalZone release];
        }
    }
    return EXIT_SUCCESS;
}
