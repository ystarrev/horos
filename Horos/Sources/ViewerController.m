/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 =========================================================================*/

#import "ViewerController.h"

#import "DCMView.h"
#import "DCMPix.h"
#import "MyPoint.h"
#import "ROI.h"

BOOL SyncButtonBehaviorIsBetweenStudies = NO;

/*
 * Compatibility boundary for code that still refers to the retired 2D
 * viewer. All new viewing is provided by the Swift Metal viewers. Keeping
 * this class name temporarily lets database, printing, and window-management
 * code compile while those remaining references are removed independently.
 */
@implementation ViewerController

@dynamic injectionDateTime;
@dynamic currentOrientationTool;
@dynamic timer;
@dynamic keyImageCheck;
@dynamic speedSlider;
@dynamic movieRateSlider;
@dynamic speedText;
@dynamic movieTextSlide;
@dynamic windowsStateName;
@dynamic blendingTypeWindow;
@dynamic blendingTypeMultiply;
@dynamic blendingTypeSubtract;
@dynamic blendingTypeRGB;
@dynamic titledGantry;
@dynamic toolbarPanel;
@dynamic blendedWindow;
@dynamic flagListPODComparatives;

+ (NSMutableArray *)getDisplayed2DViewers
{
    return [NSMutableArray array];
}

+ (NSMutableArray *)get2DViewers
{
    return [NSMutableArray array];
}

+ (NSArray *)getDisplayedSeries
{
    return @[];
}

+ (BOOL)isFrontMost2DViewer:(NSWindow *)window
{
    return NO;
}

+ (ViewerController *)frontMostDisplayed2DViewer
{
    return nil;
}

+ (ViewerController *)frontMostDisplayed2DViewerForScreen:(NSScreen *)screen
{
    return nil;
}

+ (NSArray *)displayed2DViewerForScreen:(NSScreen *)screen
{
    return @[];
}

+ (void)closeAllWindows
{
}

+ (NSArray *)studyColors
{
    return @[
        [NSColor colorWithCalibratedRed:0.0 green:0.72 blue:1.0 alpha:1.0],
        [NSColor colorWithCalibratedRed:1.0 green:0.25 blue:0.55 alpha:1.0],
        [NSColor colorWithCalibratedRed:1.0 green:0.84 blue:0.0 alpha:1.0]
    ];
}

+ (ViewerController *)newWindow:(NSMutableArray *)pixels
                                :(NSMutableArray *)files
                                :(NSData *)data
{
    return nil;
}

+ (ViewerController *)newWindow:(NSMutableArray *)pixels
                                :(NSMutableArray *)files
                                :(NSData *)data
                           frame:(NSRect)frame
{
    return nil;
}

- (ViewerController *)newWindow:(NSMutableArray *)pixels
                                :(NSMutableArray *)files
                                :(NSData *)data
{
    return nil;
}

+ (int)numberOf2DViewer
{
    return 0;
}

+ (BOOL)areLoadingViewers
{
    return NO;
}

+ (ToolMode)getToolEquivalentToHotKey:(int)hotKey
{
    return (ToolMode)-1;
}

- (DCMView *)imageView
{
    return imageView;
}

- (NSArray *)imageViews
{
    return imageView ? @[imageView] : @[];
}

- (NSMutableArray *)pixList
{
    return [self pixList:curMovieIndex];
}

- (NSMutableArray *)pixList:(long)index
{
    return index >= 0 && index < MAX4D ? pixList[index] : nil;
}

- (NSMutableArray *)fileList
{
    return [self fileList:curMovieIndex];
}

- (NSMutableArray *)fileList:(long)index
{
    return index >= 0 && index < MAX4D ? fileList[index] : nil;
}

- (NSMutableArray *)roiList
{
    return [self roiList:curMovieIndex];
}

- (NSMutableArray *)roiList:(long)index
{
    return index >= 0 && index < MAX4D ? roiList[index] : nil;
}

- (void)setRoiList:(long)index array:(NSMutableArray *)array
{
    if (index < 0 || index >= MAX4D || roiList[index] == array)
        return;

    [roiList[index] release];
    roiList[index] = [array retain];
}

- (NSData *)volumeData
{
    return [self volumeData:curMovieIndex];
}

- (NSData *)volumeData:(long)index
{
    return index >= 0 && index < MAX4D ? volumeData[index] : nil;
}

- (short)curMovieIndex
{
    return curMovieIndex;
}

- (MyPoint *)newPoint:(float)x :(float)y
{
    return [MyPoint point:NSMakePoint(x, y)];
}

- (ROI *)newROI:(ToolMode)type
{
    DCMPix *pixel = imageView.curDCM;
    const float spacingX = pixel ? pixel.pixelSpacingX : 1.0f;
    const float spacingY = pixel ? pixel.pixelSpacingY : spacingX;
    const NSPoint origin = pixel ? NSMakePoint(pixel.originX, pixel.originY) : NSZeroPoint;
    return [[[ROI alloc] initWithType:type :spacingX :spacingY :origin] autorelease];
}

- (BOOL)containsROI:(ROI *)roi
{
    for (NSArray *imageROIs in [self roiList])
        if ([imageROIs containsObject:roi])
            return YES;
    return NO;
}

- (BOOL)isEverythingLoaded
{
    return YES;
}

- (void)checkEverythingLoaded
{
}

- (BOOL)isDataVolumic
{
    return NO;
}

- (BOOL)isDataVolumicIn4D:(BOOL)check4D
{
    return NO;
}

- (BOOL)isDataVolumicIn4D:(BOOL)check4D checkEverythingLoaded:(BOOL)checkLoaded
{
    return NO;
}

- (BOOL)isDataVolumicIn4D:(BOOL)check4D
    checkEverythingLoaded:(BOOL)checkLoaded
             tryToCorrect:(BOOL)tryToCorrect
{
    return NO;
}

- (DicomImage *)currentImage
{
    return imageView.imageObj;
}

- (DicomSeries *)currentSeries
{
    return imageView.seriesObj;
}

- (DicomStudy *)currentStudy
{
    return imageView.studyObj;
}

- (BOOL)isPlaying4D
{
    return NO;
}

- (void)MovieStop:(id)sender
{
}

- (void)needsDisplayUpdate
{
    [imageView setNeedsDisplay:YES];
}

- (IBAction)ApplyWLWW:(id)sender
{
}

- (void)updateThreeDPositionController
{
}

@end
