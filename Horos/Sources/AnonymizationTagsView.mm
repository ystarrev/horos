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


#import "AnonymizationTagsView.h"
#import "DCMAttributeTag.h"
#import "N2HighlightImageButtonCell.h"
#import "AnonymizationViewController.h"
#import "N2TextField.h"
#import "DCMTagForNameDictionary.h"
#include <cmath>

@implementation AnonymizationTagsView

-(NSString*)activeSearchQuery {
	NSText *editor = [dcmTagsSearchField currentEditor];
	if (editor)
		return [editor string];
	return [dcmTagsSearchField stringValue];
}

-(void)restoreSearchFieldFocus {
	[self.window makeFirstResponder:dcmTagsSearchField];
	NSText *editor = [dcmTagsSearchField currentEditor];
	if (editor) {
		NSUInteger length = [[editor string] length];
		[editor setSelectedRange:NSMakeRange(length, 0)];
	}
}

-(id)initWithFrame:(NSRect)frameRect {
	self = [super initWithFrame:frameRect];
	
	viewGroups = [[NSMutableArray alloc] init];
	intercellSpacing = NSMakeSize(13,1);
	
	dcmTagsSearchField = [[NSTextField alloc] initWithFrame:NSZeroRect];
	[dcmTagsSearchField.cell setControlSize:NSMiniControlSize];
	[dcmTagsSearchField setFont:[NSFont labelFontOfSize:[NSFont smallSystemFontSize]-2]];
	dcmTagsSearchField.delegate = self;
	[dcmTagsSearchField.cell setPlaceholderString:NSLocalizedString(@"Search DICOM tags...", NULL)];
	[self addSubview:dcmTagsSearchField];

	NSScrollView* scrollView = [[[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 320, 220)] autorelease];
	scrollView.hasVerticalScroller = YES;
	scrollView.borderType = NSNoBorder;
	scrollView.drawsBackground = NO;

	dcmTagsTableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
	dcmTagsTableView.headerView = nil;
	dcmTagsTableView.dataSource = self;
	dcmTagsTableView.delegate = self;
	dcmTagsTableView.target = self;
	dcmTagsTableView.doubleAction = @selector(addButtonAction:);
	dcmTagsTableView.rowHeight = 20;
	dcmTagsTableView.intercellSpacing = NSMakeSize(0, 1);
	dcmTagsTableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
	dcmTagsTableView.focusRingType = NSFocusRingTypeNone;
	[dcmTagsTableView addTableColumn:[[[NSTableColumn alloc] initWithIdentifier:@"tag"] autorelease]];
	[[dcmTagsTableView tableColumns][0] setWidth:320];
	scrollView.documentView = dcmTagsTableView;

	NSViewController* popoverController = [[[NSViewController alloc] init] autorelease];
	popoverController.view = scrollView;
	dcmTagsPopover = [[NSPopover alloc] init];
	dcmTagsPopover.behavior = NSPopoverBehaviorTransient;
	dcmTagsPopover.contentSize = scrollView.frame.size;
	dcmTagsPopover.contentViewController = popoverController;

	dcmTagNameSelected = nil;

	dcmTagNamesAll = [[[[DCMTagForNameDictionary sharedTagForNameDictionary] allKeys] sortedArrayUsingSelector:@selector(compare:)] retain];
	dcmTagNamesFiltered = [dcmTagNamesAll retain];
	
	NSButtonCell* addButtonCell = [[N2HighlightImageButtonCell alloc] initWithImage:[NSImage imageNamed:@"PlusButton"]];
	dcmTagAddButton = [[NSButton alloc] initWithFrame:NSZeroRect];
	dcmTagAddButton.cell = addButtonCell;
	[addButtonCell release];
	dcmTagAddButton.target = self;
	dcmTagAddButton.action = @selector(addButtonAction:);
	[self addSubview:dcmTagAddButton];
	
	return self;
}

-(NSArray*)groupForObject:(id)object {
	for (NSArray* group in viewGroups)
		for (id obj in group)
			if (object == obj || [obj isEqual:object])
				return group;
	return NULL;
}

