#import "MetalTumourSeedSRBridge.h"

#import <AppKit/AppKit.h>

#import "DCMPix.h"
#import "DicomDatabase.h"
#import "DicomImage.h"
#import "DicomSeries.h"
#import "DicomStudy.h"
#import "ROI.h"
#import "SRAnnotation.h"

static NSString * const HorosMetalTumourSeedROIName = @"Horos Tumour Seed";
static NSString * const HorosMetalTumourSeedCommentPrefix = @"HorosMetalTumourSeed:";
static NSString * const HorosMetalTumourSeedSchema = @"com.horos.metalviewer.tumour-seed-roi.v1";

@implementation MetalTumourSeedSRBridge

+ (NSArray<NSDictionary<NSString *, id> *> *)seedDictionariesForPixList:(NSArray *)pixList
{
    if (pixList.count == 0)
        return @[];

    NSMutableArray<NSDictionary<NSString *, id> *> *seedDictionaries = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];
    DicomStudy *study = nil;

    for (DCMPix *pix in pixList)
    {
        if (![pix isKindOfClass:DCMPix.class])
            continue;

        DicomImage *image = [self imageForPix:pix];
        DicomStudy *candidateStudy = [image valueForKeyPath:@"series.study"];
        if (candidateStudy)
        {
            study = candidateStudy;
            break;
        }
    }

    NSArray *roiImages = study ? ([[[study roiSRSeries] valueForKey:@"images"] allObjects] ?: @[]) : @[];

    for (NSUInteger index = 0; index < pixList.count; index++)
    {
        DCMPix *pix = pixList[index];
        if (![pix isKindOfClass:DCMPix.class])
            continue;

        DicomImage *image = [self imageForPix:pix];
        DicomStudy *imageStudy = [image valueForKeyPath:@"series.study"];
        if (imageStudy == nil)
            continue;

        NSArray *candidateRoiImages = (imageStudy == study) ? roiImages : nil;
        NSString *path = [imageStudy roiPathForImage:image inArray:candidateRoiImages];
        NSArray *rois = [self roiArrayAtPath:path];
        for (ROI *roi in rois)
        {
            NSDictionary *dictionary = [self seedDictionaryForROI:roi pix:pix image:image sliceIndex:index];
            if (dictionary == nil)
                continue;

            NSString *identifier = dictionary[@"identifier"];
            if (identifier.length && [seenIdentifiers containsObject:identifier])
                continue;
            if (identifier.length)
                [seenIdentifiers addObject:identifier];

            [seedDictionaries addObject:dictionary];
        }
    }

    return seedDictionaries;
}

