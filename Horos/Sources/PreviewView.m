/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)

 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, version 3 of the License.

 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.

 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. See the
 GNU Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with Horos. If not, see http://www.gnu.org/licenses/lgpl.html

 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL

  See http://www.osirix-viewer.com/copyright.html for details.
      This software is distributed WITHOUT ANY WARRANTY; without even
      the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
      PURPOSE.
 ============================================================================*/

#import "PreviewView.h"
#import "StructuredReportSupport.h"
#import "DCMPix.h"
#import "DCMView.h"
#import "DCMAbstractSyntaxUID.h"
#import "Notifications.h"
#import "BrowserController.h"
#import "DicomImage.h"
#import "DicomStudy.h"
#import "N2ManagedDatabase.h"
#import "SRAnnotation.h"
#import <WebKit/WebKit.h>
#import <MetalKit/MetalKit.h>
#import <PreferencePanes/PreferencePanes.h>
#import <UserNotifications/UserNotifications.h>
#import "Horos-Swift.h"
#include <dlfcn.h>

@class PreviewView;

@interface PreviewAnnotationOverlayView : NSView
@property(nonatomic, assign) PreviewView *owner;
@end

typedef char* (*HorosModernDCMTKCopyStructuredReportHTMLFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportKeyObjectTypeFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn)(const char* path);
typedef void (*HorosModernDCMTKFreeStringFn)(char* value);

static NSString * const PreviewROISeriesDescription = @"OsiriX ROI SR";
static NSString * const PreviewTumourSeedROIName = @"Horos Tumour Seed";
static NSString * const PreviewTumourSeedCommentPrefix = @"HorosMetalTumourSeed:";
static NSString * const PreviewTumourSeedDisplayName = @"Tumour Seeds";

static void* PreviewModernDCMTKBridgeHandle(void)
{
    static void* handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        NSArray<NSString *> *basePaths = @[
            bundle.resourcePath ?: @"",
            bundle.privateFrameworksPath ?: @"",
            bundle.sharedFrameworksPath ?: @"",
            bundle.builtInPlugInsPath ?: @""
        ];
        NSArray<NSString *> *relativePaths = @[
            @"libHorosModernDCMTKBridge.dylib",
            @"DCMTK/libHorosModernDCMTKBridge.dylib"
        ];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSString *basePath in basePaths)
        {
            if (basePath.length == 0)
                continue;

            for (NSString *relativePath in relativePaths)
            {
                NSString *candidate = [basePath stringByAppendingPathComponent:relativePath];
                if ([fileManager fileExistsAtPath:candidate])
                {
                    handle = dlopen(candidate.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
                    if (handle == NULL)
                        NSLog(@"Modern DCMTK bridge failed to load at %@: %s", candidate, dlerror());
                    return;
                }
            }
        }

        NSLog(@"Modern DCMTK bridge not found in bundle search paths.");
    });
    return handle;
}

static void* PreviewModernDCMTKSymbol(const char* name)
{
    void* handle = PreviewModernDCMTKBridgeHandle();
    if (handle == NULL)
        return NULL;
    return dlsym(handle, name);
}

@implementation StructuredReportSupport

+ (NSString *)htmlStringForPath:(NSString *)path
{
    if (path.length == 0)
        return nil;

    HorosModernDCMTKCopyStructuredReportHTMLFn renderFn = (HorosModernDCMTKCopyStructuredReportHTMLFn) PreviewModernDCMTKSymbol("HorosModernDCMTKCopyStructuredReportHTML");
    HorosModernDCMTKFreeStringFn freeFn = (HorosModernDCMTKFreeStringFn) PreviewModernDCMTKSymbol("HorosModernDCMTKFreeString");
    if (renderFn == NULL)
        return nil;

    char *html = renderFn(path.UTF8String);
    if (html == NULL)
        return nil;

    NSString *htmlString = [NSString stringWithUTF8String:html];
    if (freeFn)
        freeFn(html);
    return htmlString;
}

@end

@implementation PreviewView
{
    MetalPreviewImageView *_metalView;
    NSView *_annotationOverlay;
    WebView *_reportWebView;
    NSMutableArray *_dcmPixList;
    NSArray *_dcmFilesList;
    NSString *_loadedReportPath;
    NSInteger _displayedImageIndex;
    NSInteger _displayedImageCount;
}

@synthesize syncRelativeDiff;
@synthesize stringID;

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self)
        [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self)
        [self commonInit];
    return self;
}

- (void)dealloc
{
    [_dcmPixList release];
    [_dcmFilesList release];
    [_annotationOverlay release];
    [_reportWebView release];
    [_loadedReportPath release];
    [_metalView release];
    [stringID release];
    [super dealloc];
}

