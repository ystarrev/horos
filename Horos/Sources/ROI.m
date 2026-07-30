/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 =========================================================================*/

#import "ROI.h"

#import "HorosUnkeyedArchiveCompatibility.h"
#import "Notifications.h"

#include <math.h>
#include <stdint.h>

#define ROIVERSION 11

static NSInteger HorosNextROIIdentifier = 1;
static NSString *HorosDefaultROIName = nil;
static CGFloat HorosROIFontHeight = 12.0;

static void HorosPostROIChange(ROI *roi)
{
    [[NSNotificationCenter defaultCenter] postNotificationName:OsirixROIChangeNotification
                                                        object:roi
                                                      userInfo:nil];
}

int spline(NSPoint *sourcePoints,
           int pointCount,
           NSPoint **destinationPoints,
           long **correspondingSegments,
           double scale)
{
    if (destinationPoints == NULL || sourcePoints == NULL || pointCount <= 0)
        return 0;

    *destinationPoints = malloc(sizeof(NSPoint) * (size_t)pointCount);
    if (*destinationPoints == NULL)
        return 0;
    memcpy(*destinationPoints, sourcePoints, sizeof(NSPoint) * (size_t)pointCount);

    if (correspondingSegments)
    {
        *correspondingSegments = malloc(sizeof(long) * (size_t)pointCount);
        if (*correspondingSegments)
            for (int index = 0; index < pointCount; ++index)
                (*correspondingSegments)[index] = index;
    }

    return pointCount;
}

@implementation ROI

@synthesize imageOrigin;
@synthesize originalIndexForAlias;
@synthesize hidden;
@synthesize locked;
@synthesize selectable;
@synthesize isAliased;
@synthesize displayCMOrPixels;
@synthesize mouseOverROI;
@synthesize name;
@synthesize comments;
@synthesize type;
@synthesize points;
@synthesize clickInTextBox;
@synthesize pix;
@synthesize curView;
@synthesize mousePosMeasure;
@synthesize parentROI;
@synthesize pixelSpacingX;
@synthesize pixelSpacingY;
@synthesize min = rmin;
@synthesize max = rmax;
@synthesize mean = rmean;
@synthesize layerReferenceFilePath;
@synthesize layerImage;
@synthesize layerPixelSpacingX;
@synthesize layerPixelSpacingY;
@synthesize textualBoxLine1;
@synthesize textualBoxLine2;
@synthesize textualBoxLine3;
@synthesize textualBoxLine4;
@synthesize textualBoxLine5;
@synthesize textualBoxLine6;
@synthesize groupID;
@synthesize isLayerOpacityConstant;
@synthesize canColorizeLayer;
@synthesize displayTextualData;

+ (void)setDefaultName:(NSString *)newName
{
    if (HorosDefaultROIName == newName)
        return;
    [HorosDefaultROIName release];
    HorosDefaultROIName = [newName copy];
}

+ (NSString *)defaultName
{
    return HorosDefaultROIName;
}

+ (void)setFontHeight:(float)height
{
    HorosROIFontHeight = MAX(height, 1.0f);
}

+ (BOOL)splineForROI
{
    return YES;
}

+ (void)loadDefaultSettings
{
}

+ (void)saveDefaultSettings
{
}

- (instancetype)init
{
    return [self initWithType:tROI :1.0f :1.0f :NSZeroPoint];
}

- (instancetype)initWithType:(ToolMode)roiType
                            :(float)spacing
                            :(NSPoint)origin
{
    return [self initWithType:roiType :spacing :spacing :origin];
}

