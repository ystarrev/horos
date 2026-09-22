#import "HorosAlertCompatibility.h"
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

#import "BrowserController+Sources.h"
#import "HorosSwiftInterop.h"
#import "BrowserController+Sources+Copy.h"
#import "DataNodeIdentifier.h"
#import "PrettyCell.h"
#import "DicomDatabase.h"
#import "RemoteDicomDatabase.h"
#import "NSManagedObject+N2.h"
#import "DicomImage.h"
#import "MutableArrayCategory.h"
#import "NSImage+N2.h"
#import "NSUserDefaultsController+N2.h"
#import "N2Debug.h"
#import "NSThread+N2.h"
#import "N2Operators.h"
#import "ThreadModalForWindowController.h"
#import "ThreadsManager.h"
#import "BonjourPublisher.h"
#import "DicomFile.h"
#import "NSDictionary+N2.h"
#import "DCMNetServiceDelegate.h"
#import "AppController.h"
#import <netinet/in.h>
#import <arpa/inet.h>
#import "NSHost+N2.h"
#import "DefaultsOsiriX.h"
#import "NSString+N2.h"
#import "NSString+SymlinksAndAliases.h"
#import "NSUserDefaults+OsiriX.h"
#import "WaitRendering.h"
#import "QueryController.h"
#import <errno.h>
#import <fcntl.h>
#import <netdb.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

static BOOL HorosIsTemporaryLocalDatabaseSourcePath(NSString *path)
{
    if (path.length == 0)
        return NO;

    NSString *tempPath = [NSTemporaryDirectory() stringByResolvingSymlinksAndAliases];
    NSString *standardizedPath = [path stringByStandardizingPath];
    NSString *resolvedPath = [standardizedPath stringByResolvingSymlinksAndAliases];
    NSString *candidatePath = resolvedPath.length ? resolvedPath : standardizedPath;

    if (![candidatePath hasPrefix:tempPath])
        return NO;

    NSString *databaseFolderName = candidatePath.lastPathComponent;
    NSString *parentFolderName = candidatePath.stringByDeletingLastPathComponent.lastPathComponent;
    return [databaseFolderName hasPrefix:@"Horos_"] && [parentFolderName hasPrefix:@"Horos_"];
}

static NSString* const HorosOsiriXDatabaseBonjourType = @"_osirixdb._tcp";
static NSString* const HorosDicomBonjourType = @"_dicom._tcp";
static NSString* const HorosPhoneVolumeRenderBonjourType = @"_horosiphone._tcp";
static NSString* const HorosPhoneVolumeRenderDisplayName = @"iPhonePlanner";
static NSTimeInterval const HorosBonjourHeartbeatInterval = 30.0;
static NSTimeInterval const HorosBonjourHeartbeatTimeout = 5.0;
static NSInteger const HorosBonjourHeartbeatFailureLimit = 2;

static BOOL HorosCanOpenTCPConnection(NSString *host, NSUInteger port, NSTimeInterval timeout)
{
    if (![host length] || port == 0)
        return NO;

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    NSString *portString = [NSString stringWithFormat:@"%lu", (unsigned long)port];
    struct addrinfo *addresses = NULL;
    if (getaddrinfo([host UTF8String], [portString UTF8String], &hints, &addresses) != 0)
        return NO;

    BOOL connected = NO;
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + timeout;
    for (struct addrinfo *address = addresses; address && !connected; address = address->ai_next)
    {
        int timeoutMilliseconds = (int)((deadline - [NSDate timeIntervalSinceReferenceDate]) * 1000.0);
        if (timeoutMilliseconds <= 0)
            break;

        int socketFD = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketFD < 0)
            continue;

#ifdef SO_NOSIGPIPE
        int noSigPipe = 1;
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif

        int flags = fcntl(socketFD, F_GETFL, 0);
        if (flags < 0 || fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) < 0)
        {
            close(socketFD);
            continue;
        }

        int connectResult = connect(socketFD, address->ai_addr, address->ai_addrlen);
        if (connectResult == 0)
            connected = YES;
        else if (errno == EINPROGRESS)
        {
            struct pollfd descriptor;
            descriptor.fd = socketFD;
            descriptor.events = POLLOUT;
            descriptor.revents = 0;

            int pollResult;
            do
                pollResult = poll(&descriptor, 1, timeoutMilliseconds);
            while (pollResult < 0 && errno == EINTR);

            if (pollResult > 0)
            {
                int socketError = 0;
                socklen_t socketErrorLength = sizeof(socketError);
                if (getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 && socketError == 0)
                    connected = YES;
            }
        }

        close(socketFD);
    }

    freeaddrinfo(addresses);
    return connected;
}

static NSDictionary* HorosSourceTXTDictionaryFromRecordData(NSData *recordData)
{
    if (!recordData.length)
        return [NSDictionary dictionary];

    NSDictionary *raw = [HorosBonjourService dictionaryFromTXTRecordData:recordData];
    NSMutableDictionary *decoded = [NSMutableDictionary dictionaryWithCapacity:raw.count];
    for (NSString *key in raw)
    {
        NSData *valueData = [raw objectForKey:key];
        NSString *value = [[[NSString alloc] initWithData:valueData encoding:NSUTF8StringEncoding] autorelease];
        if (value)
            [decoded setObject:value forKey:key];
    }

    return decoded;
}

static NSString* HorosBonjourServiceKey(NSString *type, NSString *name)
{
    return [NSString stringWithFormat:@"%@|%@", type ? type : @"", name ? name : @""];
}

static NSString* HorosBonjourHostWithoutTrailingDot(NSString *host)
{
    NSMutableString *cleanHost = [[host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] mutableCopy];
    while ([cleanHost hasSuffix:@"."])
        [cleanHost deleteCharactersInRange:NSMakeRange([cleanHost length] - 1, 1)];
    return [cleanHost autorelease];
}

static NSString* HorosPeerUIDFromDictionary(NSDictionary *dictionary)
{
    id value = [dictionary objectForKey:@"UID"];
    if (![value isKindOfClass:[NSString class]])
        return nil;

    NSString *uid = [(NSString*)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [uid length] ? [uid lowercaseString] : nil;
}

@interface BrowserSourcesHelper : NSObject<HorosBonjourBrowserDelegate, HorosBonjourServiceDelegate>/*<NSTableViewDelegate,NSTableViewDataSource>*/
{
    BrowserController* _browser;
    HorosBonjourBrowser* _nsbOsirix;
    HorosBonjourBrowser* _nsbDicom;
    HorosBonjourBrowser* _nsbPhoneVolumeRender;
    NSMutableArray* _bonjourSources, *_bonjourServices;
    NSTimer *_bonjourHeartbeatTimer;
    NSOperationQueue *_bonjourHeartbeatQueue;
    NSMutableDictionary *_bonjourHeartbeatFailureCounts;
    NSMutableSet *_bonjourHeartbeatInFlight;

    BOOL dontListenToSourcesChanges;
    BOOL _invalidated;
}

-(id)initWithBrowser:(BrowserController*)browser;
-(void)invalidate;
-(void)_scheduleBonjourBrowserStart;
-(void)_startBonjourBrowsers;
-(void)_startOsirixBonjourBrowser;
-(void)_startDicomBonjourBrowser;
-(void)_startPhoneVolumeRenderBonjourBrowser;
-(void)_stopBonjourBrowsers;
-(BOOL)_resolvedBonjourServiceIsThisHorosType:(NSString*)type name:(NSString*)name host:(NSString*)host port:(NSInteger)port txt:(NSDictionary*)txt;
-(NSString*)_bonjourServiceTypeForBrowser:(HorosBonjourBrowser*)browser;
-(void)_verifyBonjourSources;
-(void)_verifyBonjourSource:(DataNodeIdentifier*)source;

@end

@interface BrowserController (HorosDirectSourceReconciliation)

-(void)reconcileHorosDirectSources;

@end

@interface DefaultLocalDatabaseNodeIdentifier : LocalDatabaseNodeIdentifier

+(DefaultLocalDatabaseNodeIdentifier*)identifier;

@end

@interface UnavaliableDataNodeException : NSException
@end

@implementation BrowserController (Sources)

-(void)awakeSources
{
    [_sourcesArrayController setSortDescriptors:[NSArray arrayWithObjects: [[[NSSortDescriptor alloc] initWithKey:@"self" ascending:YES] autorelease], NULL]];
    [_sourcesArrayController setAutomaticallyRearrangesObjects:YES];
    [_sourcesArrayController addObject:[DefaultLocalDatabaseNodeIdentifier identifier]];
    [_sourcesArrayController setSelectsInsertedObjects:NO];

    _sourcesHelper = [[BrowserSourcesHelper alloc] initWithBrowser:self];
    [_sourcesTableView setDataSource:_sourcesHelper];
    [_sourcesTableView setDelegate:_sourcesHelper];

    PrettyCell* cell = [[[PrettyCell alloc] init] autorelease];
    [[_sourcesTableView tableColumnWithIdentifier:@"Source"] setDataCell:cell];

    [_sourcesTableView registerForDraggedTypes:BrowserController.DatabaseObjectXIDsPasteboardTypes];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(horosDirectSessionConnected:) name:@"HorosDirectSessionDidConnect" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(horosDirectSessionDisconnected:) name:@"HorosDirectSessionDidDisconnect" object:nil];
    [self reconcileHorosDirectSources];

    [self selectCurrentDatabaseSource];
}

