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
#import "DCMPix.h"
#import "DCMView.h"
#import "Notifications.h"
#import <MetalKit/MetalKit.h>
#import "Horos-Swift.h"

@class PreviewView;

@interface PreviewAnnotationOverlayView : NSView
@property(nonatomic, assign) PreviewView *owner;
@end

@implementation PreviewView
{
    MetalPreviewImageView *_metalView;
    NSView *_annotationOverlay;
    NSMutableArray *_dcmPixList;
    NSArray *_dcmFilesList;
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
    [self addSubview:_annotationOverlay];
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
    [_metalView updatePixList:safePixels firstImage:firstImage resetWindowLevel:reset];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void) setIndex:(short)index
{
    DCMPix *pix = nil;
    if (_dcmPixList && index >= 0 && index < [_dcmPixList count])
        pix = [_dcmPixList objectAtIndex:index];

    [_metalView updateCurrentPix:pix index:index resetWindowLevel:NO];
    [_annotationOverlay setNeedsDisplay:YES];
}

- (void) setIndexWithReset:(short)index :(BOOL)sizeToFit
{
    DCMPix *pix = nil;
    if (_dcmPixList && index >= 0 && index < [_dcmPixList count])
        pix = [_dcmPixList objectAtIndex:index];

    [_metalView updateCurrentPix:pix index:index resetWindowLevel:NO];
    if (sizeToFit)
        [_metalView resetViewTransform];
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
            [primary appendFormat:@"Im: %ld/%lu", (long)_metalView.currentIndex + 1, (unsigned long)_dcmPixList.count];
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
