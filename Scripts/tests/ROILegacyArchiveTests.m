// Standalone runtime harness for ROI.m and MyPoint.m, not an app target.
// Build/run only after approval. All archives are synthetic and memory-only.
#import "ROI.h"
#import "HorosUnkeyedArchiveCompatibility.h"
#include <math.h>

static void Check(BOOL condition, NSString *message)
{
    if (!condition)
    {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

@interface HorosLegacyROIArchiveFixture : NSObject <NSCoding>
@property(nonatomic) NSInteger archiveVersion;
@property(nonatomic) ToolMode roiType;
@property(nonatomic) BOOL populatedExtension;
@end

@implementation HorosLegacyROIArchiveFixture
- (id)initWithCoder:(NSCoder *)coder
{
    [self release];
    return nil;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSArray *fields = @[
        @[[MyPoint point:NSMakePoint(10.25, 20.5)], [MyPoint point:NSMakePoint(30.75, 40.5)]],
        NSStringFromRect(NSMakeRect(10, 20, 30, 40)), @((float)self.roiType),
        @NO, @2.0f, @NO, @0.75f, @19660.0f, @65535.0f, @19660.0f,
        @"Synthetic ROI", @"Synthetic comment", @0.5,
        NSStringFromPoint(NSMakePoint(-12, -34))
    ];
    for (id value in fields)
        [coder encodeObject:value];
    if (self.archiveVersion >= 2)
        [coder encodeObject:@0.75];
    if (self.roiType == tPlain)
    {
        for (id value in @[@2, @0, @2, @0, @10, @20, @11, @21])
            [coder encodeObject:value];
        const unsigned char mask[] = {0, 255, 255, 0};
        [coder encodeObject:[NSData dataWithBytes:mask length:sizeof(mask)]];
    }
    if (self.archiveVersion >= 3)
        [coder encodeObject:@[@3]];
    if (self.archiveVersion >= 4)
        for (id value in @[@1.0f, @2.0f]) [coder encodeObject:value];
    if (self.archiveVersion >= 5)
        for (id value in @[@0, @NO]) [coder encodeObject:value];
    if (self.archiveVersion >= 6)
    {
        [coder encodeObject:@123.0];
        [coder encodeObject:nil];
        [coder encodeObject:@"Length: synthetic"];
        for (int index = 0; index < 3; ++index) [coder encodeObject:nil];
    }
    if (self.archiveVersion >= 7)
    {
        [coder encodeObject:@NO];
        [coder encodeObject:@NO];
        [coder encodeObject:nil];
        [coder encodeObject:@YES];
    }
    if (self.archiveVersion >= 8) [coder encodeObject:@NO];
    if (self.archiveVersion >= 9)
    {
        [coder encodeObject:@YES];
        [coder encodeObject:@NO];
    }
    if (self.archiveVersion >= 10) [coder encodeObject:@NO];
    if (self.archiveVersion >= 11)
    {
        [coder encodeObject:@YES];
        [coder encodeObject:@YES];
    }
    if (self.archiveVersion >= 12) [coder encodeObject:@"2.25.123456789"];
    if (self.archiveVersion >= 14) [coder encodeObject:@0.0];
    if (self.archiveVersion >= 15) [coder encodeObject:@1.0];
    if (self.archiveVersion >= 16)
        for (id value in @[@"extension", @42, @[@1, @2], @{ @"key": @"value" }])
            [coder encodeObject:self.populatedExtension ? value : nil];
}
@end

static void CheckROI(ROI *roi, NSInteger version, ToolMode type)
{
    Check([roi isKindOfClass:ROI.class], @"Decoded the production ROI class");
    Check(roi.type == type && [roi.name isEqual:@"Synthetic ROI"], @"Type and name");
    Check([roi.comments isEqual:@"Synthetic comment"], @"Comments");
    Check(roi.points.count == 2, @"Point count");
    Check(NSEqualPoints([roi.points[0] point], NSMakePoint(10.25, 20.5)), @"First point");
    Check(NSEqualPoints([roi.points[1] point], NSMakePoint(30.75, 40.5)), @"Second point");
    Check(NSEqualRects(roi.rect, NSMakeRect(10, 20, 30, 40)), @"Rectangle");
    Check(roi.pixelSpacingX == 0.5 && roi.pixelSpacingY == (version >= 2 ? 0.75 : 0.5), @"Spacing");
    Check(NSEqualPoints(roi.imageOrigin, NSMakePoint(-12, -34)), @"Image origin");
    Check(roi.opacity == 0.75f && roi.thickness == 2.0f, @"Style");
    if (version >= 6)
        Check([roi.textualBoxLine2 isEqual:@"Length: synthetic"], @"Annotation text");
    if (type == tPlain)
    {
        const unsigned char expected[] = {0, 255, 255, 0};
        Check(roi.textureWidth == 2 && roi.textureHeight == 2, @"Mask dimensions");
        Check(roi.textureBuffer && memcmp(roi.textureBuffer, expected, sizeof(expected)) == 0, @"Mask bytes");
    }
}

int main(void)
{
    @autoreleasepool
    {
        for (NSInteger version = 1; version <= 16; ++version)
            for (NSNumber *typeValue in @[@(tMesure), @(tROI), @(tAngle), @(tPlain)])
                for (int populated = 0; populated <= 1; ++populated)
                {
                    HorosLegacyROIArchiveFixture *fixture = [[[HorosLegacyROIArchiveFixture alloc] init] autorelease];
                    fixture.archiveVersion = version;
                    fixture.roiType = typeValue.shortValue;
                    fixture.populatedExtension = populated;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    [HorosLegacyROIArchiveFixture setVersion:version];
                    NSMutableData *data = [NSMutableData data];
                    NSArchiver *writer = [[[NSArchiver alloc] initForWritingWithMutableData:data] autorelease];
                    [writer encodeClassName:NSStringFromClass(HorosLegacyROIArchiveFixture.class) intoClassName:@"ROI"];
                    [writer encodeRootObject:@[fixture, fixture, @"after ROI"]];
                    NSUnarchiver *reader = [[[NSUnarchiver alloc] initForReadingWithData:data] autorelease];
                    NSArray *result = [reader decodeObject];
                    Check(reader.isAtEnd && result.count == 3, @"Entire array consumed");
#pragma clang diagnostic pop
                    Check([result[2] isEqual:@"after ROI"], @"Following object preserved");
                    CheckROI(result[0], version, fixture.roiType);
                    Check(result[0] == result[1], @"Shared ROI reference preserved");
                    NSArray *roundTrip = HorosUnarchiveUnkeyedObject(HorosArchiveUnkeyedObject(result));
                    CheckROI(roundTrip[0], version, fixture.roiType);
                }
        puts("Legacy ROI versions 1-16: decode and round-trip checks passed");
    }
    return EXIT_SUCCESS;
}