-(void)deallocSources
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"HorosDirectSessionDidConnect" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"HorosDirectSessionDidDisconnect" object:nil];
    [self shutdownBonjourSources];
    [_sourcesHelper release]; _sourcesHelper = nil;
}

-(void)horosDirectSessionConnected:(NSNotification*)notification
{
    [self reconcileHorosDirectSources];
}

-(void)horosDirectSessionDisconnected:(NSNotification*)notification
{
    [self reconcileHorosDirectSources];
}

-(void)reconcileHorosDirectSources
{
    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread:@selector(reconcileHorosDirectSources) withObject:nil waitUntilDone:NO];
        return;
    }

    NSArray *sessions = [[HorosDirectTransferService sharedService] activeSessionDictionaries];
    NSMutableDictionary *sessionsByID = [NSMutableDictionary dictionaryWithCapacity:[sessions count]];
    for (NSDictionary *session in sessions)
    {
        NSString *sessionID = [session objectForKey:@"sessionID"];
        if ([sessionID length])
            [sessionsByID setObject:session forKey:sessionID];
    }

    NSArray *sources = [[_sourcesArrayController content] copy];
    NSMutableSet *bonjourPeerUIDs = [NSMutableSet set];
    for (DataNodeIdentifier *source in sources)
    {
        if ([source isKindOfClass:[HorosDirectNodeIdentifier class]] ||
            ![source isKindOfClass:[DicomNodeIdentifier class]])
            continue;

        NSString *peerUID = HorosPeerUIDFromDictionary(source.dictionary);
        if ([peerUID length])
            [bonjourPeerUIDs addObject:peerUID];
    }

    BOOL changed = NO;
    NSMutableSet *displayedSessionIDs = [NSMutableSet set];
    for (DataNodeIdentifier *source in sources)
    {
        if (![source isKindOfClass:[HorosDirectNodeIdentifier class]])
            continue;

        NSString *sessionID = [(HorosDirectNodeIdentifier*)source sessionIdentifier];
        NSDictionary *session = [sessionsByID objectForKey:sessionID];
        NSString *peerUID = HorosPeerUIDFromDictionary(session);
        if (!session || ([peerUID length] && [bonjourPeerUIDs containsObject:peerUID]))
        {
            [_sourcesArrayController removeObject:source];
            changed = YES;
        }
        else
            [displayedSessionIDs addObject:sessionID];
    }
    [sources release];

    for (NSDictionary *session in sessions)
    {
        NSString *sessionID = [session objectForKey:@"sessionID"];
        NSString *peerUID = HorosPeerUIDFromDictionary(session);
        if (![sessionID length] || [displayedSessionIDs containsObject:sessionID] ||
            ([peerUID length] && [bonjourPeerUIDs containsObject:peerUID]))
            continue;

        NSString *aeTitle = [session objectForKey:@"aeTitle"] ?: @"HOROS";
        NSString *displayName = [session objectForKey:@"name"] ?: aeTitle;
        if ([displayName caseInsensitiveCompare:aeTitle] == NSOrderedSame)
            displayName = aeTitle;

        NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithDictionary:session];
        [dictionary setObject:sessionID forKey:@"HorosDirectSessionID"];
        [dictionary setObject:displayName forKey:@"Description"];
        [dictionary setObject:aeTitle forKey:@"AETitle"];
        [dictionary setObject:([session objectForKey:@"address"] ?: @"Horos") forKey:@"Address"];
        [dictionary setObject:([session objectForKey:@"dicomPort"] ?: @0) forKey:@"Port"];
        [dictionary setObject:@YES forKey:@"Send"];
        [dictionary setObject:@NO forKey:@"QR"];
        [dictionary setObject:@"DICOMDestination.tif" forKey:@"icon"];

        HorosDirectNodeIdentifier *source = [HorosDirectNodeIdentifier directNodeIdentifierWithSessionDictionary:dictionary];
        source.detected = YES;
        source.entered = NO;
        [_sourcesArrayController addObject:source];
        changed = YES;
    }

    if (changed)
        [self redrawSources];
}

-(void)shutdownBonjourSources
{
    [(BrowserSourcesHelper*)_sourcesHelper invalidate];
}

-(NSInteger)sourcesCount
{
    return [[_sourcesArrayController arrangedObjects] count];
}

-(DataNodeIdentifier*)sourceIdentifierAtRow:(int)row
{
    return ([_sourcesArrayController.arrangedObjects count] > row)? [_sourcesArrayController.arrangedObjects objectAtIndex:row] : nil;
}

-(int)rowForSourceIdentifier:(DataNodeIdentifier*)source
{
    for (NSInteger i = 0; i < [[_sourcesArrayController arrangedObjects] count]; ++i)
        if ([[_sourcesArrayController.arrangedObjects objectAtIndex:i] isEqualToDataNodeIdentifier:source])
            return i;
    return -1;
}

-(DataNodeIdentifier*)sourceIdentifierForDatabase:(DicomDatabase*)database // TODO: move this to -[DicomDatabase dataNodeIdentifier]
{
    if (database == [DicomDatabase defaultDatabase])
        return [DefaultLocalDatabaseNodeIdentifier identifier];
    if (database.isLocal)
        return [LocalDatabaseNodeIdentifier localDatabaseNodeIdentifierWithPath:database.baseDirPath];
    else
        return [RemoteDatabaseNodeIdentifier remoteDatabaseNodeIdentifierWithLocation:[(RemoteDicomDatabase*)database address] port:[(RemoteDicomDatabase*)database port] description:nil dictionary:nil];
}

-(int)rowForDatabase:(DicomDatabase*)database
{
    return [self rowForSourceIdentifier:[self sourceIdentifierForDatabase:database]];
}

