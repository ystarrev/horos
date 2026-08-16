#import "StructuredReportSupport.h"

#import "DicomDatabase.h"
#import "DicomImage.h"
#import "DicomSeries.h"
#import "DicomStudy.h"
#import "NSManagedObject+N2.h"

#import <WebKit/WebKit.h>
#include <errno.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString * const StructuredReportSupportErrorDomain = @"org.horosproject.StructuredReportSupport";

typedef char* (*HorosCopyStructuredReportHTMLFunction)(const char*);
typedef char* (*HorosCopySurgicalProcedureRecordJSONFunction)(const char*);
typedef int (*HorosWriteSurgicalProcedureStructuredReportFunction)(const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*,
                                                                    const char*);
typedef void (*HorosFreeStringFunction)(char*);

static NSString * const SurgicalProcedureSeriesDescription = @"Horos Surgical Procedure SR";

static NSString * const SurgicalProcedurePayloadRecordJSONKey = @"recordJSON";
static NSString * const SurgicalProcedurePayloadEventIDKey = @"eventID";
static NSString * const SurgicalProcedurePayloadSOPInstanceUIDKey = @"sopInstanceUID";
static NSString * const SurgicalProcedurePayloadSeriesInstanceUIDKey = @"seriesInstanceUID";
static NSString * const SurgicalProcedurePayloadStudyInstanceUIDKey = @"studyInstanceUID";
static NSString * const SurgicalProcedurePayloadPatientNameKey = @"patientName";
static NSString * const SurgicalProcedurePayloadPatientBirthDateKey = @"patientBirthDate";
static NSString * const SurgicalProcedurePayloadPatientIDKey = @"patientID";
static NSString * const SurgicalProcedurePayloadContentDateKey = @"contentDate";
static NSString * const SurgicalProcedurePayloadContentTimeKey = @"contentTime";
static NSString * const SurgicalProcedurePayloadExistingPathKey = @"existingPath";

static void* StructuredReportBridgeHandle(void)
{
    static void* handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        NSArray<NSString *> *basePaths = @[
            bundle.resourcePath ?: @"",
            bundle.privateFrameworksPath ?: @"",
            bundle.sharedFrameworksPath ?: @""
        ];
        NSArray<NSString *> *relativePaths = @[
            @"libHorosModernDCMTKBridge.dylib",
            @"DCMTK/libHorosModernDCMTKBridge.dylib"
        ];

        for (NSString *basePath in basePaths)
        {
            for (NSString *relativePath in relativePaths)
            {
                NSString *candidate = [basePath stringByAppendingPathComponent:relativePath];
                if (![[NSFileManager defaultManager] fileExistsAtPath:candidate])
                    continue;

                handle = dlopen(candidate.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
                if (handle == NULL)
                    NSLog(@"Modern DCMTK bridge failed to load at %@: %s", candidate, dlerror());
                return;
            }
        }
    });
    return handle;
}

static void* StructuredReportBridgeSymbol(const char* name)
{
    void* handle = StructuredReportBridgeHandle();
    return handle != NULL ? dlsym(handle, name) : NULL;
}