-(void)addButtonAction:(NSButton*)sender {
	if (!dcmTagNameSelected)
		[self updateFilteredTagsForQuery:[self activeSearchQuery] autoSelect:YES];
	if (!dcmTagNameSelected)
		return;

	DCMAttributeTag* tag = [DCMAttributeTag tagWithName:dcmTagNameSelected];
	if (!tag)
		return;

	[anonymizationViewController addTag:tag];
	[[anonymizationViewController.tagsView checkBoxForObject:tag] setState:NSControlStateValueOn];
	[self.window makeFirstResponder:[anonymizationViewController.tagsView textFieldForObject:tag]];
	[dcmTagNameSelected release];
	dcmTagNameSelected = nil;
	[dcmTagsPopover close];
	[dcmTagsSearchField abortEditing];
	[dcmTagsSearchField setObjectValue:nil];
	[dcmTagsSearchField setStringValue:@""];
	[self updateFilteredTagsForQuery:@"" autoSelect:NO];
	[dcmTagsTableView reloadData];
}

-(void)rmButtonAction:(NSButton*)sender {
	[anonymizationViewController removeTag:[[self groupForObject:sender] objectAtIndex:3]];
}

-(void)awakeFromNib {
	[self resizeSubviewsWithOldSize:self.frame.size];
}

-(BOOL)isFlipped {
	return YES;
}

	-(void)dealloc {
	//	NSLog(@"AnonymizationTagsView dealloc");
		[dcmTagsSearchField release];
		[dcmTagsPopover release];
		[dcmTagsTableView release];
		[dcmTagNamesAll release];
		[dcmTagNamesFiltered release];
		[dcmTagNameSelected release];
		[dcmTagAddButton release];
		[viewGroups release];
		[super dealloc];
	}

-(NSInteger)columnCount {
	return 2;
}

-(NSInteger)rowCount {
	return std::ceil(CGFloat(viewGroups.count+1)/self.columnCount);
}

-(NSRect)cellFrameForIndex:(NSInteger)index {
	NSInteger column = index%self.columnCount, row = std::floor(CGFloat(index)/self.columnCount);
	return NSMakeRect((cellSize.width+intercellSpacing.width)*column, (cellSize.height+intercellSpacing.height)*row, cellSize.width, cellSize.height);
}

#define kMaxTextFieldWidth 200.f
#define kButtonSpace 15.f

-(NSRect)checkBoxFrameForCellFrame:(NSRect)frame {
	CGFloat textFieldWidth;
	if((frame.size.width-kButtonSpace)/2 < kMaxTextFieldWidth) textFieldWidth = (frame.size.width-kButtonSpace)/2;
	else textFieldWidth = kMaxTextFieldWidth;
	frame.size.width -= frame.size.height+textFieldWidth;
	return frame;
}

-(NSRect)textFieldFrameForCellFrame:(NSRect)frame {
	CGFloat textFieldWidth;
	if((frame.size.width-kButtonSpace)/2 < kMaxTextFieldWidth) textFieldWidth = (frame.size.width-kButtonSpace)/2;
	else textFieldWidth = kMaxTextFieldWidth;
	frame.origin.x += frame.size.width - textFieldWidth - frame.size.height;
	frame.size.width = textFieldWidth;
	return frame;
}

-(NSRect)buttonFrameForCellFrame:(NSRect)frame {
	frame.origin.x += frame.size.width-10;
	frame.origin.y += 4;
	frame.size = NSMakeSize(10,10);
	return frame;
}

-(NSRect)popUpButtonFrameForCellFrame:(NSRect)frame {
	frame.size.width -= kButtonSpace;
	return frame;
}

-(void)repositionGroupViews:(NSArray*)group {
	NSRect cellFrame = [self cellFrameForIndex:[viewGroups indexOfObject:group]];
	[[group objectAtIndex:0] setFrame:[self checkBoxFrameForCellFrame:cellFrame]];
	[[group objectAtIndex:1] setFrame:[self textFieldFrameForCellFrame:cellFrame]];
	[[group objectAtIndex:2] setFrame:[self buttonFrameForCellFrame:cellFrame]];
}

	-(void)repositionAddTagInterface {
		NSRect cellFrame = [self cellFrameForIndex:viewGroups.count];
		[dcmTagsSearchField setFrame:[self popUpButtonFrameForCellFrame:cellFrame]];
		[dcmTagAddButton setFrame:[self buttonFrameForCellFrame:cellFrame]];
	}