-(void)selectSourceForDatabase:(DicomDatabase*)database
{
    NSInteger row = [self rowForDatabase:database];
    if (row >= 0)
        [_sourcesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    else NSLog(@"Warning: couldn't find database in sources (%@)", database);
}

-(void)selectCurrentDatabaseSource
{
    if (!_database)
    {
        [_sourcesTableView selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:NO];
        return;
    }

    NSInteger i = [self rowForDatabase:_database];
    if (i == -1 && _database != [DicomDatabase defaultDatabase])
    {
        NSString *sourcePath = [_database.baseDirPath stringByDeletingLastPathComponent];
        if( HorosIsTemporaryLocalDatabaseSourcePath( sourcePath) == NO)
        {
            NSDictionary* source = [NSDictionary dictionaryWithObjectsAndKeys: sourcePath, @"Path", [_database.baseDirPath.stringByDeletingLastPathComponent.lastPathComponent stringByAppendingString: NSLocalizedString( @" DB", @"DB = DataBase")], @"Description", nil];
            [[NSUserDefaults standardUserDefaults] setObject:[[[NSUserDefaults standardUserDefaults] objectForKey:@"localDatabasePaths"] arrayByAddingObject:source] forKey:@"localDatabasePaths"];

            i = [self rowForDatabase:_database];
        }
    }
    if (i >= 0 && i != [_sourcesTableView selectedRow])
        [_sourcesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
    else if (i < 0)
        [_sourcesTableView selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:NO];
}

-(void)setDatabaseOnMainThread: (DicomDatabase*) db
{
    [self performSelector: @selector( setDatabase:) withObject: db afterDelay: 0.01]; //This will guarantee that this will not happen in middle of a drag & drop, for example
}

-(void)setDatabaseThread:(NSArray*)io
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    @try
    {
        NSString* type = [io objectAtIndex:0];
        DicomDatabase* db = nil;

        if ([type isEqualToString:@"Local"])
        {
            NSString* path = [io objectAtIndex:1];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            {
                NSString* message = NSLocalizedString(@"The selected database's data was not found on your computer.", nil);
                if ([path hasPrefix:@"/Volumes/"])
                    message = [message stringByAppendingFormat:@" %@", NSLocalizedString(@"If it is stored on an external drive? If so, please make sure the device in connected and on.", nil)];
                [NSException raise:NSGenericException format:@"%@", message];
            }

            NSString* name = io.count > 2? [io objectAtIndex:2] : nil;
            db = [DicomDatabase databaseAtPath:path name:name];
        }

        if ([type isEqualToString:@"Remote"])
        {
            NSString* address = [io objectAtIndex:1];
            NSInteger port = [[io objectAtIndex:2] intValue];
            NSString* name = io.count > 3? [io objectAtIndex:3] : nil;
            db = [RemoteDicomDatabase databaseForLocation:address port:port name:name update:YES];
        }

        [self performSelectorOnMainThread:@selector( setDatabaseOnMainThread:) withObject:db waitUntilDone:NO modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];

        [NSThread sleepForTimeInterval: 1];

    } @catch (NSException* e)
    {
        [self performSelectorOnMainThread:@selector(selectCurrentDatabaseSource) withObject:nil waitUntilDone:NO modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
        if (![e.description isEqualToString:@"Cancelled."])
        {
            N2LogExceptionWithStackTrace(e);
            [self performSelectorOnMainThread:@selector(_complain:) withObject:[NSArray arrayWithObjects: [NSNumber numberWithFloat:0.1], NSLocalizedString(@"Error", nil), e.description, NULL] waitUntilDone:NO modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
        }
    } @finally
    {
        [pool release];
    }
}

-(void)_complain:(NSArray*)why { // if 1st obj in array is a number then execute this after the delay specified by that number, with the rest of the array
    if ([[why objectAtIndex:0] isKindOfClass:[NSNumber class]])
        [self performSelector:@selector(_complain:) withObject:[why subarrayWithRange:NSMakeRange(1, (long)why.count-1)] afterDelay:[[why objectAtIndex:0] floatValue]];
    else
        HorosBeginAlertSheet([why objectAtIndex:0], nil, nil, nil, self.window, nil, nil, nil, nil, @"%@", [why objectAtIndex:1]);
}

-(NSThread*)initiateSetDatabaseAtPath:(NSString*)path name:(NSString*)name
{
    NSArray* io = [NSMutableArray arrayWithObjects: @"Local", path, name, nil];

    NSThread* thread = [[[ThreadsManager defaultManager] newActivityThreadWithTarget:self selector:@selector(setDatabaseThread:) object:io] autorelease];
    thread.name = NSLocalizedString(@"Loading database...", nil);
    thread.supportsCancel = YES;
    thread.status = NSLocalizedString(@"Reading data...", nil);

    [thread startModalForWindow:self.window];
    [thread start];

    return thread;
}

-(NSThread*)initiateSetRemoteDatabaseWithAddress:(NSString*)address port:(NSInteger)port name:(NSString*)name
{
    NSArray* io = [NSMutableArray arrayWithObjects: @"Remote", address, [NSNumber numberWithInteger:port], name, nil];

    NSThread* thread = [[ThreadsManager defaultManager] newActivityThreadWithTarget:self selector:@selector(setDatabaseThread:) object:io];
    thread.name = NSLocalizedString(@"Loading remote database...", nil);
    thread.supportsCancel = YES;
    [thread startModalForWindow:self.window];
    [thread start];

    return [thread autorelease];
}

- (void) setDatabaseWithModalWindow: (DicomDatabase*) db
{
    NSThread* thread = [NSThread currentThread];
    thread.name = NSLocalizedString(@"Opening database...", nil);
    thread.status = NSLocalizedString(@"Opening database...", nil);
    thread.supportsCancel = YES;

    ThreadModalForWindowController* tmc = [thread startModalForWindow:self.window];

    [self setDatabase: db];

    [tmc invalidate];
}

-(void)setDatabaseFromSourceIdentifier:(DataNodeIdentifier*)dni
{
    if ([dni isKindOfClass:[HorosDirectNodeIdentifier class]])
    {
        [self selectCurrentDatabaseSource];
        return;
    }

    if ([dni isEqualToDataNodeIdentifier:[self sourceIdentifierForDatabase:_database]])
        return;

    @try
    {
        DicomDatabase* db = [dni database];

        if (db)
            [self performSelector: @selector( setDatabaseWithModalWindow:) withObject: db afterDelay: 0.01]; //This will guarantee that this will not happen in middle of a drag & drop, for example

        else if ([dni isKindOfClass:[LocalDatabaseNodeIdentifier class]])
            [self initiateSetDatabaseAtPath:dni.location name:dni.description];

        else if ([dni isKindOfClass:[RemoteDatabaseNodeIdentifier class]])
        {
            NSString* host = nil; NSInteger port = -1;
            [RemoteDatabaseNodeIdentifier location:dni.location port:dni.port toAddress:&host port:&port];

            if( host && port != -1)
                [self initiateSetRemoteDatabaseWithAddress:host port:port name:dni.description];
        }
        else if ([dni isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]])
        {
            [UnavaliableDataNodeException raise:NSGenericException format:@"%@", NSLocalizedString(@"This is an iPhone planning app destination: you cannot browse its content. You can only drag & drop studies on it.", nil)];
        }
        else
        {
            [UnavaliableDataNodeException raise:NSGenericException format:@"%@", NSLocalizedString(@"This is a DICOM destination node: you cannot browse its content. You can only drag & drop studies on them.", nil)];
        }
    } @catch (UnavaliableDataNodeException* e)
    {
        HorosBeginAlertSheet(NSLocalizedString(@"Sources", nil), nil, nil, nil, self.window, nil, nil, nil, nil, @"%@", [e reason]);
        [self selectCurrentDatabaseSource];
    }
}

-(void)redrawSources
{
    if( [NSThread isMainThread])
        [_sourcesTableView setNeedsDisplay:YES];
    else
        [self performSelectorOnMainThread: @selector( redrawSources) withObject: nil waitUntilDone: NO];
}

-(int)findDBPath:(NSString*)path dbFolder:(NSString*)DBFolderLocation { // __deprecated
    NSInteger i = [self rowForSourceIdentifier:[LocalDatabaseNodeIdentifier localDatabaseNodeIdentifierWithPath:path]];
    if (i < 0) i = [self rowForSourceIdentifier:[LocalDatabaseNodeIdentifier localDatabaseNodeIdentifierWithPath:DBFolderLocation]];
    return i;
}

@end

@implementation BrowserSourcesHelper

static void* const LocalBrowserSourcesContext = @"LocalBrowserSourcesContext";
static void* const RemoteBrowserSourcesContext = @"RemoteBrowserSourcesContext";
static void* const DicomBrowserSourcesContext = @"DicomBrowserSourcesContext";
static void* const SearchBonjourNodesContext = @"SearchBonjourNodesContext";
static void* const SearchDicomNodesContext = @"SearchDicomNodesContext";

-(id)initWithBrowser:(BrowserController*)browser
{
    if ((self = [super init]))
    {
        _browser = browser;
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:@"localDatabasePaths" options:NSKeyValueObservingOptionInitial context:LocalBrowserSourcesContext];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:@"OSIRIXSERVERS" options:NSKeyValueObservingOptionInitial context:RemoteBrowserSourcesContext];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:@"SERVERS" options:NSKeyValueObservingOptionInitial context:DicomBrowserSourcesContext];
        _bonjourSources = [[NSMutableArray alloc] init];
        _bonjourServices = [[NSMutableArray alloc] init];
        _bonjourHeartbeatFailureCounts = [[NSMutableDictionary alloc] init];
        _bonjourHeartbeatInFlight = [[NSMutableSet alloc] init];
        _bonjourHeartbeatQueue = [[NSOperationQueue alloc] init];
        [_bonjourHeartbeatQueue setName:@"Horos Bonjour availability"];
        [_bonjourHeartbeatQueue setMaxConcurrentOperationCount:1];

        _bonjourHeartbeatTimer = [[NSTimer timerWithTimeInterval:HorosBonjourHeartbeatInterval
                                                          target:self
                                                        selector:@selector(_bonjourHeartbeatTimerFired:)
                                                        userInfo:nil
                                                         repeats:YES] retain];
        [[NSRunLoop mainRunLoop] addTimer:_bonjourHeartbeatTimer forMode:NSRunLoopCommonModes];
        [self performSelector:@selector(_verifyBonjourSources) withObject:nil afterDelay:5.0];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:@"searchDICOMBonjour" options:NSKeyValueObservingOptionInitial context:SearchDicomNodesContext];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:@"DoNotSearchForBonjourServices" options:NSKeyValueObservingOptionInitial context:SearchBonjourNodesContext];
        NSLog(@"Horos NSBonjourServices: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSBonjourServices"]);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
        [self _scheduleBonjourBrowserStart];
    }

    return self;
}