static NSError *StructuredReportError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:StructuredReportSupportErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSString *SurgicalProcedureStringValue(NSDictionary *dictionary, NSString *key)
{
    id value = dictionary[key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSDictionary *SurgicalProcedureJSONObject(NSString *json)
{
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSString *SurgicalProcedureSafeFilename(NSString *value)
{
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    NSMutableString *result = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger index = 0; index < value.length; ++index)
    {
        unichar character = [value characterAtIndex:index];
        if ([allowed characterIsMember:character])
            [result appendFormat:@"%C", character];
    }
    return result.length ? result : NSUUID.UUID.UUIDString;
}

static BOOL SurgicalProcedureSeriesMatches(DicomSeries *series)
{
    return (series.name.length && [series.name caseInsensitiveCompare:SurgicalProcedureSeriesDescription] == NSOrderedSame) ||
           (series.seriesDescription.length && [series.seriesDescription caseInsensitiveCompare:SurgicalProcedureSeriesDescription] == NSOrderedSame);
}

static NSArray<NSDictionary<NSString *, id> *> *SurgicalProcedureDescriptorsForStudies(NSArray *studies)
{
    NSMutableArray<NSDictionary<NSString *, id> *> *descriptors = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];

    for (DicomStudy *study in studies)
    {
        if (![study isKindOfClass:[DicomStudy class]])
            continue;

        for (DicomSeries *series in study.series)
        {
            if (!SurgicalProcedureSeriesMatches(series))
                continue;

            for (DicomImage *image in series.images)
            {
                NSString *path = image.completePath;
                if (path.length == 0 || [seenPaths containsObject:path])
                    continue;
                [seenPaths addObject:path];

                NSString *recordJSON = [StructuredReportSupport surgicalProcedureRecordJSONForPath:path];
                NSDictionary *record = SurgicalProcedureJSONObject(recordJSON);
                NSString *eventID = SurgicalProcedureStringValue(record, SurgicalProcedurePayloadEventIDKey);
                if (recordJSON.length == 0 || eventID.length == 0)
                    continue;

                NSMutableDictionary<NSString *, id> *descriptor = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                    recordJSON, SurgicalProcedurePayloadRecordJSONKey,
                    eventID, SurgicalProcedurePayloadEventIDKey,
                    path, @"path",
                    study.XID ?: @"", @"studyXID",
                    study.studyInstanceUID ?: @"", SurgicalProcedurePayloadStudyInstanceUIDKey,
                    series.seriesInstanceUID ?: @"", SurgicalProcedurePayloadSeriesInstanceUIDKey,
                    image.sopInstanceUID ?: @"", SurgicalProcedurePayloadSOPInstanceUIDKey,
                    nil];
                [descriptors addObject:descriptor];
            }
        }
    }

    return descriptors;
}

@interface StructuredReportPDFLoadSession : NSObject <WKNavigationDelegate>
@property(nonatomic) BOOL finished;
@property(nonatomic, strong, nullable) NSError *error;
@end

@implementation StructuredReportPDFLoadSession

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    self.finished = YES;
}

