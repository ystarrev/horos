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

#import "ThreadsManager.h"
#import "HorosSwiftInterop.h"

@interface ThreadsManager ()

-(void)subRemoveThread:(NSThread*)thread;
-(HorosActivityTask*)activityForThread:(NSThread*)thread;
-(void)activityDidComplete:(HorosActivityTask*)activity;

@end

@interface HorosActivityThread : NSThread
@end

@implementation HorosActivityThread

-(void)main
{
    @autoreleasepool
    {
        @try
        {
            [super main];
        }
        @finally
        {
            [HorosActivityTaskCoordinator completeThread:self];
        }
    }
}

@end

@implementation ThreadsManager

@synthesize threadsController = _threadsController;

+(ThreadsManager*)defaultManager {
	static ThreadsManager* threadsManager = [[self alloc] init];
	return threadsManager;
}

-(id)init {
	self = [super init];
	
	//_threads = [[NSMutableArray alloc] init];
	
	_threadsController = [[NSArrayController alloc] init];
	[_threadsController setSelectsInsertedObjects:NO];
	[_threadsController setAvoidsEmptySelection:NO];
	[_threadsController setObjectClass:[HorosActivityTask class]];
    
    // Plain NSThread activities need polling to detect completion.
	_timer = [[NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(cleanupFinishedThreads:) userInfo:nil repeats:YES] retain];
    
	return self;
}

-(void)dealloc {
    [_timer invalidate];
    [_timer release];
	[_threadsController release];
	[super dealloc];
}

-(void)cleanupFinishedThreads:(NSTimer*)timer {
    NSArray* activities = nil;
    @synchronized (_threadsController) {
        activities = [[_threadsController.content copy] autorelease];
    }

    for (HorosActivityTask* activity in activities)
        if (activity.thread.isFinished)
            [self subRemoveThread:activity.thread];
}

#pragma mark Interface

-(NSArray*)threads {
	@synchronized (_threadsController) {
		return [_threadsController.arrangedObjects valueForKey:@"thread"];
	} return nil;
}

-(NSUInteger)threadsCount {
	@synchronized (_threadsController) {
		return [_threadsController.arrangedObjects count];
	} return 0;
}

-(NSThread*)threadAtIndex:(NSUInteger)index {
	@synchronized (_threadsController) {
		return [[_threadsController.arrangedObjects objectAtIndex:index] thread];
	} return nil;
}

-(NSThread*)newActivityThreadWithTarget:(id)target selector:(SEL)selector object:(id)object
{
    return [[HorosActivityThread alloc] initWithTarget:target selector:selector object:object];
}

-(HorosActivityTask*)activityForThread:(NSThread*)thread
{
    for (HorosActivityTask* activity in _threadsController.content)
        if (activity.thread == thread)
            return activity;

    return nil;
}

-(void)activityDidComplete:(HorosActivityTask*)activity
{
    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread:@selector(activityDidComplete:) withObject:activity waitUntilDone:NO];
        return;
    }

    @synchronized (_threadsController)
    {
        if ([_threadsController.content containsObject:activity])
            [_threadsController removeObject:activity];
    }
}

-(void)subAddThread:(NSThread*)thread
{
	@synchronized (_threadsController)
    {
	@synchronized (thread)
	{
		if (![NSThread isMainThread])
			NSLog( @"***** NSThread we should NOT be here");
        
		if ([self activityForThread:thread] || [thread isFinished])
		{
            // Do nothing
        }
		else
        {
            if (![thread isMainThread]/* && ![thread isExecuting]*/)
            {
                BOOL isExe = [thread isExecuting], isDone = [thread isFinished];
                
                @try
                {

                    if (!isDone) {
                        HorosActivityTask* activity = [[HorosActivityTaskCoordinator sharedCoordinator] registerThread:thread];
                        [[HorosActivityTaskCoordinator sharedCoordinator] addCompletionHandlerForThread:thread handler:^{
                            [self activityDidComplete:activity];
                        }];
                        [_threadsController addObject:activity];
                    }
                    if (!isExe && !isDone) { // not executing, not done executing... execute now
                        [thread start];
                    }
                    
                    if ([thread isFinished]) // already done?? wtf..
                    {
                        [[HorosActivityTaskCoordinator sharedCoordinator] completeRegisteredThread:thread];
                    }
                }
                @catch (NSException* e)
                {
                    [[HorosActivityTaskCoordinator sharedCoordinator] completeRegisteredThread:thread];
                }
            }
        }
	}
    }
}

-(void)addThreadAndStart:(NSThread*)thread
{
    if (![NSThread isMainThread])
    {
        if( [thread isExecuting] == NO && [thread isFinished] == NO)
            [thread start]; // We want to start it immediately: subAddThread must add it on main thread: the main thread is maybe locked.
        [self performSelectorOnMainThread:@selector(subAddThread:) withObject:thread waitUntilDone: NO];
    }
    else [self subAddThread:thread];
}

-(void) subRemoveThread:(NSThread*)thread
{
    if (![NSThread isMainThread])
        NSLog( @"***** NSThread we should NOT be here");

    HorosActivityTask* activity = nil;
    @synchronized (_threadsController)
    {
        activity = [[self activityForThread:thread] retain];
    }

    if (activity)
    {
        [[HorosActivityTaskCoordinator sharedCoordinator] completeRegisteredThread:thread];
        [activity release];
    }
}

-(void)removeThread:(NSThread*)thread
{
    if (![NSThread isMainThread])
        [self performSelectorOnMainThread:@selector(subRemoveThread:) withObject:thread waitUntilDone:NO];
    else [self subRemoveThread:thread];
}

@end
