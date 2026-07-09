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
#import "BonjourPublisher.h"
#import "DicomFile.h"
#import "ThreadsManager.h"
#import "NSDictionary+N2.h"
#import "NSFileManager+N2.h"
#import "DCMNetServiceDelegate.h"
#import "AppController.h"
#import <netinet/in.h>
#import <arpa/inet.h>
#import "DicomDatabase+Scan.h"
#import "DCMPix.h"
#import "NSHost+N2.h"
#import "DefaultsOsiriX.h"
#import "NSString+N2.h"
#import "WaitRendering.h"

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
static NSString* const HorosNativeBonjourRecoveryNotificationShownKey = @"HorosNativeBonjourRecoveryNotificationShown";

static NSString* HorosNormalizedMountedSourcePath(NSString *path)
{
    if (path.length == 0)
        return nil;

    NSString *standardizedPath = [path stringByStandardizingPath];
    NSString *resolvedPath = [standardizedPath stringByResolvingSymlinksAndAliases];
    return resolvedPath.length ? resolvedPath : standardizedPath;
}

static NSDictionary* HorosSourceTXTDictionaryFromRecordData(NSData *recordData)
{
    if (!recordData.length)
        return [NSDictionary dictionary];

    NSDictionary *raw = [NSNetService dictionaryFromTXTRecordData:recordData];
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

static NSString* HorosDNSSDServiceKey(NSString *type, NSString *name)
{
    return [NSString stringWithFormat:@"%@|%@", type ? type : @"", name ? name : @""];
}

static NSString* HorosDNSSDTrimmedString(NSString *string)
{
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString* HorosDNSSDHostWithoutTrailingDot(NSString *host)
{
    NSMutableString *cleanHost = [NSMutableString stringWithString:HorosDNSSDTrimmedString(host)];
    while ([cleanHost hasSuffix:@"."])
        [cleanHost deleteCharactersInRange:NSMakeRange([cleanHost length] - 1, 1)];
    return cleanHost;
}

static NSString* HorosDNSSDUnescapedString(NSString *string)
{
    NSMutableString *decoded = [NSMutableString string];
    for (NSUInteger i = 0; i < [string length];)
    {
        unichar c = [string characterAtIndex:i];
        if (c == '\\' && i + 1 < [string length])
        {
            if (i + 3 < [string length])
            {
                NSString *digits = [string substringWithRange:NSMakeRange(i + 1, 3)];
                NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
                if ([digits rangeOfCharacterFromSet:nonDigits].location == NSNotFound)
                {
                    unichar escaped = (unichar)[digits intValue];
                    [decoded appendFormat:@"%C", escaped];
                    i += 4;
                    continue;
                }
            }

            [decoded appendFormat:@"%C", [string characterAtIndex:i + 1]];
            i += 2;
            continue;
        }

        [decoded appendFormat:@"%C", c];
        i++;
    }

    return decoded;
}

static NSDictionary* HorosDNSSDTXTDictionaryFromLine(NSString *line)
{
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
    for (NSString *token in [HorosDNSSDTrimmedString(line) componentsSeparatedByCharactersInSet:whitespace])
    {
        if (![token length])
            continue;

        NSRange separator = [token rangeOfString:@"="];
        if (separator.location == NSNotFound || separator.location == 0)
            continue;

        NSString *key = [token substringToIndex:separator.location];
        NSString *value = [token substringFromIndex:NSMaxRange(separator)];
        [dictionary setObject:HorosDNSSDUnescapedString(value) forKey:key];
    }

    return dictionary;
}

/*
 #include <IOKit/IOKitLib.h>
 #include <IOKit/IOMessage.h>
 #include <IOKit/IOCFPlugIn.h>
 #include <IOKit/usb/IOUSBLib.h>
 */

@class MountedDatabaseNodeIdentifier;

@interface BrowserSourcesHelper : NSObject<NSNetServiceBrowserDelegate, NSNetServiceDelegate>/*<NSTableViewDelegate,NSTableViewDataSource>*/
{
    BrowserController* _browser;
    NSNetServiceBrowser* _nsbOsirix;
    NSNetServiceBrowser* _nsbDicom;
    NSNetServiceBrowser* _nsbPhoneVolumeRender;
    NSMutableArray* _bonjourSources, *_bonjourServices;
    NSMutableDictionary *_dnssdBrowseTasks, *_dnssdBrowseBuffers;
    NSMutableDictionary *_dnssdResolveTasks, *_dnssdResolveBuffers, *_dnssdResolveInfos;

    BOOL dontListenToSourcesChanges;
}

-(id)initWithBrowser:(BrowserController*)browser;
-(void)_scheduleBonjourBrowserStart;
-(void)_startBonjourBrowsers;
-(void)_startOsirixBonjourBrowser;
-(void)_startDicomBonjourBrowser;
-(void)_startPhoneVolumeRenderBonjourBrowser;
-(void)_stopBonjourBrowsers;
-(void)_startDNSSDBrowseFallbackForType:(NSString*)type;
-(void)_stopDNSSDBrowseFallbackForType:(NSString*)type;
-(void)_stopDNSSDFallbacks;
-(void)_stopDNSSDResolveTaskForKey:(NSString*)key;
-(void)_appendDNSSDOutputData:(NSData*)data key:(NSString*)key resolving:(BOOL)resolving;
-(void)_processDNSSDBrowseLine:(NSString*)line type:(NSString*)type;
-(void)_processDNSSDResolveLine:(NSString*)line key:(NSString*)key;
-(void)_resolveDNSSDServiceName:(NSString*)name type:(NSString*)type;
-(void)_removeDNSSDServiceName:(NSString*)name type:(NSString*)type;
-(BOOL)_dnssdResolvedServiceIsThisHorosType:(NSString*)type name:(NSString*)name host:(NSString*)host port:(NSInteger)port txt:(NSDictionary*)txt;
-(void)_addDNSSDResolvedServiceForKey:(NSString*)key;
-(void)_notifyIfNativeBonjourSearchRecoveredForType:(NSString*)type;
-(void)_analyzeVolumeAtPath:(NSString*)path;
-(NSString*)_bonjourServiceTypeForBrowser:(NSNetServiceBrowser*)browser;
-(MountedDatabaseNodeIdentifier*)_deduplicateMountedSourcesForPath:(NSString*)path;
-(MountedDatabaseNodeIdentifier*)_deduplicateMountedSourcesForPath:(NSString*)path identity:(NSString*)identity;
-(void)_addMountedSourceForPath:(NSString*)path description:(NSString*)description type:(NSInteger)type;
-(void)_addMountedSourceForPath:(NSString*)path description:(NSString*)description type:(NSInteger)type identity:(NSString*)identity;

@end

@interface DefaultLocalDatabaseNodeIdentifier : LocalDatabaseNodeIdentifier

+(DefaultLocalDatabaseNodeIdentifier*)identifier;

@end

/*@interface BonjourDataNodeIdentifier : DataNodeIdentifier
 {
	NSNetService* _service;
 }

 @property(retain) NSNetService* service;

 -(NSInteger)port;

 @end*/

@interface MountedDatabaseNodeIdentifier : LocalDatabaseNodeIdentifier
{
    NSString* _devicePath;
    NSString* _mountIdentity;
    DicomDatabase* _database;
    NSInteger _mountType;
    NSThread* _scanThread;
    NSButton* _unmountButton;
}

enum {
    MountTypeGeneric = 0,
    MountTypeIPod = 1
};

@property(retain) NSString* devicePath;
@property(retain) NSString* mountIdentity;
@property NSInteger mountType;

+(id)mountedDatabaseNodeIdentifierWithPath:(NSString*)devicePath description:(NSString*)description dictionary:(NSDictionary*)dictionary type:(NSInteger)type;

-(void)willUnmount;

@end

static NSString* HorosStringValueFromDiskutilInfo(NSDictionary *info, NSString *key)
{
    id value = [info objectForKey:key];
    if ([value isKindOfClass:[NSString class]])
        return [value length] ? value : nil;
    if ([value respondsToSelector:@selector(stringValue)])
        return [[value stringValue] length] ? [value stringValue] : nil;
    return nil;
}

static NSArray* HorosMountedSourceIdentitiesFromDiskutilInfo(NSDictionary *info)
{
    NSMutableArray *identities = [NSMutableArray array];
    for (NSString *key in [NSArray arrayWithObjects:@"VolumeUUID", @"APFSVolumeUUID", @"DiskUUID", @"MediaUUID", @"DeviceIdentifier", @"DeviceNode", nil])
    {
        NSString *value = HorosStringValueFromDiskutilInfo(info, key);
        if (value.length)
            [identities addObject:[NSString stringWithFormat:@"%@:%@", key, value]];
    }

    return identities;
}

static NSString* HorosMountedSourceIdentityFromDiskutilInfo(NSDictionary *info)
{
    NSArray *identities = HorosMountedSourceIdentitiesFromDiskutilInfo(info);
    return identities.count ? [identities componentsJoinedByString:@"\n"] : nil;
}

static BOOL HorosMountedSourceIdentityMatches(NSString *sourceIdentity, NSString *identity)
{
    if (!sourceIdentity.length || !identity.length)
        return NO;

    NSArray *sourceIdentities = [sourceIdentity componentsSeparatedByString:@"\n"];
    NSArray *identities = [identity componentsSeparatedByString:@"\n"];
    for (NSString *sourceToken in sourceIdentities)
        if (sourceToken.length && [identities containsObject:sourceToken])
            return YES;

    return NO;
}

static NSArray* HorosMountedSourcesForPathOrIdentity(NSArray *sources, NSString *path, NSString *identity)
{
    NSString *normalizedPath = HorosNormalizedMountedSourcePath(path);
    if (normalizedPath.length == 0 && identity.length == 0)
        return [NSArray array];

    NSMutableArray *matches = [NSMutableArray array];
    for (MountedDatabaseNodeIdentifier* source in sources)
    {
        if ([source isKindOfClass:[MountedDatabaseNodeIdentifier class]] == NO)
            continue;

        NSString *normalizedSourcePath = HorosNormalizedMountedSourcePath(source.devicePath);
        if ((identity.length && HorosMountedSourceIdentityMatches(source.mountIdentity, identity)) ||
            (normalizedPath.length && [normalizedSourcePath isEqualToString:normalizedPath]))
            [matches addObject: source];
    }

    return matches;
}

static NSArray* HorosMountedSourcesForPath(NSArray *sources, NSString *path)
{
    return HorosMountedSourcesForPathOrIdentity(sources, path, nil);
}

@interface UnavaliableDataNodeException : NSException
@end

@implementation BrowserController (Sources)

-(void)removePathFromSources:(NSString*) path
{
    NSArray *mountedSources = HorosMountedSourcesForPath(self.sources.arrangedObjects, path);
    for (MountedDatabaseNodeIdentifier* mbs in mountedSources)
    {
        if ([[self sourceIdentifierForDatabase:self.database] isEqualToDataNodeIdentifier:mbs])
            [self performSelector: @selector(setDatabase:) withObject: DicomDatabase.defaultDatabase afterDelay: 0.01]; //This will guarantee that this will not happen in middle of a drag & drop, for example

        [mbs retain];
        [self.sources removeObject:mbs];
        [mbs willUnmount];
        [mbs performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
    }
}

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

    [self selectCurrentDatabaseSource];
}

-(void)deallocSources
{
    [_sourcesHelper release]; _sourcesHelper = nil;
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
        NSBeginAlertSheet([why objectAtIndex:0], nil, nil, nil, self.window, NSApp, @selector(endSheet:), nil, nil, @"%@", [why objectAtIndex:1]);
}

-(NSThread*)initiateSetDatabaseAtPath:(NSString*)path name:(NSString*)name
{
    NSArray* io = [NSMutableArray arrayWithObjects: @"Local", path, name, nil];

    NSThread* thread = [[[NSThread alloc] initWithTarget:self selector:@selector(setDatabaseThread:) object:io] autorelease];
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

    NSThread* thread = [[NSThread alloc] initWithTarget:self selector:@selector(setDatabaseThread:) object:io];
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
        NSBeginAlertSheet(NSLocalizedString(@"Sources", nil), nil, nil, nil, self.window, NSApp, @selector(endSheet:), nil, nil, @"%@", [e reason]);
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
        _dnssdBrowseTasks = [[NSMutableDictionary alloc] init];
        _dnssdBrowseBuffers = [[NSMutableDictionary alloc] init];
        _dnssdResolveTasks = [[NSMutableDictionary alloc] init];
        _dnssdResolveBuffers = [[NSMutableDictionary alloc] init];
        _dnssdResolveInfos = [[NSMutableDictionary alloc] init];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:@"searchDICOMBonjour" options:NSKeyValueObservingOptionInitial context:SearchDicomNodesContext];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:@"DoNotSearchForBonjourServices" options:NSKeyValueObservingOptionInitial context:SearchBonjourNodesContext];
        NSLog(@"Horos NSBonjourServices: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSBonjourServices"]);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
        [self _scheduleBonjourBrowserStart];

        // mounted devices
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(_observeVolumeNotification:) name:NSWorkspaceDidMountNotification object:nil];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(_observeVolumeNotification:) name:NSWorkspaceDidUnmountNotification object:nil];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(_observeVolumeNotification:) name:NSWorkspaceDidRenameVolumeNotification object:nil];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(_observeVolumeWillUnmountNotification:) name:NSWorkspaceWillUnmountNotification object:nil];

        // Is there a DICOMDIR at the same level of OsiriX ?
        NSString *appFolder = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
        if( [[NSFileManager defaultManager] fileExistsAtPath: [appFolder stringByAppendingPathComponent: @"DICOMDIR"]])
        {
            [self _addMountedSourceForPath:appFolder description:appFolder.lastPathComponent type:MountTypeGeneric];
        }
        else if ( [[NSFileManager defaultManager] fileExistsAtPath: [appFolder stringByAppendingPathComponent: @"DICOMDIRPATH"]]) // Created by OsiriX Lite App Launcher (see main.mm)
        {
            NSString *dicomdir = [NSString stringWithContentsOfFile: [appFolder stringByAppendingPathComponent: @"DICOMDIRPATH"] encoding: NSUTF8StringEncoding error:nil];

            if( [[NSFileManager defaultManager] fileExistsAtPath: dicomdir])
                [self _addMountedSourceForPath:dicomdir.stringByDeletingLastPathComponent description:dicomdir.stringByDeletingLastPathComponent.lastPathComponent type:MountTypeGeneric];
        }
        else
        {
            int mode = [[NSUserDefaults standardUserDefaults] integerForKey: @"MOUNT"];

            if( mode != 2)
            {
                for (NSString* path in [[NSWorkspace sharedWorkspace] mountedRemovableMedia])
                    [self _analyzeVolumeAtPath:path];
            }
        }
    }

    return self;
}