- (instancetype)initWithType:(ToolMode)roiType
                            :(float)spacingX
                            :(float)spacingY
                            :(NSPoint)origin
{
    self = [super init];
    if (self)
    {
        uniqueID = [[NSNumber alloc] initWithInteger:HorosNextROIIdentifier++];
        points = [[NSMutableArray alloc] init];
        zPositions = [[NSMutableArray alloc] init];
        comments = [@"" retain];
        name = [(HorosDefaultROIName ?: NSLocalizedString(@"Unnamed", nil)) copy];
        type = roiType;
        pixelSpacingX = spacingX == 0.0f ? 1.0 : spacingX;
        pixelSpacingY = spacingY == 0.0f ? pixelSpacingX : spacingY;
        imageOrigin = origin;
        mode = ROI_sleep;
        selectable = YES;
        opacity = 1.0f;
        thickness = 1.0f;
        color.red = color.green = color.blue = UINT16_MAX;
        rmean = rmax = rmin = rdev = rtotal = -1.0f;
        Brmean = Brmax = Brmin = Brdev = Brtotal = -1.0f;
        mousePosMeasure = -1.0f;
        PointUnderMouse = -1;
        selectedModifyPoint = -1;
        displayTextualData = YES;
        layerPixelSpacingX = layerPixelSpacingY = 25.4 / 72.0;

        if (roiType == tPlain)
        {
            [name release];
            name = [NSLocalizedString(@"Region", nil) copy];
        }
        else if (roiType == tLayerROI)
        {
            [name release];
            name = [NSLocalizedString(@"Layer", nil) copy];
        }
        else if (roiType == tText)
        {
            [name release];
            name = [NSLocalizedString(@"Double-Click to edit", nil) copy];
        }
    }
    HorosPostROIChange(self);
    return self;
}

