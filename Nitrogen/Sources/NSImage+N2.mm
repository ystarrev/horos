/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#import "NSImage+N2.h"
#include <algorithm>
#include <cmath>
#import <Accelerate/Accelerate.h>
#import "N2Operators.h"
#import "NSColor+N2.h"
#import "N2Debug.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CIFilterBuiltins.h>

static CIContext* N2ExportImageContext()
{
    static CIContext* context = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Reuse compiled kernels without retaining intermediates from every movie frame.
        context = [[CIContext alloc] initWithOptions:@{kCIContextCacheIntermediates: @NO}];
    });
    return context;
}

@implementation N2Image
@synthesize inchSize = _inchSize, portion = _portion;

-(id)initWithContentsOfFile:(NSString*)path {
	self = [super initWithContentsOfFile:path];
	NSSize size = [self size];
	_inchSize = NSMakeSize(size.width/72, size.height/72);
	_portion.size = NSMakeSize(1,1);
	return self;
}

-(id)initWithSize:(NSSize)size inches:(NSSize)inches {
	self = [super initWithSize:size];
	_inchSize = inches;
	return self;
}

-(id)initWithSize:(NSSize)size inches:(NSSize)inches portion:(NSRect)portion {
	self = [self initWithSize:size inches:inches];
	_portion = portion;
	return self;
}

-(NSSize)originalInchSize {
	return _inchSize/_portion.size;
}

-(NSPoint)convertPointFromPageInches:(NSPoint)p {
	return (p-_portion.origin*[self originalInchSize])*[self resolution];
}

-(void)setSize:(NSSize)size {
	NSSize oldSize = [self size];
	if (oldSize.width > 0 && oldSize.height > 0)
		_inchSize = NSMakeSize(_inchSize.width/oldSize.width*size.width, _inchSize.height/oldSize.height*size.height);
	[super setSize:size];
}

-(N2Image*)crop:(NSRect)cropRect {
	NSSize size = [self size];
	
	NSRect portion;
	portion.size = _portion.size*(cropRect.size/size);// NSMakeSize(_portion.size.width*(cropRect.size.width/size.width), _portion.size.height*(cropRect.size.height/size.height));
	portion.origin = _portion.origin+_portion.size*(cropRect.origin/size);//, _portion.origin.y+_portion.size.height*(cropRect.origin.y/size.height));
	
	N2Image* croppedImage = [[N2Image alloc] initWithSize:cropRect.size inches:NSMakeSize(_inchSize.width/size.width*cropRect.size.width, _inchSize.height/size.height*cropRect.size.height) portion:portion];
	NSImage *contents = [NSImage imageWithSize:cropRect.size flipped:NO drawingHandler:^BOOL(NSRect destinationRect) {
        [self drawInRect:destinationRect fromRect:cropRect operation:NSCompositingOperationSourceOver fraction:1.0];
        return YES;
    }];
	for (NSImageRep *representation in [contents representations])
		[croppedImage addRepresentation:representation];
	
	return [croppedImage autorelease];
}

-(float)resolution {
	NSSize size = [self size];
	return (size.width+size.height)/(_inchSize.width+_inchSize.height);
}

@end


@implementation NSImage (N2)

-(NSImage*)shadowImage
{
	return [NSImage imageWithSize:[self size] flipped:NO drawingHandler:^BOOL(NSRect destinationRect) {
		[self drawInRect:destinationRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        [[NSColor colorWithCalibratedWhite:0 alpha:0.5] set];
        NSRectFillUsingOperation(destinationRect, NSCompositingOperationSourceAtop);
		return YES;
	}];
}

- (void)flipImageHorizontally {
	NSSize imageSize = [self size];
	// bitmap init
	NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithData:[self TIFFRepresentation]];
	// flip
	vImage_Buffer src, dest;
	src.height = dest.height = bitmap.pixelsHigh;
	src.width = dest.width = bitmap.pixelsWide;
	src.rowBytes = dest.rowBytes = [bitmap bytesPerRow];
	src.data = dest.data = [bitmap bitmapData];
	vImageHorizontalReflect_ARGB8888(&src, &dest, 0L);
	[bitmap setSize:imageSize];
	NSArray *oldRepresentations = [[self representations] copy];
	for (NSImageRep *representation in oldRepresentations)
		[self removeRepresentation:representation];
	[oldRepresentations release];
	[self addRepresentation:bitmap];
	[self setSize:imageSize];
	// release
	[bitmap release];
}