-(void)dealloc
{
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self name:NSWorkspaceDidMountNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self name:NSWorkspaceDidUnmountNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self name:NSWorkspaceWillUnmountNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self name:NSWorkspaceDidRenameVolumeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startBonjourBrowsers) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startOsirixBonjourBrowser) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startDicomBonjourBrowser) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_startPhoneVolumeRenderBonjourBrowser) object:nil];

    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"DoNotSearchForBonjourServices"];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"searchDICOMBonjour"];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"SERVERS"];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"OSIRIXSERVERS"];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:@"localDatabasePaths"];

    [self _stopBonjourBrowsers];
    [self _stopDNSSDFallbacks];
    [_bonjourSources release];
    [_bonjourServices release];
    [_dnssdBrowseTasks release];
    [_dnssdBrowseBuffers release];
    [_dnssdResolveTasks release];
    [_dnssdResolveBuffers release];
    [_dnssdResolveInfos release];

    //	[[[NSUserDefaults standardUserDefaults] objectForKey:@"localDatabasePaths"] removeObserver:self forValuesKey:@"values"];
    _browser = nil;
    [super dealloc];
}

-(void)_applicationDidBecomeActive:(NSNotification*)notification
{
    [self _scheduleBonjourBrowserStart];
}

-(void)_scheduleBonjourBrowserStart
{
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

-(void)_stopDNSSDFallbacks
{
    for (NSTask *task in [_dnssdBrowseTasks allValues])
    {
        NSFileHandle *handle = [[task standardOutput] fileHandleForReading];
        [handle setReadabilityHandler:nil];
        if ([task isRunning])
            [task terminate];
    }

    for (NSString *key in [_dnssdResolveTasks allKeys])
        [self _stopDNSSDResolveTaskForKey:key];

    [_dnssdBrowseTasks removeAllObjects];
    [_dnssdBrowseBuffers removeAllObjects];
    [_dnssdResolveTasks removeAllObjects];
    [_dnssdResolveBuffers removeAllObjects];
    [_dnssdResolveInfos removeAllObjects];
}

-(void)_startDNSSDBrowseFallbackForType:(NSString*)type
{
    if (!type.length || [_dnssdBrowseTasks objectForKey:type])
        return;

    if (![type isEqualToString:HorosOsiriXDatabaseBonjourType] && ![type isEqualToString:HorosDicomBonjourType])
        return;

    if ([type isEqualToString:HorosOsiriXDatabaseBonjourType] && [[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"])
        return;

    if ([type isEqualToString:HorosDicomBonjourType] && ![[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"])
        return;

    NSString *dnsSDPath = @"/usr/bin/dns-sd";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:dnsSDPath])
    {
        NSLog(@"Warning: DNS-SD Bonjour fallback unavailable: %@", dnsSDPath);
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    [task setExecutableURL:[NSURL fileURLWithPath:dnsSDPath]];
    [task setArguments:[NSArray arrayWithObjects:@"-B", type, @"local", nil]];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];

    [_dnssdBrowseTasks setObject:task forKey:type];
    [_dnssdBrowseBuffers setObject:[NSMutableString string] forKey:type];

    BrowserSourcesHelper *helper = self;
    NSString *taskKey = [[type copy] autorelease];
    [[pipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (![data length])
        {
            [handle setReadabilityHandler:nil];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [helper _appendDNSSDOutputData:data key:taskKey resolving:NO];
        });
    }];

    @try
    {
        HorosLaunchTaskOrRaise(task);
        NSLog(@"DNS-SD Bonjour fallback browsing for %@", type);
    }
    @catch (NSException *exception)
    {
        NSLog(@"Warning: DNS-SD Bonjour fallback failed for %@: %@", type, exception);
        [[pipe fileHandleForReading] setReadabilityHandler:nil];
        [_dnssdBrowseTasks removeObjectForKey:type];
        [_dnssdBrowseBuffers removeObjectForKey:type];
    }

    [task release];
}

-(void)_stopDNSSDBrowseFallbackForType:(NSString*)type
{
    NSTask *task = [_dnssdBrowseTasks objectForKey:type];
    if (task)
    {
        NSFileHandle *handle = [[task standardOutput] fileHandleForReading];
        [handle setReadabilityHandler:nil];
        if ([task isRunning])
            [task terminate];
        [_dnssdBrowseTasks removeObjectForKey:type];
        [_dnssdBrowseBuffers removeObjectForKey:type];
    }

    NSString *prefix = [NSString stringWithFormat:@"%@|", type];
    for (NSString *key in [[[_dnssdResolveTasks allKeys] copy] autorelease])
    {
        if ([key hasPrefix:prefix])
            [self _stopDNSSDResolveTaskForKey:key];
    }
}

-(void)_stopDNSSDResolveTaskForKey:(NSString*)key
{
    NSTask *task = [_dnssdResolveTasks objectForKey:key];
    if (!task)
        return;

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_stopDNSSDResolveTaskForKey:) object:key];
    NSFileHandle *handle = [[task standardOutput] fileHandleForReading];
    [handle setReadabilityHandler:nil];
    if ([task isRunning])
        [task terminate];

    [_dnssdResolveTasks removeObjectForKey:key];
    [_dnssdResolveBuffers removeObjectForKey:key];
    [_dnssdResolveInfos removeObjectForKey:key];
}

-(void)_appendDNSSDOutputData:(NSData*)data key:(NSString*)key resolving:(BOOL)resolving
{
    if (![NSThread isMainThread])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _appendDNSSDOutputData:data key:key resolving:resolving];
        });
        return;
    }

    NSString *chunk = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!chunk)
        chunk = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
    if (![chunk length])
        return;

    NSMutableDictionary *buffers = resolving ? _dnssdResolveBuffers : _dnssdBrowseBuffers;
    NSMutableString *buffer = [buffers objectForKey:key];
    if (!buffer)
    {
        buffer = [NSMutableString string];
        [buffers setObject:buffer forKey:key];
    }

    [buffer appendString:chunk];
    NSArray *lines = [buffer componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if ([lines count] == 0)
        return;

    [buffer setString:[lines lastObject]];
    for (NSUInteger i = 0; i + 1 < [lines count]; i++)
    {
        NSString *line = [lines objectAtIndex:i];
        if (resolving)
            [self _processDNSSDResolveLine:line key:key];
        else
            [self _processDNSSDBrowseLine:line type:key];
    }
}