- (void)commonInit
{
    if (_metalView != nil)
        return;

    _metalView = [[MetalPreviewImageView alloc] initWithFrame:self.bounds device:nil];
    [_metalView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self addSubview:_metalView];

    _annotationOverlay = [[PreviewAnnotationOverlayView alloc] initWithFrame:self.bounds];
    [(PreviewAnnotationOverlayView *)_annotationOverlay setOwner:self];
    [_annotationOverlay setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_annotationOverlay setWantsLayer:YES];
    [_annotationOverlay setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawDuringViewResize];
    [self addSubview:_annotationOverlay positioned:NSWindowAbove relativeTo:_metalView];

    _reportWebView = [[WebView alloc] initWithFrame:self.bounds];
    [_reportWebView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_reportWebView setHidden:YES];
    [self addSubview:_reportWebView];
}

- (void) setPixels:(NSMutableArray*)pixels files:(NSArray*)files rois:(NSMutableArray*)rois firstImage:(short)firstImage level:(char)level reset:(BOOL)reset
{
    if (_dcmPixList != pixels)
    {
        [_dcmPixList release];
        _dcmPixList = [pixels retain];
    }

    if (_dcmFilesList != files)
    {
        [_dcmFilesList release];
        _dcmFilesList = [files retain];
    }

    NSArray *safePixels = pixels ? pixels : @[];
    _displayedImageIndex = MAX(0, firstImage);
    _displayedImageCount = files.count > 0 ? (NSInteger)files.count : (NSInteger)safePixels.count;

    if (_displayedImageCount == 0 || safePixels.count == _displayedImageCount)
    {
        [_metalView updatePixList:safePixels firstImage:firstImage resetWindowLevel:reset];
    }
    else
    {
        DCMPix *pix = nil;
        if (firstImage >= 0 && firstImage < [safePixels count])
            pix = [safePixels objectAtIndex:firstImage];
        [_metalView updateCurrentPix:pix index:firstImage resetWindowLevel:reset];
    }

    [self ensureAnnotationsForCurrentPix];
    [self refreshPreviewMode];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void) setIndex:(short)index
{
    DCMPix *pix = nil;
    if (_dcmPixList && index >= 0 && index < [_dcmPixList count])
        pix = [_dcmPixList objectAtIndex:index];

    BOOL canRefreshFullPixList = _dcmPixList && (_dcmFilesList.count == 0 || [_dcmPixList count] == _dcmFilesList.count);
    if (pix && canRefreshFullPixList && [_dcmPixList count] != _metalView.currentPixListCount)
        [_metalView updatePixList:_dcmPixList firstImage:index resetWindowLevel:NO];
    else
        [_metalView updateCurrentPix:pix index:index resetWindowLevel:NO];
    [self ensureAnnotationsForCurrentPix];
    [self refreshPreviewMode];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void) setIndexWithReset:(short)index :(BOOL)sizeToFit
{
    DCMPix *pix = nil;
    if (_dcmPixList && index >= 0 && index < [_dcmPixList count])
        pix = [_dcmPixList objectAtIndex:index];

    BOOL canRefreshFullPixList = _dcmPixList && (_dcmFilesList.count == 0 || [_dcmPixList count] == _dcmFilesList.count);
    if (pix && canRefreshFullPixList && [_dcmPixList count] != _metalView.currentPixListCount)
        [_metalView updatePixList:_dcmPixList firstImage:index resetWindowLevel:NO];
    else
        [_metalView updateCurrentPix:pix index:index resetWindowLevel:NO];
    if (sizeToFit)
        [_metalView resetViewTransform];
    [self ensureAnnotationsForCurrentPix];
    [self refreshPreviewMode];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void) setWLWW:(float)wl :(float)ww
{
    [_metalView setWindowLevel:wl width:ww];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void) getWLWW:(float*)wl :(float*)ww
{
    if (wl) *wl = _metalView.currentWindowLevel;
    if (ww) *ww = _metalView.currentWindowWidth;
}

- (void)setDisplayedImageIndex:(NSInteger)index totalCount:(NSInteger)totalCount
{
    _displayedImageIndex = MAX(0, index);
    _displayedImageCount = MAX(totalCount, 0);
    [_metalView setDisplayedImageIndex:_displayedImageIndex];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void)refreshMetalPixListIfNeeded
{
    if (_dcmPixList == nil || [_dcmPixList count] == 0)
        return;

    if ((_dcmFilesList.count == 0 || [_dcmPixList count] == _dcmFilesList.count)
        && [_dcmPixList count] != _metalView.currentPixListCount)
    {
        NSInteger index = _metalView.currentIndex;
        if (index < 0) index = 0;
        if (index >= [_dcmPixList count]) index = [_dcmPixList count] - 1;
        [_metalView updatePixList:_dcmPixList firstImage:index resetWindowLevel:NO];
        [self ensureAnnotationsForCurrentPix];
        [self refreshPreviewMode];
        [_annotationOverlay setNeedsDisplay:YES];
    }
}

