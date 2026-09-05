// Standalone runtime regression harness; deliberately not part of the app target.
// Run only after a user-approved build. These tests do not open database files
// or modify persistent defaults.
#import <Foundation/Foundation.h>
#import "DCMAbstractSyntaxUID.h"
#import "DCMTransferSyntax.h"

static void Check(BOOL condition, NSString *message)
{
    if (!condition)
    {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

static void CheckTransfer(DCMTransferSyntax *syntax, NSDictionary *expected)
{
    Check([syntax.transferSyntax isEqual:expected[@"uid"]], @"Transfer UID");
    Check(syntax.isEncapsulated == [expected[@"encapsulated"] boolValue], @"Encapsulation");
    Check(syntax.isLittleEndian == [expected[@"littleEndian"] boolValue], @"Byte order");
    Check(syntax.isExplicit == [expected[@"explicitVR"] boolValue], @"Value representation");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        Check(argc >= 2, @"Usage: DCMSyntaxTests baseline.json [--display-overrides]");
        BOOL overrides = argc >= 3 && strcmp(argv[2], "--display-overrides") == 0;
        NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
        Check(data != nil, @"Read baseline");
        NSDictionary *baseline = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        Check(baseline != nil, @"Parse baseline");

        NSString *mr = @"1.2.840.10008.5.1.4.1.1.4";
        NSString *custom = @"2.25.999999";
        [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{
            @"additionalDisplayedStorageSOPClassUIDArray": overrides ? @[custom] : @[],
            @"hiddenDisplayedStorageSOPClassUIDArray": overrides ? @[mr] : @[]
        } forName:NSArgumentDomain];

        // Cold-start callers can arrive in any order, including on import queues.
        dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            @autoreleasepool
            {
                NSArray *hidden = [DCMAbstractSyntaxUID hiddenImageSyntaxes];
                NSArray *images = [DCMAbstractSyntaxUID imageSyntaxes];
                NSArray *supported = [DCMAbstractSyntaxUID allSupportedSyntaxes];
                Check(hidden != nil && images.count > 0 && supported.count > 0, @"Initialized lists");
                Check([images containsObject:mr] == !overrides, @"Concurrent image policy");
                Check([hidden containsObject:mr] == overrides, @"Concurrent hidden policy");
                Check([supported containsObject:mr], @"Hidden objects remain supported");
                Check([[DCMTransferSyntax JPEG2000LosslessTransferSyntax] isEncapsulated], @"Concurrent syntax");
            }
        });

        for (NSString *selector in baseline[@"getters"])
        {
            id value = [DCMAbstractSyntaxUID performSelector:NSSelectorFromString(selector)];
            Check([value isEqual:baseline[@"getters"][selector]], selector);
        }
        for (NSString *selector in baseline[@"arrays"])
        {
            NSMutableArray *expected = [[baseline[@"arrays"][selector] mutableCopy] autorelease];
            if (overrides && [selector isEqual:@"imageSyntaxes"])
            {
                [expected addObject:custom];
                [expected removeObject:mr];
            }
            id value = [DCMAbstractSyntaxUID performSelector:NSSelectorFromString(selector)];
            Check([value isEqual:expected], selector);
        }
        Check(![DCMAbstractSyntaxUID isImageStorage:nil], @"Nil image UID");
        Check(![DCMAbstractSyntaxUID isImageStorage:@"unknown"], @"Unknown image UID");
        Check([DCMAbstractSyntaxUID isImageStorage:mr] == !overrides, @"Visible MR policy");
        Check([DCMAbstractSyntaxUID isHiddenImageStorage:mr] == overrides, @"Hidden MR policy");
        Check([DCMAbstractSyntaxUID isImageStorage:custom] == overrides, @"Additional image policy");
        Check([DCMAbstractSyntaxUID isImageStorage:[DCMAbstractSyntaxUID pdfStorageClassUID]], @"PDF display policy");
        Check([DCMAbstractSyntaxUID isNonImageStorage:[DCMAbstractSyntaxUID segmentationStorage]], @"SEG policy");
        Check(![DCMAbstractSyntaxUID isImageStorage:[DCMAbstractSyntaxUID segmentationStorage]], @"SEG is not a scout image");
        Check([DCMAbstractSyntaxUID isStructuredReport:[DCMAbstractSyntaxUID basicTextSRStorage]], @"SR policy");
        Check([DCMAbstractSyntaxUID isSupportedPrivateClasses:@"1.3.46.670589.5.0.9"], @"Philips prefix policy");
        Check([DCMAbstractSyntaxUID isMultiframe:[DCMAbstractSyntaxUID enhancedMRImageStorage]], @"Enhanced MR policy");
        Check([DCMAbstractSyntaxUID isStandalone:@"1.2.840.10008.5.1.4.1.1.9"], @"Correct retired curve UID");

        for (NSDictionary *expected in baseline[@"transferSyntaxes"])
        {
            DCMTransferSyntax *syntax = [[[DCMTransferSyntax alloc] initWithTS:expected[@"uid"]] autorelease];
            CheckTransfer(syntax, expected);
            DCMTransferSyntax *copy = [[syntax copy] autorelease];
            CheckTransfer(copy, expected);
            Check([copy isEqual:syntax] && copy.hash == syntax.hash, @"Copy equality/hash");
        }
        for (NSString *selector in baseline[@"transferFactories"])
        {
            DCMTransferSyntax *syntax = [DCMTransferSyntax performSelector:NSSelectorFromString(selector)];
            Check([syntax.transferSyntax isEqual:baseline[@"transferFactories"][selector]], selector);
        }
        Check([[DCMTransferSyntax alloc] initWithTS:nil] == nil, @"Nil transfer syntax");
        Check([[DCMTransferSyntax alloc] initWithTS:@""] == nil, @"Empty transfer syntax");
        DCMTransferSyntax *unknown = [[[DCMTransferSyntax alloc] initWithTS:custom] autorelease];
        Check(unknown.isEncapsulated && unknown.isExplicit && unknown.isLittleEndian, @"Private syntax compatibility");
        Check([unknown.name isEqual:@"Unknown Syntax"], @"Unknown syntax description");
        Check(![unknown isEqual:custom] && ![unknown isEqual:nil], @"Equality with another type");

        DCMTransferSyntax *customSyntax = [[[DCMTransferSyntax alloc] initWithTS:custom
            isEncapsulated:NO isLittleEndian:NO isExplicit:NO name:@"Custom"] autorelease];
        DCMTransferSyntax *copy = [[customSyntax copy] autorelease];
        Check(!copy.isEncapsulated && !copy.isLittleEndian && !copy.isExplicit, @"Custom copy flags");
        Check([copy.name isEqual:@"Custom"], @"Custom copy name");

        // Recognition is not a claim that the legacy decoder supports these codecs.
        DCMTransferSyntax *deflated = [[[DCMTransferSyntax alloc] initWithTS:@"1.2.840.10008.1.2.1.99"] autorelease];
        Check(!deflated.isEncapsulated && deflated.isExplicit && deflated.isLittleEndian, @"Deflated is not encapsulated pixel data");
        DCMTransferSyntax *encapsulated = [[[DCMTransferSyntax alloc] initWithTS:@"1.2.840.10008.1.2.1.98"] autorelease];
        Check(encapsulated.isEncapsulated, @"Encapsulated uncompressed pixel data");
        printf("DCM syntax runtime tests passed (%s).\n", overrides ? "display overrides" : "default policy");
    }
    return EXIT_SUCCESS;
}
