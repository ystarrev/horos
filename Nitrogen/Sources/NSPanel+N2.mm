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

#import "NSPanel+N2.h"
#import <objc/runtime.h>


@implementation NSPanel (N2)

+(NSPanel*)alertWithTitle:(NSString*)title message:(NSString*)message defaultButton:(NSString*)defaultButton alternateButton:(NSString*)alternateButton icon:(NSImage*)icon {
	return [self alertWithTitle:title message:message defaultButton:defaultButton alternateButton:alternateButton icon:icon sheet:NO];
}

+(NSPanel*)alertWithTitle:(NSString*)title message:(NSString*)message defaultButton:(NSString*)defaultButton alternateButton:(NSString*)alternateButton icon:(NSImage*)icon sheet:(BOOL)sheet {
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	alert.alertStyle = NSAlertStyleWarning;
	alert.messageText = title ?: @"";
	alert.informativeText = message ?: @"";
	[alert addButtonWithTitle:defaultButton.length ? defaultButton : NSLocalizedString(@"OK", nil)];
	if (alternateButton.length)
		[alert addButtonWithTitle:alternateButton];
	if (icon)
		alert.icon = icon;

	NSPanel *panel = (NSPanel *)alert.window;
	objc_setAssociatedObject(panel, @selector(alertWithTitle:message:defaultButton:alternateButton:icon:sheet:), alert, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	
	if (sheet) {
		for (NSButton *button in alert.buttons) {
			[button setTarget:self];
			[button setAction:@selector(_sheetButtonAction:)];
		}
	}
	
	return panel;
}

+(void)_sheetButtonAction:(NSButton*)button {
	NSWindow *sheet = [button window];
	NSWindow *parentWindow = [sheet sheetParent];
	if (parentWindow)
		[parentWindow endSheet:sheet returnCode:[button tag]];
	else {
		if ([NSApp modalWindow] == sheet)
			[NSApp stopModalWithCode:[button tag]];
		[sheet orderOut:nil];
	}
}

@end