- (instancetype)initWithTexture:(unsigned char *)buffer
                      textWidth:(int)width
                     textHeight:(int)height
                       textName:(NSString *)roiName
                      positionX:(int)x
                      positionY:(int)y
                       spacingX:(float)spacingX
                       spacingY:(float)spacingY
                    imageOrigin:(NSPoint)origin
{
    if (width < 0 || height < 0)
        return nil;

    self = [self initWithType:tPlain :spacingX :spacingY :origin];
    if (self)
    {
        textureWidth = width;
        textureHeight = height;
        textureUpLeftCornerX = x;
        textureUpLeftCornerY = y;
        textureDownRightCornerX = x + MAX(width - 1, 0);
        textureDownRightCornerY = y + MAX(height - 1, 0);
        if (width > 0 && height > 0)
        {
            textureBuffer = malloc((size_t)width * (size_t)height);
            if (textureBuffer && buffer)
                memcpy(textureBuffer, buffer, (size_t)width * (size_t)height);
        }
        self.name = roiName;
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self == nil)
        return nil;

    uniqueID = [[NSNumber alloc] initWithInteger:HorosNextROIIdentifier++];
    PointUnderMouse = -1;
    selectedModifyPoint = -1;

    const NSInteger fileVersion = [coder versionForClassName:@"ROI"];
    points = [[coder decodeObject] mutableCopy];
    if (points == nil)
        points = [[NSMutableArray alloc] init];
    rect = NSRectFromString([coder decodeObject]);
    type = (ToolMode)[[coder decodeObject] integerValue];

    // Later OsiriX versions used values 30 and 31 for incompatible ROI types.
    if (type == 30 || type == 31)
    {
        [self release];
        return nil;
    }

    needQuartz = [[coder decodeObject] boolValue];
    thickness = [[coder decodeObject] floatValue];
    fill = [[coder decodeObject] boolValue];
    opacity = [[coder decodeObject] floatValue];
    color.red = [[coder decodeObject] unsignedShortValue];
    color.green = [[coder decodeObject] unsignedShortValue];
    color.blue = [[coder decodeObject] unsignedShortValue];
    name = [[coder decodeObject] copy];
    comments = [[coder decodeObject] copy];
    pixelSpacingX = [[coder decodeObject] doubleValue];
    imageOrigin = NSPointFromString([coder decodeObject]);
    pixelSpacingY = fileVersion >= 2 ? [[coder decodeObject] doubleValue] : pixelSpacingX;

    if (type == tPlain)
    {
        textureWidth = [[coder decodeObject] intValue];
        [coder decodeObject];
        textureHeight = [[coder decodeObject] intValue];
        [coder decodeObject];
        textureUpLeftCornerX = [[coder decodeObject] intValue];
        textureUpLeftCornerY = [[coder decodeObject] intValue];
        textureDownRightCornerX = [[coder decodeObject] intValue];
        textureDownRightCornerY = [[coder decodeObject] intValue];

        NSData *textureData = [coder decodeObject];
        if (textureWidth > 0 && textureHeight > 0)
        {
            const size_t expectedLength = (size_t)textureWidth * (size_t)textureHeight;
            textureBuffer = calloc(expectedLength, 1);
            if (textureBuffer)
                memcpy(textureBuffer, textureData.bytes, MIN(expectedLength, textureData.length));
        }
    }

    zPositions = fileVersion >= 3 ? [[coder decodeObject] mutableCopy] : [[NSMutableArray alloc] init];
    if (zPositions == nil)
        zPositions = [[NSMutableArray alloc] init];

    if (fileVersion >= 4)
    {
        offsetTextBox_x = [[coder decodeObject] floatValue];
        offsetTextBox_y = [[coder decodeObject] floatValue];
    }
    if (fileVersion >= 5)
    {
        [coder decodeObject];
        [coder decodeObject];
    }
    if (fileVersion >= 6)
    {
        groupID = [[coder decodeObject] doubleValue];
        if (type == tLayerROI)
        {
            layerImageJPEG = [[coder decodeObject] retain];
            layerImage = [[NSImage alloc] initWithData:layerImageJPEG];
        }
        textualBoxLine1 = [[coder decodeObject] copy];
        textualBoxLine2 = [[coder decodeObject] copy];
        textualBoxLine3 = [[coder decodeObject] copy];
        textualBoxLine4 = [[coder decodeObject] copy];
        textualBoxLine5 = [[coder decodeObject] copy];
    }
    if (fileVersion >= 7)
    {
        isLayerOpacityConstant = [[coder decodeObject] boolValue];
        canColorizeLayer = [[coder decodeObject] boolValue];
        layerColor = [[coder decodeObject] retain];
        displayTextualData = [[coder decodeObject] boolValue];
    }
    else
    {
        displayTextualData = YES;
    }
    if (fileVersion >= 8)
        canResizeLayer = [[coder decodeObject] boolValue];
    if (fileVersion >= 9)
    {
        selectable = [[coder decodeObject] boolValue];
        locked = [[coder decodeObject] boolValue];
    }
    else
    {
        selectable = YES;
    }
    if (fileVersion >= 10)
        isAliased = [[coder decodeObject] boolValue];
    if (fileVersion >= 11)
    {
        _isSpline = [[coder decodeObject] boolValue];
        _hasIsSpline = [[coder decodeObject] boolValue];
    }
    if (fileVersion >= 12)
        [coder decodeObject];
    if (fileVersion >= 13 && type == 31)
    {
        [coder decodeObject];
        [coder decodeObject];
    }
    if (fileVersion >= 14)
        [coder decodeObject];
    if (fileVersion >= 15)
        [coder decodeObject];

    if (name == nil)
        name = [@"" copy];
    if (comments == nil)
        comments = [@"" copy];
    mode = ROI_sleep;
    rmean = rmax = rmin = rdev = rtotal = -1.0f;
    Brmean = Brmax = Brmin = Brdev = Brtotal = -1.0f;
    mousePosMeasure = -1.0f;
    HorosPostROIChange(self);
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [ROI setVersion:ROIVERSION];

    [coder encodeObject:points];
    [coder encodeObject:NSStringFromRect(rect)];
    [coder encodeObject:@(type)];
    [coder encodeObject:@(needQuartz)];
    [coder encodeObject:@(thickness)];
    [coder encodeObject:@(fill)];
    [coder encodeObject:@(opacity)];
    [coder encodeObject:@(color.red)];
    [coder encodeObject:@(color.green)];
    [coder encodeObject:@(color.blue)];
    [coder encodeObject:name];
    [coder encodeObject:comments];
    [coder encodeObject:@(pixelSpacingX)];
    [coder encodeObject:NSStringFromPoint(imageOrigin)];
    [coder encodeObject:@(pixelSpacingY)];

    if (type == tPlain)
    {
        [coder encodeObject:@(textureWidth)];
        [coder encodeObject:@0];
        [coder encodeObject:@(textureHeight)];
        [coder encodeObject:@0];
        [coder encodeObject:@(textureUpLeftCornerX)];
        [coder encodeObject:@(textureUpLeftCornerY)];
        [coder encodeObject:@(textureDownRightCornerX)];
        [coder encodeObject:@(textureDownRightCornerY)];
        const NSUInteger byteCount = textureWidth > 0 && textureHeight > 0 ?
            (NSUInteger)textureWidth * (NSUInteger)textureHeight : 0;
        [coder encodeObject:(byteCount && textureBuffer) ?
            [NSData dataWithBytes:textureBuffer length:byteCount] : [NSData data]];
    }

    [coder encodeObject:zPositions];
    [coder encodeObject:@(offsetTextBox_x)];
    [coder encodeObject:@(offsetTextBox_y)];
    [coder encodeObject:@0];
    [coder encodeObject:@NO];
    [coder encodeObject:@(groupID)];

    if (type == tLayerROI)
    {
        [self generateEncodedLayerImage];
        [coder encodeObject:layerImageJPEG];
    }

    [coder encodeObject:textualBoxLine1];
    [coder encodeObject:textualBoxLine2];
    [coder encodeObject:textualBoxLine3];
    [coder encodeObject:textualBoxLine4];
    [coder encodeObject:textualBoxLine5];
    [coder encodeObject:@(isLayerOpacityConstant)];
    [coder encodeObject:@(canColorizeLayer)];
    [coder encodeObject:layerColor];
    [coder encodeObject:@(displayTextualData)];
    [coder encodeObject:@(canResizeLayer)];
    [coder encodeObject:@(selectable)];
    [coder encodeObject:@(locked)];
    [coder encodeObject:@(isAliased)];
    [coder encodeObject:@(_isSpline)];
    [coder encodeObject:@(_hasIsSpline)];
}