- (void)webView:(WKWebView *)webView
didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error
{
    self.error = error;
    self.finished = YES;
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error
{
    self.error = error;
    self.finished = YES;
}

@end

@implementation StructuredReportSupport

+ (NSString *)surgicalProcedureSeriesDescription
{
    return SurgicalProcedureSeriesDescription;
}

+ (NSString *)surgicalProcedureRecordJSONForPath:(NSString *)path
{
    if (path.length == 0)
        return nil;

    HorosCopySurgicalProcedureRecordJSONFunction copyRecord =
        (HorosCopySurgicalProcedureRecordJSONFunction)StructuredReportBridgeSymbol("HorosModernDCMTKCopySurgicalProcedureRecordJSON");
    HorosFreeStringFunction freeString =
        (HorosFreeStringFunction)StructuredReportBridgeSymbol("HorosModernDCMTKFreeString");
    if (copyRecord == NULL)
        return nil;

    char *json = copyRecord(path.fileSystemRepresentation);
    if (json == NULL)
        return nil;

    NSString *result = [NSString stringWithUTF8String:json];
    if (freeString != NULL)
        freeString(json);
    else
        free(json);
    return result;
}

+ (BOOL)writeSurgicalProcedureRecordJSON:(NSString *)recordJSON
                                  toPath:(NSString *)path
                           sopInstanceUID:(NSString *)sopInstanceUID
                        seriesInstanceUID:(NSString *)seriesInstanceUID
                         studyInstanceUID:(NSString *)studyInstanceUID
                              patientName:(NSString *)patientName
                         patientBirthDate:(NSString *)patientBirthDate
                                patientID:(NSString *)patientID
                              contentDate:(NSString *)contentDate
                              contentTime:(NSString *)contentTime
                                    error:(NSError **)error
{
    if (recordJSON.length == 0 || path.length == 0 || sopInstanceUID.length == 0 ||
        seriesInstanceUID.length == 0 || studyInstanceUID.length == 0 ||
        contentDate.length == 0 || contentTime.length == 0)
    {
        if (error != NULL)
            *error = StructuredReportError(10, @"The surgical procedure SR metadata is incomplete.");
        return NO;
    }

    HorosWriteSurgicalProcedureStructuredReportFunction writeReport =
        (HorosWriteSurgicalProcedureStructuredReportFunction)StructuredReportBridgeSymbol("HorosModernDCMTKWriteSurgicalProcedureStructuredReport");
    if (writeReport == NULL)
    {
        if (error != NULL)
            *error = StructuredReportError(11, @"The modern DCMTK surgical procedure writer is unavailable.");
        return NO;
    }

    NSData *jsonData = [recordJSON dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *record = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
    if (![record isKindOfClass:[NSDictionary class]])
    {
        if (error != NULL)
            *error = StructuredReportError(12, @"The surgical procedure record could not be encoded.");
        return NO;
    }

    NSString *(^field)(NSString *) = ^NSString *(NSString *key) {
        id value = record[key];
        return [value isKindOfClass:[NSString class]] ? value : @"";
    };
    int wroteReport = writeReport(path.fileSystemRepresentation,
                                  sopInstanceUID.UTF8String,
                                  seriesInstanceUID.UTF8String,
                                  studyInstanceUID.UTF8String,
                                  patientName.UTF8String,
                                  patientBirthDate.length ? patientBirthDate.UTF8String : "",
                                  patientID.UTF8String,
                                  contentDate.UTF8String,
                                  contentTime.UTF8String,
                                  field(@"operation").UTF8String,
                                  field(@"diagnosis").UTF8String,
                                  field(@"results").UTF8String,
                                  field(@"optics").UTF8String,
                                  field(@"assistants").UTF8String,
                                  recordJSON.UTF8String);
    if (!wroteReport)
    {
        if (error != NULL)
            *error = StructuredReportError(13, @"The modern DCMTK writer could not create the surgical procedure SR.");
        return NO;
    }
    return YES;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)surgicalProcedureRecordDescriptorsForStudies:(NSArray *)studies
{
    if (studies.count == 0)
        return @[];
    return SurgicalProcedureDescriptorsForStudies(studies);
}

+ (NSArray<NSDictionary<NSString *, id> *> *)surgicalProcedureRecordDescriptorsForDatabaseBasePath:(NSString *)basePath
{
    if (basePath.length == 0)
        return @[];

    DicomDatabase *database = [[DicomDatabase databaseAtPath:basePath] independentDatabase];
    if (database == nil)
        return @[];

    __block NSArray *descriptors = nil;
    N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Study"];
        request.predicate = [NSPredicate predicateWithFormat:
            @"ANY series.name ==[cd] %@ OR ANY series.seriesDescription ==[cd] %@",
            SurgicalProcedureSeriesDescription,
            SurgicalProcedureSeriesDescription];
        NSArray *studies = [database.managedObjectContext executeFetchRequest:request error:nil] ?: @[];
        descriptors = [SurgicalProcedureDescriptorsForStudies(studies) copy];
    });
    return descriptors ?: @[];
}