- (DCMPix *)curDCM
{
    return _metalView.curDCM;
}

- (BOOL)mouseDragging
{
    return _metalView.mouseDragging;
}

- (void)setStringID:(NSString *)value
{
    if (stringID != value)
    {
        [stringID release];
        stringID = [value retain];
    }
}

- (void) setTheMatrix:(NSMatrix *)value
{
    (void)value;
}

- (void) scaleToFit
{
    [_metalView resetViewTransform];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void) setOriginX:(float)x Y:(float)y
{
    [_metalView setPanOffsetX:x y:y];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void) annotMenu:(id)sender
{
    short chosenLine = [sender tag];

    [[NSUserDefaults standardUserDefaults] setInteger:chosenLine forKey:@"ANNOTATIONS"];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:OsirixUpdateViewNotification object:self userInfo:nil];

    [_annotationOverlay setNeedsDisplay:YES];
    [_metalView setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent *)event
{
    BrowserController *browser = [BrowserController currentBrowser];
    if (browser && [browser window] == [self window])
        [browser scrollWheel:event];
    else
        [super scrollWheel:event];
}

- (void)swipeWithEvent:(NSEvent *)event
{
    [super swipeWithEvent:event];
}

- (BOOL)is2DViewer
{
    return NO;
}

-(BOOL)actionForHotKey:(NSString *)hotKey
{
    (void)hotKey;
    return NO;
}

- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)currentPixIsStructuredReport
{
    NSString *sopClassUID = self.curDCM.SOPClassUID;
    return [sopClassUID hasPrefix:@"1.2.840.10008.5.1.4.1.1.88"];
}

- (BOOL)currentPixIsKeyObjectDocument
{
    NSString *sopClassUID = self.curDCM.SOPClassUID;
    return [DCMAbstractSyntaxUID isKeyObjectDocument:sopClassUID];
}

- (BOOL)currentPixIsROIStructuredReport
{
    DCMPix *pix = self.curDCM;
    DicomImage *image = [pix imageObj];
    NSString *seriesName = [image valueForKeyPath:@"series.name"];
    NSString *seriesDescription = [image valueForKeyPath:@"series.seriesDescription"];

    return [seriesName hasPrefix:PreviewROISeriesDescription] ||
           [seriesDescription hasPrefix:PreviewROISeriesDescription];
}

- (NSString *)htmlEscapedString:(NSString *)string
{
    if (string.length == 0)
        return @"";

    NSMutableString *escaped = [[string mutableCopy] autorelease];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

- (NSArray *)roiArrayForStructuredReportPix:(DCMPix *)pix
{
    if (pix.srcFile.length == 0)
        return nil;

    NSData *data = [SRAnnotation roiFromDICOM:pix.srcFile];
    if (data == nil)
        return nil;

    @try
    {
        id object = [NSUnarchiver unarchiveObjectWithData:data];
        return [object isKindOfClass:[NSArray class]] ? object : nil;
    }
    @catch (NSException *exception)
    {
        NSLog(@"PreviewView could not unarchive ROI SR at %@: %@", pix.srcFile, exception);
        return nil;
    }
}

- (NSString *)displayNameForPreviewROI:(ROI *)roi
{
    if ([roi isKindOfClass:[ROI class]] == NO)
        return NSLocalizedString(@"ROI", nil);

    NSString *comments = roi.comments;
    if ([roi.name isEqualToString:PreviewTumourSeedROIName] ||
        (comments.length > 0 && [comments rangeOfString:PreviewTumourSeedCommentPrefix].location != NSNotFound))
        return NSLocalizedString(PreviewTumourSeedDisplayName, nil);

    NSString *name = [roi.name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return name.length ? name : NSLocalizedString(@"Unnamed ROI", nil);
}

- (NSString *)previewCountStringForCount:(NSUInteger)count singular:(NSString *)singular plural:(NSString *)plural
{
    return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, count == 1 ? singular : plural];
}

- (NSString *)roiStructuredReportCacheKeyForPix:(DCMPix *)pix
{
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:pix.srcFile error:nil];
    NSDate *modificationDate = [attributes objectForKey:NSFileModificationDate];
    NSNumber *fileSize = [attributes objectForKey:NSFileSize];
    return [NSString stringWithFormat:@"roi:%@:%@:%@", pix.srcFile ?: @"", modificationDate ?: [NSDate distantPast], fileSize ?: @0];
}

