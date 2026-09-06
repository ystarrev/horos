/*=========================================================================
  Program:   OsiriX

  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.

     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
=========================================================================*/




#import "Survey.h"


@implementation Survey

- (void)windowWillClose:(NSNotification *)notification
{
	NSLog( @"Survey closing");
	
	[self autorelease];
}

-(IBAction) dontShowAgain : (id) sender
{
	[[NSUserDefaults standardUserDefaults] setBool: YES forKey: @"SURVEYDONE5"];
}

-(IBAction) done : (id) sender
{
	if( [sender tag] == 2)
		[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://www.osirix-viewer.com/OsiriXWorkshopParis-FR.pdf"]];
	
	[[self window] orderOut: self];
}

@end