- (id)copyWithZone:(NSZone *)zone
{
    ROI *copy = [[[self class] allocWithZone:zone] initWithType:type
                                                              :(float)pixelSpacingX
                                                              :(float)pixelSpacingY
                                                              :imageOrigin];
    copy.rect = rect;
    copy.points = [[points mutableCopy] autorelease];
    copy.name = name;
    copy.comments = comments;
    copy.opacity = opacity;
    copy.thickness = thickness;
    copy.rgbcolor = color;
    copy.locked = locked;
    copy.selectable = selectable;
    copy.isAliased = isAliased;
    copy.isSpline = _isSpline;
    copy.groupID = groupID;
    copy.pix = pix;
    if (textureBuffer && textureWidth > 0 && textureHeight > 0)
        [copy setTexture:textureBuffer width:textureWidth height:textureHeight];
    return copy;
}

- (void)dealloc
{
    free(textureBuffer);
    free(textureBufferSelected);
    [points release];
    [zPositions release];
    [name release];
    [comments release];
    [pix release];
    [parentROI release];
    [uniqueID release];
    [layerReferenceFilePath release];
    [layerImage release];
    [layerImageJPEG release];
    [layerColor release];
    [textualBoxLine1 release];
    [textualBoxLine2 release];
    [textualBoxLine3 release];
    [textualBoxLine4 release];
    [textualBoxLine5 release];
    [textualBoxLine6 release];
    [super dealloc];
}

- (NSData *)data
{
    return HorosArchiveUnkeyedObject(self);
}

- (long)ROImode
{
    return mode;
}

- (void)setROIMode:(long)newMode
{
    mode = newMode;
}

