/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 =========================================================================*/

#import "DCMView.h"

#import "DCMPix.h"

#include <math.h>

NSString * const HorosPasteboardType = @"com.opensource.horos";
NSString * const pasteBoardOsiriX = @"OsiriX pasteboard";
NSString * const pasteBoardHoros = @"Horos pasteboard";
NSString * const HorosPboardUTI = @"com.opensource.horos.uti";

int CLUTBARS = barHide;
int ANNOTATIONS = annotBase;
int SOFTWAREINTERPOLATION_MAX = 0;
int DISPLAYCROSSREFERENCELINES = YES;

static short HorosLegacySynchronizationMode = syncroLOC;
static BOOL HorosLegacyViewIgnoresSynchronization = NO;

void Normalise(XYZ *point)
{
    const double length = sqrt(point->x * point->x + point->y * point->y + point->z * point->z);
    if (length == 0.0)
    {
        point->x = point->y = point->z = 0.0;
        return;
    }

    point->x /= length;
    point->y /= length;
    point->z /= length;
}

XYZ ArbitraryRotate(XYZ point, double angle, XYZ axis)
{
    XYZ result = {0.0, 0.0, 0.0};
    Normalise(&axis);

    const double cosine = cos(angle);
    const double sine = sin(angle);

    result.x += (cosine + (1.0 - cosine) * axis.x * axis.x) * point.x;
    result.x += ((1.0 - cosine) * axis.x * axis.y - axis.z * sine) * point.y;
    result.x += ((1.0 - cosine) * axis.x * axis.z + axis.y * sine) * point.z;

    result.y += ((1.0 - cosine) * axis.x * axis.y + axis.z * sine) * point.x;
    result.y += (cosine + (1.0 - cosine) * axis.y * axis.y) * point.y;
    result.y += ((1.0 - cosine) * axis.y * axis.z - axis.x * sine) * point.z;

    result.z += ((1.0 - cosine) * axis.x * axis.z - axis.y * sine) * point.x;
    result.z += ((1.0 - cosine) * axis.y * axis.z + axis.x * sine) * point.y;
    result.z += (cosine + (1.0 - cosine) * axis.z * axis.z) * point.z;

    return result;
}

@implementation DCMExportPlugin

- (void)finalize:(DCMObject *)destination withSourceObject:(DCMObject *)source
{
}

- (NSString *)seriesName
{
    return nil;
}

@end

@interface DCMView ()
@property(nonatomic, strong, readwrite) DCMPix *curDCM;
@end

@implementation DCMView

@synthesize drawingFrameRect;
@synthesize rectArray;
@synthesize COPYSETTINGSINSERIES;
@synthesize flippedData;
@synthesize showDescriptionInLarge;
@synthesize whiteBackground;
@synthesize dcmPixList;
@synthesize dcmFilesList;
@synthesize dcmRoiList;
@synthesize curRoiList;
@synthesize syncSeriesIndex;
@synthesize syncRelativeDiff;
@synthesize studyColorR;
@synthesize studyColorG;
@synthesize studyColorB;
@synthesize blendingMode;
@synthesize studyDateIndex;
@synthesize blendingView;
@synthesize blendingFactor;
@synthesize xFlipped;
@synthesize yFlipped;
@synthesize stringID;
@synthesize currentTool;
@synthesize currentToolRight;
@synthesize scaleValue;
@synthesize rotation;
@synthesize origin;
@synthesize dcmExportPlugin;
@synthesize tag = _tag;
@synthesize eraserFlag;
@synthesize drawing;
@synthesize volumicSeries;
@synthesize timeIntervalForDrag;
@synthesize annotationType;
@synthesize curDCM = _curDCM;

- (BOOL)suppressLabels
{
    return suppress_labels;
}

- (double)pixelSpacing
{
    return self.pixelSpacingX;
}

- (double)pixelSpacingX
{
    return _curDCM ? _curDCM.pixelSpacingX : 1.0;
}