- (NSString *)roiStructuredReportSummaryHTMLForPix:(DCMPix *)pix
{
    NSArray *rois = [self roiArrayForStructuredReportPix:pix];
    if (rois == nil)
        return nil;

    NSMutableDictionary *countsByName = [NSMutableDictionary dictionary];
    NSUInteger totalCount = 0;

    for (id object in rois)
    {
        if ([object isKindOfClass:[ROI class]] == NO)
            continue;

        NSString *displayName = [self displayNameForPreviewROI:object];
        NSNumber *count = [countsByName objectForKey:displayName];
        [countsByName setObject:[NSNumber numberWithUnsignedInteger:count.unsignedIntegerValue + 1] forKey:displayName];
        totalCount++;
    }

    BOOL onlyTumourSeeds = countsByName.count == 1 && [countsByName objectForKey:NSLocalizedString(PreviewTumourSeedDisplayName, nil)] != nil;
    NSString *title = onlyTumourSeeds ? NSLocalizedString(PreviewTumourSeedDisplayName, nil) : NSLocalizedString(@"ROI Summary", nil);
    NSString *summary = onlyTumourSeeds ?
        [self previewCountStringForCount:totalCount singular:NSLocalizedString(@"seed", nil) plural:NSLocalizedString(@"seeds", nil)] :
        [self previewCountStringForCount:totalCount singular:NSLocalizedString(@"ROI", nil) plural:NSLocalizedString(@"ROIs", nil)];

    NSMutableArray *sortedNames = [[[countsByName allKeys] mutableCopy] autorelease];
    [sortedNames sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *tumourSeedName = NSLocalizedString(PreviewTumourSeedDisplayName, nil);
    if ([sortedNames containsObject:tumourSeedName])
    {
        [sortedNames removeObject:tumourSeedName];
        [sortedNames insertObject:tumourSeedName atIndex:0];
    }

    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!doctype html><html><head><meta charset=\"utf-8\"><style>"];
    [html appendString:@"body{margin:0;padding:22px;font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;background:#f5f6f7;color:#20242a;}"];
    [html appendString:@"h1{font-size:22px;line-height:1.2;margin:0 0 8px;font-weight:600;}"];
    [html appendString:@".summary{font-size:15px;margin:0 0 20px;color:#4b5563;}"];
    [html appendString:@"table{border-collapse:collapse;width:100%;font-size:14px;background:#fff;border:1px solid #d7dbe0;}"];
    [html appendString:@"th,td{padding:9px 11px;border-bottom:1px solid #e4e7eb;text-align:left;}"];
    [html appendString:@"th{font-weight:600;color:#5b6470;background:#eef1f4;}"];
    [html appendString:@"tr:last-child td{border-bottom:0;}"];
    [html appendString:@".count{text-align:right;font-variant-numeric:tabular-nums;}"];
    [html appendString:@"</style></head><body>"];
    [html appendFormat:@"<h1>%@</h1>", [self htmlEscapedString:title]];
    [html appendFormat:@"<p class=\"summary\">%@</p>", [self htmlEscapedString:summary]];
    [html appendString:@"<table><thead><tr>"];
    [html appendFormat:@"<th>%@</th><th class=\"count\">%@</th>",
        [self htmlEscapedString:NSLocalizedString(@"Name", nil)],
        [self htmlEscapedString:NSLocalizedString(@"Count", nil)]];
    [html appendString:@"</tr></thead><tbody>"];

    if (sortedNames.count == 0)
    {
        [html appendFormat:@"<tr><td>%@</td><td class=\"count\">0</td></tr>",
            [self htmlEscapedString:NSLocalizedString(@"No ROIs", nil)]];
    }
    else
    {
        for (NSString *name in sortedNames)
        {
            NSNumber *count = [countsByName objectForKey:name];
            [html appendFormat:@"<tr><td>%@</td><td class=\"count\">%@</td></tr>",
                [self htmlEscapedString:name],
                [count stringValue]];
        }
    }

    [html appendString:@"</tbody></table></body></html>"];
    return html;
}