+ (nullable NSString *)archiveSeedWithIdentifier:(NSString *)identifier
                                          pixelX:(double)pixelX
                                          pixelY:(double)pixelY
                                      sliceIndex:(NSInteger)sliceIndex
                                          dicomX:(double)dicomX
                                          dicomY:(double)dicomY
                                          dicomZ:(double)dicomZ
                                      diameterMM:(double)diameterMM
                                       createdAt:(NSDate *)createdAt
                                         pixList:(NSArray *)pixList
{
    if (pixList.count == 0)
        return [self failure:@"Cannot save tumour seed because the viewer has no source images."];

    if (sliceIndex < 0 || sliceIndex >= (NSInteger)pixList.count)
        return [self failure:@"Cannot save tumour seed because its source slice is outside the series."];

    DCMPix *pix = pixList[(NSUInteger)sliceIndex];
    if (![pix isKindOfClass:DCMPix.class])
        return [self failure:@"Cannot save tumour seed because the source slice is invalid."];

    DicomImage *image = [self imageForPix:pix];
    if (image == nil)
        return [self failure:@"Cannot save tumour seed because the source image is not in the database."];

    DicomStudy *study = [image valueForKeyPath:@"series.study"];
    if (study == nil)
        return [self failure:@"Cannot save tumour seed because the source study is not available."];

    DicomDatabase *database = [DicomDatabase databaseForContext:image.managedObjectContext];
    if (database == nil)
        return [self failure:@"Cannot save tumour seed because the source database is not available."];

    ROI *seedROI = [self roiForSeedWithIdentifier:identifier
                                           pixelX:pixelX
                                           pixelY:pixelY
                                       sliceIndex:sliceIndex
                                           dicomX:dicomX
                                           dicomY:dicomY
                                           dicomZ:dicomZ
                                       diameterMM:diameterMM
                                        createdAt:createdAt
                                              pix:pix
                                            image:image];
    if (seedROI == nil)
        return [self failure:@"Cannot save tumour seed because the ROI object could not be created."];

    __block NSString *errorMessage = nil;
    N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
        @try
        {
        NSString *path = [study roiPathForImage:image inArray:nil];
        NSMutableArray *rois = [NSMutableArray arrayWithArray:[self roiArrayAtPath:path]];

        NSIndexSet *duplicateIndexes = [rois indexesOfObjectsPassingTest:^BOOL(id candidate, NSUInteger idx, BOOL *stop) {
            if (![candidate isKindOfClass:ROI.class])
                return NO;
            NSDictionary *metadata = [self metadataForROI:candidate];
            return [metadata[@"identifier"] isEqualToString:identifier];
        }];
        if (duplicateIndexes.count)
            [rois removeObjectsAtIndexes:duplicateIndexes];

        [rois addObject:seedROI];

        if (path == nil)
        {
            NSNumber *frameID = [image valueForKey:@"frameID"];
            path = [image SRPathForFrame:frameID.intValue];
            [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
        }

        [SRAnnotation archiveROIsAsDICOM:rois toPath:path forImage:image];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path] == NO)
        {
            errorMessage = [NSString stringWithFormat:@"Cannot save tumour seed because the ROI SR file was not written: %@", path];
        }
        else
        {
            NSArray *importedObjects = [database addFilesAtPaths:@[path]
                                               postNotifications:NO
                                                       dicomOnly:YES
                                             rereadExistingItems:YES
                                              generatedByOsiriX:YES];
            if (importedObjects.count == 0)
                errorMessage = [NSString stringWithFormat:@"Cannot save tumour seed because the ROI SR file was not imported into the database: %@", path];
        }
        }
        @catch (NSException *exception)
        {
            errorMessage = [NSString stringWithFormat:@"Cannot save tumour seed as an ROI SR: %@", exception.reason ?: exception.name];
        }
    });

    if (errorMessage.length)
        return [self failure:errorMessage];

    return nil;
}

+ (nullable NSString *)deleteSeedWithIdentifier:(NSString *)identifier
                                        pixList:(NSArray *)pixList
{
    NSString *trimmedIdentifier = [self nonEmptyString:identifier];
    if (trimmedIdentifier.length == 0)
        return [self failure:@"Cannot delete tumour seed because its identifier is empty."];

    if (pixList.count == 0)
        return [self failure:@"Cannot delete tumour seed because the viewer has no source images."];

    DicomDatabase *database = nil;
    for (DCMPix *pix in pixList)
    {
        if (![pix isKindOfClass:DCMPix.class])
            continue;

        DicomImage *image = [self imageForPix:pix];
        if (image == nil)
            continue;

        database = [DicomDatabase databaseForContext:image.managedObjectContext];
        if (database)
            break;
    }

    if (database == nil)
        return [self failure:@"Cannot delete tumour seed because the source database is not available."];

    __block NSString *errorMessage = nil;
    __block BOOL removedSeed = NO;
    NSMutableArray<NSString *> *updatedPaths = [NSMutableArray array];

    N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
        @try
        {
        for (NSUInteger index = 0; index < pixList.count; index++)
        {
            DCMPix *pix = [pixList objectAtIndex:index];
            if (![pix isKindOfClass:DCMPix.class])
                continue;

            DicomImage *image = [self imageForPix:pix];
            DicomStudy *study = [image valueForKeyPath:@"series.study"];
            if (image == nil || study == nil)
                continue;

            NSString *path = [study roiPathForImage:image inArray:nil];
            if (path.length == 0)
                continue;

            NSMutableArray *rois = [NSMutableArray arrayWithArray:[self roiArrayAtPath:path]];
            if (rois.count == 0)
                continue;

            NSIndexSet *matchingIndexes = [rois indexesOfObjectsPassingTest:^BOOL(id candidate, NSUInteger idx, BOOL *stop) {
                if (![candidate isKindOfClass:ROI.class])
                    return NO;

                NSDictionary *dictionary = [self seedDictionaryForROI:candidate pix:pix image:image sliceIndex:index];
                return [dictionary[@"identifier"] isEqualToString:trimmedIdentifier];
            }];
            if (matchingIndexes.count == 0)
                continue;

            [rois removeObjectsAtIndexes:matchingIndexes];
            [SRAnnotation archiveROIsAsDICOM:rois toPath:path forImage:image];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path] == NO)
            {
                errorMessage = [NSString stringWithFormat:@"Cannot delete tumour seed because the ROI SR file was not written: %@", path];
                break;
            }

            removedSeed = YES;
            [updatedPaths addObject:path];
        }

        if (removedSeed == NO && errorMessage.length == 0)
            errorMessage = @"Cannot delete tumour seed because it was not found in the stored ROI list.";

        if (updatedPaths.count && errorMessage.length == 0)
        {
            [database addFilesAtPaths:updatedPaths
                    postNotifications:NO
                            dicomOnly:YES
                  rereadExistingItems:YES
                   generatedByOsiriX:YES];
        }
        }
        @catch (NSException *exception)
        {
            errorMessage = [NSString stringWithFormat:@"Cannot delete tumour seed from ROI SR: %@", exception.reason ?: exception.name];
        }
    });

    if (errorMessage.length)
        return [self failure:errorMessage];

    return nil;
}