-(void)dealloc
{
    [self invalidate];
    [_bonjourSources release];
    [_bonjourServices release];
    [_bonjourHeartbeatQueue release];
    [_bonjourHeartbeatFailureCounts release];
    [_bonjourHeartbeatInFlight release];

    _browser = nil;
    [super dealloc];
}

-(void)invalidate
{
    if (_invalidated)
        return;

    _invalidated = YES;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_verifyBonjourSources) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startBonjourBrowsers) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startOsirixBonjourBrowser) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startDicomBonjourBrowser) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startPhoneVolumeRenderBonjourBrowser) object:nil];

    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"DoNotSearchForBonjourServices"];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"searchDICOMBonjour"];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"SERVERS"];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"OSIRIXSERVERS"];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"localDatabasePaths"];

    [_bonjourHeartbeatTimer invalidate];
    [_bonjourHeartbeatTimer release];
    _bonjourHeartbeatTimer = nil;
    [_bonjourHeartbeatQueue cancelAllOperations];
    [self _stopBonjourBrowsers];
    _browser = nil;
}

-(void)_applicationDidBecomeActive:(NSNotification*)notification
{
    if (_invalidated)
        return;

    [self _scheduleBonjourBrowserStart];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_verifyBonjourSources) object:nil];
    [self performSelector:@selector(_verifyBonjourSources) withObject:nil afterDelay:2.0];
}

-(void)_scheduleBonjourBrowserStart
{
    if (_invalidated)
        return;

    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread:@selector(_scheduleBonjourBrowserStart) withObject:nil waitUntilDone:NO];
        return;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startBonjourBrowsers) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startOsirixBonjourBrowser) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startDicomBonjourBrowser) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startPhoneVolumeRenderBonjourBrowser) object:nil];
    [self performSelector:@selector(_startBonjourBrowsers) withObject:nil afterDelay:1.0];
}

-(void)_stopBonjourBrowsers
{
    [_nsbOsirix setDelegate:nil];
    [_nsbOsirix stop];
    [_nsbOsirix release];
    _nsbOsirix = nil;

    [_nsbDicom setDelegate:nil];
    [_nsbDicom stop];
    [_nsbDicom release];
    _nsbDicom = nil;

    [_nsbPhoneVolumeRender setDelegate:nil];
    [_nsbPhoneVolumeRender stop];
    [_nsbPhoneVolumeRender release];
    _nsbPhoneVolumeRender = nil;
}

-(void)_bonjourHeartbeatTimerFired:(NSTimer*)timer
{
    [self _verifyBonjourSources];
}

-(BOOL)_bonjourHeartbeatShouldProbeSource:(DataNodeIdentifier*)source
{
    if ([source isKindOfClass:[HorosDirectNodeIdentifier class]])
        return NO;

    if (![source.location length] || source.port == 0)
        return NO;

    if ([source isKindOfClass:[DicomNodeIdentifier class]])
        return [[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"];

    if ([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]])
        return ![[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"];

    return NO;
}

-(NSString*)_bonjourHeartbeatKeyForSource:(DataNodeIdentifier*)source
{
    NSString *serviceKey = [source.dictionary objectForKey:@"BonjourServiceKey"];
    if ([serviceKey length])
        return serviceKey;

    NSString *type = nil;
    if ([source isKindOfClass:[DicomNodeIdentifier class]])
        type = HorosDicomBonjourType;
    else if ([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]])
        type = HorosOsiriXDatabaseBonjourType;
    else
        return nil;

    return [NSString stringWithFormat:@"%@|%@|%@|%lu|%@",
            type,
            source.description ? source.description : @"",
            source.location ? source.location : @"",
            (unsigned long)source.port,
            source.aetitle ? source.aetitle : @""];
}

-(NSDictionary*)_bonjourHeartbeatProbeInfoForSource:(DataNodeIdentifier*)source
{
    if (![self _bonjourHeartbeatShouldProbeSource:source])
        return nil;

    NSString *key = [self _bonjourHeartbeatKeyForSource:source];
    if (![key length])
        return nil;

    NSMutableDictionary *probeInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                      key, @"Key",
                                      source.location, @"Address",
                                      [NSNumber numberWithUnsignedInteger:source.port], @"Port",
                                      nil];
    if ([source isKindOfClass:[DicomNodeIdentifier class]])
    {
        NSString *aetitle = [source.aetitle length] ? source.aetitle : source.description;
        if (![aetitle length])
            return nil;

        [probeInfo setObject:[NSNumber numberWithBool:YES] forKey:@"DICOM"];
        [probeInfo setObject:aetitle forKey:@"AETitle"];
    }

    return probeInfo;
}

-(BOOL)_runBonjourHeartbeatProbe:(NSDictionary*)probeInfo
{
    if ([[probeInfo objectForKey:@"DICOM"] boolValue])
    {
        return [QueryController echoServer:[NSDictionary dictionaryWithObjectsAndKeys:
                                            [probeInfo objectForKey:@"Address"], @"Address",
                                            [probeInfo objectForKey:@"Port"], @"Port",
                                            [probeInfo objectForKey:@"AETitle"], @"AETitle",
                                            [NSNumber numberWithBool:NO], @"TLSEnabled",
                                            [NSNumber numberWithBool:YES], @"HorosHeartbeatStrict",
                                            [NSNumber numberWithBool:YES], @"HorosHeartbeatQuiet",
                                            [NSNumber numberWithInteger:(NSInteger)HorosBonjourHeartbeatTimeout], @"HorosHeartbeatTimeout",
                                            nil]];
    }

    return HorosCanOpenTCPConnection([probeInfo objectForKey:@"Address"],
                                     [[probeInfo objectForKey:@"Port"] unsignedIntegerValue],
                                     HorosBonjourHeartbeatTimeout);
}

-(BOOL)_bonjourHeartbeatManagesSource:(DataNodeIdentifier*)source
{
    @synchronized (_bonjourSources)
    {
        return [_bonjourSources indexOfObjectIdenticalTo:source] != NSNotFound;
    }
}

-(void)_forgetBonjourHeartbeatStateForSource:(DataNodeIdentifier*)source
{
    NSString *key = [self _bonjourHeartbeatKeyForSource:source];
    if ([key length])
        [_bonjourHeartbeatFailureCounts removeObjectForKey:key];
}

-(void)_applyBonjourHeartbeatResult:(BOOL)available source:(DataNodeIdentifier*)source key:(NSString*)key
{
    if (_invalidated || ![self _bonjourHeartbeatManagesSource:source])
        return;

    BOOL isDisplayed = [_browser.sources.content indexOfObjectIdenticalTo:source] != NSNotFound;
    NSInteger previousFailureCount = [[_bonjourHeartbeatFailureCounts objectForKey:key] integerValue];

    if (available)
    {
        [_bonjourHeartbeatFailureCounts removeObjectForKey:key];
        if (![self _bonjourHeartbeatShouldProbeSource:source])
        {
            source.detected = NO;
            return;
        }

        BOOL changed = !source.detected || !isDisplayed;
        source.detected = YES;

        if (!isDisplayed)
            [_browser.sources addObject:source];

        [_browser reconcileHorosDirectSources];

        if (changed)
        {
            NSLog(@"Bonjour source responding again: %@ %@:%lu", source.description, source.location, (unsigned long)source.port);
            [_browser redrawSources];
        }
        return;
    }

    NSInteger failureCount = MIN(previousFailureCount + 1, HorosBonjourHeartbeatFailureLimit);
    [_bonjourHeartbeatFailureCounts setObject:[NSNumber numberWithInteger:failureCount] forKey:key];
    if (failureCount < HorosBonjourHeartbeatFailureLimit)
        return;

    source.detected = NO;
    if (!source.entered && isDisplayed)
    {
        [source retain];
        [_browser.sources removeObject:source];
        [source performSelector:@selector(autorelease) withObject:nil afterDelay:60];
    }

    [_browser reconcileHorosDirectSources];

    if ([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]] &&
        [[_browser sourceIdentifierForDatabase:_browser.database] isEqualToDataNodeIdentifier:source])
        [_browser performSelector:@selector(setDatabase:) withObject:DicomDatabase.defaultDatabase afterDelay:0.01];

    if (previousFailureCount < HorosBonjourHeartbeatFailureLimit)
    {
        NSLog(@"Bonjour source hidden after %ld failed availability checks: %@ %@:%lu",
              (long)HorosBonjourHeartbeatFailureLimit,
              source.description,
              source.location,
              (unsigned long)source.port);
        [_browser redrawSources];
    }
}