- (NSString *)keyObjectTypeForPix:(DCMPix *)pix
{
    if (pix == nil || pix.srcFile.length == 0)
        return nil;

    HorosModernDCMTKCopyStructuredReportKeyObjectTypeFn copyTypeFn = (HorosModernDCMTKCopyStructuredReportKeyObjectTypeFn)PreviewModernDCMTKSymbol("HorosModernDCMTKCopyStructuredReportKeyObjectType");
    HorosModernDCMTKFreeStringFn freeFn = (HorosModernDCMTKFreeStringFn)PreviewModernDCMTKSymbol("HorosModernDCMTKFreeString");
    if (copyTypeFn == NULL)
        return nil;

    char *value = copyTypeFn(pix.srcFile.UTF8String);
    if (value == NULL)
        return nil;

    NSString *type = [NSString stringWithUTF8String:value];
    if (freeFn)
        freeFn(value);
    return type;
}

- (NSArray *)referencedImagesForPix:(DCMPix *)pix
{
    NSArray *uids = [self referencedUIDsForPix:pix];
    if (uids.count == 0)
        return @[];

    BrowserController *browser = [BrowserController currentBrowser];
    NSManagedObjectContext *context = browser.managedObjectContext;
    if (context == nil)
        return @[];

    __block NSArray *result = nil;
    N2PerformManagedObjectContextBlockAndWait(context, ^{
        @try
        {
            NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
            [request setEntity:[NSEntityDescription entityForName:@"Image" inManagedObjectContext:context]];
            [request setPredicate:[NSPredicate predicateWithFormat:@"compressedSopInstanceUID != NIL"]];

            NSArray *matches = [context executeFetchRequest:request error:nil];
            NSMutableArray *orderedImages = [NSMutableArray array];
            for (NSString *uid in uids)
            {
                NSPredicate *match = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"compressedSopInstanceUID"]
                                                                        rightExpression:[NSExpression expressionForConstantValue:[DicomImage sopInstanceUIDEncodeString:uid]]
                                                                         customSelector:@selector(isEqualToSopInstanceUID:)];
                NSArray *found = [matches filteredArrayUsingPredicate:match];
                if (found.count)
                    [orderedImages addObject:[found objectAtIndex:0]];
            }
            result = [orderedImages copy];
        }
        @catch (NSException *e)
        {
            NSLog(@"KO preview lookup exception: %@", e);
        }
    });
    return result ? [result autorelease] : @[];
}

- (NSArray *)referencedUIDsForPix:(DCMPix *)pix
{
    if (pix == nil || pix.srcFile.length == 0)
        return @[];

    HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn copyRefsFn = (HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn)PreviewModernDCMTKSymbol("HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDs");
    HorosModernDCMTKFreeStringFn freeFn = (HorosModernDCMTKFreeStringFn)PreviewModernDCMTKSymbol("HorosModernDCMTKFreeString");
    if (copyRefsFn == NULL)
        return @[];

    char *value = copyRefsFn(pix.srcFile.UTF8String);
    if (value == NULL)
        return @[];

    NSString *uidsString = [NSString stringWithUTF8String:value];
    if (freeFn)
        freeFn(value);
    if (uidsString.length == 0)
        return @[];

    NSMutableArray *uids = [NSMutableArray array];
    for (NSString *uid in [uidsString componentsSeparatedByString:@"\\"])
        if (uid.length)
            [uids addObject:uid];

    return uids;
}

- (NSString *)structuredReportHTMLPathForPix:(DCMPix *)pix
{
    if (pix == nil || pix.srcFile.length == 0)
        return nil;

    NSString *directory = @"/tmp/dicomsr_osirix/";
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *htmlPath = [[directory stringByAppendingPathComponent:pix.srcFile.lastPathComponent] stringByAppendingPathExtension:@"xml"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:htmlPath] == NO)
    {
        NSString *dsr2htmlPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"dsr2html"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:dsr2htmlPath] == NO)
            return nil;

        NSTask *task = [[[NSTask alloc] init] autorelease];
        [task setEnvironment:[NSDictionary dictionaryWithObject:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"dicom.dic"] forKey:@"DCMDICTPATH"]];
        [task setExecutableURL:[NSURL fileURLWithPath:dsr2htmlPath]];
        [task setArguments:[NSArray arrayWithObjects:@"+X1", @"--unknown-relationship", @"--ignore-constraints", @"--ignore-item-errors", @"--skip-invalid-items", pix.srcFile, htmlPath, nil]];
        [task setStandardOutput:[NSPipe pipe]];
        [task setStandardError:[NSPipe pipe]];
        HorosLaunchTaskOrRaise(task);
        while ([task isRunning])
            [NSThread sleepForTimeInterval:0.05];
        [task interrupt];
    }

    return [[NSFileManager defaultManager] fileExistsAtPath:htmlPath] ? htmlPath : nil;
}

