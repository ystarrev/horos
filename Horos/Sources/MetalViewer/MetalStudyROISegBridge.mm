#import "MetalStudyROISegBridge.h"

#import <dlfcn.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <vector>

#import "DCMPix.h"
#import "DicomDatabase.h"
#import "DicomImage.h"

typedef int (*HorosWriteBinarySegmentationFunction)(const char*,
                                                     const char*,
                                                     const char*,
                                                     const char*,
                                                     double,
                                                     double,
                                                     double,
                                                     const char* const*,
                                                     const unsigned char* const*,
                                                     int,
                                                     unsigned short,
                                                     unsigned short,
                                                     char**);
typedef void (*HorosFreeStringFunction)(char*);

static void *MetalStudyROIModernBridgeHandle(void)
{
    static void *handle = nullptr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *relativePaths = @[
            @"libHorosModernDCMTKBridge.dylib",
            @"DCMTK/libHorosModernDCMTKBridge.dylib"
        ];
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        for (NSString *relativePath in relativePaths)
        {
            NSString *privateFrameworkPath = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:relativePath];
            if (privateFrameworkPath.length)
                [candidates addObject:privateFrameworkPath];
            NSString *resourcePath = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:relativePath];
            if (resourcePath.length)
                [candidates addObject:resourcePath];
        }
        [candidates addObject:@"libHorosModernDCMTKBridge.dylib"];
        for (NSString *candidate in candidates)
        {
            handle = dlopen(candidate.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
            if (handle != nullptr)
                break;
        }
    });
    return handle;
}

static void *MetalStudyROIModernBridgeSymbol(const char *name)
{
    void *handle = MetalStudyROIModernBridgeHandle();
    return handle != nullptr ? dlsym(handle, name) : nullptr;
}

@implementation MetalStudyROISegBridge

+ (NSDictionary<NSString *, NSString *> *)writeSegmentationWithLabel:(NSString *)label
                                                          trackingUID:(NSString *)trackingUID
                                                        authoringJSON:(NSString *)authoringJSON
                                                              colorRed:(double)colorRed
                                                            colorGreen:(double)colorGreen
                                                             colorBlue:(double)colorBlue
                                                     sourceImagePaths:(NSArray<NSString *> *)sourceImagePaths
                                                           frameMasks:(NSArray<NSData *> *)frameMasks
                                                                 rows:(NSUInteger)rows
                                                              columns:(NSUInteger)columns
                                                              pixList:(NSArray *)pixList
                                                         existingPath:(NSString *)existingPath
{
    if (sourceImagePaths.count == 0 || sourceImagePaths.count != frameMasks.count || pixList.count == 0)
        return @{ @"error": @"Cannot save DICOM SEG because its source frames are incomplete." };
    if (rows == 0 || columns == 0
        || rows > std::numeric_limits<unsigned short>::max()
        || columns > std::numeric_limits<unsigned short>::max())
        return @{ @"error": @"Cannot save DICOM SEG because its frame dimensions are invalid." };

    HorosWriteBinarySegmentationFunction writeFunction =
        (HorosWriteBinarySegmentationFunction)MetalStudyROIModernBridgeSymbol("HorosModernDCMTKWriteBinarySegmentation");
    HorosFreeStringFunction freeStringFunction =
        (HorosFreeStringFunction)MetalStudyROIModernBridgeSymbol("HorosModernDCMTKFreeString");
    if (writeFunction == nullptr)
        return @{ @"error": @"Cannot save DICOM SEG because the modern DCMTK segmentation writer is unavailable." };

    DicomImage *sourceImage = nil;
    for (DCMPix *pix in pixList)
    {
        if ([pix isKindOfClass:DCMPix.class] && [pix respondsToSelector:@selector(imageObj)])
        {
            sourceImage = [pix imageObj];
            if (sourceImage)
                break;
        }
    }
    if (sourceImage == nil)
        return @{ @"error": @"Cannot save DICOM SEG because the source series is not in the database." };

    DicomDatabase *database = [DicomDatabase databaseForContext:sourceImage.managedObjectContext];
    if (database == nil)
        return @{ @"error": @"Cannot save DICOM SEG because its database is unavailable." };

    __block NSString *outputPath = nil;
    __block BOOL replacesExistingSegmentation = NO;
    N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
        if (existingPath.length && [NSFileManager.defaultManager fileExistsAtPath:existingPath])
        {
            outputPath = [existingPath copy];
            replacesExistingSegmentation = YES;
        }
        else
            outputPath = [[database uniquePathForNewDataFileWithExtension:@"dcm"] copy];
    });
    if (outputPath.length == 0)
        return @{ @"error": @"Cannot allocate a database path for DICOM SEG." };

    // Readers can still have the indexed SEG open while autosave runs.  Write a
    // replacement beside it and atomically swap it into place so nobody can
    // observe a partially written DICOM object.
    NSString *writePath = outputPath;
    if (replacesExistingSegmentation)
    {
        NSString *temporaryName = [NSString stringWithFormat:@".%@.%@.writing.dcm",
                                   outputPath.lastPathComponent,
                                   [[NSUUID UUID] UUIDString]];
        writePath = [outputPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:temporaryName];
    }

    const NSUInteger frameCount = sourceImagePaths.count;
    std::vector<const char *> pathPointers(frameCount);
    std::vector<const unsigned char *> maskPointers(frameCount);
    for (NSUInteger index = 0; index < frameCount; ++index)
    {
        NSData *mask = frameMasks[index];
        if (mask.length != rows * columns)
            return @{ @"error": @"Cannot save DICOM SEG because a mask frame has the wrong dimensions." };
        pathPointers[index] = sourceImagePaths[index].fileSystemRepresentation;
        maskPointers[index] = (const unsigned char *)mask.bytes;
    }

    char *failureReason = nullptr;
    const int success = writeFunction(writePath.fileSystemRepresentation,
                                      label.UTF8String,
                                      trackingUID.UTF8String,
                                      authoringJSON.UTF8String,
                                      colorRed,
                                      colorGreen,
                                      colorBlue,
                                      pathPointers.data(),
                                      maskPointers.data(),
                                      (int)frameCount,
                                      (unsigned short)rows,
                                      (unsigned short)columns,
                                      &failureReason);
    NSString *failure = failureReason != nullptr
        ? [NSString stringWithUTF8String:failureReason]
        : nil;
    if (failureReason != nullptr)
    {
        if (freeStringFunction != nullptr)
            freeStringFunction(failureReason);
        else
            std::free(failureReason);
    }
    if (!success)
    {
        if (replacesExistingSegmentation)
            [NSFileManager.defaultManager removeItemAtPath:writePath error:nil];
        return @{ @"error": failure.length ? failure : @"The modern DCMTK writer could not create DICOM SEG." };
    }

    if (replacesExistingSegmentation)
    {
        if (std::rename(writePath.fileSystemRepresentation, outputPath.fileSystemRepresentation) != 0)
        {
            const int renameError = errno;
            [NSFileManager.defaultManager removeItemAtPath:writePath error:nil];
            return @{ @"error": [NSString stringWithFormat:@"The updated DICOM SEG could not replace the previous file: %s",
                                                           std::strerror(renameError)] };
        }

        // Its SOP/Series identity and database path have not changed. Re-importing
        // here would rebuild every Core Data frame and broadcast a study refresh
        // after each anchor movement. The live ROI store already publishes the
        // targeted change notification needed by the Metal viewers.
        return @{ @"path": outputPath };
    }

    NSString *importError = nil;
    @try
    {
        NSArray *objects = [database addFilesAtPaths:@[outputPath]
                                   postNotifications:YES
                                           dicomOnly:YES
                                 rereadExistingItems:NO
                                  generatedByOsiriX:YES];
        if (objects.count == 0)
            importError = @"The DICOM SEG file was written but could not be indexed in the database.";
    }
    @catch (NSException *exception)
    {
        importError = [NSString stringWithFormat:@"The DICOM SEG file was written but could not be indexed: %@",
                       exception.reason ?: exception.name];
    }
    if (importError.length)
        return @{ @"error": importError, @"path": outputPath };
    return @{ @"path": outputPath };
}