-(NSRect)boundingBoxSkippingColor:(NSColor*)color inRect:(NSRect)box {
	if (box.size.width < 0) {
		box.origin.x += box.size.width;
		box.size.width = -box.size.width;
	}
	if (box.size.height < 0) {
		box.origin.y += box.size.height;
		box.size.height = -box.size.height;
	}
	
	NSSize size = [self size];
	
	if (box.origin.x < 0) {
		box.size.width += box.origin.x;
		box.origin.x = 0;
	}
	if (box.origin.y < 0) {
		box.size.height += box.origin.y;
		box.origin.y = 0;
	}
	if (box.origin.x+box.size.width > size.width)
		box.size.width = size.width-box.origin.x;
	if (box.origin.y+box.size.height > size.height)
		box.size.height = size.height-box.origin.y;
	
//	if (![self isFlipped])
		box.origin.y = size.height-box.origin.y-box.size.height;
	
	NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithData:[self TIFFRepresentation]];
	uint8* data = [bitmap bitmapData];
	
	color = [color colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
	NSInteger componentsCount = [color numberOfComponents];
	CGFloat *components = (CGFloat *)malloc(componentsCount * sizeof(CGFloat));
	if (components == NULL) {
		[bitmap release];
		return box;
	}
	[color getComponents:components];
	
	const size_t rowBytes = [bitmap bytesPerRow], pixelBytes = [bitmap bitsPerPixel]/8;
#define P(x,y) (y*rowBytes+x*pixelBytes)

	int x, y;
#define Match(x,y) ( (data[P(x,y)] == data[P(x,y)+3]*components[0]) && (data[P(x,y)+1] == data[P(x,y)+3]*components[1]) && (data[P(x,y)+2] == data[P(x,y)+3]*components[2]) )
	
	// change origin.x
	for (x = box.origin.x; x < box.origin.x+box.size.width; ++x)
		for (y = box.origin.y; y <= box.origin.y+box.size.height; ++y)
			if (!Match(x,y))
				goto end_origin_x;
end_origin_x:
	if (x < box.origin.x+box.size.width) {
		box.size.width -= x-box.origin.x;
		box.origin.x = x;
	}
	
	// change origin.y
	for (y = box.origin.y; y < box.origin.y+box.size.height; ++y)
		for (x = box.origin.x; x <= box.origin.x+box.size.width; ++x)
			if (!Match(x,y))
				goto end_origin_y;
end_origin_y:
	if (y < box.origin.y+box.size.height) {
		box.size.height -= y-box.origin.y;
		box.origin.y = y;
	}
	
	// change size.width
	for (x = box.origin.x+box.size.width-1; x >= box.origin.x; --x)
		for (y = box.origin.y; y <= box.origin.y+box.size.height; ++y)
			if (!Match(x,y))
				goto end_size_x;
end_size_x:
	if (x >= box.origin.x)
		box.size.width = x-box.origin.x+1;
	
	// change size.height
	for (y = box.origin.y+box.size.height-1; y >= box.origin.y; --y)
		for (x = box.origin.x; x <= box.origin.x+box.size.width; ++x)
			if (!Match(x,y))
				goto end_size_y;
end_size_y:
	if (y >= box.origin.y)
		box.size.height = y-box.origin.y+1;
	
	free(components);
	[bitmap release];
	
	//if (![self isFlipped])
		box.origin.y = size.height-box.origin.y-box.size.height;
	
	return box;
	
#undef Match
#undef P
}

-(NSRect)boundingBoxSkippingColor:(NSColor*)color {
	NSSize imageSize = [self size];
	return [self boundingBoxSkippingColor:color inRect:NSMakeRect(0, 0, imageSize.width, imageSize.height)];
}

