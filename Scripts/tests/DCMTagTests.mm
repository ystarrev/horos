// Standalone runtime harness; not part of the app target. Link the newly built
// DCM.framework after a user-approved build so its bundled dictionaries are used.
// No database, DICOM image file, or persistent preferences are accessed.
#import <Foundation/Foundation.h>
#import "DCMAttributeTag.h"
#import "DCMTagDictionary.h"
#import "DCMTagForNameDictionary.h"

static void Check(BOOL condition, NSString *message)
{
    if (!condition)
    {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        Check(argc == 2, @"Usage: DCMTagTests dcm_tags_baseline.tsv");
        dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            @autoreleasepool
            {
                if (index % 2)
                    Check([[DCMTagForNameDictionary sharedTagForNameDictionary] count] > 3600, @"Cold name lookup");
                DCMAttributeTag *tag = [DCMAttributeTag tagWithGroup:0x0010 element:0x0010];
                Check([tag.name isEqual:@"PatientsName"] && [tag.vr isEqual:@"PN"], @"Concurrent tag lookup");
                Check([[DCMTagDictionary sharedTagDictionary] count] > 5000, @"Concurrent dictionary lookup");
            }
        });

        NSString *baseline = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:NULL];
        Check(baseline != nil, @"Read baseline");
        NSMutableDictionary *expectedNames = [NSMutableDictionary dictionary];
        NSUInteger count = 0;
        for (NSString *line in [baseline componentsSeparatedByString:@"\n"])
        {
            if (!line.length || [line hasPrefix:@"#"])
                continue;
            NSArray *fields = [line componentsSeparatedByString:@"\t"];
            Check(fields.count == 4, @"Four baseline fields");
            DCMAttributeTag *tag = [DCMAttributeTag tagWithTagString:fields[0]];
            Check([tag.stringValue isEqual:fields[0]], line);
            Check([tag.name isEqual:fields[1]], line);
            Check([tag.vr isEqual:fields[2]], line);
            NSDictionary *info = [DCMTagDictionary infoForGroup:tag.group element:tag.element];
            Check([info[@"VM"] isEqual:fields[3]], line);
            Check([[DCMAttributeTag tagWithGroup:tag.group element:tag.element] isEqual:tag], line);
            expectedNames[fields[1]] = fields[0];
            ++count;
        }
        Check(count == 3672, @"Complete legacy baseline");
        expectedNames[@"ReferencedPrintJobSequence"] = @"2100,0500";
        expectedNames[@"TM-LinePosition"] = @"0018,603D";
        for (NSString *name in expectedNames)
            Check([[[DCMAttributeTag tagWithName:name] stringValue] isEqual:expectedNames[name]], name);

        DCMAttributeTag *patientName = [DCMAttributeTag tagWithName:@"PatientName"];
        Check([patientName isEqual:[DCMAttributeTag tagWithName:@"PatientsName"]], @"Modern and legacy name aliases");
        for (NSString *text in @[@"0010,0010", @" (0010,0010) ", @"0x10,0X0010", @"( 10 , 10 )"])
            Check([[DCMAttributeTag tagWithTagString:text] isEqual:patientName], text);
        for (NSString *text in @[@"", @"0010", @"xyz,0010", @"0010,", @",0010", @"0010,0010,junk",
                                @"-1,0010", @"10000,0010", @"0010,10000", @"0010,10z", @"0010,0010)",
                                @"(0010,0010", @"((0010,0010))", @"0x,0010", @"0010,+10"])
            Check([DCMAttributeTag tagWithTagString:text] == nil, text);
        Check([DCMAttributeTag tagWithTagString:nil] == nil, @"Nil tag string");
        Check([DCMAttributeTag tagWithName:nil] == nil, @"Nil tag name");
        Check([DCMAttributeTag tagWithName:@"NotAnAttribute"] == nil, @"Unknown tag name");
        Check([DCMAttributeTag tagWithTag:nil] == nil, @"Nil copied tag");
        Check([DCMAttributeTag tagWithGroup:-1 element:0] == nil, @"Negative group");
        Check([DCMAttributeTag tagWithGroup:0 element:65536] == nil, @"Oversized element");
        Check([[[DCMAttributeTag tagWithTagString:@"fffe,e000"] stringValue] isEqual:@"FFFE,E000"], @"Canonical tag string");
        Check([[DCMAttributeTag tagWithGroup:0xfffe element:0xe000] longValue] == 0xfffee000L, @"Unsigned packed tag");

        patientName.vr = @"LO";
        DCMAttributeTag *copy = [[patientName copy] autorelease];
        Check([copy.vr isEqual:@"LO"], @"Copy preserves explicit VR");
        Check([copy isEqual:patientName] && copy.hash == patientName.hash, @"Equality and hash agree");
        Check(![copy isEqual:@"0010,0010"], @"Equality with another type");
        Check([@{patientName: @"value"}[copy] isEqual:@"value"], @"Tag dictionary keys");

        DCMAttributeTag *overlay = [DCMAttributeTag tagWithGroup:0x6002 element:0x3000];
        Check([overlay.name isEqual:@"OverlayData"] && [overlay.vr isEqual:@"ox"], @"Repeating overlay group");
        DCMAttributeTag *unknown = [DCMAttributeTag tagWithGroup:0x7055 element:0x1234];
        Check(unknown.isPrivate && [unknown.vr isEqual:@"UN"] && [unknown.name isEqual:@"Unknown"], @"Unknown private data");
        Check([[[DCMAttributeTag tagWithName:@"PhilipsFactor"] vr] isEqual:@"DS"], @"Known Philips compatibility");
        Check([[[DCMAttributeTag tagWithName:@"CurveDescription14"] stringValue] isEqual:@"5014,0022"], @"Correct curve alias");
        printf("DCM tag runtime tests passed (%lu legacy tags).\n", (unsigned long)count);
    }
    return EXIT_SUCCESS;
}
