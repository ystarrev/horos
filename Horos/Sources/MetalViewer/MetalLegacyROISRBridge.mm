#import "MetalLegacyROISRBridge.h"

#import <AppKit/AppKit.h>
#include <math.h>
#include <string.h>

#import "DCMPix.h"
#import "DicomDatabase.h"
#import "DicomImage.h"
#import "DicomSeries.h"
#import "DicomStudy.h"
#import "MyPoint.h"
#import "ROI.h"
#import "SRAnnotation.h"

static NSString * const HorosMetalTumourSeedROIName = @"Horos Tumour Seed";
static NSString * const HorosMetalTumourSeedCommentPrefix = @"HorosMetalTumourSeed:";

@implementation MetalLegacyROISRBridge

+ (NSArray<NSDictionary<NSString *, id> *> *)roiDictionariesForPixList:(NSArray *)pixList
{
    NSArray<NSDictionary<NSString *, id> *> *sourceRecords = [self sourceRecordsForPixList:pixList];
    NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seenROISignatures = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *record in sourceRecords)
    {
        @autoreleasepool
        {
            NSString *path = record[@"path"];
            NSNumber *sliceIndex = record[@"sliceIndex"];
            NSArray *rois = [self roiArrayAtPath:path];
            for (ROI *roi in rois)
            {
                if (![roi isKindOfClass:ROI.class] || roi.hidden || [self isMetalTumourSeed:roi])
                    continue;

                NSDictionary<NSString *, id> *dictionary = [self dictionaryForROI:roi sliceIndex:sliceIndex.integerValue];
                if (dictionary == nil)
                    continue;

                NSString *signature = [self signatureForROIDictionary:dictionary];
                if ([seenROISignatures containsObject:signature])
                    continue;
                [seenROISignatures addObject:signature];
                [result addObject:dictionary];
            }
        }
    }

    return result;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)sourceRecordsForPixList:(NSArray *)pixList
{
    if (pixList.count == 0)
        return @[];

    DicomImage *firstImage = nil;
    for (DCMPix *pix in pixList)
    {
        if (![pix isKindOfClass:DCMPix.class])
            continue;
        firstImage = [self imageForPix:pix];
        if (firstImage)
            break;
    }

    NSManagedObjectContext *context = firstImage.managedObjectContext;
    if (context == nil)
        return @[];

    __block NSArray<NSDictionary<NSString *, id> *> *sourceRecords = nil;
    N2PerformManagedObjectContextBlockAndWait(context, ^{
        @try
        {
        NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *sliceIndexesByReference = [NSMutableDictionary dictionary];
        DicomStudy *study = nil;

        for (NSUInteger sliceIndex = 0; sliceIndex < pixList.count; ++sliceIndex)
        {
            DCMPix *pix = pixList[sliceIndex];
            if (![pix isKindOfClass:DCMPix.class])
                continue;

            DicomImage *image = [self imageForPix:pix];
            DicomStudy *imageStudy = image.series.study;
            NSString *sopInstanceUID = image.sopInstanceUID;
            if (imageStudy == nil || sopInstanceUID.length == 0)
                continue;
            if (study == nil)
                study = imageStudy;
            if (imageStudy != study)
                continue;

            NSInteger frame = image.frameID.integerValue;
            NSArray<NSString *> *references = frame > 0
                ? @[[sopInstanceUID stringByAppendingFormat:@"-%ld", (long)frame]]
                : @[sopInstanceUID, [sopInstanceUID stringByAppendingString:@"-0"]];
            for (NSString *reference in references)
            {
                NSMutableArray<NSNumber *> *indexes = sliceIndexesByReference[reference];
                if (indexes == nil)
                {
                    indexes = [NSMutableArray array];
                    sliceIndexesByReference[reference] = indexes;
                }
                [indexes addObject:@(sliceIndex)];
            }
        }

        if (study == nil || sliceIndexesByReference.count == 0)
        {
            sourceRecords = [@[] retain];
            return;
        }

        NSMutableArray<NSDictionary<NSString *, id> *> *records = [NSMutableArray array];
        NSMutableSet<NSString *> *seenRecordKeys = [NSMutableSet set];
        NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;

        for (DicomSeries *series in study.series)
        {
            if (![self isLegacyROISeries:series])
                continue;

            for (DicomImage *roiImage in series.images)
            {
                NSString *reference = [roiImage.comment stringByTrimmingCharactersInSet:whitespace];
                NSArray<NSNumber *> *sliceIndexes = sliceIndexesByReference[reference];
                if (sliceIndexes.count == 0)
                    continue;

                NSString *path = roiImage.completePathResolved;
                if (path.length == 0)
                    continue;

                for (NSNumber *sliceIndex in sliceIndexes)
                {
                    NSString *recordKey = [NSString stringWithFormat:@"%@:%@", path, sliceIndex];
                    if ([seenRecordKeys containsObject:recordKey])
                        continue;
                    [seenRecordKeys addObject:recordKey];
                    [records addObject:@{
                        @"path": path,
                        @"sliceIndex": sliceIndex,
                        @"date": roiImage.date ?: NSDate.distantPast,
                    }];
                }
            }
        }

        [records sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSComparisonResult dateResult = [left[@"date"] compare:right[@"date"]];
            if (dateResult != NSOrderedSame)
                return dateResult;
            return [left[@"path"] compare:right[@"path"]];
        }];
        sourceRecords = [records copy];
        }
        @catch (NSException *exception)
        {
            [sourceRecords release];
            sourceRecords = [@[] retain];
            NSLog(@"MetalLegacyROISRBridge could not locate ROI SR records: %@", exception);
        }
    });

    return [sourceRecords autorelease];
}