-(void)_verifyBonjourSource:(DataNodeIdentifier*)source
{
    if (_invalidated || ![NSThread isMainThread] || ![self _bonjourHeartbeatManagesSource:source])
        return;

    NSDictionary *probeInfo = [self _bonjourHeartbeatProbeInfoForSource:source];
    NSString *key = [probeInfo objectForKey:@"Key"];
    if (!probeInfo || [_bonjourHeartbeatInFlight containsObject:key])
        return;

    [_bonjourHeartbeatInFlight addObject:key];
    BrowserSourcesHelper *helper = self;
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        @autoreleasepool
        {
            BOOL available = [helper _runBonjourHeartbeatProbe:probeInfo];
            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                [helper->_bonjourHeartbeatInFlight removeObject:key];
                [helper _applyBonjourHeartbeatResult:available source:source key:key];
            }];
        }
    }];
    [_bonjourHeartbeatQueue addOperation:operation];
}

-(void)_verifyBonjourSources
{
    if (_invalidated)
        return;

    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread:@selector(_verifyBonjourSources) withObject:nil waitUntilDone:NO];
        return;
    }

    NSArray *sources = nil;
    @synchronized (_bonjourSources)
    {
        sources = [[_bonjourSources copy] autorelease];
    }

    for (DataNodeIdentifier *source in sources)
        [self _verifyBonjourSource:source];
}

-(BOOL)_bonjourHost:(NSString*)host matchesCurrentHost:(NSHost*)currentHost
{
    if (![host length] || currentHost == nil)
        return NO;

    if ([[self class] host:[NSHost hostWithAddressOrName:host] isEqualToHost:currentHost])
        return YES;

    NSString *cleanHost = [HorosBonjourHostWithoutTrailingDot(host) lowercaseString];
    for (NSString *localName in [currentHost names])
        if ([[HorosBonjourHostWithoutTrailingDot(localName) lowercaseString] isEqualToString:cleanHost])
            return YES;

    for (NSString *localAddress in [currentHost addresses])
        if ([[HorosBonjourHostWithoutTrailingDot(localAddress) lowercaseString] isEqualToString:cleanHost])
            return YES;

    return NO;
}

-(BOOL)_resolvedBonjourServiceIsThisHorosType:(NSString*)type name:(NSString*)name host:(NSString*)host port:(NSInteger)port txt:(NSDictionary*)txt
{
    NSString *uid = [txt objectForKey:@"UID"];
    if ([uid length] && [uid isEqualToString:[AppController UID]])
    {
        NSLog(@"Bonjour source ignored as this Horos instance UID=%@", uid);
        return YES;
    }

    NSHost *currentHost = [DefaultsOsiriX currentHost];
    if (![self _bonjourHost:host matchesCurrentHost:currentHost])
        return NO;

    if ([type isEqualToString:HorosDicomBonjourType])
    {
        NSString *localAETitle = [[NSUserDefaults standardUserDefaults] stringForKey:@"AETITLE"];
        NSString *serviceAETitle = [txt objectForKey:@"AETitle"] ? [txt objectForKey:@"AETitle"] : name;
        NSInteger localPort = [[[NSUserDefaults standardUserDefaults] stringForKey:@"AEPORT"] integerValue];

        if (localPort == port && [serviceAETitle length] && [localAETitle length] && [serviceAETitle caseInsensitiveCompare:localAETitle] == NSOrderedSame)
        {
            NSLog(@"DICOM Bonjour source ignored as this Horos instance: %@ %@:%ld", serviceAETitle, host, (long)port);
            return YES;
        }
    }
    else if ([type isEqualToString:HorosOsiriXDatabaseBonjourType])
    {
        NSInteger localPort = [AppController sharedAppController].bonjourPublisher.port;

        if (localPort > 0 && localPort == port)
        {
            NSLog(@"Horos Bonjour source ignored as this Horos instance: %@ %@:%ld", name, host, (long)port);
            return YES;
        }
    }

    return NO;
}

-(void)_startBonjourBrowsers
{
    if (_invalidated) return;
    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread:@selector(_startBonjourBrowsers) withObject:nil waitUntilDone:NO];
        return;
    }

    [self _startPhoneVolumeRenderBonjourBrowser];
    [self performSelector:@selector(_startOsirixBonjourBrowser) withObject:nil afterDelay:1.5];
    [self performSelector:@selector(_startDicomBonjourBrowser) withObject:nil afterDelay:3.0];
}