- (NSRect)rect
{
    return rect;
}

- (void)setROIRect:(NSRect)newRect
{
    rect = newRect;
    HorosPostROIChange(self);
}

- (NSMutableArray *)zPositions
{
    return zPositions;
}

- (float)opacity
{
    return opacity;
}

- (void)setOpacity:(float)newOpacity
{
    [self setOpacity:newOpacity globally:YES];
}

- (void)setOpacity:(float)newOpacity globally:(BOOL)globally
{
    opacity = fmaxf(0.0f, fminf(1.0f, newOpacity));
}

- (float)thickness
{
    return thickness;
}

- (void)setThickness:(float)newThickness
{
    [self setThickness:newThickness globally:YES];
}

- (void)setThickness:(float)newThickness globally:(BOOL)globally
{
    thickness = MAX(newThickness, 0.0f);
}

- (RGBColor)rgbcolor
{
    return color;
}

- (void)setColor:(RGBColor)newColor
{
    [self setColor:newColor globally:YES];
}

- (void)setColor:(RGBColor)newColor globally:(BOOL)globally
{
    color = newColor;
}

- (NSColor *)NSColor
{
    return [NSColor colorWithCalibratedRed:(CGFloat)color.red / UINT16_MAX
                                     green:(CGFloat)color.green / UINT16_MAX
                                      blue:(CGFloat)color.blue / UINT16_MAX
                                     alpha:opacity];
}

- (void)setNSColor:(NSColor *)newColor
{
    [self setNSColor:newColor globally:YES];
}