- (double)pixelSpacingY
{
    return _curDCM ? _curDCM.pixelSpacingY : 1.0;
}

- (float)mouseXPos
{
    return mouseXPos;
}

- (float)mouseYPos
{
    return mouseYPos;
}

- (float)contextualMenuInWindowPosX
{
    return contextualMenuInWindowPosX;
}

- (float)contextualMenuInWindowPosY
{
    return contextualMenuInWindowPosY;
}

- (float)curWW
{
    return curWW;
}

- (float)curWL
{
    return curWL;
}

- (NSCursor *)cursor
{
    return cursor;
}

- (BOOL)isKeyView
{
    return isKeyView;
}

- (BOOL)mouseDragging
{
    return mouseDragging;
}

+ (void)setDontListenToSyncMessage:(BOOL)value
{
    HorosLegacyViewIgnoresSynchronization = value;
}

+ (BOOL)noPropagateSettingsInSeriesForModality:(NSString *)modality
{
    return NO;
}

+ (void)purgeStringTextureCache
{
}

+ (void)setDefaults
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CLUTBARS = (int)[defaults integerForKey:@"CLUTBARS"];
    ANNOTATIONS = (int)[defaults integerForKey:@"ANNOTATIONS"];
    SOFTWAREINTERPOLATION_MAX = (int)[defaults integerForKey:@"SOFTWAREINTERPOLATION_MAX"];
    DISPLAYCROSSREFERENCELINES = [defaults boolForKey:@"DisplayCrossReferenceLines"];
}

+ (void)setCLUTBARS:(int)bars ANNOTATIONS:(int)annotations
{
    CLUTBARS = bars;
    ANNOTATIONS = annotations;
}

+ (void)setPluginOverridesMouse:(BOOL)override
{
}

+ (void)computePETBlendingCLUT
{
}

+ (short)syncro
{
    return HorosLegacySynchronizationMode;
}

+ (void)setSyncro:(short)mode
{
    HorosLegacySynchronizationMode = mode;
}

+ (NSArray<NSString *> *)PasteboardTypes
{
    return @[HorosPasteboardType, pasteBoardHoros, pasteBoardOsiriX];
}

+ (NSSize)sizeOfString:(NSString *)string forFont:(NSFont *)font
{
    if (string.length == 0)
        return NSZeroSize;

    return [string sizeWithAttributes:@{NSFontAttributeName: font ?: [NSFont systemFontOfSize:[NSFont systemFontSize]]}];
}

+ (float)Magnitude:(NSPoint)first :(NSPoint)second
{
    return hypotf((float)(second.x - first.x), (float)(second.y - first.y));
}

+ (float)angleBetweenVector:(float *)first andVector:(float *)second
{
    const double firstLength = sqrt(first[0] * first[0] + first[1] * first[1] + first[2] * first[2]);
    const double secondLength = sqrt(second[0] * second[0] + second[1] * second[1] + second[2] * second[2]);
    if (firstLength == 0.0 || secondLength == 0.0)
        return 0.0f;

    const double cosine = (first[0] * second[0] + first[1] * second[1] + first[2] * second[2]) /
                          (firstLength * secondLength);
    return (float)acos(fmax(-1.0, fmin(1.0, cosine)));
}

+ (double)angleBetweenVectorD:(double *)first andVector:(double *)second
{
    const double firstLength = sqrt(first[0] * first[0] + first[1] * first[1] + first[2] * first[2]);
    const double secondLength = sqrt(second[0] * second[0] + second[1] * second[1] + second[2] * second[2]);
    if (firstLength == 0.0 || secondLength == 0.0)
        return 0.0;

    const double cosine = (first[0] * second[0] + first[1] * second[1] + first[2] * second[2]) /
                          (firstLength * secondLength);
    return acos(fmax(-1.0, fmin(1.0, cosine)));
}

