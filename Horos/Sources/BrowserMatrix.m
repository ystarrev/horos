#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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

#import "BrowserMatrix.h"
#import "BrowserController.h"
#import "DCMPix.h"
#import "N2Stuff.h"
#import "N2Debug.h"
#import "DicomImage.h"

@implementation BrowserMatrix

- (void)print:(id)sender
{
    id controller = self.window.windowController;
    if ([controller isKindOfClass:[BrowserController class]])
    {
        [controller printDatabaseSelection:self];
        return;
    }
    [super print:sender];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent
{
	return YES;
}

- (id) selectedCell
{
	NSButtonCell *s = [super selectedCell];
	
	if( [s isTransparent])
	{
		for( NSButtonCell *c in [super selectedCells])
		{
			if( [c isTransparent] == NO)
				return c;
		}
	}
	
	return s;
}

- (NSArray*) selectedCells
{
	NSMutableArray *m = [NSMutableArray arrayWithArray: [super selectedCells]];
	NSMutableArray *r = [NSMutableArray arrayWithCapacity: [m count]];
	
	for( NSButtonCell *c in m)
	{
		if( [c isTransparent] == NO)
			[r addObject: c];
	}
	
	return r;
} 

- (void) selectCellEvent:(NSEvent*) theEvent
{
	NSInteger row, column;
 
	if( [self getRow: &row column: &column forPoint: [self convertPoint:[theEvent locationInWindow] fromView:nil]])
	{
        NSButtonCell *cell = [self cellAtRow:row column:column];
        if (cell.isTransparent || !cell.isEnabled)
            return;
		if( ([theEvent modifierFlags] & NSEventModifierFlagShift) && self.selectedCells.count > 0 )
		{
			NSInteger start = [[self cells] indexOfObject: [[self selectedCells] objectAtIndex: 0]];
			NSInteger end = [[self cells] indexOfObject: [self cellAtRow:row column:column]];
			
			[self setSelectionFrom:start to:end anchor:start highlight: NO];
			
		}
		else if( [theEvent modifierFlags] & NSEventModifierFlagCommand )
		{
			NSInteger end = [[self cells] indexOfObject: [self cellAtRow:row column:column]];
			
			if( [[self selectedCells] containsObject:[self cellAtRow:row column:column]])
				[self setSelectionFrom:end to:end anchor:end highlight: NO];
			else
				[self setSelectionFrom:end to:end anchor:end highlight: NO];

		}
		else
		{
			if( ![self.selectedCells containsObject:cell]) [self selectCellAtRow: row column:column];
		}
	}
}

- (void) startDrag:(NSEvent *) event
{
	@try {
	
	NSArray *cells = [self selectedCells];
	
	if( [cells count])
	{
        NSArray *subArray = cells;
        
        if( subArray.count > 20)
            subArray = [cells subarrayWithRange: NSMakeRange( 0, 20)];
        
		int i, width = 0;
		NSImage	*firstCell = [[subArray objectAtIndex: 0] image];
		
		#define MARGIN 3
		
		width += MARGIN;
		for( i = 0; i < [subArray count]; i++)
		{
			width += [[[subArray objectAtIndex: i] image] size].width;
			width += MARGIN;
		}
		
		NSImage *thumbnail = [NSImage imageWithSize:NSMakeSize(width, 70+6) flipped:NO drawingHandler:^BOOL(NSRect destinationRect) {
			[[NSColor grayColor] set];
			NSRectFill(destinationRect);
			
			CGFloat drawX = MARGIN;
			for(NSUInteger drawIndex = 0; drawIndex < [subArray count]; drawIndex++)
			{
				NSRectFill(NSMakeRect(drawX, 0, [firstCell size].width, [firstCell size].height));
				
				NSImage	*im = [[subArray objectAtIndex:drawIndex] image];
				[im drawAtPoint:NSMakePoint(drawX, 3) fromRect:NSMakeRect(0,0,[im size].width,[im size].height) operation:NSCompositingOperationCopy fraction:0.8];
			
				drawX += [im size].width + MARGIN;
			}
			return YES;
		}];
		
        NSMutableArray* objects = [NSMutableArray array];
        NSArray *matrixObjects = [[BrowserController currentBrowser] matrixViewArray];
        for( i = 0; i < [cells count]; i++)
        {
            NSButtonCell *cell = [cells objectAtIndex:i];
            if (cell.isEnabled && cell.tag >= 0 && cell.tag < matrixObjects.count)
                [objects addObject:matrixObjects[cell.tag]];
        }
        id<NSPasteboardWriting> promise = [[BrowserController currentBrowser] filePromiseForDatabaseObjects:objects];
        if (!promise) return;
        
        NSDraggingItem* di = [[[NSDraggingItem alloc] initWithPasteboardWriter:promise] autorelease];
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        [di setDraggingFrame:NSMakeRect(p.x-thumbnail.size.width/2, p.y-thumbnail.size.height/2, thumbnail.size.width, thumbnail.size.height) contents:thumbnail];
        
        NSDraggingSession* session = [self beginDraggingSessionWithItems:@[di] event:event source:self];
        session.animatesToStartingPositionsOnCancelOrFail = YES;
	}
	
	} @catch( NSException *e) {
		N2LogException( e);
	}
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextOutsideApplication ? NSDragOperationCopy : NSDragOperationEvery;
}


- (void) startDragJPEG:(NSEvent *) event
{
    NSInteger row, column;
    if (![self getRow:&row column:&column forPoint:[self convertPoint:event.locationInWindow fromView:nil]])
        return;
    NSButtonCell *selectedButtonCell = [self cellAtRow:row column:column];
    NSArray *objects = [[BrowserController currentBrowser] matrixViewArray];
    if (selectedButtonCell.isTransparent || !selectedButtonCell.isEnabled || selectedButtonCell.tag < 0 || selectedButtonCell.tag >= objects.count)
        return;
    [self selectCellAtRow:row column:column];
    [[BrowserController currentBrowser] matrixPressed:self];
    NSManagedObject *selectedObject = objects[selectedButtonCell.tag];
    @try {
        NSImage *image = [selectedButtonCell image];
        int thumbnailWidth = [image size].width + 6;
        NSImage *thumbnail = [NSImage imageWithSize:NSMakeSize(thumbnailWidth, 70+6) flipped:NO drawingHandler:^BOOL(NSRect destinationRect) {
            [[NSColor grayColor] set];
            NSRectFill(destinationRect);
            NSRectFill(NSMakeRect(3, 0, [image size].width, [image size].height));
            [image drawAtPoint:NSMakePoint(3, 3) fromRect:NSMakeRect(0,0,[image size].width,[image size].height) operation:NSCompositingOperationCopy fraction:0.8];
            return YES;
        }];

        id<NSPasteboardWriting> promise = nil;
        DicomImage *selectedImage = [selectedObject isKindOfClass:[DicomImage class]] ? (DicomImage *)selectedObject : nil;
        if (selectedImage.isImageStorage.boolValue && ![BrowserController isReportSeriesForFileExport:selectedImage.series]) {
            DCMPix *previewPix = [[BrowserController currentBrowser] previewPix:selectedButtonCell.tag];
            if (!previewPix || previewPix.notAbleToLoadImage) return;
            NSArray *representations = [[previewPix image] representations];
            NSData *jpeg = [NSBitmapImageRep representationOfImageRepsInArray:representations usingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor: @0.9}];
            NSString *name = [NSString stringWithFormat:@"%@.%ld.jpg", [(DicomImage *)selectedObject completePath].lastPathComponent, (long)previewPix.frameNo];
            promise = [[BrowserController currentBrowser] filePromiseForJPEGData:jpeg name:name];
        } else
            promise = [[BrowserController currentBrowser] filePromiseForDatabaseObjects:@[selectedObject] asJPEG:YES];
        if (!promise) return;

        NSDraggingItem *di = [[[NSDraggingItem alloc] initWithPasteboardWriter:promise] autorelease];
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        [di setDraggingFrame:NSMakeRect(p.x-thumbnail.size.width/2, p.y-thumbnail.size.height/2, thumbnail.size.width, thumbnail.size.height) contents:thumbnail];

        NSDraggingSession *session = [self beginDraggingSessionWithItems:@[di] event:event source:self];
        session.animatesToStartingPositionsOnCancelOrFail = YES;
    } @catch (NSException *e) {
        N2LogException(e);
    }
}