- (NSString *)structuredReportHTMLStringForPix:(DCMPix *)pix
{
    if (pix == nil || pix.srcFile.length == 0)
        return nil;

    HorosModernDCMTKCopyStructuredReportHTMLFn renderFn = (HorosModernDCMTKCopyStructuredReportHTMLFn) PreviewModernDCMTKSymbol("HorosModernDCMTKCopyStructuredReportHTML");
    HorosModernDCMTKFreeStringFn freeFn = (HorosModernDCMTKFreeStringFn) PreviewModernDCMTKSymbol("HorosModernDCMTKFreeString");
    if (renderFn == NULL)
        return nil;

    char *html = renderFn(pix.srcFile.UTF8String);
    if (html == NULL)
        return nil;

    NSString *htmlString = [NSString stringWithUTF8String:html];
    if (freeFn)
        freeFn(html);
    return htmlString;
}

- (NSString *)htmlStringByStrippingLinks:(NSString *)htmlString
{
    if (htmlString.length == 0)
        return htmlString;

    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<a\\b[^>]*>(.*?)</a>"
                                                                           options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                             error:&error];
    if (regex == nil)
        return htmlString;

    return [regex stringByReplacingMatchesInString:htmlString
                                           options:0
                                             range:NSMakeRange(0, htmlString.length)
                                      withTemplate:@"$1"];
}

- (NSString *)keyObjectReferenceHTMLSummaryForPix:(DCMPix *)pix
{
    if ([self currentPixIsKeyObjectDocument] == NO)
        return @"";

    NSArray *images = [self referencedImagesForPix:pix];
    if (images.count == 0)
    {
        NSArray *uids = [self referencedUIDsForPix:pix];
        if (uids.count == 0)
            return @"";
        return [NSString stringWithFormat:@"<hr/><p><b>%@</b>: %lu</p>",
                NSLocalizedString(@"Referenced Images", nil),
                (unsigned long)uids.count];
    }

    NSMutableString *html = [NSMutableString stringWithFormat:@"<hr/><p><b>%@</b></p><ul>",
                             NSLocalizedString(@"Referenced Images", nil)];
    for (DicomImage *image in images)
    {
        NSString *seriesName = [image valueForKeyPath:@"series.name"];
        NSNumber *instanceNumber = [image valueForKey:@"instanceNumber"];
        if (seriesName.length == 0)
            seriesName = NSLocalizedString(@"Series", nil);

        if (instanceNumber)
            [html appendFormat:@"<li>%@ — %@ %@</li>", seriesName, NSLocalizedString(@"Image", nil), instanceNumber];
        else
            [html appendFormat:@"<li>%@</li>", seriesName];
    }
    [html appendString:@"</ul>"];
    return html;
}

- (void)refreshPreviewMode
{
    DCMPix *pix = self.curDCM;
    if ([self currentPixIsStructuredReport] == NO)
    {
        [_reportWebView setHidden:YES];
        [_metalView setHidden:NO];
        [_annotationOverlay setHidden:NO];
        return;
    }

    NSString *htmlPath = nil;
    NSString *htmlString = nil;
    NSString *reportCacheKey = nil;

    if ([self currentPixIsROIStructuredReport])
    {
        htmlString = [self roiStructuredReportSummaryHTMLForPix:pix];
        reportCacheKey = [self roiStructuredReportCacheKeyForPix:pix];
    }

    if (htmlString.length == 0)
    {
        htmlPath = [self structuredReportHTMLPathForPix:pix];
        htmlString = [self structuredReportHTMLStringForPix:pix];
        reportCacheKey = pix.srcFile;
    }

    if ([self currentPixIsKeyObjectDocument] && htmlString.length > 0 && [self currentPixIsROIStructuredReport] == NO)
    {
        htmlString = [self htmlStringByStrippingLinks:htmlString];
        NSString *summary = [self keyObjectReferenceHTMLSummaryForPix:pix];
        if (summary.length)
            htmlString = [htmlString stringByAppendingString:summary];
    }

    if (htmlString.length == 0 && htmlPath.length == 0)
    {
        [_reportWebView setHidden:YES];
        [_metalView setHidden:NO];
        [_annotationOverlay setHidden:NO];
        return;
    }

    [_metalView setHidden:YES];
    [_annotationOverlay setHidden:YES];
    [_reportWebView setHidden:NO];

    if (htmlString.length > 0)
    {
        if ([_loadedReportPath isEqualToString:reportCacheKey] == NO)
        {
            [_loadedReportPath release];
            _loadedReportPath = [reportCacheKey copy];
            [[_reportWebView mainFrame] loadHTMLString:htmlString baseURL:nil];
        }
    }
    else if ([_loadedReportPath isEqualToString:htmlPath] == NO)
    {
        [_loadedReportPath release];
        _loadedReportPath = [htmlPath copy];

        NSURL *fileURL = [NSURL fileURLWithPath:htmlPath];
        [[_reportWebView mainFrame] loadRequest:[NSURLRequest requestWithURL:fileURL]];
    }
}