- (instancetype)initWithFrame:(NSRect)frame
{
    return [self initWithFrame:frame imageRows:1 imageColumns:1];
}

- (instancetype)initWithFrame:(NSRect)frame imageRows:(int)rows imageColumns:(int)columns
{
    self = [super initWithFrame:frame];
    if (self)
    {
        _imageRows = MAX(rows, 1);
        _imageColumns = MAX(columns, 1);
        rectArray = [[NSMutableArray alloc] init];
        dcmPixList = [[NSMutableArray alloc] init];
        dcmRoiList = [[NSMutableArray alloc] init];
        curRoiList = [[NSMutableArray alloc] init];
        currentTool = tWL;
        currentToolRight = tZoom;
        scaleValue = 1.0f;
        whiteBackground = NO;
    }
    return self;
}

- (void)dealloc
{
    [rectArray release];
    [dcmPixList release];
    [dcmFilesList release];
    [dcmRoiList release];
    [curRoiList release];
    [_curDCM release];
    [blendingView release];
    [stringID release];
    [matrix release];
    [dcmExportPlugin release];
    [super dealloc];
}

- (NSInteger)rows
{
    return _imageRows;
}

- (void)setRows:(NSInteger)rows
{
    _imageRows = MAX(rows, 1);
}

- (NSInteger)columns
{
    return _imageColumns;
}

- (void)setColumns:(NSInteger)columns
{
    _imageColumns = MAX(columns, 1);
}

- (void)setRows:(int)rows columns:(int)columns
{
    _imageRows = MAX(rows, 1);
    _imageColumns = MAX(columns, 1);
}

- (short)curImage
{
    return curImage;
}

- (void)setPixels:(NSMutableArray *)pixels
             files:(NSArray *)files
              rois:(NSMutableArray *)rois
        firstImage:(short)firstImage
             level:(char)level
             reset:(BOOL)reset
{
    [dcmPixList release];
    dcmPixList = [pixels mutableCopy];
    if (dcmPixList == nil)
        dcmPixList = [[NSMutableArray alloc] init];

    [dcmFilesList release];
    dcmFilesList = [files copy];

    [dcmRoiList release];
    dcmRoiList = [rois mutableCopy];
    if (dcmRoiList == nil)
        dcmRoiList = [[NSMutableArray alloc] init];

    curImage = firstImage >= 0 ? firstImage : 0;
    if (curImage >= (short)dcmPixList.count)
        curImage = dcmPixList.count ? (short)dcmPixList.count - 1 : 0;

    self.curDCM = dcmPixList.count ? [dcmPixList objectAtIndex:curImage] : nil;

    [curRoiList release];
    if (curImage < (short)dcmRoiList.count && [[dcmRoiList objectAtIndex:curImage] isKindOfClass:[NSMutableArray class]])
        curRoiList = [[dcmRoiList objectAtIndex:curImage] retain];
    else
        curRoiList = [[NSMutableArray alloc] init];

    [self setNeedsDisplay:YES];
}

- (void)setDCM:(NSMutableArray *)pixels
              :(NSArray *)files
              :(NSMutableArray *)rois
              :(short)firstImage
              :(char)level
              :(BOOL)reset
{
    [self setPixels:pixels files:files rois:rois firstImage:firstImage level:level reset:reset];
}

- (void)setIndex:(short)index
{
    if (index < 0 || index >= (short)dcmPixList.count)
        return;

    curImage = index;
    self.curDCM = [dcmPixList objectAtIndex:index];

    [curRoiList release];
    if (index < (short)dcmRoiList.count && [[dcmRoiList objectAtIndex:index] isKindOfClass:[NSMutableArray class]])
        curRoiList = [[dcmRoiList objectAtIndex:index] retain];
    else
        curRoiList = [[NSMutableArray alloc] init];

    [self setNeedsDisplay:YES];
}