+ (NSString *)deleteSegmentationAtPath:(NSString *)path pixList:(NSArray *)pixList
{
    if (path.length == 0 || pixList.count == 0)
        return @"Cannot delete DICOM SEG because its database location is unavailable.";
    DicomImage *sourceImage = nil;
    for (DCMPix *pix in pixList)
    {
        if ([pix isKindOfClass:DCMPix.class] && [pix respondsToSelector:@selector(imageObj)])
        {
            sourceImage = [pix imageObj];
            if (sourceImage)
                break;
        }
    }
    DicomDatabase *database = sourceImage ? [DicomDatabase databaseForContext:sourceImage.managedObjectContext] : nil;
    if (database == nil)
        return @"Cannot delete DICOM SEG because its database is unavailable.";

    __block NSString *failure = nil;
    N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
        NSString *relativePath = path;
        NSString *databasePrefix = [database.dataBaseDirPath stringByAppendingString:@"/"];
        if ([path hasPrefix:databasePrefix])
            relativePath = [path substringFromIndex:databasePrefix.length];

        NSString *filename = path.lastPathComponent;
        NSMutableSet<NSString *> *pathStrings = [NSMutableSet setWithObjects:path, relativePath, filename, nil];
        NSMutableArray<NSPredicate *> *pathPredicates = [NSMutableArray arrayWithObject:
            [NSPredicate predicateWithFormat:@"pathString IN %@", pathStrings]];
        NSString *numberString = filename.stringByDeletingPathExtension;
        BOOL hasNumericDatabaseFilename =
            [filename.pathExtension caseInsensitiveCompare:@"dcm"] == NSOrderedSame
            && numberString.length > 0
            && [numberString rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
        if (hasNumericDatabaseFilename)
            [pathPredicates addObject:[NSPredicate predicateWithFormat:@"pathNumber == %@", @([numberString longLongValue])]];

        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Image"];
        // DicomImage.path is a computed convenience property. Core Data stores
        // local numeric filenames and linked paths in separate attributes.
        request.predicate = [NSCompoundPredicate orPredicateWithSubpredicates:pathPredicates];
        NSError *fetchError = nil;
        NSArray *images = [database.managedObjectContext executeFetchRequest:request error:&fetchError];
        if (fetchError)
        {
            failure = fetchError.localizedDescription;
            return;
        }

        NSSet *matchedImages = [NSSet setWithArray:images];
        NSMutableSet *emptySeries = [NSMutableSet set];
        for (NSManagedObject *image in images)
        {
            NSManagedObject *series = [image valueForKey:@"series"];
            NSSet *seriesImages = [series valueForKey:@"images"];
            if (series && seriesImages.count > 0 && [seriesImages isSubsetOfSet:matchedImages])
                [emptySeries addObject:series];
            [database.managedObjectContext deleteObject:image];
        }
        for (NSManagedObject *series in emptySeries)
            [database.managedObjectContext deleteObject:series];

        NSError *saveError = nil;
        if ([database.managedObjectContext save:&saveError] == NO)
            failure = saveError.localizedDescription;
    });
    if (failure.length)
        return failure;
    NSError *removeError = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:path]
        && [NSFileManager.defaultManager removeItemAtPath:path error:&removeError] == NO)
        return removeError.localizedDescription;
    return nil;
}

@end