+ (DicomImage *)imageForPix:(DCMPix *)pix
{
    if ([pix respondsToSelector:@selector(imageObj)])
        return [pix imageObj];
    return nil;
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
        NSLog(@"MetalTumourSeedSRBridge could not read ROI SR at %@: %@", path, exception);
    }

    return @[];
}

+ (ROI *)roiForSeedWithIdentifier:(NSString *)identifier
                            pixelX:(double)pixelX
                            pixelY:(double)pixelY
                        sliceIndex:(NSInteger)sliceIndex
                            dicomX:(double)dicomX
                            dicomY:(double)dicomY
                            dicomZ:(double)dicomZ
                        diameterMM:(double)diameterMM
                         createdAt:(NSDate *)createdAt
                               pix:(DCMPix *)pix
                             image:(DicomImage *)image
{
    ROI *roi = [[[ROI alloc] initWithType:t2DPoint
                                          :(float)pix.pixelSpacingX
                                          :(float)pix.pixelSpacingY
                                          :[DCMPix originCorrectedAccordingToOrientation:pix]] autorelease];
    roi.name = HorosMetalTumourSeedROIName;
    roi.rect = NSMakeRect(pixelX, pixelY, 0.0, 0.0);
    roi.pix = pix;
    [roi setNSColor:[NSColor colorWithCalibratedRed:1.0 green:0.24 blue:0.12 alpha:1.0] globally:NO];
    [roi setThickness:2.0 globally:NO];

    NSDictionary *metadata = [self metadataWithIdentifier:identifier
                                                   pixelX:pixelX
                                                   pixelY:pixelY
                                               sliceIndex:sliceIndex
                                                   dicomX:dicomX
                                                   dicomY:dicomY
                                                   dicomZ:dicomZ
                                               diameterMM:diameterMM
                                                createdAt:createdAt
                                                    image:image];
    NSData *data = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil];
    if (data)
    {
        NSString *json = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        roi.comments = [HorosMetalTumourSeedCommentPrefix stringByAppendingString:json ?: @""];
    }

    return roi;
}

+ (NSDictionary *)metadataWithIdentifier:(NSString *)identifier
                                  pixelX:(double)pixelX
                                  pixelY:(double)pixelY
                              sliceIndex:(NSInteger)sliceIndex
                                  dicomX:(double)dicomX
                                  dicomY:(double)dicomY
                                  dicomZ:(double)dicomZ
                              diameterMM:(double)diameterMM
                               createdAt:(NSDate *)createdAt
                                   image:(DicomImage *)image
{
    NSString *studyIdentifier = [self nonEmptyString:[image valueForKeyPath:@"series.study.studyInstanceUID"]];
    NSString *seriesIdentifier = [self nonEmptyString:[image valueForKeyPath:@"series.seriesDICOMUID"]];
    if (seriesIdentifier.length == 0)
        seriesIdentifier = [self nonEmptyString:[image valueForKeyPath:@"series.seriesInstanceUID"]];

    return @{
        @"schema": HorosMetalTumourSeedSchema,
        @"identifier": identifier ?: [[NSUUID UUID] UUIDString],
        @"studyIdentifier": studyIdentifier ?: @"",
        @"seriesIdentifier": seriesIdentifier ?: @"",
        @"sliceIndex": @(sliceIndex),
        @"pixelX": @(pixelX),
        @"pixelY": @(pixelY),
        @"dicomX": @(dicomX),
        @"dicomY": @(dicomY),
        @"dicomZ": @(dicomZ),
        @"diameterMM": @(MAX(diameterMM, 0.1)),
        @"createdAtUnix": @([createdAt timeIntervalSince1970])
    };
}