- (void)setIndexWithReset:(short)index :(BOOL)fit
{
    [self setIndex:index];
    if (fit)
        [self scaleToFit];
}

- (void)drawRect:(NSRect)dirtyRect
{
    [super drawRect:dirtyRect];

    [(whiteBackground ? [NSColor whiteColor] : [NSColor blackColor]) setFill];
    NSRectFill(self.bounds);

    NSImage *image = [_curDCM image];
    if (image == nil)
        return;

    NSSize imageSize = image.size;
    if (imageSize.width <= 0.0 || imageSize.height <= 0.0)
        return;

    const CGFloat scale = MIN(NSWidth(self.bounds) / imageSize.width, NSHeight(self.bounds) / imageSize.height);
    const NSSize destinationSize = NSMakeSize(imageSize.width * scale, imageSize.height * scale);
    const NSRect destination = NSMakeRect(NSMidX(self.bounds) - destinationSize.width / 2.0,
                                          NSMidY(self.bounds) - destinationSize.height / 2.0,
                                          destinationSize.width,
                                          destinationSize.height);

    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [image drawInRect:destination
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:nil];
}

- (NSImage *)nsimage
{
    return [self nsimage:NO];
}

- (NSImage *)nsimage:(BOOL)originalSize
{
    NSRect bounds = self.bounds;
    NSBitmapImageRep *representation = [self bitmapImageRepForCachingDisplayInRect:bounds];
    [self cacheDisplayInRect:bounds toBitmapImageRep:representation];

    NSImage *image = [[[NSImage alloc] initWithSize:bounds.size] autorelease];
    [image addRepresentation:representation];
    return image;
}

- (NSImage *)nsimage:(BOOL)originalSize allViewers:(BOOL)allViewers
{
    return [self nsimage:originalSize];
}

- (unsigned char *)getRawPixels:(long *)width
                               :(long *)height
                               :(long *)samplesPerPixel
                               :(long *)bitsPerPixel
                               :(BOOL)screenCapture
                               :(BOOL)force8bits
{
    return [self getRawPixelsViewWidth:width
                               height:height
                                  spp:samplesPerPixel
                                  bpp:bitsPerPixel
                        screenCapture:screenCapture
                           force8bits:force8bits
                      removeGraphical:NO
                         squarePixels:NO
                   allowSmartCropping:NO
                               origin:NULL
                              spacing:NULL
                               offset:NULL
                             isSigned:NULL];
}

- (unsigned char *)getRawPixelsViewWidth:(long *)width
                                  height:(long *)height
                                     spp:(long *)samplesPerPixel
                                     bpp:(long *)bitsPerPixel
                           screenCapture:(BOOL)screenCapture
                              force8bits:(BOOL)force8bits
                         removeGraphical:(BOOL)removeGraphical
                            squarePixels:(BOOL)squarePixels
                      allowSmartCropping:(BOOL)allowSmartCropping
                                  origin:(float *)imageOrigin
                                 spacing:(float *)imageSpacing
                                  offset:(int *)offset
                                isSigned:(BOOL *)isSigned
{
    const NSInteger pixelWidth = MAX((NSInteger)NSWidth(self.bounds), 1);
    const NSInteger pixelHeight = MAX((NSInteger)NSHeight(self.bounds), 1);
    NSBitmapImageRep *representation = [[[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:pixelWidth
                      pixelsHigh:pixelHeight
                   bitsPerSample:8
                 samplesPerPixel:3
                        hasAlpha:NO
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:pixelWidth * 3
                    bitsPerPixel:24] autorelease];

    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:representation];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [self drawRect:self.bounds];
    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];

    const size_t byteCount = (size_t)pixelWidth * (size_t)pixelHeight * 3;
    unsigned char *result = malloc(byteCount);
    if (result)
        memcpy(result, representation.bitmapData, byteCount);

    if (width) *width = pixelWidth;
    if (height) *height = pixelHeight;
    if (samplesPerPixel) *samplesPerPixel = 3;
    if (bitsPerPixel) *bitsPerPixel = 8;
    if (offset) *offset = 0;
    if (isSigned) *isSigned = NO;
    if (imageOrigin) imageOrigin[0] = imageOrigin[1] = imageOrigin[2] = 0.0f;
    if (imageSpacing) imageSpacing[0] = imageSpacing[1] = 1.0f;
    return result;
}