- (void)setNSColor:(NSColor *)newColor globally:(BOOL)globally
{
    NSColor *rgb = [newColor colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (rgb == nil)
        return;
    color.red = (unsigned short)lrint(rgb.redComponent * UINT16_MAX);
    color.green = (unsigned short)lrint(rgb.greenComponent * UINT16_MAX);
    color.blue = (unsigned short)lrint(rgb.blueComponent * UINT16_MAX);
    opacity = rgb.alphaComponent;
}

- (BOOL)isSpline
{
    return _isSpline;
}

- (void)setIsSpline:(BOOL)value
{
    _hasIsSpline = YES;
    _isSpline = value;
}

- (void)setDefaultName:(NSString *)newName
{
    [ROI setDefaultName:newName];
}

- (NSString *)defaultName
{
    return [ROI defaultName];
}

- (BOOL)isValidForVolume
{
    return type == tCPolygon || type == tOPolygon || type == tPlain || type == tPencil || type == tOval;
}

- (void)prepareForRelease
{
    curView = nil;
}

- (void)updateLabelFont
{
    (void)HorosROIFontHeight;
}

- (void)setOriginAndSpacing:(float)spacing :(NSPoint)origin
{
    [self setOriginAndSpacing:spacing :spacing :origin];
}

- (void)setOriginAndSpacing:(float)spacingX :(float)spacingY :(NSPoint)origin
{
    [self setOriginAndSpacing:spacingX :spacingY :origin :YES];
}

- (void)setOriginAndSpacing:(float)spacingX
                           :(float)spacingY
                           :(NSPoint)origin
                           :(BOOL)sendNotification
{
    [self setOriginAndSpacing:spacingX :spacingY :origin :sendNotification :YES];
}

- (void)setOriginAndSpacing:(float)spacingX
                           :(float)spacingY
                           :(NSPoint)origin
                           :(BOOL)sendNotification
                           :(BOOL)inImageCheck
{
    pixelSpacingX = spacingX;
    pixelSpacingY = spacingY;
    imageOrigin = origin;
    if (sendNotification)
        HorosPostROIChange(self);
}

- (NSPoint)pointAtIndex:(NSUInteger)index
{
    return index < points.count ? [[points objectAtIndex:index] point] : NSZeroPoint;
}

- (void)setPoint:(NSPoint)point atIndex:(NSUInteger)index
{
    if (index >= points.count)
        return;
    [[points objectAtIndex:index] setPoint:point];
    HorosPostROIChange(self);
}

- (void)addPoint:(NSPoint)point
{
    [points addObject:[MyPoint point:point]];
    HorosPostROIChange(self);
}

- (void)addPointUnderMouse:(NSPoint)point scale:(float)scale
{
    [self addPoint:point];
}

+ (NSPoint)pointBetweenPoint:(NSPoint)first and:(NSPoint)second ratio:(float)ratio
{
    return NSMakePoint(first.x + (second.x - first.x) * ratio,
                       first.y + (second.y - first.y) * ratio);
}

- (NSPoint)centroid
{
    if (points.count == 0)
        return NSMakePoint(NSMidX(rect), NSMidY(rect));

    NSPoint result = NSZeroPoint;
    for (MyPoint *point in points)
    {
        result.x += point.x;
        result.y += point.y;
    }
    result.x /= points.count;
    result.y /= points.count;
    return result;
}

- (float)roiArea
{
    if (type == tOval)
        return (float)(M_PI * NSWidth(rect) * pixelSpacingX * NSHeight(rect) * pixelSpacingY / 400.0);
    if (type == tROI)
        return (float)(fabs(NSWidth(rect) * pixelSpacingX * NSHeight(rect) * pixelSpacingY) / 100.0);
    if (points.count < 3)
        return 0.0f;

    double twiceArea = 0.0;
    for (NSUInteger index = 0; index < points.count; ++index)
    {
        const NSPoint first = [[points objectAtIndex:index] point];
        const NSPoint second = [[points objectAtIndex:(index + 1) % points.count] point];
        twiceArea += first.x * second.y - second.x * first.y;
    }
    return (float)(fabs(twiceArea) * pixelSpacingX * pixelSpacingY / 200.0);
}

- (float)Length:(NSPoint)first :(NSPoint)second
{
    return [self LengthFrom:first to:second inPixel:NO];
}

- (float)LengthFrom:(NSPoint)first to:(NSPoint)second inPixel:(BOOL)inPixel
{
    const double dx = (second.x - first.x) * (inPixel ? 1.0 : pixelSpacingX);
    const double dy = (second.y - first.y) * (inPixel ? 1.0 : pixelSpacingY);
    return (float)sqrt(dx * dx + dy * dy);
}

- (float)MesureLength:(float *)pixels
{
    if (points.count < 2)
        return 0.0f;
    return [self Length:[[points objectAtIndex:0] point] :[[points objectAtIndex:1] point]];
}

- (float)Angle:(NSPoint)second :(NSPoint)vertex :(NSPoint)third
{
    const double firstAngle = atan2(second.y - vertex.y, second.x - vertex.x);
    const double secondAngle = atan2(third.y - vertex.y, third.x - vertex.x);
    return (float)(fabs(secondAngle - firstAngle) * 180.0 / M_PI);
}

- (void)roiMove:(NSPoint)offset
{
    [self roiMove:offset :YES];
}

- (void)roiMove:(NSPoint)offset :(BOOL)sendNotification
{
    rect.origin.x += offset.x;
    rect.origin.y += offset.y;
    for (MyPoint *point in points)
        [point move:offset.x :offset.y];
    if (sendNotification)
        HorosPostROIChange(self);
}

- (BOOL)valid
{
    return type == tPlain || type == tLayerROI || points.count > 0 || !NSIsEmptyRect(rect);
}

- (BOOL)needQuartz
{
    return NO;
}

- (void)recompute
{
    rtotal = Brtotal = -1.0f;
}

- (void)drawROI:(float)scaleValue
               :(float)offsetX
               :(float)offsetY
               :(float)spacingX
               :(float)spacingY
{
}

- (void)drawROIWithScaleValue:(float)scaleValue
                      offsetX:(float)offsetX
                      offsetY:(float)offsetY
                pixelSpacingX:(float)spacingX
                pixelSpacingY:(float)spacingY
          highlightIfSelected:(BOOL)highlight
                    thickness:(float)drawThickness
           prepareTextualData:(BOOL)prepareTextualData
{
}

- (void)rotate:(float)angle :(NSPoint)center
{
    const double radians = angle * M_PI / 180.0;
    const double cosine = cos(radians);
    const double sine = sin(radians);
    for (MyPoint *point in points)
    {
        const double x = point.x - center.x;
        const double y = point.y - center.y;
        point.point = NSMakePoint(center.x + x * cosine - y * sine,
                                  center.y + x * sine + y * cosine);
    }
    HorosPostROIChange(self);
}

- (void)flipVertically:(BOOL)vertically
{
    const NSPoint center = [self centroid];
    for (MyPoint *point in points)
        point.point = vertically ? NSMakePoint(point.x, 2.0 * center.y - point.y)
                                 : NSMakePoint(2.0 * center.x - point.x, point.y);
    HorosPostROIChange(self);
}

- (BOOL)canResize
{
    return YES;
}

- (void)resize:(float)factor :(NSPoint)center
{
    for (MyPoint *point in points)
        point.point = NSMakePoint(center.x + (point.x - center.x) * factor,
                                  center.y + (point.y - center.y) * factor);
    rect.origin = NSMakePoint(center.x + (rect.origin.x - center.x) * factor,
                              center.y + (rect.origin.y - center.y) * factor);
    rect.size.width *= factor;
    rect.size.height *= factor;
    HorosPostROIChange(self);
}

- (BOOL)reduceTextureIfPossible
{
    return NO;
}

- (void)textureBufferHasChanged
{
    HorosPostROIChange(self);
}

- (void)setCanResizeLayer:(BOOL)value
{
    canResizeLayer = value;
}

- (void)generateEncodedLayerImage
{
    if (layerImageJPEG == nil && layerImage)
        layerImageJPEG = [[layerImage TIFFRepresentation] retain];
}

- (NSPoint)lowerRightPoint
{
    return NSMakePoint(NSMaxX(rect), NSMaxY(rect));
}

- (NSPoint)clickPoint
{
    return clickPoint;
}

- (NSMutableArray *)splinePoints
{
    return points;
}

- (NSMutableArray *)splinePoints:(float)scale
{
    return points;
}

- (NSMutableArray *)splinePoints:(float)scale correspondingSegmentArray:(NSMutableArray **)segments
{
    if (segments)
        *segments = nil;
    return points;
}

- (NSMutableArray *)splineZPositions
{
    return zPositions;
}

- (void)setTexture:(unsigned char *)texture width:(int)width height:(int)height
{
    free(textureBuffer);
    textureBuffer = NULL;
    textureWidth = MAX(width, 0);
    textureHeight = MAX(height, 0);
    if (texture && textureWidth > 0 && textureHeight > 0)
    {
        const size_t byteCount = (size_t)textureWidth * (size_t)textureHeight;
        textureBuffer = malloc(byteCount);
        if (textureBuffer)
            memcpy(textureBuffer, texture, byteCount);
    }
    textureDownRightCornerX = textureUpLeftCornerX + textureWidth;
    textureDownRightCornerY = textureUpLeftCornerY + textureHeight;
}

- (int)textureWidth
{
    return textureWidth;
}

- (int)textureHeight
{
    return textureHeight;
}

- (int)textureDownRightCornerX
{
    return textureDownRightCornerX;
}

- (int)textureDownRightCornerY
{
    return textureDownRightCornerY;
}

- (int)textureUpLeftCornerX
{
    return textureUpLeftCornerX;
}

- (int)textureUpLeftCornerY
{
    return textureUpLeftCornerY;
}

- (unsigned char *)textureBuffer
{
    return textureBuffer;
}

- (void)setTextBoxOffset:(NSPoint)offset
{
    offsetTextBox_x = offset.x;
    offsetTextBox_y = offset.y;
}

- (void)setRoiView:(DCMView *)view
{
    curView = view;
}

@end