+ (NSDictionary<NSString *, id> *)storeSurgicalProcedureRecordPayloads:(NSArray<NSDictionary<NSString *, id> *> *)payloads
                                                       databaseBasePath:(NSString *)basePath
{
    if (basePath.length == 0 || payloads.count == 0)
        return @{ @"descriptors": @[], @"errors": @[], @"storedCount": @0 };

    DicomDatabase *mainDatabase = [DicomDatabase databaseAtPath:basePath];
    DicomDatabase *database = [mainDatabase independentDatabase];
    if (database == nil)
        return @{ @"descriptors": @[],
                  @"errors": @[@"The current Horos database could not be opened for surgical procedure import."],
                  @"storedCount": @0 };

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *operations = [NSMutableArray array];
    NSMutableArray<NSString *> *pathsToImport = [NSMutableArray array];

    for (NSDictionary<NSString *, id> *payload in payloads)
    {
        @autoreleasepool
        {
            NSString *eventID = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadEventIDKey);
            NSString *recordJSON = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadRecordJSONKey);
            NSString *sopInstanceUID = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadSOPInstanceUIDKey);
            NSString *seriesInstanceUID = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadSeriesInstanceUIDKey);
            NSString *studyInstanceUID = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadStudyInstanceUIDKey);
            NSString *patientName = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadPatientNameKey);
            NSString *patientBirthDate = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadPatientBirthDateKey);
            NSString *patientID = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadPatientIDKey);
            NSString *contentDate = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadContentDateKey);
            NSString *contentTime = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadContentTimeKey);
            NSString *existingPath = SurgicalProcedureStringValue(payload, SurgicalProcedurePayloadExistingPathKey);

            if (eventID.length == 0 || recordJSON.length == 0 || sopInstanceUID.length == 0 ||
                seriesInstanceUID.length == 0 || studyInstanceUID.length == 0 || contentDate.length == 0 ||
                contentTime.length == 0)
            {
                [errors addObject:[NSString stringWithFormat:@"Procedure %@ has incomplete SR metadata.", eventID.length ? eventID : @"(unknown)"]];
                continue;
            }

            BOOL replacesExistingFile = existingPath.length > 0 && [fileManager fileExistsAtPath:existingPath];
            NSString *destinationPath = replacesExistingFile ? existingPath : [database uniquePathForNewDataFileWithExtension:@"dcm"];
            if (destinationPath.length == 0)
            {
                [errors addObject:[NSString stringWithFormat:@"No database path was available for procedure %@.", eventID]];
                continue;
            }

            NSString *temporaryPath = replacesExistingFile
                ? [destinationPath stringByAppendingFormat:@".surgery-%@.tmp", NSUUID.UUID.UUIDString]
                : destinationPath;
            NSError *writeError = nil;
            BOOL wrote = [self writeSurgicalProcedureRecordJSON:recordJSON
                                                         toPath:temporaryPath
                                                  sopInstanceUID:sopInstanceUID
                                               seriesInstanceUID:seriesInstanceUID
                                                studyInstanceUID:studyInstanceUID
                                                     patientName:patientName
                                                patientBirthDate:patientBirthDate
                                                       patientID:patientID
                                                     contentDate:contentDate
                                                     contentTime:contentTime
                                                           error:&writeError];
            if (!wrote)
            {
                [fileManager removeItemAtPath:temporaryPath error:nil];
                [errors addObject:[NSString stringWithFormat:@"Procedure %@ could not be written: %@",
                    eventID, writeError.localizedDescription ?: @"Unknown error"]];
                continue;
            }

            NSString *backupPath = @"";
            if (replacesExistingFile)
            {
                NSString *backupName = [NSString stringWithFormat:@".%@.surgery-%@.backup",
                    SurgicalProcedureSafeFilename(destinationPath.lastPathComponent), NSUUID.UUID.UUIDString];
                backupPath = [destinationPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:backupName];
                NSError *replacementError = nil;
                if (![fileManager copyItemAtPath:destinationPath toPath:backupPath error:&replacementError] ||
                    rename(temporaryPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation) != 0)
                {
                    int replacementErrno = errno;
                    [fileManager removeItemAtPath:temporaryPath error:nil];
                    [fileManager removeItemAtPath:backupPath error:nil];
                    NSString *reason = replacementError.localizedDescription;
                    if (reason.length == 0)
                        reason = [NSString stringWithUTF8String:strerror(replacementErrno)] ?: @"Unknown error";
                    [errors addObject:[NSString stringWithFormat:@"Procedure %@ could not replace its existing SR: %@", eventID, reason]];
                    continue;
                }
            }

            [pathsToImport addObject:destinationPath];
            [operations addObject:@{
                SurgicalProcedurePayloadEventIDKey: eventID,
                SurgicalProcedurePayloadStudyInstanceUIDKey: studyInstanceUID,
                @"path": destinationPath,
                @"backupPath": backupPath,
                @"isNew": @(!replacesExistingFile)
            }];
        }
    }

    if (pathsToImport.count)
    {
        @try
        {
            [database addFilesAtPaths:pathsToImport
                    postNotifications:YES
                            dicomOnly:YES
                  rereadExistingItems:YES
                   generatedByOsiriX:YES
                          returnArray:YES];
        }
        @catch (NSException *exception)
        {
            [errors addObject:[NSString stringWithFormat:@"Horos could not index the surgical procedure SR files: %@",
                exception.reason ?: exception.description]];
        }
    }

    NSSet<NSString *> *studyUIDs = [NSSet setWithArray:[operations valueForKey:SurgicalProcedurePayloadStudyInstanceUIDKey]];
    __block NSArray *matchingStudies = nil;
    if (studyUIDs.count)
    {
        N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
            NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Study"];
            request.predicate = [NSPredicate predicateWithFormat:@"studyInstanceUID IN %@", studyUIDs.allObjects];
            matchingStudies = [[database.managedObjectContext executeFetchRequest:request error:nil] copy] ?: @[];
        });
    }
    else
        matchingStudies = @[];

    __block NSArray *verifiedDescriptors = nil;
    N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
        verifiedDescriptors = [SurgicalProcedureDescriptorsForStudies(matchingStudies) copy];
    });
    NSSet<NSString *> *verifiedEventIDs = [NSSet setWithArray:[verifiedDescriptors valueForKey:SurgicalProcedurePayloadEventIDKey]];

    NSMutableArray<NSString *> *rollbackPaths = [NSMutableArray array];
    NSMutableArray<NSString *> *failedNewStudyUIDs = [NSMutableArray array];
    NSUInteger storedCount = 0;
    for (NSDictionary *operation in operations)
    {
        NSString *eventID = operation[SurgicalProcedurePayloadEventIDKey];
        NSString *path = operation[@"path"];
        NSString *backupPath = operation[@"backupPath"];
        BOOL isNew = [operation[@"isNew"] boolValue];
        if ([verifiedEventIDs containsObject:eventID])
        {
            storedCount++;
            if (backupPath.length)
                [fileManager removeItemAtPath:backupPath error:nil];
            continue;
        }

        [errors addObject:[NSString stringWithFormat:@"Procedure %@ was written but could not be verified in the Horos database.", eventID]];
        if (isNew)
        {
            [fileManager removeItemAtPath:path error:nil];
            [failedNewStudyUIDs addObject:operation[SurgicalProcedurePayloadStudyInstanceUIDKey]];
        }
        else if (backupPath.length)
        {
            [fileManager removeItemAtPath:path error:nil];
            if ([fileManager moveItemAtPath:backupPath toPath:path error:nil])
                [rollbackPaths addObject:path];
        }
    }

    if (failedNewStudyUIDs.count)
    {
        N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
            NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Study"];
            request.predicate = [NSPredicate predicateWithFormat:@"studyInstanceUID IN %@", failedNewStudyUIDs];
            NSArray *failedStudies = [database.managedObjectContext executeFetchRequest:request error:nil];
            for (DicomStudy *study in failedStudies)
            {
                BOOL isSurgicalProcedureStudy = NO;
                for (DicomSeries *series in study.series)
                    isSurgicalProcedureStudy |= SurgicalProcedureSeriesMatches(series);
                if (isSurgicalProcedureStudy)
                    [database.managedObjectContext deleteObject:study];
            }
            [database.managedObjectContext save:nil];
        });
    }

    if (rollbackPaths.count)
    {
        [database addFilesAtPaths:rollbackPaths
                postNotifications:YES
                        dicomOnly:YES
              rereadExistingItems:YES
               generatedByOsiriX:YES
                      returnArray:NO];
    }

    return @{ @"descriptors": verifiedDescriptors ?: @[],
              @"errors": errors,
              @"storedCount": @(storedCount) };
}