-(NSImage*)imageWithHue:(CGFloat)hue {
	NSImageRep *rep = [NSCIImageRep imageRepWithCIImage: [[CIFilter filterWithName:@"CIHueAdjust" keysAndValues:@"inputAngle", [NSNumber numberWithFloat: hue*2*M_PI] , @"inputImage", [CIImage imageWithData:[self TIFFRepresentation]], nil] valueForKey:@"outputImage"]];
	NSImage *image = [[NSImage alloc] initWithSize:[rep size]];
	[image addRepresentation:rep];
	return [image autorelease];
}

-(NSImage*)imageInverted {
    CIFilter *invert = [CIFilter filterWithName: @"CIColorMatrix"];
    
    [invert setDefaults];
    [invert setValue: [CIImage imageWithData:[self TIFFRepresentation]] forKey: kCIInputImageKey];
    [invert setValue: [CIVector vectorWithX: -1 Y:0 Z:0] forKey: @"inputRVector"];
    [invert setValue: [CIVector vectorWithX: 0 Y:-1 Z:0] forKey: @"inputGVector"];
    [invert setValue: [CIVector vectorWithX: 0 Y:0 Z:-1] forKey: @"inputBVector"];
    [invert setValue: [CIVector vectorWithX: 0.9 Y:0.9 Z:0.9] forKey:@"inputBiasVector"];
    
	NSImageRep *rep = [NSCIImageRep imageRepWithCIImage: [invert valueForKey:@"outputImage"]];
	NSImage *image = [[NSImage alloc] initWithSize:[rep size]];
	[image addRepresentation:rep];
	return [image autorelease];
}

-(NSSize)sizeByScalingProportionallyToSize:(NSSize)targetSize {
    return N2ProportionallyScaleSize(self.size, targetSize);
}

-(NSSize)sizeByScalingDownProportionallyToSize:(NSSize)targetSize {
    NSSize imageSize = self.size;
	NSSize outSize = [self sizeByScalingProportionallyToSize:targetSize];
    return outSize.width < imageSize.width? outSize : imageSize;
}

- (NSImage*)imageByScalingProportionallyUsingNSImage:(float)ratio
{
    return [self imageByScalingProportionallyToSizeUsingNSImage: NSMakeSize( self.size.width*ratio, self.size.height*ratio)];
}