-(void)_startOsirixBonjourBrowser
{
    if (_invalidated || [[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"]) return;
    if (!_nsbOsirix)
    {
        _nsbOsirix = [[HorosBonjourBrowser alloc] init];
        [_nsbOsirix setDelegate:self];
        [_nsbOsirix searchForServicesOfType:HorosOsiriXDatabaseBonjourType inDomain:@""];
    }
}

-(void)_startDicomBonjourBrowser
{
    if (_invalidated || ![[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"]) return;
    if (!_nsbDicom)
    {
        _nsbDicom = [[HorosBonjourBrowser alloc] init];
        [_nsbDicom setDelegate:self];
        [_nsbDicom searchForServicesOfType:HorosDicomBonjourType inDomain:@""];
    }
}

-(void)_startPhoneVolumeRenderBonjourBrowser
{
    if (_invalidated) return;
    if (!_nsbPhoneVolumeRender)
    {
        _nsbPhoneVolumeRender = [[HorosBonjourBrowser alloc] init];
        [_nsbPhoneVolumeRender setDelegate:self];
        [_nsbPhoneVolumeRender searchForServicesOfType:HorosPhoneVolumeRenderBonjourType inDomain:@""];
    }
}

-(void)_observeValueForKeyPathOfObjectChangeContext:(NSArray*)args {
    [self observeValueForKeyPath:[args objectAtIndex:0] ofObject:[args objectAtIndex:1] change:[args objectAtIndex:2] context:[[args objectAtIndex:3] pointerValue]];
}

+ (BOOL)host:(NSHost*)h1 isEqualToHost:(NSHost*)h2 {
#define MAC_CONCURRENT_ISEQUALTOHOST 10
    static dispatch_semaphore_t sid = 0;
    if (!sid)
        sid = dispatch_semaphore_create(MAC_CONCURRENT_ISEQUALTOHOST);

    if (dispatch_semaphore_wait(sid, DISPATCH_TIME_FOREVER) == 0)
        @try {
            if (h1.address && h2.address && [h1.address isEqualToString:h2.address])
                return YES;
            if (h1.name && h2.name && [h1.name isEqualToString:h2.name])
                return YES;
        } @catch (...) {
            @throw;
        } @finally {
            dispatch_semaphore_signal(sid);
        }

    return NO;
}

-(void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread:@selector(_observeValueForKeyPathOfObjectChangeContext:) withObject:[NSArray arrayWithObjects: keyPath, object, change, [NSValue valueWithPointer:context], nil] waitUntilDone:NO modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
        return;
    }


    dontListenToSourcesChanges = YES;

    id previousNode = [_browser sourceIdentifierForDatabase:_browser.database];

    @try
    {
        if (context == LocalBrowserSourcesContext)
        {
            NSArray* a = [[NSUserDefaults standardUserDefaults] objectForKey:@"localDatabasePaths"];
            // remove old items
            for (DataNodeIdentifier* dni in [[_browser.sources.content copy] autorelease])
            {
                if ([dni isKindOfClass:[LocalDatabaseNodeIdentifier class]] && dni.entered) // is a local database and is flagged as "entered"
                    if (![[a valueForKey:@"Path"] containsObject:dni.location]) {          // is no longer in the entered list
                        dni.entered = NO;                                                 // mark it as not entered
                        if (!dni.detected)
                        {
                            [dni retain];
                            [_browser.sources removeObject:dni]; // not entered, not detected.. remove it
                            [dni performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
                        }
                    }
            }
            // add new items
            for (NSDictionary* d in a)
            {
                NSString* dpath = [d valueForKey:@"Path"];
                if ([[DicomDatabase baseDirPathForPath:dpath] isEqualToString:DicomDatabase.defaultDatabase.baseDirPath]) // is already listed as "default database"
                    continue;
                DataNodeIdentifier* dni;
                NSUInteger i = [[_browser.sources.content valueForKey:@"location"] indexOfObject:dpath];
                if (i == NSNotFound) {
                    dni = [LocalDatabaseNodeIdentifier localDatabaseNodeIdentifierWithPath:dpath description:[d objectForKey:@"Description"] dictionary:d];
                    dni.entered = YES;
                    [_browser.sources addObject:dni];
                } else {
                    dni = [_browser.sources.content objectAtIndex:i];
                    dni.entered = YES;
                    dni.description = [d objectForKey:@"Description"];
                    dni.dictionary = d;
                }
            }
        }

        if (context == RemoteBrowserSourcesContext)
        {
            NSHost* currentHost = [DefaultsOsiriX currentHost];
            NSArray* a = [[NSUserDefaults standardUserDefaults] objectForKey:@"OSIRIXSERVERS"];
            // remove old items
            for (DataNodeIdentifier* dni in [[_browser.sources.content copy] autorelease])
            {
                if ([dni isKindOfClass:[RemoteDatabaseNodeIdentifier class]] && dni.entered) // is a remote database and is flagged as "entered"
                    if (![[a valueForKey:@"Address"] containsObject:dni.location])          // is no longer in the entered list
                    {
                        dni.entered = NO;                                                  // mark it as not entered
                        if (!dni.detected)
                        {
                            [dni retain];
                            [_browser.sources removeObject:dni]; // not entered, not detected.. remove it
                            [dni performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
                        }
                    }
            }
            // add new items
            //        NSOperationQueue* queue = [[[NSOperationQueue alloc] init] autorelease];
            for (NSDictionary* d in a)
            {
                [NSThread performBlockInBackground:^{
                    // we're now in a background thread
                    NSString* dadd = [d valueForKey:@"Address"];
                    if ([[self class] host:[NSHost hostWithAddressOrName:dadd] isEqualToHost:currentHost]) // don't list self
                        return;
                    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        // we're now back in the main thread
                        DataNodeIdentifier* dni;
                        NSUInteger i = [[_browser.sources.content valueForKey:@"location"] indexOfObject:dadd];
                        if (i == NSNotFound) {
                            dni = [RemoteDatabaseNodeIdentifier remoteDatabaseNodeIdentifierWithLocation:dadd port:[[d valueForKey:@"Port"] intValue] description:[d objectForKey:@"Description"] dictionary:d];
                            dni.entered = YES;
                            [_browser.sources addObject:dni];
                        } else {
                            dni = [_browser.sources.content objectAtIndex:i];
                            dni.entered = YES;
                            dni.description = [d objectForKey:@"Description"];
                            dni.dictionary = d;
                        }
                    }];
                }];
            }
        }

        if (context == DicomBrowserSourcesContext)
        {
            NSMutableDictionary* aa = [NSMutableDictionary dictionary];
            // Configured DICOM servers are QR/Send presets, not Sources-pane destinations.
            // Bonjour-discovered DICOM peers are handled by SearchDicomNodesContext below.
            // remove old items
            for (DataNodeIdentifier* dni in [[_browser.sources.content copy] autorelease])
            {
                if ([dni isKindOfClass:[DicomNodeIdentifier class]] && dni.entered) // is a dicom node and is flagged as "entered"
                    if (![[aa allKeys] containsObject:dni.location]) {             // is no longer in the entered list
                        dni.entered = NO;                                         // mark it as not entered
                        if (!dni.detected)
                        {
                            [dni retain];
                            [_browser.sources removeObject:dni]; // not entered, not detected.. remove it
                            [dni performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
                        }
                    }
            }
            // add new items
            for (NSString* aak in aa)
            {
                DataNodeIdentifier* dni;
                NSUInteger i = [[_browser.sources.content valueForKey:@"location"] indexOfObject:aak];
                if (i == NSNotFound)
                {
                    NSDictionary *k = [aa objectForKey:aak];
                    dni = [DicomNodeIdentifier dicomNodeIdentifierWithLocation: [k objectForKey:@"Address"] port:[[k objectForKey:@"Port"] intValue] aetitle:[k objectForKey:@"AETitle"] description:[k objectForKey:@"Description"] dictionary:[aa objectForKey:aak]];
                    dni.entered = YES;
                    [_browser.sources addObject:dni];
                } else {
                    dni = [_browser.sources.content objectAtIndex:i];
                    dni.entered = YES;
                    dni.dictionary = [aa objectForKey:aak];
                    dni.description = [dni.dictionary objectForKey:@"Description"];
                }
            }
        }

        if (context == SearchBonjourNodesContext)
            @synchronized (_bonjourSources) {
                if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"]) // add remote databases detected with bonjour
                { // remove remote databases detected with bonjour
                    for (DataNodeIdentifier* dni in _bonjourSources)
                        if ([dni isKindOfClass:[RemoteDatabaseNodeIdentifier class]] && dni.detected) {
                            dni.detected = NO;
                            if (!dni.entered && [_browser.sources.content containsObject:dni])
                            {
                                [dni retain];
                                [_browser.sources removeObject:dni]; // not entered, not detected.. remove it
                                [dni performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
                            }
                        }
                } else
                { // add remote databases detected with bonjour
                    [self _scheduleBonjourBrowserStart];
                    for (DataNodeIdentifier* dni in _bonjourSources)
                        if ([dni isKindOfClass:[RemoteDatabaseNodeIdentifier class]] && !dni.detected && dni.location) {
                            dni.detected = YES;
                            if (![_browser.sources.content containsObject:dni])
                                [_browser.sources addObject:dni];
                        }
                }
            }

        if (context == SearchDicomNodesContext)
            @synchronized (_bonjourSources) {
                if (![[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"])
                { // remove dicom nodes detected with bonjour
                    for (DataNodeIdentifier* dni in _bonjourSources)
                        if ([dni isKindOfClass:[DicomNodeIdentifier class]] && dni.detected) {
                            dni.detected = NO;
                            if (!dni.entered && [_browser.sources.content containsObject:dni])
                            {
                                [dni retain];
                                [_browser.sources removeObject:dni]; // not entered, not detected.. remove it
                                [dni performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
                            }
                        }
                } else
                { // add dicom nodes detected with bonjour
                    [self _scheduleBonjourBrowserStart];
                    for (DataNodeIdentifier* dni in _bonjourSources)
                        if ([dni isKindOfClass:[DicomNodeIdentifier class]] && !dni.detected && dni.location) {
                            dni.detected = YES;
                            if (![_browser.sources.content containsObject:dni])
                                [_browser.sources addObject:dni];
                        }
                }
            }
    }
    @catch (NSException *exception) {
        N2LogExceptionWithStackTrace( exception);
    }

    dontListenToSourcesChanges = NO;

    [_browser reconcileHorosDirectSources];

    if( [_browser rowForSourceIdentifier: previousNode] == -1)
        [_browser performSelector: @selector(setDatabase:) withObject: DicomDatabase.defaultDatabase afterDelay: 0.01]; //This will guarantee that this will not happen in middle of a drag & drop, for example
    else
        [_browser selectSourceForDatabase: _browser.database];

}

-(NSString*)_bonjourServiceTypeForBrowser:(HorosBonjourBrowser*)browser
{
    if (browser == _nsbOsirix)
        return HorosOsiriXDatabaseBonjourType;
    if (browser == _nsbDicom)
        return HorosDicomBonjourType;
    if (browser == _nsbPhoneVolumeRender)
        return HorosPhoneVolumeRenderBonjourType;

    return @"unknown Bonjour service";
}

-(void)netServiceBrowserWillSearch:(HorosBonjourBrowser*)nsb
{
    NSString *type = [self _bonjourServiceTypeForBrowser:nsb];
    NSLog(@"Horos Network Bonjour browser searching for %@", type);
}

-(void)netServiceBrowser:(HorosBonjourBrowser*)nsb didNotSearch:(NSDictionary*)errorDict
{
    NSLog(@"Warning: Horos Bonjour browser did not search for %@: %@", [self _bonjourServiceTypeForBrowser:nsb], errorDict);

    if (nsb == _nsbOsirix)
    {
        [_nsbOsirix setDelegate:nil];
        [_nsbOsirix stop];
        [_nsbOsirix release];
        _nsbOsirix = nil;
        [self performSelector:@selector(_startOsirixBonjourBrowser) withObject:nil afterDelay:10.0];
    }
    else if (nsb == _nsbDicom)
    {
        [_nsbDicom setDelegate:nil];
        [_nsbDicom stop];
        [_nsbDicom release];
        _nsbDicom = nil;
        [self performSelector:@selector(_startDicomBonjourBrowser) withObject:nil afterDelay:10.0];
    }
    else if (nsb == _nsbPhoneVolumeRender)
    {
        [_nsbPhoneVolumeRender setDelegate:nil];
        [_nsbPhoneVolumeRender stop];
        [_nsbPhoneVolumeRender release];
        _nsbPhoneVolumeRender = nil;
        [self performSelector:@selector(_startPhoneVolumeRenderBonjourBrowser) withObject:nil afterDelay:10.0];
    }
}

-(void)netServiceDidResolveAddress:(HorosBonjourService*)service
{
    if (_invalidated) return;
    @try
    {
        [service retain];
        [service stop];

        DataNodeIdentifier* source0 = nil;
        @synchronized (_bonjourSources)
        {
            if( [_bonjourServices indexOfObject: service] != NSNotFound)
                source0 = [_bonjourSources objectAtIndex: [_bonjourServices indexOfObject: service]];
            else
                NSLog( @"***** unknown didResolve Service");
        }
        if (!source0)
            return;

        NSDictionary* resolvedTXTDictionary = nil;
        @try
        {
            NSDictionary *rawTXTDictionary = HorosSourceTXTDictionaryFromRecordData(service.TXTRecordData);
            if ([source0 isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]])
                resolvedTXTDictionary = HorosSourceTXTDictionaryFromRecordData(service.TXTRecordData);
            else if ([source0 isKindOfClass:[RemoteDatabaseNodeIdentifier class]])
                resolvedTXTDictionary = [BonjourPublisher dictionaryFromXTRecordData:service.TXTRecordData];
            else
            {
                resolvedTXTDictionary = [DCMNetServiceDelegate DICOMNodeInfoFromTXTRecordData:service.TXTRecordData];
                if ((![resolvedTXTDictionary objectForKey:@"UID"] && [rawTXTDictionary objectForKey:@"UID"]) ||
                    (![resolvedTXTDictionary objectForKey:@"AETitle"] && [rawTXTDictionary objectForKey:@"AETitle"]))
                {
                    NSMutableDictionary *mergedTXTDictionary = [NSMutableDictionary dictionaryWithDictionary:resolvedTXTDictionary ? resolvedTXTDictionary : [NSDictionary dictionary]];
                    if (![mergedTXTDictionary objectForKey:@"UID"] && [rawTXTDictionary objectForKey:@"UID"])
                        [mergedTXTDictionary setObject:[rawTXTDictionary objectForKey:@"UID"] forKey:@"UID"];
                    if (![mergedTXTDictionary objectForKey:@"AETitle"] && [rawTXTDictionary objectForKey:@"AETitle"])
                        [mergedTXTDictionary setObject:[rawTXTDictionary objectForKey:@"AETitle"] forKey:@"AETitle"];
                    resolvedTXTDictionary = mergedTXTDictionary;
                }
            }

        }
        @catch (NSException *exception) {
            N2LogException( exception);
            return;
        }

        @try {
            NSString *serviceType = nil;
            if ([source0 isKindOfClass:[RemoteDatabaseNodeIdentifier class]])
                serviceType = HorosOsiriXDatabaseBonjourType;
            else if ([source0 isKindOfClass:[DicomNodeIdentifier class]])
                serviceType = HorosDicomBonjourType;

            NSString *resolvedHost = service.resolvedAddress;
            NSInteger resolvedPort = service.port;

            if (serviceType && [self _resolvedBonjourServiceIsThisHorosType:serviceType name:service.name host:resolvedHost port:resolvedPort txt:resolvedTXTDictionary])
            {
                @synchronized (_bonjourSources)
                {
                    NSUInteger serviceIndex = [_bonjourServices indexOfObject:service];
                    NSLog(@"Remove Service: %@ ignored as this Horos instance", service);
                    if (serviceIndex != NSNotFound)
                    {
                        [_bonjourSources removeObjectAtIndex:serviceIndex];
                        [_bonjourServices removeObjectAtIndex:serviceIndex];
                    }
                    else
                        NSLog(@"***** unknown didResolve Service");
                }
                return;
            }

            DataNodeIdentifier* source = source0;

            if (resolvedHost.length && resolvedPort > 0)
            {
                if ([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]] || [source isKindOfClass:[DicomNodeIdentifier class]] || [source isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]])
                {
                    source.location = resolvedHost;
                    source.port = resolvedPort;
                }
            }

            NSUInteger i = [_browser.sources.content indexOfObject:source];
            if (i != NSNotFound) // Already known
                @synchronized (_bonjourSources)
            {
                if( [_bonjourServices indexOfObject: service] != NSNotFound)
                    [_bonjourSources replaceObjectAtIndex: [_bonjourServices indexOfObject: service] withObject: (source = [_browser.sources.content objectAtIndex:i])];
                else
                    NSLog( @"***** unknown didResolve Service");
            }

            if ([source isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]])
                source.description = NSLocalizedString(HorosPhoneVolumeRenderDisplayName, nil);
            else if ([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]] && service.name.length)
                source.description = service.name;
            else if ([source isKindOfClass:[DicomNodeIdentifier class]])
            {
                NSString *resolvedAETitle = [resolvedTXTDictionary objectForKey:@"AETitle"];
                source.aetitle = [resolvedAETitle length] ? resolvedAETitle : service.name;
            }

            NSMutableDictionary *sourceDictionary = [NSMutableDictionary dictionaryWithDictionary:resolvedTXTDictionary ? resolvedTXTDictionary : [NSDictionary dictionary]];
            if ([serviceType length] && [service.name length])
                [sourceDictionary setObject:HorosBonjourServiceKey(serviceType, service.name) forKey:@"BonjourServiceKey"];
            source.dictionary = sourceDictionary;

            if (source.location)
            {
                if (([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]] && ![[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"]) ||
                    [source isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]] ||
                    ([source isKindOfClass:[DicomNodeIdentifier class]] && [[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"])) {

                    source.detected = YES;
                    if (![_browser.sources.content containsObject:source])
                    {
                        [_browser.sources addObject:source];
                        NSLog(@"Bonjour source added: %@ %@:%ld", source.description, source.location, (long)source.port);
                    }

                    [self _verifyBonjourSource:source];
                    [_browser reconcileHorosDirectSources];
                }
            }

        }
        @catch (NSException *exception) {
            N2LogException( exception);
        }
    }
    @catch ( NSException *exception) {
        N2LogException( exception);
    }
    @finally {
        [service release];
    }
}

-(void)netService:(HorosBonjourService*)service didNotResolve:(NSDictionary*)errorDict
{
    if (_invalidated) return;
    NSLog(@"Warning: Bonjour service did not resolve: %@ error=%@", service, errorDict);
    [service stop];

    HorosBonjourService* bsk = nil;

    @synchronized (_bonjourSources) {
        for (HorosBonjourService* ibsk in _bonjourServices) {
            if ([ibsk isEqual: service]) {
                bsk = ibsk;
                break;
            }
        }

        if (!bsk)
            return;

        DataNodeIdentifier *source = [_bonjourSources objectAtIndex:[_bonjourServices indexOfObject:bsk]];
        // A refresh failure is not a service removal. Keep a resolved source
        // tracked so its existing availability checks can hide or restore it.
        if ([source.location length])
        {
            [self _verifyBonjourSource:source];
            return;
        }
        NSLog( @"Remove unresolved Service: %@", bsk);
        [self _forgetBonjourHeartbeatStateForSource:source];
        [_bonjourSources removeObjectAtIndex: [_bonjourServices indexOfObject: bsk]];
        [_bonjourServices removeObject: bsk];
    }

    [_browser reconcileHorosDirectSources];
}

-(void)netServiceBrowser:(HorosBonjourBrowser*)nsb didUpdateService:(HorosBonjourService*)service
{
    if (_invalidated) return;
    [service stop];
    if (![_bonjourServices containsObject:service])
    {
        [self netServiceBrowser:nsb didFindService:service moreComing:NO];
        return;
    }
    [service setDelegate:self];
    [service resolveWithTimeout:30];
}

-(void)netServiceBrowser:(HorosBonjourBrowser*)nsb didFindService:(HorosBonjourService*)service moreComing:(BOOL)moreComing
{
    if (_invalidated || [_bonjourServices containsObject:service]) return;

    DataNodeIdentifier* source;
    if (nsb == _nsbOsirix)
        source = [RemoteDatabaseNodeIdentifier remoteDatabaseNodeIdentifierWithLocation:nil port:0 description:service.name dictionary:nil];
    else if (nsb == _nsbPhoneVolumeRender)
        source = [PhoneVolumeRenderNodeIdentifier phoneVolumeRenderNodeIdentifierWithLocation:nil port:0 description:NSLocalizedString(HorosPhoneVolumeRenderDisplayName, nil) dictionary:nil];
    else
        source = [DicomNodeIdentifier dicomNodeIdentifierWithLocation:nil port:0 aetitle:@"" description:service.name dictionary:nil];

    @synchronized (_bonjourSources) {
        [_bonjourServices addObject: service];
        [_bonjourSources addObject: source];
    }
    NSLog( @"Find Service: %@", service);

    // resolve the address and port for this HorosBonjourService
    [service setDelegate:self];
    [service resolveWithTimeout:30];
}

-(void)netServiceBrowser:(HorosBonjourBrowser*)nsb didRemoveService:(HorosBonjourService*)service moreComing:(BOOL)moreComing
{
    NSLog(@"Bonjour service gone: %@", service);

    DataNodeIdentifier* dni;

    HorosBonjourService *bsk = nil;
    @synchronized (_bonjourSources) {
        for (HorosBonjourService* ibsk in _bonjourServices) {
            if ([ibsk isEqual: service]) {
                bsk = ibsk;
                break;
            }
        }

        if (!bsk)
            return;

        dni = [_bonjourSources objectAtIndex: [_bonjourServices indexOfObject: bsk]];

        if (([dni isKindOfClass:[RemoteDatabaseNodeIdentifier class]] && ![[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"]) ||
            [dni isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]] ||
            ([dni isKindOfClass:[DicomNodeIdentifier class]] && [[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"])) {

            dni.detected = NO;
            if (!dni.entered && [_browser.sources.content containsObject:dni])
            {
                [dni retain];
                [_browser.sources removeObject:dni]; // not entered, not detected.. remove it
                [dni performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
            }
        }

        // if the disappearing node is active, select the default DB
        if ([[_browser sourceIdentifierForDatabase:_browser.database] isEqualToDataNodeIdentifier:dni])
        {
            [_browser performSelector: @selector(setDatabase:) withObject: DicomDatabase.defaultDatabase afterDelay: 0.01]; //This will guarantee that this will not happen in middle of a drag & drop, for example
        }
        NSLog( @"Remove Service: %@", bsk);
        [self _forgetBonjourHeartbeatStateForSource:dni];
        [_bonjourSources removeObjectAtIndex: [_bonjourServices indexOfObject: bsk]];
        [_bonjourServices removeObject: bsk];
    }

    [_browser reconcileHorosDirectSources];
}

-(NSString*)tableView:(NSTableView*)tableView toolTipForCell:(NSCell*)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn*)tc row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation
{
    DataNodeIdentifier* bs = [_browser sourceIdentifierAtRow:row];
    NSString* tip = [bs toolTip];
    if (tip)
        return tip;
    return @"";
}

-(void)tableView:(NSTableView*)aTableView willDisplayCell:(PrettyCell*)cell forTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row
{
    cell.image = nil;
    cell.font = [NSFont systemFontOfSize: [_browser fontSize: @"dbSourceFont"]];
    cell.textColor = [aTableView isRowSelected:row] ? [NSColor alternateSelectedControlTextColor] : [NSColor labelColor];
    [cell.rightSubviews removeAllObjects];
    DataNodeIdentifier* bs = [_browser sourceIdentifierAtRow:row];
    cell.title = bs.description;
    [bs willDisplayCell:cell];
    if (cell.image)
    {
        NSImage *sourceImage = [[cell.image copy] autorelease];
        sourceImage.size = [sourceImage sizeByScalingProportionallyToSize:NSMakeSize(32, 32)];
        cell.image = sourceImage;
    }
}


-(NSDragOperation)tableView:(NSTableView*)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation
{
    if( operation != NSTableViewDropOn)
        return NSDragOperationNone;

    NSInteger selectedDatabaseIndex = [_browser rowForDatabase:_browser.database];
    if (row == selectedDatabaseIndex)
        return NSDragOperationNone;

    if (row >= _browser.sourcesCount && _browser.database != DicomDatabase.defaultDatabase)
    {
        [tableView setDropRow:[_browser rowForDatabase:DicomDatabase.defaultDatabase] dropOperation:NSTableViewDropOn];
        return NSDragOperationCopy;
    }

    if (row < [_browser sourcesCount])
    {
        DataNodeIdentifier *source = [_browser sourceIdentifierAtRow:row];
        if ([source isReadOnly])
            return NSDragOperationNone;
        [tableView setDropRow:row dropOperation:NSTableViewDropOn];
        return NSDragOperationCopy;
    }

    return NSDragOperationNone;
}

-(BOOL)tableView:(NSTableView*)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation
{
    NSPasteboard* pb = [info draggingPasteboard];
    NSArray* xids = [BrowserController databaseObjectXIDsFromPasteboard:pb];
    NSMutableArray* items = [NSMutableArray array];
    for (NSString* xid in xids)
        [items addObject:[_browser.database objectWithID:[NSManagedObject UidForXid:xid]]];

    NSMutableArray* dicomImages = [DicomImage dicomImagesInObjects:items];

    DataNodeIdentifier *destination = [_browser sourceIdentifierAtRow:row];
    return [_browser initiateCopyImages:dicomImages toSource:destination];
}

-(void)tableViewSelectionDidChange:(NSNotification*)notification
{
    if( dontListenToSourcesChanges == NO)
    {
        NSInteger row = [(NSTableView*)notification.object selectedRow];
        DataNodeIdentifier* bs = [_browser sourceIdentifierAtRow:row];
        [_browser setDatabaseFromSourceIdentifier:bs];
    }
}

@end

@implementation DefaultLocalDatabaseNodeIdentifier

+(DefaultLocalDatabaseNodeIdentifier*)identifier
{
    static DefaultLocalDatabaseNodeIdentifier* identifier = nil;
    if (!identifier)
        identifier = [[[self class] localDatabaseNodeIdentifierWithPath:DicomDatabase.defaultDatabase.baseDirPath] retain];
    return identifier;
}

-(void)willDisplayCell:(PrettyCell*)cell
{
    cell.font = [NSFont boldSystemFontOfSize: [[BrowserController currentBrowser] fontSize: @"dbSourceFont"]];
    cell.image = [NSImage imageNamed:@"Horos.icns"];
}

-(NSString*)description
{
    for( NSDictionary *d in [[NSUserDefaults standardUserDefaults] objectForKey:@"localDatabasePaths"])
    {
        if( [[d valueForKey:@"Path"] isEqualToString: self.location.stringByDeletingLastPathComponent])
            return [d valueForKey: @"Description"];
    }

    return [[[self.location stringByDeletingLastPathComponent] lastPathComponent] stringByAppendingString: NSLocalizedString( @" DB", @"DB = DataBase")];
}

-(CGFloat)sortValue {
    return CGFLOAT_MIN;
}

@end


@implementation UnavaliableDataNodeException
@end