+ (DicomImage *)imageForPix:(DCMPix *)pix
{
    if ([pix respondsToSelector:@selector(imageObj)])
        return pix.imageObj;
    return nil;
}

+ (BOOL)isLegacyROISeries:(DicomSeries *)series
{
    NSString *name = series.name ?: @"";
    NSString *description = series.seriesDescription ?: @"";
    return [name hasPrefix:@"OsiriX ROI SR"] || [description hasPrefix:@"OsiriX ROI SR"];
}

+ (NSArray *)roiArrayAtPath:(NSString *)path
{
    if (path.length == 0)
        return @[];

    NSData *data = [SRAnnotation roiFromDICOM:path];
    if (data == nil)
        return @[];

    @try
    {
        id object = [SRAnnotation unarchiveROIsFromCompatibilityData:data];
        if ([object isKindOfClass:NSArray.class])
            return object;
    }
    @catch (NSException *exception)
    {
        NSLog(@"MetalLegacyROISRBridge could not read ROI SR at %@: %@", path, exception);
    }
    return @[];
}

+ (BOOL)isMetalTumourSeed:(ROI *)roi
{
    return [roi.name isEqualToString:HorosMetalTumourSeedROIName] ||
        [roi.comments hasPrefix:HorosMetalTumourSeedCommentPrefix];
}