+ (NSDictionary *)metadataForROI:(ROI *)roi
{
    NSString *comments = roi.comments;
    if (comments.length == 0)
        return nil;

    NSRange prefixRange = [comments rangeOfString:HorosMetalTumourSeedCommentPrefix];
    if (prefixRange.location == NSNotFound)
        return nil;

    NSString *json = [comments substringFromIndex:NSMaxRange(prefixRange)];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil)
        return nil;

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class])
        return nil;

    NSDictionary *metadata = object;
    if ([metadata[@"schema"] isEqualToString:HorosMetalTumourSeedSchema] == NO)
        return nil;

    return metadata;
}

+ (NSDictionary *)seedDictionaryForROI:(ROI *)roi pix:(DCMPix *)pix image:(DicomImage *)image sliceIndex:(NSUInteger)sliceIndex
{
    if (![roi isKindOfClass:ROI.class])
        return nil;

    NSDictionary *metadata = [self metadataForROI:roi];
    BOOL isNamedSeed = [roi.name isEqualToString:HorosMetalTumourSeedROIName];
    if (metadata == nil && isNamedSeed == NO)
        return nil;
    if (metadata == nil && roi.type != t2DPoint)
        return nil;

    NSPoint point = roi.rect.origin;
    double pixelX = [self doubleFromObject:metadata[@"pixelX"] fallback:point.x];
    double pixelY = [self doubleFromObject:metadata[@"pixelY"] fallback:point.y];

    double dicom[3] = {0.0, 0.0, 0.0};
    [pix convertPixDoubleX:pixelX pixY:pixelY toDICOMCoords:dicom pixelCenter:YES];

    NSString *identifier = [self nonEmptyString:metadata[@"identifier"]];
    if (identifier.length == 0)
    {
        NSString *sopInstanceUID = [self nonEmptyString:[image valueForKey:@"sopInstanceUID"]];
        identifier = [NSString stringWithFormat:@"%@-%lu-%.3f-%.3f", sopInstanceUID ?: @"seed", (unsigned long)sliceIndex, pixelX, pixelY];
    }

    NSString *studyIdentifier = [self nonEmptyString:metadata[@"studyIdentifier"]];
    if (studyIdentifier.length == 0)
        studyIdentifier = [self nonEmptyString:[image valueForKeyPath:@"series.study.studyInstanceUID"]];

    NSString *seriesIdentifier = [self nonEmptyString:metadata[@"seriesIdentifier"]];
    if (seriesIdentifier.length == 0)
        seriesIdentifier = [self nonEmptyString:[image valueForKeyPath:@"series.seriesDICOMUID"]];
    if (seriesIdentifier.length == 0)
        seriesIdentifier = [self nonEmptyString:[image valueForKeyPath:@"series.seriesInstanceUID"]];

    return @{
        @"identifier": identifier,
        @"studyIdentifier": studyIdentifier ?: @"",
        @"seriesIdentifier": seriesIdentifier ?: @"",
        @"sliceIndex": @((NSInteger)[self doubleFromObject:metadata[@"sliceIndex"] fallback:(double)sliceIndex]),
        @"pixelX": @(pixelX),
        @"pixelY": @(pixelY),
        @"dicomX": @([self doubleFromObject:metadata[@"dicomX"] fallback:dicom[0]]),
        @"dicomY": @([self doubleFromObject:metadata[@"dicomY"] fallback:dicom[1]]),
        @"dicomZ": @([self doubleFromObject:metadata[@"dicomZ"] fallback:dicom[2]]),
        @"diameterMM": @([self doubleFromObject:metadata[@"diameterMM"] fallback:5.0]),
        @"createdAtUnix": @([self doubleFromObject:metadata[@"createdAtUnix"] fallback:[[NSDate date] timeIntervalSince1970]])
    };
}

+ (double)doubleFromObject:(id)object fallback:(double)fallback
{
    if ([object respondsToSelector:@selector(doubleValue)])
        return [object doubleValue];
    return fallback;
}

+ (NSString *)nonEmptyString:(id)object
{
    if (![object isKindOfClass:NSString.class])
        return nil;

    NSString *string = [object stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return string.length ? string : nil;
}

+ (NSString *)failure:(NSString *)message
{
    NSLog(@"MetalTumourSeedSRBridge %@", message);
    return message;
}

@end