- (void)ensureAnnotationsForCurrentPix
{
#ifdef OSIRIX_VIEWER
    DCMPix *pix = self.curDCM;
    if (pix == nil)
        return;

    if (pix.annotationsDictionary.count == 0)
        [pix loadCustomImageAnnotationsPapyLink:-1 DCMLink:nil];
#endif
}

- (void)drawAnnotationsInBounds:(NSRect)bounds
{
    DCMPix *pix = self.curDCM;
    if (pix == nil)
        return;

    NSInteger annotationLevel = [[NSUserDefaults standardUserDefaults] integerForKey:@"ANNOTATIONS"];
    if (annotationLevel <= annotGraphics)
        return;
    BOOL fullText = (annotationLevel >= annotFull);

    NSDictionary *annotationsDictionary = pix.annotationsDictionary ?: @{};
    if (annotationsDictionary.count == 0)
    {
        [self ensureAnnotationsForCurrentPix];
        annotationsDictionary = pix.annotationsDictionary ?: @{};
    }

    if (annotationsDictionary.count == 0)
        return;

    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.2 green:1.0 blue:0.3 alpha:1.0]
    };

    NSDictionary *xRasterInit = @{
        @"TopLeft": @6,
        @"MiddleLeft": @6,
        @"LowerLeft": @6,
        @"TopRight": @(bounds.size.width - 2),
        @"MiddleRight": @(bounds.size.width - 2),
        @"LowerRight": @(bounds.size.width - 2),
        @"TopMiddle": @(bounds.size.width / 2.0),
        @"LowerMiddle": @(bounds.size.width / 2.0)
    };

    NSDictionary *yRasterInit = @{
        @"TopLeft": @14,
        @"TopMiddle": @12,
        @"TopRight": @14,
        @"MiddleLeft": @(bounds.size.height / 2.0),
        @"MiddleRight": @(bounds.size.height / 2.0),
        @"LowerLeft": @(bounds.size.height - 2),
        @"LowerRight": @(bounds.size.height - 14),
        @"LowerMiddle": @(bounds.size.height - 2)
    };

    NSDictionary *yRasterIncrement = @{
        @"TopLeft": @14,
        @"TopMiddle": @14,
        @"TopRight": @14,
        @"MiddleLeft": @14,
        @"MiddleRight": @14,
        @"LowerLeft": @-14,
        @"LowerRight": @-14,
        @"LowerMiddle": @-14
    };

    NSDictionary *alignments = @{
        @"TopLeft": @(NSTextAlignmentLeft),
        @"MiddleLeft": @(NSTextAlignmentLeft),
        @"LowerLeft": @(NSTextAlignmentLeft),
        @"TopRight": @(NSTextAlignmentRight),
        @"MiddleRight": @(NSTextAlignmentRight),
        @"LowerRight": @(NSTextAlignmentRight),
        @"TopMiddle": @(NSTextAlignmentCenter),
        @"LowerMiddle": @(NSTextAlignmentCenter)
    };

    for (NSString *key in annotationsDictionary.allKeys)
    {
        NSArray *annotations = annotationsDictionary[key];
        if (annotations.count == 0)
            continue;

        CGFloat x = [xRasterInit[key] doubleValue];
        CGFloat y = [yRasterInit[key] doubleValue];
        CGFloat increment = [yRasterIncrement[key] doubleValue];
        NSTextAlignment alignment = [alignments[key] integerValue];
        NSEnumerator *enumerator = [key hasPrefix:@"Lower"] ? [annotations reverseObjectEnumerator] : [annotations objectEnumerator];

        for (NSArray *annotation in enumerator)
        {
            NSArray<NSString *> *lines = [self resolvedAnnotationLines:annotation key:key bounds:bounds fullText:fullText];
            for (NSString *line in lines)
            {
                if (line.length == 0)
                    continue;
                [self drawAnnotationString:line attributes:attributes alignment:alignment x:x y:y];
                y += increment;
            }
        }
    }
}