+ (NSDictionary<NSString *, id> *)dictionaryForROI:(ROI *)roi sliceIndex:(NSInteger)sliceIndex
{
    NSMutableArray<NSNumber *> *pointCoordinates = [NSMutableArray arrayWithCapacity:roi.points.count * 2];
    for (id object in roi.points)
    {
        NSPoint point;
        if ([object isKindOfClass:MyPoint.class])
            point = [object point];
        else if ([object respondsToSelector:@selector(pointValue)])
            point = [object pointValue];
        else
            continue;
        if (!isfinite(point.x) || !isfinite(point.y))
            continue;
        [pointCoordinates addObject:@(point.x)];
        [pointCoordinates addObject:@(point.y)];
    }

    NSRect rect = roi.rect;
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height))
        rect = NSZeroRect;

    NSColor *color = [roi.NSColor colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace] ?: NSColor.systemYellowColor;
    CGFloat alpha = MIN(MAX(color.alphaComponent, 0.0), 1.0);
    CGFloat thickness = isfinite(roi.thickness) ? MAX(roi.thickness, 1.0) : 1.0;
    NSMutableDictionary<NSString *, id> *dictionary = [@{
        @"sliceIndex": @(sliceIndex),
        @"kind": [self kindForROIType:roi.type],
        @"type": @(roi.type),
        @"name": roi.name ?: @"",
        @"comments": roi.comments ?: @"",
        @"points": pointCoordinates,
        @"rectX": @(rect.origin.x),
        @"rectY": @(rect.origin.y),
        @"rectWidth": @(rect.size.width),
        @"rectHeight": @(rect.size.height),
        @"red": @(color.redComponent),
        @"green": @(color.greenComponent),
        @"blue": @(color.blueComponent),
        @"alpha": @(alpha),
        @"thickness": @(thickness),
        @"spline": @(roi.isSpline),
        @"displayText": @(roi.displayTextualData),
    } mutableCopy];

    NSMutableArray<NSString *> *textLines = [NSMutableArray array];
    for (NSString *line in @[roi.textualBoxLine1 ?: @"", roi.textualBoxLine2 ?: @"", roi.textualBoxLine3 ?: @"",
                             roi.textualBoxLine4 ?: @"", roi.textualBoxLine5 ?: @"", roi.textualBoxLine6 ?: @""])
    {
        if (line.length)
            [textLines addObject:line];
    }
    dictionary[@"textLines"] = textLines;

    if (roi.type == tPlain)
    {
        NSInteger width = roi.textureWidth;
        NSInteger height = roi.textureHeight;
        if (width > 0 && height > 0 && width <= 100000 && height <= 100000 &&
            (NSUInteger)width <= NSUIntegerMax / (NSUInteger)height && roi.textureBuffer != NULL)
        {
            NSUInteger length = (NSUInteger)width * (NSUInteger)height;
            dictionary[@"maskWidth"] = @(width);
            dictionary[@"maskHeight"] = @(height);
            dictionary[@"maskOriginX"] = @(roi.textureUpLeftCornerX);
            dictionary[@"maskOriginY"] = @(roi.textureUpLeftCornerY);

            // OsiriX stores the first brush row at the top; CGImage masks consume it at the bottom.
            NSMutableData *maskData = [NSMutableData dataWithLength:length];
            const unsigned char *source = roi.textureBuffer;
            unsigned char *destination = (unsigned char *)maskData.mutableBytes;
            for (NSInteger row = 0; row < height; ++row)
            {
                memcpy(destination + (NSUInteger)row * (NSUInteger)width,
                       source + (NSUInteger)(height - row - 1) * (NSUInteger)width,
                       (size_t)width);
            }
            dictionary[@"maskData"] = maskData;
        }
    }
    else if (roi.type == tLayerROI && roi.layerImage)
    {
        NSData *layerData = roi.layerImage.TIFFRepresentation;
        if (layerData.length)
            dictionary[@"layerImageData"] = layerData;
    }

    return [dictionary autorelease];
}

+ (NSString *)kindForROIType:(ToolMode)type
{
    switch (type)
    {
        case tMesure: return @"line";
        case tROI: return @"rectangle";
        case tOval: return @"oval";
        case tOPolygon: return @"openPolygon";
        case tCPolygon: return @"closedPolygon";
        case tAngle: return @"angle";
        case tDynAngle: return @"angle";
        case tText: return @"text";
        case tArrow: return @"arrow";
        case tPencil: return @"closedPolygon";
        case tCurvedROI: return @"closedPolygon";
        case t3Dpoint:
        case t2DPoint: return @"point";
        case tPlain: return @"brush";
        case tLayerROI: return @"layer";
        default: return @"polyline";
    }
}

+ (NSString *)signatureForROIDictionary:(NSDictionary<NSString *, id> *)dictionary
{
    NSMutableString *signature = [NSMutableString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@|%@",
        dictionary[@"sliceIndex"], dictionary[@"type"], dictionary[@"name"], dictionary[@"comments"],
        dictionary[@"rectX"], dictionary[@"rectY"], dictionary[@"rectWidth"], dictionary[@"rectHeight"],
        dictionary[@"red"], dictionary[@"green"], dictionary[@"blue"], dictionary[@"alpha"], dictionary[@"thickness"],
        dictionary[@"spline"], dictionary[@"displayText"], dictionary[@"points"], dictionary[@"textLines"]];
    NSData *maskData = dictionary[@"maskData"];
    if (maskData)
        [signature appendFormat:@"|%@|%@|%@|%@|%lu", dictionary[@"maskWidth"], dictionary[@"maskHeight"],
            dictionary[@"maskOriginX"], dictionary[@"maskOriginY"], (unsigned long)maskData.hash];
    NSData *layerData = dictionary[@"layerImageData"];
    if (layerData)
        [signature appendFormat:@"|%lu", (unsigned long)layerData.hash];
    return signature;
}

@end