- (void)setWLWW:(float)level :(float)width
{
    curWL = level;
    curWW = width;
    [self setNeedsDisplay:YES];
}

- (void)discretelySetWLWW:(float)level :(float)width
{
    [self setWLWW:level :width];
}

- (void)getWLWW:(float *)level :(float *)width
{
    if (level) *level = curWL;
    if (width) *width = curWW;
}

- (void)setBlendingFactor:(float)factor
{
    blendingFactor = factor;
}

- (void)setRightTool:(ToolMode)tool
{
    currentToolRight = tool;
}

- (void)setTheMatrix:(NSMatrix *)newMatrix
{
    if (matrix == newMatrix)
        return;
    [matrix release];
    matrix = [newMatrix retain];
}

- (NSMatrix *)theMatrix
{
    return matrix;
}

- (void)setCOPYSETTINGSINSERIESdirectly:(BOOL)value
{
    COPYSETTINGSINSERIES = value;
}

- (void)setScaleValueCentered:(float)value
{
    scaleValue = value;
}

- (void)scaleToFit
{
    scaleValue = 1.0f;
    origin = NSZeroPoint;
    [self setNeedsDisplay:YES];
}

- (IBAction)scaleToFit:(id)sender
{
    [self scaleToFit];
}

- (void)prepareToRelease
{
    self.curDCM = nil;
    self.blendingView = nil;
}

- (void)sendSyncMessage:(short)increment
{
    if (HorosLegacyViewIgnoresSynchronization)
        return;
}

- (void)annotMenu:(id)sender
{
}

- (void)updatePresentationStateFromSeries
{
}

- (void)updatePresentationStateFromSeriesOnlyImageLevel:(BOOL)onlyImage
{
}

- (void)updatePresentationStateFromSeriesOnlyImageLevel:(BOOL)onlyImage
                                                  scale:(BOOL)scale
                                                 offset:(BOOL)offset
{
}

- (DicomImage *)imageObj
{
    if (curImage >= 0 && curImage < (short)dcmFilesList.count)
        return [dcmFilesList objectAtIndex:curImage];
    return [_curDCM imageObj];
}

- (DicomSeries *)seriesObj
{
    return [[self imageObj] valueForKey:@"series"] ?: [_curDCM seriesObj];
}

- (DicomStudy *)studyObj
{
    return [[self imageObj] valueForKeyPath:@"series.study"] ?: [_curDCM studyObj];
}

- (DicomImage *)dicomImage
{
    return [self imageObj];
}

- (BOOL)roiTool:(ToolMode)tool
{
    switch (tool)
    {
        case tMesure:
        case tROI:
        case tOval:
        case tOPolygon:
        case tCPolygon:
        case tAngle:
        case tText:
        case tArrow:
        case tPencil:
        case t3Dpoint:
        case t2DPoint:
        case tPlain:
        case tLayerROI:
        case tAxis:
        case tDynAngle:
        case tCurvedROI:
        case tTAGT:
            return YES;
        default:
            return NO;
    }
}

- (id)windowController
{
    return self.window.windowController;
}

- (BOOL)is2DViewer
{
    return NO;
}

- (void)becomeMainWindow
{
    [self.window makeKeyAndOrderFront:nil];
}

- (void)drawImage:(NSImage *)image inBounds:(NSRect)rect
{
    [image drawInRect:rect];
}

+ (NSArray *)cleanedOutDcmPixArray:(NSArray *)input
{
    return input ?: @[];
}

@end