- (NSArray<NSString *> *)resolvedAnnotationLines:(NSArray *)annotation key:(NSString *)key bounds:(NSRect)bounds fullText:(BOOL)fullText
{
    DCMPix *pix = self.curDCM;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableString *primary = [NSMutableString string];
    NSMutableString *secondary = [NSMutableString string];
    NSMutableString *third = [NSMutableString string];
    NSMutableString *fourth = [NSMutableString string];

    for (id item in annotation)
    {
        if ([item isKindOfClass:[NSString class]] == NO)
            continue;

        NSString *value = item;

        if ([value isEqualToString:@"Image Size"] && fullText)
            [primary appendFormat:@"Image size: %ld x %ld", (long)pix.pwidth, (long)pix.pheight];
        else if ([value isEqualToString:@"View Size"] && fullText)
            [primary appendFormat:@"View size: %ld x %ld", (long)bounds.size.width, (long)bounds.size.height];
        else if ([value isEqualToString:@"Mouse Position (px)"])
        {
            if (_metalView.mouseOnImage)
                [primary appendFormat:@"X: %ld px Y: %ld px Value: %2.2f", (long)_metalView.mousePixelX, (long)_metalView.mousePixelY, _metalView.mousePixelValue];
        }
        else if ([value isEqualToString:@"Mouse Position (mm)"])
        {
            if (self.stringID == nil && _metalView.mouseOnImage)
                [primary appendFormat:@"X: %2.2f mm Y: %2.2f mm Z: %2.2f mm", _metalView.mouseDicomX, _metalView.mouseDicomY, _metalView.mouseDicomZ];
        }
        else if ([value isEqualToString:@"Zoom"] && fullText)
            [primary appendString:@"Zoom: 100%"];
        else if ([value isEqualToString:@"Rotation Angle"] && fullText)
            [primary appendString:@" Angle: 0"];
        else if ([value isEqualToString:@"Image Position"])
        {
            NSInteger displayedIndex = _displayedImageCount > 0 ? _displayedImageIndex : _metalView.currentIndex;
            NSUInteger totalCount = _displayedImageCount > 0 ? (NSUInteger)_displayedImageCount : (_dcmFilesList.count ? _dcmFilesList.count : _dcmPixList.count);
            [primary appendFormat:@"Im: %ld/%lu", (long)displayedIndex + 1, (unsigned long)totalCount];
        }
        else if ([value isEqualToString:@"Window Level / Window Width"])
            [primary appendFormat:@"WL: %d WW: %d", (int)lrintf(_metalView.currentWindowLevel), (int)lrintf(_metalView.currentWindowWidth)];
        else if ([value isEqualToString:@"Thickness / Location / Position"])
        {
            if (pix.sliceThickness != 0 && pix.sliceLocation != 0)
                [primary appendFormat:@"Thickness: %0.2f mm Location: %0.2f mm", pix.sliceThickness, pix.sliceLocation];
            else if (pix.viewPosition || pix.patientPosition)
            {
                if (pix.viewPosition) [primary appendFormat:@"Position: %@ ", pix.viewPosition];
                if (pix.patientPosition) [primary appendString:pix.patientPosition];
            }
        }
        else if ([value isEqualToString:@"PatientName"])
        {
            id patientName = fullText ? [_dcmFilesList.firstObject valueForKeyPath:@"series.study.name"] : nil;
            if (patientName)
                [primary appendString:patientName];
        }
        else if ([value isEqualToString:@"Orientation"])
        {
            // Keep orientation layout untouched for now; browser preview mainly relies on corner labels.
        }
        else if ([value isEqualToString:@"Plugin"])
        {
            // Not implemented for the lightweight Metal preview.
        }
        else
        {
            if (primary.length == 0)
                [primary appendString:value];
            else
                [primary appendFormat:@" %@", value];
        }
    }

    for (NSMutableString *line in @[primary, secondary, third, fourth])
    {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0)
            [lines addObject:trimmed];
    }

    return lines;
}

- (void)drawAnnotationString:(NSString *)line attributes:(NSDictionary *)attributes alignment:(NSTextAlignment)alignment x:(CGFloat)x y:(CGFloat)y
{
    NSSize textSize = [line sizeWithAttributes:attributes];
    CGFloat drawX = x;
    if (alignment == NSTextAlignmentRight)
        drawX -= textSize.width;
    else if (alignment == NSTextAlignmentCenter)
        drawX -= textSize.width / 2.0;

    [line drawAtPoint:NSMakePoint(drawX, y) withAttributes:attributes];
}

@end

@implementation PreviewAnnotationOverlayView

- (BOOL)isOpaque
{
    return NO;
}

- (BOOL)isFlipped
{
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
    [super drawRect:dirtyRect];
    [self.owner drawAnnotationsInBounds:self.bounds];
}

- (NSView *)hitTest:(NSPoint)point
{
    return nil;
}

@end