- (void) mouseDown:(NSEvent *)event
{
    [self.window makeFirstResponder:self];
    NSInteger row, column;
    if (![self getRow:&row column:&column forPoint:[self convertPoint:event.locationInWindow fromView:nil]])
    {
        [super mouseDown:event];
        return;
    }
    NSButtonCell *cell = [self cellAtRow:row column:column];
    if (cell.isTransparent || !cell.isEnabled || event.clickCount > 1)
    {
        [super mouseDown:event];
        return;
    }

    NSEventMask mask = NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged;
    while (YES)
    {
        // Leave mouse-up queued so NSMatrix can handle ordinary/modifier clicks
        // with the original mouse-down event, including its click count.
        NSEvent *nextEvent = [self.window nextEventMatchingMask:mask untilDate:[NSDate distantFuture]
                                                       inMode:NSEventTrackingRunLoopMode dequeue:NO];
        if (!nextEvent)
            return;
        if (nextEvent.type == NSEventTypeLeftMouseUp)
        {
            [super mouseDown:event];
            return;
        }
        [self.window nextEventMatchingMask:mask untilDate:[NSDate distantPast]
                                   inMode:NSEventTrackingRunLoopMode dequeue:YES];
        CGFloat dx = nextEvent.locationInWindow.x - event.locationInWindow.x;
        CGFloat dy = nextEvent.locationInWindow.y - event.locationInWindow.y;
        if (dx * dx + dy * dy < 16.0)
            continue;

        if (event.modifierFlags & NSEventModifierFlagOption)
            [self startDragJPEG:event];
        else
        {
            if (![self.selectedCells containsObject:cell])
                [self selectCellEvent:event];
            [self startDrag:nextEvent];
        }
        return;
    }
}

- (void) rightMouseDown:(NSEvent *)theEvent
{
	[self selectCellEvent: theEvent];
	
	[[BrowserController currentBrowser] matrixPressed: self];
	
	[super rightMouseDown: theEvent];
 }

@end