- (NSImage*)imageByScalingProportionallyToSizeUsingNSImage:(NSSize)targetSize
{
    @try {
        if (targetSize.width > 0 && targetSize.height > 0)
        {
            NSPoint thumbnailPoint = NSZeroPoint;
            
            NSSize imageSize = [self size];
            float width  = imageSize.width;
            float height = imageSize.height;
            float targetWidth  = targetSize.width;
            float targetHeight = targetSize.height;
            float scaledWidth  = targetWidth;
            float scaledHeight = targetHeight;
            
            if( NSEqualSizes( imageSize, targetSize) == NO)
            {
                float widthFactor  = targetWidth / width;
                float heightFactor = targetHeight / height;
                float scaleFactor  = 0.0;
                
                
                if ( widthFactor < heightFactor )
                    scaleFactor = widthFactor;
                else
                    scaleFactor = heightFactor;
                
                scaledWidth  = width  * scaleFactor;
                scaledHeight = height * scaleFactor;
                
                if ( widthFactor < heightFactor )
                    thumbnailPoint.y = (targetHeight - scaledHeight) * 0.5;
                
                else if ( widthFactor > heightFactor )
                    thumbnailPoint.x = (targetWidth - scaledWidth) * 0.5;
            }
            
            NSRect thumbnailRect;
            thumbnailRect.origin = thumbnailPoint;
            thumbnailRect.size.width = scaledWidth;
            thumbnailRect.size.height = scaledHeight;

			return [NSImage imageWithSize:targetSize flipped:NO drawingHandler:^BOOL(NSRect destinationRect) {
				[[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
				[self drawInRect:thumbnailRect
						 fromRect:NSZeroRect
						operation:NSCompositingOperationCopy
						 fraction:1.0];
				return YES;
			}];
        }
    }
    @catch (NSException *exception) {
        N2LogException( exception);
    }
    return self;
}

- (NSImage*)imageByScalingProportionallyToSize:(NSSize)targetSize
{
    if (!std::isfinite(targetSize.width) || !std::isfinite(targetSize.height) ||
        targetSize.width <= 0 || targetSize.height <= 0)
        return nil;

    NSImage* result = nil;
    @autoreleasepool {
        CGImageRef sourceCGImage = nil;
        CGImageRef outputCGImage = nil;
        CGColorSpaceRef colorSpace = nil;
        @try {
            NSSize imageSize;
            // Only snapshot acquisition needs the source-image lock, not GPU rendering.
            @synchronized(self) {
                if (!self.isValid) return nil;
                imageSize = self.size;
                if (!std::isfinite(imageSize.width) || !std::isfinite(imageSize.height) ||
                    imageSize.width <= 0 || imageSize.height <= 0)
                    return nil;
                NSRect sourceRect = NSMakeRect(0, 0, imageSize.width, imageSize.height);
                sourceCGImage = CGImageRetain([self CGImageForProposedRect:&sourceRect context:nil hints:nil]);
            }
            if (!sourceCGImage) return nil;

            // Export dimensions are pixels, independent of the display's backing scale.
            NSSize pixelSize = NSMakeSize(std::ceil(targetSize.width), std::ceil(targetSize.height));
            CGFloat fit = std::min(pixelSize.width / imageSize.width, pixelSize.height / imageSize.height);
            NSSize contentSize = NSMakeSize(imageSize.width * fit, imageSize.height * fit);
            CGFloat scaleY = contentSize.height / CGImageGetHeight(sourceCGImage);
            CGFloat scaleX = contentSize.width / CGImageGetWidth(sourceCGImage);
            float scale = scaleY;
            float aspectRatio = scaleX / scaleY;
            if (!std::isfinite(scale) || !std::isfinite(aspectRatio) || scale <= 0 || aspectRatio <= 0)
                return nil;

            CIFilter<CILanczosScaleTransform>* filter = [CIFilter lanczosScaleTransformFilter];
            filter.inputImage = [[CIImage imageWithCGImage:sourceCGImage] imageByClampingToExtent];
            filter.scale = scale;
            filter.aspectRatio = aspectRatio;
            CGRect contentRect = CGRectMake(0, 0, contentSize.width, contentSize.height);
            CIImage* content = [filter.outputImage imageByCroppingToRect:contentRect];
            content = [content imageByApplyingTransform:CGAffineTransformMakeTranslation(
                (pixelSize.width - contentSize.width) * 0.5, (pixelSize.height - contentSize.height) * 0.5)];
            if (!content) return nil;

            CGRect canvasRect = CGRectMake(0, 0, pixelSize.width, pixelSize.height);
            CIImage* background = [[CIImage imageWithColor:CIColor.clearColor] imageByCroppingToRect:canvasRect];
            CIImage* output = [content imageByCompositingOverImage:background];
            CGColorSpaceRef sourceColorSpace = CGImageGetColorSpace(sourceCGImage);
            colorSpace = sourceColorSpace && CGColorSpaceGetModel(sourceColorSpace) == kCGColorSpaceModelRGB
                ? CGColorSpaceRetain(sourceColorSpace) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            outputCGImage = [N2ExportImageContext() createCGImage:output fromRect:canvasRect
                                                         format:kCIFormatRGBA8 colorSpace:colorSpace deferred:NO];
            if (outputCGImage)
                result = [[NSImage alloc] initWithCGImage:outputCGImage size:targetSize];
        } @catch (NSException* exception) {
            N2LogException(exception);
        } @finally {
            CGImageRelease(outputCGImage);
            CGImageRelease(sourceCGImage);
            CGColorSpaceRelease(colorSpace);
        }
    }
    return [result autorelease];
}

@end