-(NSString*)normalizedSearchString:(NSString*)string {
	NSString *value = string ? string : @"";
	NSString *withoutSpaces = [value stringByReplacingOccurrencesOfString:@" " withString:@""];
	return [withoutSpaces stringByReplacingOccurrencesOfString:@"_" withString:@""];
}

-(NSArray*)searchTokensForName:(NSString*)name {
	if (name.length == 0)
		return [NSArray array];

	NSMutableArray* tokens = [NSMutableArray array];
	NSMutableString* current = [NSMutableString string];
	NSCharacterSet* uppercaseSet = [NSCharacterSet uppercaseLetterCharacterSet];

	for (NSUInteger i = 0; i < name.length; ++i) {
		unichar ch = [name characterAtIndex:i];
		BOOL isSeparator = [[NSCharacterSet alphanumericCharacterSet] characterIsMember:ch] == NO;
		BOOL startsNewToken = NO;

		if (!isSeparator && current.length > 0 && [uppercaseSet characterIsMember:ch])
			startsNewToken = YES;

		if (isSeparator || startsNewToken) {
			if (current.length > 0) {
				[tokens addObject:[[self normalizedSearchString:current] uppercaseString]];
				[current setString:@""];
			}
		}

		if (!isSeparator)
			[current appendFormat:@"%C", ch];
	}

	if (current.length > 0)
		[tokens addObject:[[self normalizedSearchString:current] uppercaseString]];

	return tokens;
}

	-(void)updateFilteredTagsForQuery:(NSString*)query autoSelect:(BOOL)autoSelect {
		NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		NSString *upper = [[self normalizedSearchString:trimmed] uppercaseString];

		[dcmTagNameSelected release];
		dcmTagNameSelected = nil;

		if (upper.length == 0) {
			[dcmTagNamesFiltered release];
			dcmTagNamesFiltered = [dcmTagNamesAll retain];
			return;
		}

	NSMutableArray *prefixMatches = [NSMutableArray array];
	NSMutableArray *tokenMatches = [NSMutableArray array];
	NSMutableArray *containsMatches = [NSMutableArray array];
	NSString *exactMatch = nil;
	NSDictionary *nameDictionary = [DCMTagForNameDictionary sharedTagForNameDictionary];
	for (NSString *name in dcmTagNamesAll) {
		NSString *value = [nameDictionary objectForKey:name] ?: @"";
		NSString *nameUpper = [[self normalizedSearchString:name] uppercaseString];
		NSString *valueUpper = [value uppercaseString];
		BOOL nameHasPrefix = [nameUpper hasPrefix:upper];
		BOOL valueHasPrefix = [valueUpper hasPrefix:upper];
		BOOL nameContains = [nameUpper containsString:upper];
		BOOL valueContains = [valueUpper containsString:upper];
		if (!nameContains && !valueContains)
			continue;

		if ([nameUpper isEqualToString:upper] || [valueUpper isEqualToString:upper])
			exactMatch = name;

		BOOL tokenPrefixMatch = NO;
		for (NSString* token in [self searchTokensForName:name]) {
			if ([token hasPrefix:upper]) {
				tokenPrefixMatch = YES;
				break;
			}
		}

		if (nameHasPrefix || valueHasPrefix)
			[prefixMatches addObject:name];
		else if (tokenPrefixMatch)
			[tokenMatches addObject:name];
		else
			[containsMatches addObject:name];
	}

	[prefixMatches sortUsingSelector:@selector(compare:)];
	[tokenMatches sortUsingSelector:@selector(compare:)];
	[containsMatches sortUsingSelector:@selector(compare:)];

	NSMutableArray *matches = [NSMutableArray arrayWithCapacity:prefixMatches.count + tokenMatches.count + containsMatches.count];
	[matches addObjectsFromArray:prefixMatches];
	[matches addObjectsFromArray:tokenMatches];
	[matches addObjectsFromArray:containsMatches];

	[dcmTagNamesFiltered release];
	dcmTagNamesFiltered = [matches copy];

		if (autoSelect && dcmTagNamesFiltered.count > 0) {
			NSString *candidate = exactMatch ?: [dcmTagNamesFiltered objectAtIndex:0];
			dcmTagNameSelected = [candidate retain];
		}
	}

	-(void)controlTextDidChange:(NSNotification *)notification {
		if ([notification object] != dcmTagsSearchField)
			return;
		[self updateFilteredTagsForQuery:[self activeSearchQuery] autoSelect:YES];
		[dcmTagsTableView reloadData];
		if (dcmTagNamesFiltered.count > 0) {
			[dcmTagsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
			[dcmTagsTableView scrollRowToVisible:0];
			if (dcmTagsPopover.isShown == NO && [self activeSearchQuery].length > 0) {
				[dcmTagsPopover showRelativeToRect:dcmTagsSearchField.bounds ofView:dcmTagsSearchField preferredEdge:NSMaxYEdge];
				[self restoreSearchFieldFocus];
			}
			[dcmTagsTableView setNeedsDisplay:YES];
		} else {
			[dcmTagsPopover close];
		}
	}

	-(void)controlTextDidEndEditing:(NSNotification *)notification {
		if ([notification object] != dcmTagsSearchField)
			return;
		[self updateFilteredTagsForQuery:[self activeSearchQuery] autoSelect:YES];
	}

	-(BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
		if (control != dcmTagsSearchField)
			return NO;

		if (commandSelector == @selector(moveDown:)) {
			if (dcmTagNamesFiltered.count == 0)
				return YES;
			if (!dcmTagsPopover.isShown)
				[dcmTagsPopover showRelativeToRect:dcmTagsSearchField.bounds ofView:dcmTagsSearchField preferredEdge:NSMaxYEdge];
			[self restoreSearchFieldFocus];
			NSInteger row = MAX([dcmTagsTableView selectedRow], 0);
			row = MIN(row + 1, (NSInteger)dcmTagNamesFiltered.count - 1);
			[dcmTagsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
			[dcmTagsTableView scrollRowToVisible:row];
			return YES;
		}

		if (commandSelector == @selector(moveUp:)) {
			if (dcmTagNamesFiltered.count == 0)
				return YES;
			NSInteger row = [dcmTagsTableView selectedRow];
			if (row == -1)
				row = 0;
			else
				row = MAX(row - 1, 0);
			[dcmTagsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
			[dcmTagsTableView scrollRowToVisible:row];
			return YES;
		}

		if (commandSelector == @selector(cancelOperation:)) {
			[dcmTagsPopover close];
			return YES;
		}

		if (commandSelector == @selector(insertNewline:)) {
			[self addButtonAction:dcmTagAddButton];
			return YES;
		}

		return NO;
	}

	- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
		if (tableView != dcmTagsTableView)
			return 0;
		return [dcmTagNamesFiltered count];
	}

	- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
		if (tableView != dcmTagsTableView || row < 0 || row >= [dcmTagNamesFiltered count])
			return nil;
		return [dcmTagNamesFiltered objectAtIndex:row];
	}

	- (void)tableViewSelectionDidChange:(NSNotification *)notification {
		if ([notification object] != dcmTagsTableView)
			return;
		NSInteger row = [dcmTagsTableView selectedRow];
		if (row < 0 || row >= [dcmTagNamesFiltered count])
			return;
		[dcmTagNameSelected release];
		dcmTagNameSelected = [[dcmTagNamesFiltered objectAtIndex:row] retain];
	}

-(void)addTag:(DCMAttributeTag*)tag {
	static NSFont* font = [[NSFont labelFontOfSize:[NSFont smallSystemFontSize]-1] retain];

	NSButton* checkBox = [[NSButton alloc] initWithFrame:NSZeroRect];
	[[checkBox cell] setControlSize:NSMiniControlSize];
	[checkBox setFont:font];
	[[checkBox cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[checkBox setButtonType:NSSwitchButton];
	[checkBox setTitle:tag.name];
	[self addSubview:checkBox];
	
	N2TextField* textField = [[N2TextField alloc] initWithFrame:NSZeroRect];
	[[textField cell] setControlSize:NSMiniControlSize];
	[textField setFont:font];
	[textField setBezeled:YES];
	[textField setBezelStyle:NSTextFieldSquareBezel];
	[textField setDrawsBackground:YES];
	[[textField cell] setPlaceholderString:NSLocalizedString(@"Reset", @"Placeholder string for Anonymization Tag cells")];
	[textField setStringValue:@""];
	[self addSubview:textField];
	
//	NSLog( @"VR: %@", tag.vr);
	
	NSDateFormatter* df = NULL;
	NSNumberFormatter* nf = NULL;
	if ([tag.vr isEqualToString:@"DA"] || [tag.vr isEqualToString:@"TM"] || [tag.vr isEqualToString:@"DT"])
    {
		[textField.cell setFormatter: df = [[[NSDateFormatter alloc] init] autorelease]];
		[df setFormatterBehavior:NSDateFormatterBehavior10_4];
		if ([tag.vr isEqualToString:@"DA"]) { //Date String
			[df setTimeStyle:NSDateFormatterNoStyle];
			[df setDateStyle:NSDateFormatterShortStyle];
		} else if ([tag.vr isEqualToString:@"TM"]) { //Time String
			[df setTimeStyle:NSDateFormatterShortStyle];
			[df setDateStyle:NSDateFormatterNoStyle];
		} else if ([tag.vr isEqualToString:@"DT"]) { //Date Time
			[df setTimeStyle:NSDateFormatterShortStyle];
			[df setDateStyle:NSDateFormatterShortStyle];
		}
        
        if ([df.dateFormat rangeOfString:@"yyyy"].location == NSNotFound && [df.dateFormat rangeOfString:@"yy"].location != NSNotFound)
        {
            NSString *fourDigitYearFormat = [[df dateFormat] stringByReplacingOccurrencesOfString:@"yy" withString:@"yyyy"];
            [df setDateFormat:fourDigitYearFormat];
        }
        
        [textField setToolTip: [NSString stringWithFormat: NSLocalizedString( @"Required format: %@", nil), df.dateFormat]];
        
	} else if ([tag.vr isEqualToString:@"DS"] || [tag.vr isEqualToString:@"IS"] || [tag.vr isEqualToString:@"SL"] || [tag.vr isEqualToString:@"SS"] || [tag.vr isEqualToString:@"UL"] || [tag.vr isEqualToString:@"US"] || [tag.vr isEqualToString:@"FL"] || [tag.vr isEqualToString:@"FD"]) {
		[textField.cell setFormatter: nf = [[[NSNumberFormatter alloc] init] autorelease]];
		[nf setFormatterBehavior:NSNumberFormatterBehavior10_4];
		[nf setNumberStyle:NSNumberFormatterDecimalStyle];
		if ([tag.vr isEqualToString:@"DS"]) { //Decimal String representing floating point
			[nf setMaximumSignificantDigits:16];
            [textField setToolTip: NSLocalizedString( @"Required format: floating point number", nil)];
		} else if ([tag.vr isEqualToString:@"IS"]) { //Integer String
			[nf setMaximumSignificantDigits:12];
			[nf setAllowsFloats:NO];
            [textField setToolTip: NSLocalizedString( @"Required format: integer number", nil)];
		} else if ([tag.vr isEqualToString:@"SL"]) { //signed long
			[nf setAllowsFloats:NO];
			[nf setMinimum:[NSNumber numberWithInteger:-0x80000000]];
			[nf setMaximum:[NSNumber numberWithInteger:0x7FFFFFFF]];
            [textField setToolTip: NSLocalizedString( @"Required format: integer number", nil)];
		} else if ([tag.vr isEqualToString:@"SS"]) { //signed short
			[nf setAllowsFloats:NO];
			[nf setMinimum:[NSNumber numberWithInteger:-0x8000]];
			[nf setMaximum:[NSNumber numberWithInteger:0x7FFF]];
            [textField setToolTip: NSLocalizedString( @"Required format: integer number", nil)];
		} else if ([tag.vr isEqualToString:@"UL"]) { //unsigned long
			[textField.cell setFormatter: nf = [[[NSNumberFormatter alloc] init] autorelease]];
			[nf setAllowsFloats:NO];
			[nf setMinimum:[NSNumber numberWithInteger:0]];
			[nf setMaximum:[NSNumber numberWithInteger:0xFFFFFFFF]];
            [textField setToolTip: NSLocalizedString( @"Required format: integer number", nil)];
		} else if ([tag.vr isEqualToString:@"US"]) { //unsigned short
			[nf setAllowsFloats:NO];
			[nf setMinimum:[NSNumber numberWithInteger:0]];
			[nf setMaximum:[NSNumber numberWithInteger:0xFFFF]];
            [textField setToolTip: NSLocalizedString( @"Required format: integer number", nil)];
		} else if ([tag.vr isEqualToString:@"FL"]) { //float
            [textField setToolTip: NSLocalizedString( @"Required format: floating point number", nil)];
		} else if ([tag.vr isEqualToString:@"FD"]) { //double
            [textField setToolTip: NSLocalizedString( @"Required format: floating point number", nil)];
		}
	}
	
	NSButtonCell* rmButtonCell = [[N2HighlightImageButtonCell alloc] initWithImage:[NSImage imageNamed:@"MinusButton"]];
	NSButton* rmButton = [[NSButton alloc] initWithFrame:NSZeroRect];
	rmButton.cell = rmButtonCell;
	[rmButtonCell release];
	rmButton.target = self;
	rmButton.action = @selector(rmButtonAction:);
	[self addSubview:rmButton];
	
	[textField bind:@"enabled" toObject:checkBox.cell withKeyPath:@"state" options:NULL];
	[checkBox.cell addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionInitial context:textField];
	[textField addObserver:self forKeyPath:@"formatIsOk" options:NSKeyValueObservingOptionInitial context:textField];
	
	NSArray* group = [NSArray arrayWithObjects: checkBox, textField, rmButton, tag, NULL];
	[viewGroups addObject:group];
	[self resizeSubviewsWithOldSize:self.frame.size];
	
	[checkBox release];
	[textField release];
	[rmButton release];
}

-(void)removeTag:(DCMAttributeTag*)tag {
	NSArray* group = [self groupForObject:tag];
	if (!group) return;
	
//	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSControlTextDidEndEditingNotification object:[group objectAtIndex:1]];
//	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSControlTextDidChangeNotification object:[group objectAtIndex:1]];
	[[[group objectAtIndex:0] cell] removeObserver:self forKeyPath:@"state"];
	[[group objectAtIndex:1] removeObserver:self forKeyPath:@"formatIsOk"];
//	[[group objectAtIndex:1] removeObserver:self forKeyPath:@"value"];
	[[group objectAtIndex:0] removeFromSuperview];
	[[group objectAtIndex:1] removeFromSuperview];
	[[group objectAtIndex:2] removeFromSuperview];
	
	[viewGroups removeObject:group];

	[self resizeSubviewsWithOldSize:self.frame.size];
}

-(void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)obj change:(NSDictionary*)change context:(void*)context {
	N2TextField* textField = (id)context;
	
	if ([textField isKindOfClass:[NSTextField class]]) {
		NSButton* checkBox = [self checkBoxForObject:textField];
		[textField setBackgroundColor: (checkBox.state&&textField.stringValue.length&&!textField.formatIsOk)? [NSColor colorWithCalibratedHue:[[NSColor orangeColor] hueComponent] saturation:0.25 brightness:1 alpha:1] : [NSColor whiteColor] ];
	}
}

-(void)observeTextDidChange:(NSNotification*)notification {
	NSTextField* textField = notification.object;
	[self observeValueForKeyPath:NULL ofObject:NULL change:NULL context:textField];
}

-(NSButton*)checkBoxForObject:(id)object {
	return [[self groupForObject:object] objectAtIndex:0];
}

-(N2TextField*)textFieldForObject:(id)object {
	return [[self groupForObject:object] objectAtIndex:1];
}

-(NSSize)idealSize {
	NSInteger columnCount = self.columnCount, rowCount = self.rowCount;
	float rC = rowCount-1;
	if( rC < 0) rC = 0;
	float cC = columnCount-1;
	if( cC < 0) cC = 0;
	
	return NSMakeSize(cellSize.width*columnCount+intercellSpacing.width*cC, cellSize.height*rowCount+intercellSpacing.height*rC);
}

-(void)resizeSubviewsWithOldSize:(NSSize)oldSize {
	cellSize = NSMakeSize((self.frame.size.width-intercellSpacing.width*(self.columnCount-1))/2,17);
	for (NSArray* group in viewGroups)
		[self repositionGroupViews:group];
	[self repositionAddTagInterface];
}







@end