-(void)_processDNSSDBrowseLine:(NSString*)line type:(NSString*)type
{
    NSString *trimmed = HorosDNSSDTrimmedString(line);
    if (![trimmed length])
        return;

    if ([trimmed rangeOfString:@"failed" options:NSCaseInsensitiveSearch].location != NSNotFound)
        NSLog(@"Warning: DNS-SD Bonjour fallback for %@ reported: %@", type, trimmed);

    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])
        if ([part length])
            [parts addObject:part];

    if ([parts count] < 7)
        return;

    NSString *action = [parts objectAtIndex:1];
    NSString *reportedType = [parts objectAtIndex:5];
    if (![reportedType hasPrefix:type])
        return;

    NSRange typeRange = [line rangeOfString:reportedType];
    NSString *name = nil;
    if (typeRange.location != NSNotFound)
        name = HorosDNSSDUnescapedString(HorosDNSSDTrimmedString([line substringFromIndex:NSMaxRange(typeRange)]));
    if (![name length])
        return;

    if ([action isEqualToString:@"Add"])
        [self _resolveDNSSDServiceName:name type:type];
    else if ([action isEqualToString:@"Rmv"])
        [self _removeDNSSDServiceName:name type:type];
}

-(void)_resolveDNSSDServiceName:(NSString*)name type:(NSString*)type
{
    if ([type isEqualToString:HorosOsiriXDatabaseBonjourType] && [[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"])
        return;

    if ([type isEqualToString:HorosDicomBonjourType] && ![[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"])
        return;

    NSString *key = HorosDNSSDServiceKey(type, name);
    if ([_dnssdResolveTasks objectForKey:key])
        return;

    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObjectsAndKeys:type, @"Type", name, @"Name", nil];
    [_dnssdResolveInfos setObject:info forKey:key];

    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    [task setExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/dns-sd"]];
    [task setArguments:[NSArray arrayWithObjects:@"-L", name, type, @"local", nil]];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];

    [_dnssdResolveTasks setObject:task forKey:key];
    [_dnssdResolveBuffers setObject:[NSMutableString string] forKey:key];

    BrowserSourcesHelper *helper = self;
    NSString *taskKey = [[key copy] autorelease];
    [[pipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (![data length])
        {
            [handle setReadabilityHandler:nil];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [helper _appendDNSSDOutputData:data key:taskKey resolving:YES];
        });
    }];

    @try
    {
        HorosLaunchTaskOrRaise(task);
        [self performSelector:@selector(_stopDNSSDResolveTaskForKey:) withObject:key afterDelay:10.0];
    }
    @catch (NSException *exception)
    {
        NSLog(@"Warning: DNS-SD Bonjour fallback resolve failed for %@: %@", key, exception);
        [[pipe fileHandleForReading] setReadabilityHandler:nil];
        [_dnssdResolveTasks removeObjectForKey:key];
        [_dnssdResolveBuffers removeObjectForKey:key];
        [_dnssdResolveInfos removeObjectForKey:key];
    }

    [task release];
}

-(void)_processDNSSDResolveLine:(NSString*)line key:(NSString*)key
{
    NSMutableDictionary *info = [_dnssdResolveInfos objectForKey:key];
    if (!info)
        return;

    NSRange reachedRange = [line rangeOfString:@" can be reached at "];
    if (reachedRange.location != NSNotFound)
    {
        NSString *hostAndPort = [line substringFromIndex:NSMaxRange(reachedRange)];
        NSRange interfaceRange = [hostAndPort rangeOfString:@" (interface"];
        if (interfaceRange.location != NSNotFound)
            hostAndPort = [hostAndPort substringToIndex:interfaceRange.location];

        hostAndPort = HorosDNSSDTrimmedString(hostAndPort);
        NSRange portRange = [hostAndPort rangeOfString:@":" options:NSBackwardsSearch];
        if (portRange.location != NSNotFound && portRange.location + 1 < [hostAndPort length])
        {
            NSString *host = HorosDNSSDHostWithoutTrailingDot([hostAndPort substringToIndex:portRange.location]);
            NSInteger port = [[hostAndPort substringFromIndex:NSMaxRange(portRange)] integerValue];
            if ([host length] && port > 0)
            {
                [info setObject:host forKey:@"Host"];
                [info setObject:[NSNumber numberWithInteger:port] forKey:@"Port"];
            }
        }
    }
    else if ([line rangeOfString:@"="].location != NSNotFound)
    {
        NSDictionary *txt = HorosDNSSDTXTDictionaryFromLine(line);
        if ([txt count])
            [info setObject:txt forKey:@"TXT"];
    }

    NSString *type = [info objectForKey:@"Type"];
    BOOL hasAddress = [[info objectForKey:@"Host"] length] && [[info objectForKey:@"Port"] integerValue] > 0;
    BOOL hasTXT = [[info objectForKey:@"TXT"] count] > 0;
    if (hasAddress && (hasTXT || ![type isEqualToString:HorosOsiriXDatabaseBonjourType]))
        [self _addDNSSDResolvedServiceForKey:key];
}

-(BOOL)_dnssdHost:(NSString*)host matchesCurrentHost:(NSHost*)currentHost
{
    if (![host length] || currentHost == nil)
        return NO;

    if ([[self class] host:[NSHost hostWithAddressOrName:host] isEqualToHost:currentHost])
        return YES;

    NSString *cleanHost = [HorosDNSSDHostWithoutTrailingDot(host) lowercaseString];
    for (NSString *localName in [currentHost names])
        if ([[HorosDNSSDHostWithoutTrailingDot(localName) lowercaseString] isEqualToString:cleanHost])
            return YES;

    for (NSString *localAddress in [currentHost addresses])
        if ([[HorosDNSSDHostWithoutTrailingDot(localAddress) lowercaseString] isEqualToString:cleanHost])
            return YES;

    return NO;
}

-(BOOL)_dnssdResolvedServiceIsThisHorosType:(NSString*)type name:(NSString*)name host:(NSString*)host port:(NSInteger)port txt:(NSDictionary*)txt
{
    NSString *uid = [txt objectForKey:@"UID"];
    if ([uid length] && [uid isEqualToString:[AppController UID]])
    {
        NSLog(@"DNS-SD Bonjour source ignored as this Horos instance UID=%@", uid);
        return YES;
    }

    NSHost *currentHost = [DefaultsOsiriX currentHost];
    if (![self _dnssdHost:host matchesCurrentHost:currentHost])
        return NO;

    if ([type isEqualToString:HorosDicomBonjourType])
    {
        NSString *localAETitle = [[NSUserDefaults standardUserDefaults] stringForKey:@"AETITLE"];
        NSString *serviceAETitle = [txt objectForKey:@"AETitle"] ? [txt objectForKey:@"AETitle"] : name;
        NSInteger localPort = [[[NSUserDefaults standardUserDefaults] stringForKey:@"AEPORT"] integerValue];

        if (localPort == port && [serviceAETitle length] && [localAETitle length] && [serviceAETitle caseInsensitiveCompare:localAETitle] == NSOrderedSame)
        {
            NSLog(@"DNS-SD DICOM Bonjour source ignored as this Horos instance: %@ %@:%ld", serviceAETitle, host, (long)port);
            return YES;
        }
    }
    else if ([type isEqualToString:HorosOsiriXDatabaseBonjourType])
    {
        NSString *localName = [NSUserDefaults bonjourSharingName];
        NSInteger localPort = [[[AppController sharedAppController] bonjourPublisher] OsiriXDBCurrentPort];

        if (localPort == port && [name length] && [localName length] && [name caseInsensitiveCompare:localName] == NSOrderedSame)
        {
            NSLog(@"DNS-SD Horos Bonjour source ignored as this Horos instance: %@ %@:%ld", name, host, (long)port);
            return YES;
        }
    }

    return NO;
}

-(void)_addDNSSDResolvedServiceForKey:(NSString*)key
{
    NSMutableDictionary *info = [_dnssdResolveInfos objectForKey:key];
    NSString *type = [info objectForKey:@"Type"];
    NSString *name = [info objectForKey:@"Name"];
    NSString *host = [info objectForKey:@"Host"];
    NSInteger port = [[info objectForKey:@"Port"] integerValue];
    NSDictionary *txt = [info objectForKey:@"TXT"] ? [info objectForKey:@"TXT"] : [NSDictionary dictionary];

    if (![type length] || ![name length] || ![host length] || port <= 0)
        return;

    if ([self _dnssdResolvedServiceIsThisHorosType:type name:name host:host port:port txt:txt])
    {
        [self _stopDNSSDResolveTaskForKey:key];
        return;
    }

    NSMutableDictionary *sourceDictionary = [NSMutableDictionary dictionaryWithDictionary:txt];
    [sourceDictionary setObject:key forKey:@"DNSSDServiceKey"];

    DataNodeIdentifier *source = nil;
    if ([type isEqualToString:HorosOsiriXDatabaseBonjourType])
        source = [RemoteDatabaseNodeIdentifier remoteDatabaseNodeIdentifierWithLocation:host port:port description:name dictionary:sourceDictionary];
    else if ([type isEqualToString:HorosDicomBonjourType])
    {
        NSString *aet = [txt objectForKey:@"AETitle"] ? [txt objectForKey:@"AETitle"] : name;
        source = [DicomNodeIdentifier dicomNodeIdentifierWithLocation:host port:port aetitle:aet description:name dictionary:sourceDictionary];
    }

    if (!source)
        return;

    @synchronized (_bonjourSources)
    {
        for (DataNodeIdentifier *bonjourSource in _bonjourSources)
        {
            if ([[bonjourSource.dictionary objectForKey:@"DNSSDServiceKey"] isEqualToString:key])
            {
                [self _stopDNSSDResolveTaskForKey:key];
                return;
            }
        }

        NSUInteger existingIndex = [_browser.sources.content indexOfObject:source];
        if (existingIndex != NSNotFound)
        {
            source = [_browser.sources.content objectAtIndex:existingIndex];
            NSMutableDictionary *mergedDictionary = [NSMutableDictionary dictionaryWithDictionary:source.dictionary ? source.dictionary : [NSDictionary dictionary]];
            [mergedDictionary addEntriesFromDictionary:sourceDictionary];
            source.dictionary = mergedDictionary;
        }
        else
            source.dictionary = sourceDictionary;

        [_bonjourSources addObject:source];
        [_bonjourServices addObject:[NSNull null]];

        if (([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]] && ![[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"]) ||
            ([source isKindOfClass:[DicomNodeIdentifier class]] && [[NSUserDefaults standardUserDefaults] boolForKey:@"searchDICOMBonjour"]))
        {
            source.detected = YES;
            if (![_browser.sources.content containsObject:source])
            {
                [_browser.sources addObject:source];
                NSLog(@"DNS-SD Bonjour source added: %@ %@:%ld", source.description, source.location, (long)source.port);
            }
        }
    }

    [self _stopDNSSDResolveTaskForKey:key];
}

-(void)_removeDNSSDServiceName:(NSString*)name type:(NSString*)type
{
    NSString *key = HorosDNSSDServiceKey(type, name);
    @synchronized (_bonjourSources)
    {
        for (NSUInteger i = 0; i < [_bonjourSources count]; i++)
        {
            DataNodeIdentifier *source = [_bonjourSources objectAtIndex:i];
            if (![[source.dictionary objectForKey:@"DNSSDServiceKey"] isEqualToString:key])
                continue;

            source.detected = NO;
            if (!source.entered && [_browser.sources.content containsObject:source])
            {
                [source retain];
                [_browser.sources removeObject:source];
                [source performSelector:@selector(autorelease) withObject:nil afterDelay:60];
            }

            [_bonjourSources removeObjectAtIndex:i];
            [_bonjourServices removeObjectAtIndex:i];
            break;
        }
    }
}

-(void)_notifyIfNativeBonjourSearchRecoveredForType:(NSString*)type
{
    if (![type isEqualToString:HorosOsiriXDatabaseBonjourType] && ![type isEqualToString:HorosDicomBonjourType])
        return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:HorosNativeBonjourRecoveryNotificationShownKey])
        return;

    [defaults setBool:YES forKey:HorosNativeBonjourRecoveryNotificationShownKey];
    [defaults synchronize];

    NSString *message = [NSString stringWithFormat:@"Native NSNetServiceBrowser started for %@. Revisit the DNS-SD Bonjour fallback and simplify this code.", type];
    NSLog(@"%@", message);
    [[AppController sharedAppController] notificationTitle:@"Horos Bonjour workaround may be removable" description:message name:@"bonjour"];
}

-(void)_startBonjourBrowsers
{
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
    if ([_dnssdBrowseTasks objectForKey:HorosOsiriXDatabaseBonjourType])
        return;

    if (!_nsbOsirix)
    {
        _nsbOsirix = [[NSNetServiceBrowser alloc] init];
        [_nsbOsirix setDelegate:self];
        [_nsbOsirix searchForServicesOfType:HorosOsiriXDatabaseBonjourType inDomain:@""];
    }
}

-(void)_startDicomBonjourBrowser
{
    if ([_dnssdBrowseTasks objectForKey:HorosDicomBonjourType])
        return;

    if (!_nsbDicom)
    {
        _nsbDicom = [[NSNetServiceBrowser alloc] init];
        [_nsbDicom setDelegate:self];
        [_nsbDicom searchForServicesOfType:HorosDicomBonjourType inDomain:@""];
    }
}

-(void)_startPhoneVolumeRenderBonjourBrowser
{
    if (!_nsbPhoneVolumeRender)
    {
        _nsbPhoneVolumeRender = [[NSNetServiceBrowser alloc] init];
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
            //             return [h1 isEqualToHost:h2];
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

    //    NSKeyValueChange changeKind = [[change valueForKey:NSKeyValueChangeKindKey] unsignedIntegerValue];

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
                //                [NSThread performBlockInBackground:^{
                //                    // we're now in a background thread
                //                    NSString* aet = nil;
                //                    if ([[self class] host:[DicomNodeIdentifier location:aak toHost:NULL port:NULL aet:&aet] isEqualToHost:currentHost] && [aet isEqualToString:[[NSUserDefaults standardUserDefaults] stringForKey:@"AETITLE"]]) // don't list self
                //                        return;
                //                    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                // we're now back in the main thread
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
                //                    }];
                //                }];
            }
        }

        if (context == SearchBonjourNodesContext)
            @synchronized (_bonjourSources) {
                if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DoNotSearchForBonjourServices"]) // add remote databases detected with bonjour
                { // remove remote databases detected with bonjour
                    [self _stopDNSSDBrowseFallbackForType:HorosOsiriXDatabaseBonjourType];
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
                    [self _stopDNSSDBrowseFallbackForType:HorosDicomBonjourType];
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

    if( [_browser rowForSourceIdentifier: previousNode] == -1)
        [_browser performSelector: @selector(setDatabase:) withObject: DicomDatabase.defaultDatabase afterDelay: 0.01]; //This will guarantee that this will not happen in middle of a drag & drop, for example
    else
        [_browser selectSourceForDatabase: _browser.database];
}

-(NSString*)_bonjourServiceTypeForBrowser:(NSNetServiceBrowser*)browser
{
    if (browser == _nsbOsirix)
        return HorosOsiriXDatabaseBonjourType;
    if (browser == _nsbDicom)
        return HorosDicomBonjourType;
    if (browser == _nsbPhoneVolumeRender)
        return HorosPhoneVolumeRenderBonjourType;

    return @"unknown Bonjour service";
}

-(void)netServiceBrowserWillSearch:(NSNetServiceBrowser*)nsb
{
    NSString *type = [self _bonjourServiceTypeForBrowser:nsb];
    NSLog(@"Horos Bonjour browser searching for %@", type);
    [self _notifyIfNativeBonjourSearchRecoveredForType:type];
}

-(void)netServiceBrowser:(NSNetServiceBrowser*)nsb didNotSearch:(NSDictionary*)errorDict
{
    NSLog(@"Warning: Horos Bonjour browser did not search for %@: %@", [self _bonjourServiceTypeForBrowser:nsb], errorDict);
    NSInteger errorCode = [[errorDict objectForKey:NSNetServicesErrorCode] integerValue];

    if (nsb == _nsbOsirix)
    {
        [_nsbOsirix setDelegate:nil];
        [_nsbOsirix stop];
        [_nsbOsirix release];
        _nsbOsirix = nil;
        if (errorCode != NSNetServicesMissingRequiredConfigurationError)
            [self performSelector:@selector(_startOsirixBonjourBrowser) withObject:nil afterDelay:10.0];
        else
            [self _startDNSSDBrowseFallbackForType:HorosOsiriXDatabaseBonjourType];
    }
    else if (nsb == _nsbDicom)
    {
        [_nsbDicom setDelegate:nil];
        [_nsbDicom stop];
        [_nsbDicom release];
        _nsbDicom = nil;
        if (errorCode != NSNetServicesMissingRequiredConfigurationError)
            [self performSelector:@selector(_startDicomBonjourBrowser) withObject:nil afterDelay:10.0];
        else
            [self _startDNSSDBrowseFallbackForType:HorosDicomBonjourType];
    }
    else if (nsb == _nsbPhoneVolumeRender)
    {
        [_nsbPhoneVolumeRender setDelegate:nil];
        [_nsbPhoneVolumeRender stop];
        [_nsbPhoneVolumeRender release];
        _nsbPhoneVolumeRender = nil;
        if (errorCode != NSNetServicesMissingRequiredConfigurationError)
            [self performSelector:@selector(_startPhoneVolumeRenderBonjourBrowser) withObject:nil afterDelay:10.0];
    }
}

-(void)netServiceDidResolveAddress:(NSNetService*)service
{
    @try
    {
        [service retain];
        [service stop]; //Technical Q&A QA1297

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
                if (![resolvedTXTDictionary objectForKey:@"UID"] && [rawTXTDictionary objectForKey:@"UID"])
                {
                    NSMutableDictionary *mergedTXTDictionary = [NSMutableDictionary dictionaryWithDictionary:resolvedTXTDictionary ? resolvedTXTDictionary : [NSDictionary dictionary]];
                    [mergedTXTDictionary setObject:[rawTXTDictionary objectForKey:@"UID"] forKey:@"UID"];
                    resolvedTXTDictionary = mergedTXTDictionary;
                }
            }

            if (![source0 isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]] && [[resolvedTXTDictionary objectForKey:@"UID"] isEqualToString:[AppController UID]])
            {
                @synchronized (_bonjourSources)
                {
                    NSLog( @"Remove Service: %@ ignored as this Horos instance UID=%@", service, [resolvedTXTDictionary objectForKey:@"UID"]);
                    if( [_bonjourServices indexOfObject: service] != NSNotFound)
                    {
                        [_bonjourSources removeObjectAtIndex: [_bonjourServices indexOfObject: service]];
                        [_bonjourServices removeObject: service];
                    }
                    else
                        NSLog( @"***** unknown didResolve Service");
                }
                return; // it's me
            }
        }
        @catch (NSException *exception) {
            N2LogException( exception);
            return;
        }

        @try {
            // we're now back in the main thread
            NSMutableArray* addresses = [NSMutableArray array];
            // Prefer IP4
            for (NSData* address in service.addresses)
            {
                struct sockaddr* sockAddr = (struct sockaddr*)address.bytes;
                if (sockAddr->sa_family == AF_INET)
                {
                    struct sockaddr_in* sockAddrIn = (struct sockaddr_in*)sockAddr;
                    char *str = inet_ntoa(sockAddrIn->sin_addr);
                    if( str)
                    {
                        NSString* host = [NSString stringWithUTF8String:str];
                        NSInteger port = ntohs(sockAddrIn->sin_port);
                        [addresses addObject:[NSArray arrayWithObjects: host, [NSNumber numberWithInteger:port], NULL]];
                    }
                }
            }
            // And search IPv6
            for (NSData* address in service.addresses)
            {
                struct sockaddr* sockAddr = (struct sockaddr*)address.bytes;
                if (sockAddr->sa_family == AF_INET6)
                {
                    struct sockaddr_in6* sockAddrIn6 = (struct sockaddr_in6*)sockAddr;
                    char buffer[INET6_ADDRSTRLEN];
                    if( inet_ntop(AF_INET6, &sockAddrIn6->sin6_addr, buffer, INET6_ADDRSTRLEN))
                    {
                        NSString* host = [NSString stringWithUTF8String:buffer];
                        NSInteger port = ntohs(sockAddrIn6->sin6_port);
                        [addresses addObject:[NSArray arrayWithObjects: host, [NSNumber numberWithInteger:port], NULL]];
                    }
                }
            }

            DataNodeIdentifier* source = source0;

            for (NSArray* address in addresses)
            {
                if (!source.location && address.count >= 2)
                {
                    if ([source isKindOfClass:[RemoteDatabaseNodeIdentifier class]] || [source isKindOfClass:[DicomNodeIdentifier class]] || [source isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]])
                    {
                        source.location = [address objectAtIndex:0];
                        source.port = [[address objectAtIndex:1] integerValue];
                    }

                    if( [source isKindOfClass:[DicomNodeIdentifier class]])
                        source.aetitle = source.description;
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

            source.dictionary = resolvedTXTDictionary;

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

-(void)netService:(NSNetService*)service didNotResolve:(NSDictionary*)errorDict
{
    NSLog(@"Warning: Bonjour service did not resolve: %@ error=%@", service, errorDict);
    [service stop];

    NSNetService* bsk = nil;

    @synchronized (_bonjourSources) {
        for (NSNetService* ibsk in _bonjourServices) {
            if ([ibsk isEqual: service]) {
                bsk = ibsk;
                break;
            }
        }

        if (!bsk)
            return;

        NSLog( @"Remove Service: %@", bsk);
        [_bonjourSources removeObjectAtIndex: [_bonjourServices indexOfObject: bsk]];
        [_bonjourServices removeObject: bsk];
    }
}

-(void)netServiceBrowser:(NSNetServiceBrowser*)nsb didFindService:(NSNetService*)service moreComing:(BOOL)moreComing
{
    //NSLog(@"Bonjour service found: %@", service);

    DataNodeIdentifier* source;
    if (nsb == _nsbOsirix)
        source = [RemoteDatabaseNodeIdentifier remoteDatabaseNodeIdentifierWithLocation:nil port:0 description:service.name dictionary:nil];
    else if (nsb == _nsbPhoneVolumeRender)
        source = [PhoneVolumeRenderNodeIdentifier phoneVolumeRenderNodeIdentifierWithLocation:nil port:0 description:NSLocalizedString(HorosPhoneVolumeRenderDisplayName, nil) dictionary:nil];
    else
        source = [DicomNodeIdentifier dicomNodeIdentifierWithLocation:nil port:0 aetitle:@"" description:service.name dictionary:nil];

    //    source.discovered = YES;
    //	source.service = service;
    @synchronized (_bonjourSources) {
        [_bonjourServices addObject: service];
        [_bonjourSources addObject: source];
    }
    NSLog( @"Find Service: %@", service);

    // resolve the address and port for this NSNetService
    [service setDelegate:self];
    [service resolveWithTimeout:30];
}

-(void)netServiceBrowser:(NSNetServiceBrowser*)nsb didRemoveService:(NSNetService*)service moreComing:(BOOL)moreComing
{
    NSLog(@"Bonjour service gone: %@", service);

    DataNodeIdentifier* dni;

    NSNetService *bsk = nil;
    @synchronized (_bonjourSources) {
        for (NSNetService* ibsk in _bonjourServices) {
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
        [_bonjourSources removeObjectAtIndex: [_bonjourServices indexOfObject: bsk]];
        [_bonjourServices removeObject: bsk];
    }
}

-(MountedDatabaseNodeIdentifier*)_deduplicateMountedSourcesForPath:(NSString*)path
{
    return [self _deduplicateMountedSourcesForPath:path identity:nil];
}

-(MountedDatabaseNodeIdentifier*)_deduplicateMountedSourcesForPath:(NSString*)path identity:(NSString*)identity
{
    NSArray *matches = HorosMountedSourcesForPathOrIdentity([[_browser.sources.arrangedObjects copy] autorelease], path, identity);
    if ([matches count] == 0)
        return nil;

    MountedDatabaseNodeIdentifier *sourceToKeep = nil;
    DataNodeIdentifier *activeSource = [_browser sourceIdentifierForDatabase:_browser.database];

    for (MountedDatabaseNodeIdentifier* source in matches)
        if ([activeSource isEqualToDataNodeIdentifier:source])
            sourceToKeep = source;

    if (sourceToKeep == nil)
        sourceToKeep = [matches objectAtIndex: 0];

    for (MountedDatabaseNodeIdentifier *duplicateSource in matches)
    {
        if (duplicateSource == sourceToKeep)
            continue;

        [duplicateSource retain];
        [_browser.sources removeObject: duplicateSource];
        [duplicateSource willUnmount];
        [duplicateSource performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
    }

    return sourceToKeep;
}

-(void)_addMountedSourceForPath:(NSString*)path description:(NSString*)description type:(NSInteger)type
{
    [self _addMountedSourceForPath:path description:description type:type identity:nil];
}

-(void)_addMountedSourceForPath:(NSString*)path description:(NSString*)description type:(NSInteger)type identity:(NSString*)identity
{
    MountedDatabaseNodeIdentifier *existingSource = [self _deduplicateMountedSourcesForPath:path identity:identity];
    if (existingSource)
    {
        existingSource.description = description;
        existingSource.mountType = type;
        existingSource.mountIdentity = identity;
        return;
    }

    @try {
        MountedDatabaseNodeIdentifier *source = [MountedDatabaseNodeIdentifier mountedDatabaseNodeIdentifierWithPath:path description:description dictionary:nil type:type];
        source.mountIdentity = identity;
        [_browser.sources addObject:source];
    } @catch (NSException* e) {
        N2LogExceptionWithStackTrace(e);
    }
}

-(void)_analyzeVolumeAtPath:(NSString*)path
{
    if ([self _deduplicateMountedSourcesForPath:path])
        return;

    for (DataNodeIdentifier* ibs in _browser.sources.arrangedObjects)
        if ([ibs isKindOfClass:[LocalDatabaseNodeIdentifier class]] && [ibs.location hasPrefix:path])
        {
            return; // device is somehow already listed as a source
        }

    NSTask* task = [[NSTask alloc] init];
    [task setExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/diskutil"]];
    [task setArguments:[NSArray arrayWithObjects: @"info", @"-plist", path, NULL]];
    [task setStandardError:[NSPipe pipe]];
    [task setStandardOutput:[task standardError]];
    HorosLaunchTaskOrRaise(task);
    while( [task isRunning]) [NSThread sleepForTimeInterval: 0.01];

    NSData* output = [[[[[task standardError] fileHandleForReading] readDataToEndOfFile] retain] autorelease];
    [task release];

    id plist = [NSPropertyListSerialization propertyListWithData:output options:NSPropertyListImmutable format:NULL error:NULL];
    NSDictionary *result = [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
    NSString *mountIdentity = HorosMountedSourceIdentityFromDiskutilInfo(result);

    if ([self _deduplicateMountedSourcesForPath:path identity:mountIdentity])
        return;

    if ([[result objectForKey:@"OpticalMediaType"] length]) // is CD/DVD or other optical media
        [self _addMountedSourceForPath:path description:path.lastPathComponent type:MountTypeGeneric identity:mountIdentity];

    else if ([[result objectForKey:@"MediaType"] isEqualToString:@"iPod"])
        [self _addMountedSourceForPath:path description:path.lastPathComponent type:MountTypeIPod identity:mountIdentity];
    else // Is there a DICOMDIR at root?
    {
        if( [[NSFileManager defaultManager] fileExistsAtPath: [path stringByAppendingPathComponent: @"DICOMDIR"]])
            [self _addMountedSourceForPath:path description:path.lastPathComponent type:MountTypeGeneric identity:mountIdentity];
        else if( [[NSFileManager defaultManager] fileExistsAtPath: [path stringByAppendingPathComponent: OsirixDataDirName]])
            [self _addMountedSourceForPath:path description:path.lastPathComponent type:MountTypeGeneric identity:mountIdentity];
    }

}

-(void)_observeVolumeNotification:(NSNotification*)notification
{
    int mode = [[NSUserDefaults standardUserDefaults] integerForKey: @"MOUNT"];

    if( mode == 2)
        return;

    NSString* path = [[notification.userInfo objectForKey: NSWorkspaceVolumeURLKey] path];
    BOOL oldPathWasMounted = NO;

    [_browser redrawSources];

    if ([notification.name isEqualToString:NSWorkspaceDidMountNotification])
    {
        [self _analyzeVolumeAtPath:[[notification.userInfo objectForKey: NSWorkspaceVolumeURLKey] path]];
    }

    if( [notification.name isEqualToString:NSWorkspaceDidRenameVolumeNotification])
    {
        path = [[[notification userInfo] objectForKey: NSWorkspaceVolumeOldURLKey] path];
    }

    if ([notification.name isEqualToString:NSWorkspaceDidUnmountNotification] || [notification.name isEqualToString:NSWorkspaceDidRenameVolumeNotification])
    {
        NSArray *mountedSources = HorosMountedSourcesForPath(_browser.sources.arrangedObjects, path);
        oldPathWasMounted = [mountedSources count] > 0;

        for (MountedDatabaseNodeIdentifier* mbs in mountedSources)
        {
            if ([[_browser sourceIdentifierForDatabase:_browser.database] isEqualToDataNodeIdentifier:mbs])
                [_browser performSelector: @selector(setDatabase:) withObject: DicomDatabase.defaultDatabase afterDelay: 0.01]; //This will guarantee that this will not happen in middle of a drag & drop, for example
            [mbs retain];
            [_browser.sources removeObject:mbs];
            [mbs willUnmount];
            [mbs performSelector: @selector( autorelease) withObject: nil afterDelay: 60];
        }
    }

    if ([notification.name isEqualToString:NSWorkspaceDidRenameVolumeNotification] && oldPathWasMounted) // Re-mount an renamed path, that was previously mounted
    {
        [self _analyzeVolumeAtPath:[[notification.userInfo objectForKey: NSWorkspaceVolumeURLKey] path]];
    }
}


-(void)_observeVolumeWillUnmountNotification:(NSNotification*)notification
{
    NSString* path = [notification.userInfo objectForKey:@"NSDevicePath"];
    if (path == nil)
        path = [[notification.userInfo objectForKey:NSWorkspaceVolumeURLKey] path];

    [DCMPix purgeCachedDictionaries];

    NSArray *mountedSources = HorosMountedSourcesForPath(_browser.sources.arrangedObjects, path);

    for (MountedDatabaseNodeIdentifier* mbs in mountedSources)
    {
        [mbs willUnmount];

        if ([[_browser sourceIdentifierForDatabase:_browser.database] isEqualToDataNodeIdentifier:mbs])
        {
            DicomDatabase* db = [DicomDatabase activeLocalDatabase];
            if (db == _browser.database)
                db = [DicomDatabase defaultDatabase];

            [_browser performSelector: @selector(setDatabase:) withObject: db afterDelay: 0.01]; //This will guarantee that this will not happen in middle of a drag & drop, for example
        }
    }
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
    cell.textColor = nil;
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
    NSArray* xids = [NSPropertyListSerialization propertyListWithData:[pb propertyListForType:[pb availableTypeFromArray:BrowserController.DatabaseObjectXIDsPasteboardTypes]]
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:NULL];
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


@implementation MountedDatabaseNodeIdentifier

@synthesize devicePath = _devicePath;
@synthesize mountIdentity = _mountIdentity;
@synthesize mountType = _mountType;

-(id)init
{
    if ((self = [super init]))
    {
        _unmountButton = [[NSButton alloc] initWithFrame:NSMakeRect(0,0,14,14)];
        _unmountButton.image = [NSImage imageNamed:@"Eject_gray"];
        _unmountButton.image.size = NSMakeSize(10,11);
        _unmountButton.alternateImage = [NSImage imageNamed:@"Eject_lightgray"];
        _unmountButton.alternateImage.size = NSMakeSize(10,11);
        _unmountButton.imagePosition = NSImageOnly;
        _unmountButton.bezelStyle = 0;
        [_unmountButton setButtonType:NSMomentaryLightButton];
        [_unmountButton setBordered:NO];
        NSButtonCell* cell = _unmountButton.cell;
        cell.gradientType = NSGradientNone;
        [cell setHighlightsBy:NSContentsCellMask];

        _unmountButton.target = self;
        _unmountButton.action = @selector(_eject:);
    }

    return self;
}

-(void)_eject:(id)sender
{
    [[NSWorkspace sharedWorkspace] performSelectorInBackground:@selector(unmountAndEjectDeviceAtPath:) withObject:self.devicePath];
}

-(void)initiateVolumeScan
{
    [_database release];

    _database = [[DicomDatabase databaseAtPath:self.location] retain];
    _database.isReadOnly = YES;
    _database.sourcePath = self.devicePath;
    _database.name = self.description;
    _database.hasPotentiallySlowDataAccess = YES;
    for (NSManagedObject* obj in _database.albums)
        [_database.managedObjectContext deleteObject:obj];

    [_database.managedObjectContext save: nil];

    [self performSelectorInBackground:@selector(volumeScanThread) withObject:nil];
}

-(void)volumeScanThread
{
    NSAutoreleasePool* pool = [NSAutoreleasePool new];
    @try
    {
        NSLog( @"--- volumeScanThread: start");

        NSThread* thread = [NSThread currentThread];
        @synchronized (self)
        {
            _scanThread = thread;
        }

        DicomDatabase* database = [_database independentDatabase];

        thread.name = NSLocalizedString(@"Scanning disc...", nil);
        [[ThreadsManager defaultManager] addThreadAndStart:thread];

        BOOL autoselect = [database scanAtPath:self.devicePath];

        if (![[database objectsForEntity:database.imageEntity] count])
        {
            [self retain];
            [[[BrowserController currentBrowser] sources] removeObject:self];
            [self willUnmount];
            [self performSelector: @selector( autorelease) withObject: nil afterDelay: 60];

            return;
        }

        self.detected = YES;

        BOOL selectSource = NO;

        NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:@"MOUNT"];
//        BOOL autoSelectSourceCDDVD = [[NSUserDefaults standardUserDefaults] boolForKey:@"autoSelectSourceCDDVD"];


        if (mode == -1 || [[NSApp currentEvent] modifierFlags]&NSCommandKeyMask) //The user clicked on the dialog box
        {
            if( autoselect)
                selectSource = YES;
        }
        else if ([[NSUserDefaults standardUserDefaults] boolForKey:@"autoSelectSourceCDDVD"] && [[NSFileManager defaultManager] fileExistsAtPath:self.devicePath])
            selectSource = YES;

        if( selectSource)
            [[BrowserController currentBrowser] performSelectorOnMainThread:@selector(setDatabaseFromSourceIdentifier:) withObject:self waitUntilDone:NO modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
        else
            [[BrowserController currentBrowser] redrawSources];

    }
    @catch (NSException* e)
    {
        N2LogExceptionWithStackTrace(e);
    }
    @finally
    {
        @synchronized (self)
        {
            _scanThread = nil;
        }

        [pool release];

        NSLog( @"--- volumeScanThread: end");
    }
}

-(DicomDatabase*)database
{
    if (!_detected)
        [UnavaliableDataNodeException raise:NSGenericException format:@"%@", NSLocalizedString(@"This disk is being processed. It is currently not available.", nil)];
    return _database;
}

+(id)mountedDatabaseNodeIdentifierWithPath:(NSString*)devicePath description:(NSString*)description dictionary:(NSDictionary*)dictionary type:(NSInteger)type
{
    BOOL scan = YES;
    NSString* path = [[NSFileManager defaultManager] tmpFilePathInTmp];

    // does it contain an Horos Data folder?
    BOOL isDir;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[devicePath stringByAppendingPathComponent:OsirixDataDirName] isDirectory:&isDir] && isDir) {
        path = devicePath;
        scan = NO;
    }

    if (type == MountTypeIPod) {
        path = devicePath;
        scan = NO;
    }

    MountedDatabaseNodeIdentifier* bs = [[self class] localDatabaseNodeIdentifierWithPath:path description:description dictionary:dictionary];
    bs.devicePath = devicePath;
    bs.mountType = type;
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];

    if (scan)
        [bs initiateVolumeScan];
    else
        bs.detected = YES;

    return bs;
}

-(void)dealloc
{
    [_database release];

    [_unmountButton removeFromSuperview];
    [_unmountButton autorelease];
    _unmountButton = nil;

    //    [[NSFileManager defaultManager] removeItemAtPath:self.location error:NULL]; We cannot do it, because there was maybe threads attached to this sql file. The entire folder will be deleted when quitting or restarting OsiriX
    self.devicePath = nil;
    self.mountIdentity = nil;
    [super dealloc];
}

//-(NSString*)_bcsChars:(NSString*)s {
//	NSMutableString* r = [NSMutableString stringWithFormat:@"%d, %@ -", s.length, s];
//	for (NSInteger i = 0; i < s.length; ++i)
//		[r appendFormat:@" %04x", [s characterAtIndex:i]];
//	return r;
//}

-(void)willDisplayCell:(PrettyCell*)cell
{
    [super willDisplayCell:cell];

    //	NSLog(@"%@", [self _bcsChars:self.devicePath]);
    NSImage* im = [[NSWorkspace sharedWorkspace] iconForFile:self.devicePath];
    im.size = [im sizeByScalingProportionallyToSize: cell.image? cell.image.size : NSMakeSize(16,16) ];
    cell.image = im;

    if (!_detected)
        cell.textColor = [NSColor grayColor];

    if( _unmountButton)
        [cell.rightSubviews addObject:_unmountButton];
}

-(NSString*)toolTip
{
    return self.devicePath;
}

-(BOOL)isReadOnly
{
    if (self.mountType == MountTypeIPod)
        return NO;
    return YES;
}

-(CGFloat)sortValue {
    return CGFLOAT_MIN+1;
}

-(void)willUnmount
{
    @synchronized (self)
    {
        [DCMPix purgeCachedDictionaries];

        if (_scanThread)
            [_scanThread cancel];

        [[BrowserController currentBrowser] redrawSources];

        [_unmountButton removeFromSuperview];
        [_unmountButton autorelease];
        _unmountButton = nil;
    }
}

@end

@implementation UnavaliableDataNodeException
@end