+ (NSString *)htmlStringForPath:(NSString *)path
{
    if (path.length == 0)
        return nil;

    HorosCopyStructuredReportHTMLFunction render =
        (HorosCopyStructuredReportHTMLFunction)StructuredReportBridgeSymbol("HorosModernDCMTKCopyStructuredReportHTML");
    HorosFreeStringFunction freeString =
        (HorosFreeStringFunction)StructuredReportBridgeSymbol("HorosModernDCMTKFreeString");
    if (render == NULL)
        return nil;

    char *html = render(path.fileSystemRepresentation);
    if (html == NULL)
        return nil;

    NSString *result = [NSString stringWithUTF8String:html];
    if (freeString != NULL)
        freeString(html);
    else
        free(html);
    return result;
}

+ (BOOL)writePDFForDICOMAtPath:(NSString *)dicomPath
                        toPath:(NSString *)pdfPath
                         error:(NSError **)error
{
    NSString *html = [self htmlStringForPath:dicomPath];
    if (html.length == 0)
    {
        if (error != NULL)
            *error = StructuredReportError(1, @"The structured report could not be rendered as HTML.");
        return NO;
    }

    __block BOOL succeeded = NO;
    __block NSError *conversionError = nil;
    void (^renderPDF)(void) = ^{
        StructuredReportPDFLoadSession *session = [[StructuredReportPDFLoadSession alloc] init];
        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];

        WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 612, 792)
                                               configuration:configuration];
        webView.navigationDelegate = session;

        NSWindow *window = [[NSWindow alloc] initWithContentRect:webView.frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.contentView = webView;

        NSURL *baseURL = [NSURL fileURLWithPath:dicomPath.stringByDeletingLastPathComponent
                                   isDirectory:YES];
        [webView loadHTMLString:html baseURL:baseURL];

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
        while (!session.finished && deadline.timeIntervalSinceNow > 0.0)
        {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }

        if (!session.finished)
            conversionError = StructuredReportError(2, @"Timed out while loading the structured report.");
        else if (session.error != nil)
            conversionError = session.error;
        else
        {
            [[NSFileManager defaultManager] removeItemAtPath:pdfPath error:nil];
            NSMutableDictionary *printDictionary =
                [NSMutableDictionary dictionaryWithDictionary:[NSPrintInfo sharedPrintInfo].dictionary];
            printDictionary[NSPrintJobDisposition] = NSPrintSaveJob;
            printDictionary[NSPrintJobSavingURL] = [NSURL fileURLWithPath:pdfPath];

            NSPrintInfo *printInfo = [[NSPrintInfo alloc] initWithDictionary:printDictionary];
            printInfo.bottomMargin = 30.0;
            printInfo.topMargin = 30.0;
            printInfo.leftMargin = 24.0;
            printInfo.rightMargin = 24.0;
            printInfo.horizontalPagination = NSPrintingPaginationModeAutomatic;
            printInfo.verticalPagination = NSPrintingPaginationModeAutomatic;
            printInfo.verticallyCentered = NO;

            NSPrintOperation *operation = [webView printOperationWithPrintInfo:printInfo];
            operation.showsPrintPanel = NO;
            operation.showsProgressPanel = NO;
            succeeded = [operation runOperation] &&
                        [[NSFileManager defaultManager] fileExistsAtPath:pdfPath];
            if (!succeeded)
                conversionError = StructuredReportError(3, @"The structured report PDF could not be written.");
        }

        webView.navigationDelegate = nil;
        window.contentView = nil;
    };

    if ([NSThread isMainThread])
        renderPDF();
    else
        dispatch_sync(dispatch_get_main_queue(), renderPDF);

    if (!succeeded && error != NULL)
        *error = conversionError;
    return succeeded;
}

@end
