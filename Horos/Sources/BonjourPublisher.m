#import "HorosUnkeyedArchiveCompatibility.h"
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

#import "BonjourPublisher.h"
#import "HorosSwiftInterop.h"
#import "BonjourBrowser.h"
#import "DCMPix.h"
#import "DCMTKStoreSCU.h"
#import "SendController.h"
#import "DicomStudy.h"
#import "NSUserDefaultsController+OsiriX.h"
#import "NSUserDefaultsController+N2.h"
#import "N2Debug.h"
#import "DicomDatabase.h"
#import "DicomImage.h"
#import "AppController.h"
#import "NSFileManager+N2.h"
#include <limits.h>

@interface O2DatabaseConnection : NSObject {
    int _mode, _hdi;
    NSMutableArray* _stack;
    NSMutableData* _readBuffer;
    HorosDatabasePeer* _peer;
}
@property(nonatomic, readonly) NSUInteger availableSize;
@property(nonatomic, readonly) NSMutableData* readBuffer;
- (instancetype)initWithPeer:(HorosDatabasePeer*)peer;
- (void)run;
- (NSData*)readData:(NSUInteger)length;
- (void)readData:(NSUInteger)length toBuffer:(void*)buffer;
- (void)writeData:(NSData*)data;
@end

@interface BonjourPublisher () <HorosDatabaseServerDelegate>
- (void)updateBonjour;
@end

@implementation BonjourPublisher

- (NSInteger)port
{
    return _listener ? _listener.port : 0;
}

+ (BonjourPublisher*) currentPublisher // __deprecated
{
    return [[AppController sharedAppController] bonjourPublisher];
}

- (id)init
{
    if ((self = [super init]))
    {
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:OsirixBonjourSharingIsActiveDefaultsKey options:NSKeyValueObservingOptionInitial context:NULL];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:OsirixBonjourSharingNameDefaultsKey options:NSKeyValueObservingOptionInitial context:NULL];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:OsirixBonjourSharingIsPasswordProtectedDefaultsKey options:NSKeyValueObservingOptionInitial context:NULL];
        [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forValuesKey:OsirixBonjourSharingPasswordDefaultsKey options:NSKeyValueObservingOptionInitial context:NULL];
    }
    return self;
}

- (void) dealloc
{
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:OsirixBonjourSharingIsActiveDefaultsKey];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:OsirixBonjourSharingNameDefaultsKey];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:OsirixBonjourSharingIsPasswordProtectedDefaultsKey];
    [[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forValuesKey:OsirixBonjourSharingPasswordDefaultsKey];
    
    [dicomSendLock release];
    _listener.delegate = nil;
    [_listener stop];
    [_listener release];
    [_bonjour stop];
    [_bonjour release];
    
    [super dealloc];
}

-(void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        });
        return;
    }
    if (object == [NSUserDefaultsController sharedUserDefaultsController]) {
        keyPath = [keyPath substringFromIndex:7];
        if ([keyPath isEqualToString:OsirixBonjourSharingIsActiveDefaultsKey]) {
            [self toggleSharing:NSUserDefaults.bonjourSharingIsActive];
            return;
        } else
            if ([keyPath isEqualToString:OsirixBonjourSharingNameDefaultsKey]) {
                [_bonjour stop];
                [_bonjour release];
                _bonjour = nil;
                [self updateBonjour];
                return;
            } else
                if ([keyPath isEqualToString:OsirixBonjourSharingIsPasswordProtectedDefaultsKey]) {
                    return;
                } else
                    if ([keyPath isEqualToString:OsirixBonjourSharingPasswordDefaultsKey]) {
                        return;
                    }
    }
    
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)toggleSharing:(BOOL)activate
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggleSharing:activate]; });
        return;
    }
    @try {
        if (activate && !_listener) {
            _listener = [[HorosDatabaseServer alloc] initWithPort:8780 handler:^(HorosDatabasePeer* peer) {
                O2DatabaseConnection* connection = [[O2DatabaseConnection alloc] initWithPeer:peer];
                @try { [connection run]; }
                @finally { [connection release]; }
            }];
            _listener.delegate = self;
        }
        if (activate)
            [_listener start];
        
        if (!activate && _listener) {
            _listener.delegate = nil;
            [_listener stop];
            [_listener release];
            _listener = nil;
        }
        
        [self updateBonjour];
    } @catch (NSException* e) {
        N2LogExceptionWithStackTrace(e);
    }
}

- (void)databaseServerDidStart:(HorosDatabaseServer*)server {
    if (server != _listener) return;
    NSLog(@"Horos database shared on port %ld", (long)server.port);
    [self updateBonjour];
}

- (void)databaseServer:(HorosDatabaseServer*)server didFail:(NSError*)error {
    if (server != _listener) return;
    NSLog(@"Warning: unable to share Horos database: %@", error);
    [self updateBonjour];
}

- (void)updateBonjour {
    if (!_listener || !_listener.port)
    {
        if (_bonjour)
        {
            [_bonjour stop];
            [_bonjour release];
            _bonjour = nil;
        }

        if (!_listener)
            NSLog(@"Horos database Bonjour sharing is disabled");
        return;
    }

    if (_bonjour && [_bonjour port] != [_listener port])
    {
        [_bonjour stop];
        [_bonjour release];
        _bonjour = nil;
    }

    if (!_bonjour) {
        _bonjour = [[HorosBonjourAdvertisement alloc] initWithName:[NSUserDefaults bonjourSharingName] ?: @""
                                                            type:@"_osirixdb._tcp" port:[_listener port]];
    }
    
    NSMutableDictionary* txtrec = [NSMutableDictionary dictionary];
#define EitherOr(a, b) (a? a : b)
    [txtrec setObject: EitherOr([[NSUserDefaults standardUserDefaults] stringForKey:@"AETITLE"], @"OSIRIX") forKey:@"AETitle"];
    [txtrec setObject: EitherOr([[NSUserDefaults standardUserDefaults] stringForKey: @"AEPORT"], @"11112") forKey:@"port"];
#undef EitherOr
    if ([AppController UID])
        [txtrec setObject:[AppController UID] forKey:@"UID"];
    
    [_bonjour publishWithTXTRecord:txtrec];
}

+(NSDictionary*)dictionaryFromXTRecordData:(NSData*)data {
    NSMutableDictionary* d = [NSMutableDictionary dictionary];
    NSDictionary* dict = [HorosBonjourService dictionaryFromTXTRecordData:data];
    
    for (NSString* key in dict) {
        NSData* data = [dict objectForKey:key];
        if ([key isEqualToString:@"AETitle"])
            [d setObject:[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] forKey:key];
        else if ([key isEqualToString:@"port"])
            [d setObject:[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] forKey:key];
        else if ([key isEqualToString:@"UID"])
            [d setObject:[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] forKey:key];
        else [d setObject:data forKey:key];
    }
    
    return d;
}

- (void) sendDICOMFilesToOsiriXNode:(NSDictionary*) todo
{
    @autoreleasepool
    {
        if (dicomSendLock == nil)
            dicomSendLock = [[NSLock alloc] init];
        
        [dicomSendLock lock];
        @try {
            DCMTKStoreSCU *storeSCU = [[DCMTKStoreSCU alloc]	initWithCallingAET: [[NSUserDefaults standardUserDefaults] stringForKey: @"AETITLE"]
                                                                      calledAET: [todo objectForKey:@"AETitle"]
                                                                       hostname: [todo objectForKey:@"Address"]
                                                                           port: [[todo objectForKey:@"Port"] intValue]
                                                                    filesToSend: [todo valueForKey: @"Files"]
                                                                 transferSyntax: [[todo objectForKey:@"TransferSyntax"] intValue]
                                                                    compression: 1.0
                                                                extraParameters: [NSDictionary dictionaryWithObject:[DicomDatabase defaultDatabase] forKey:@"DicomDatabase"]]; // nil == TLS not supported !
            
            @try
            {
                [storeSCU run: nil];
            }
            
            @catch (NSException *ne)
            {
                NSLog( @"Bonjour DICOM Send FAILED");
                NSLog( @"%@", [ne name]);
                NSLog( @"%@", [ne reason]);
            }
            
            [storeSCU release];
            storeSCU = nil;
        } @catch (NSException* e) {
            N2LogExceptionWithStackTrace(e);
        } @finally {
            [dicomSendLock unlock];
        }
    }
}

@end

@implementation O2DatabaseConnection

- (instancetype)initWithPeer:(HorosDatabasePeer*)peer {
    if ((self = [super init])) {
        _peer = [peer retain];
        _stack = [[NSMutableArray alloc] init];
        _readBuffer = [[NSMutableData alloc] init];
    }
    
    return self;
}

- (void)dealloc {
    [_peer release];
    [_readBuffer release];
    [_stack release];
    [super dealloc];
}

enum Modes {
    NONE = 0, DONE,
    DATAB,
    DBSIZ,
    GETDI,
    VERSI,
    DBVER,
    ISPWD,
    PASWD,
    SENDD,
    SENDG,
    NEWMS,
    ADDAL,
    REMAL,
    SETVA,
    MFILE,
    DCMSE,
    DICOM
};

static NSString* const O2NotEnoughData = @"O2NotEnoughData";

- (void)run {
    // Keep incremental parser state and its independent database on this worker.
    @try {
        while (_mode != DONE) {
            @autoreleasepool {
                NSError* error = nil;
                NSData* data = [_peer receiveDataWithError:&error];
                if (error)
                    [NSException raise:NSGenericException format:@"Database receive failed: %@", error];
                if (!data.length) {
                    if (_mode == NONE && !_readBuffer.length) return; // Availability probe.
                    [NSException raise:NSGenericException format:@"Incomplete shared-database request"];
                }
                [_readBuffer appendData:data];
                [self handleData:_readBuffer];
            }
        }
        NSError* error = nil;
        if (![_peer finishWithError:&error])
            [NSException raise:NSGenericException format:@"Database response failed: %@", error];
    } @catch (NSException* exception) {
        // Objective-C exceptions must not escape into the Swift network worker.
        NSLog(@"Shared-database request from %@ failed: %@", _peer.address, exception.reason);
    }
}

- (NSUInteger)availableSize { return _readBuffer.length; }
- (NSMutableData*)readBuffer { return _readBuffer; }

- (NSData*)readData:(NSUInteger)length {
    NSData* data = [_readBuffer subdataWithRange:NSMakeRange(0, length)];
    [_readBuffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
    return data;
}

- (void)readData:(NSUInteger)length toBuffer:(void*)buffer {
    [_readBuffer getBytes:buffer length:length];
    [_readBuffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
}

- (void)writeData:(NSData*)data {
    if (!data.length) return;
    NSError* error = nil;
    if (![_peer writeData:data error:&error])
        [NSException raise:NSGenericException format:@"Database send failed: %@", error];
}

- (void)handleData:(NSMutableData*)data {
    _hdi = 0;
    
    @try {
        if (_mode == NONE) {
            if (self.availableSize < 6)
                return;
            char command[6];
            [self readData:6 toBuffer:command];
            if (command[5] != '\0')
                [NSException raise:NSInvalidArgumentException format:@"Invalid shared-database command"];
            
            if (strcmp(command, "DATAB") == 0)
                _mode = DATAB;
            else if (strcmp(command, "DBSIZ") == 0)
                _mode = DBSIZ;
            else if (strcmp(command, "GETDI") == 0)
                _mode = GETDI;
            else if (strcmp(command, "VERSI") == 0)
                _mode = VERSI;
            else if (strcmp(command, "DBVER") == 0)
                _mode = DBVER;
            else if (strcmp(command, "ISPWD") == 0)
                _mode = ISPWD;
            else if (strcmp(command, "PASWD") == 0)
                _mode = PASWD;
            else if (strcmp(command, "SENDD") == 0)
                _mode = SENDD;
            else if (strcmp(command, "SENDG") == 0)
                _mode = SENDG;
            else if (strcmp(command, "NEWMS") == 0)
                _mode = NEWMS;
            else if (strcmp(command, "ADDAL") == 0)
                _mode = ADDAL;
            else if (strcmp(command, "REMAL") == 0)
                _mode = REMAL;
            else if (strcmp(command, "SETVA") == 0)
                _mode = SETVA;
            else if (strcmp(command, "MFILE") == 0)
                _mode = MFILE;
            else if (strcmp(command, "DCMSE") == 0)
                _mode = DCMSE;
            else if (strcmp(command, "DICOM") == 0)
                _mode = DICOM;
            
            if (_mode == NONE)
                [NSException raise:NSInvalidArgumentException format:@"Unknown shared-database command"];
        }
        
        switch (_mode) {
            case DATAB:
                return [self DATAB];
            case DBSIZ:
                return [self DBSIZ];
            case GETDI:
                return [self GETDI];
            case VERSI:
                return [self VERSI];
            case DBVER:
                return [self DBVER];
            case ISPWD:
                return [self ISPWD];
            case PASWD:
                return [self PASWD];
            case SENDD:
                return [self SEND];
            case SENDG:
                return [self SEND];
            case NEWMS:
                return [self NEWMS];
            case ADDAL:
                return [self ADDAL];
            case REMAL:
                return [self REMAL];
            case SETVA:
                return [self SETVA];
            case MFILE:
                return [self MFILE];
            case DCMSE:
                return [self DCMSE];
            case DICOM:
                return [self DICOM];
        }
    } @catch (NSException* e) {
        if ([e.name isEqualToString:O2NotEnoughData])
            return;
        @throw e;
    }
}

- (void)_stackObject:(id)o {
    [_stack addObject:o];
    ++_hdi;
}

- (id)_stackedObject {
    if (_stack.count <= _hdi)
        return nil;
    return [_stack objectAtIndex:_hdi++];
}

- (void)_unstack {
    [_stack removeObjectAtIndex:--_hdi];
}

- (void)_requireDataSize:(int)size {
    if (size < 0)
        [NSException raise:NSInvalidArgumentException format:@"Negative shared-database data size"];
    if (self.availableSize < size)
        [NSException raise:O2NotEnoughData format:@""];
}

- (int)_readInt {
    [self _requireDataSize:4];
    
    int value;
    [self readData:4 toBuffer:&value];
    value = NSSwapBigIntToHost(value);
    
    return value;
}

- (int)_stackReadInt {
    if (_stack.count > _hdi)
    {
        return [[self _stackedObject] intValue];
    }
    int value = [self _readInt];
    if (value < 0)
        [NSException raise:NSInvalidArgumentException format:@"Negative shared-database count or size"];
    
    [self _stackObject:[NSNumber numberWithInt:value]];
    
    return value;
}

- (NSString*)_readString {
    [self _requireDataSize:4];
    
    int length;
    [self.readBuffer getBytes:&length length:4];
    length = NSSwapBigIntToHost(length);
    if (length < 0 || length > INT_MAX - 4)
        [NSException raise:NSInvalidArgumentException format:@"Invalid shared-database string length"];
    
    [self _requireDataSize:length+4];
    
    [self readData:4];
    if (!length) return nil; // The existing protocol uses zero length for null.
    
    NSData* data = [self readData:length];
    
    const char* bytes = data.bytes;
    if (bytes[length-1] != '\0')
        [NSException raise:NSInvalidArgumentException format:@"Unterminated shared-database string"];
    NSString* value = [[[NSString alloc] initWithBytes:bytes length:length-1 encoding:NSUTF8StringEncoding] autorelease];
    if (!value)
        [NSException raise:NSInvalidArgumentException format:@"Invalid UTF-8 in shared-database string"];
    return value;
}

- (NSString*)_stackReadString {
    if (_stack.count > _hdi)
    {
        id value = [self _stackedObject];
        return value == NSNull.null ? nil : value;
    }
    NSString* value = [self _readString];
    
    [self _stackObject:value ?: NSNull.null];
    
    return value;
}

- (DicomDatabase*)_stackIndependentDatabase {
    if (_stack.count > _hdi)
    {
        return [self _stackedObject];
    }
    DicomDatabase* database = [[DicomDatabase defaultDatabase] independentDatabase];
    
    [self _stackObject:database];
    
    return database;
}

- (void)DATAB {
    DicomDatabase* idatabase = [self _stackIndependentDatabase];

    __block NSMutableData* representationToSend = nil;
    @try
    {
        [idatabase save];
        NSString* databasePath = [idatabase sqlFilePath];
        NSPersistentStoreCoordinator *coordinator = idatabase.managedObjectContext.persistentStoreCoordinator;
        [coordinator performBlockAndWait:^{
            representationToSend = [[NSMutableData dataWithContentsOfFile:databasePath] retain];
        }];
    }
    @catch (NSException *e) {
        N2LogExceptionWithStackTrace(e);
    }

    @try {
        if (representationToSend)
            [self writeData:representationToSend];
    } @finally {
        [representationToSend release];
    }
    
    NSLog(@"Bonjour connection received from %@", _peer.address);
    
    _mode = DONE;
}

- (void)DBSIZ {
    DicomDatabase* idatabase = [self _stackIndependentDatabase];
    
    __block int fileSize = 0;

    @try
    {
        [idatabase save];
        NSString *databasePath = [idatabase sqlFilePath];
        NSPersistentStoreCoordinator *coordinator = idatabase.managedObjectContext.persistentStoreCoordinator;
        [coordinator performBlockAndWait:^{
            NSDictionary *fattrs = [[NSFileManager defaultManager] attributesOfItemAtPath:databasePath error:NULL];
            fileSize = [[fattrs objectForKey:NSFileSize] intValue];
        }];
    }
    @catch (NSException* e) {
        N2LogExceptionWithStackTrace(e);
    }
    
    int size = NSSwapHostIntToBig(fileSize);
    [self writeData:[NSData dataWithBytes:&size length:sizeof(int)]];
    
    _mode = DONE;
}

- (void)GETDI {
    NSDictionary* dictionary = [NSDictionary dictionaryWithObjectsAndKeys: [[NSUserDefaults standardUserDefaults] stringForKey: @"AETITLE"], @"AETitle", [[NSUserDefaults standardUserDefaults] stringForKey: @"AEPORT"], @"Port", [NSString stringWithFormat: @"%d", [DCMTKStoreSCU sendSyntaxForListenerSyntax: [[NSUserDefaults standardUserDefaults] integerForKey: @"preferredSyntaxForIncoming"]]], @"TransferSyntax", nil];
    
    [self writeData:[NSMutableData dataWithData:HorosArchiveUnkeyedObject(dictionary)]];
    
    _mode = DONE;
}

- (void)VERSI {
    DicomDatabase* idatabase = [self _stackIndependentDatabase];
    
    NSTimeInterval val = [idatabase timeOfLastModification];
    
    NSSwappedDouble swappedValue = NSSwapHostDoubleToBig( val);
    
    if( sizeof( swappedValue.v) != 8) NSLog(@"********** warning sizeof( swappedValue) != 8");
    
    [self writeData:[NSMutableData dataWithBytes: &swappedValue.v length:sizeof(NSTimeInterval)]];
    
    _mode = DONE;
}

- (void)DBVER {
    [self writeData:[NSMutableData dataWithData:[CurrentDatabaseVersion dataUsingEncoding:NSASCIIStringEncoding]]];
    
    _mode = DONE;
}

- (void)ISPWD {
    // is this database protected by a password
    NSString* pswd = NSUserDefaults.bonjourSharingPassword;
    
    int val = 0;
    if (pswd)
        val = NSSwapHostIntToBig(1);
    
    [self writeData:[NSMutableData dataWithBytes:&val length:sizeof(int)]];
    
    _mode = DONE;
}

- (void)PASWD {
    NSString* incomingPswd = [self _stackReadString];
    
    // We read the string
    int val = 0;
    
    if (!NSUserDefaults.bonjourSharingPassword || [incomingPswd isEqualToString: NSUserDefaults.bonjourSharingPassword])
    {
        val = NSSwapHostIntToBig(1);
    }
    
    [self writeData:[NSMutableData dataWithBytes:&val length:sizeof(int)]];
    
    _mode = DONE;
}

- (void)SEND {
    int fileNo = [self _stackReadInt];
    
    NSMutableArray* savedFiles = [self _stackedObject];
    if (!savedFiles) [self _stackObject:(savedFiles = [NSMutableArray array])];
    
    while (savedFiles.count < fileNo)
    {
        int fileSize = [self _stackReadInt];
        [self _requireDataSize:fileSize];
        
        NSString* dstPath = [[[BrowserController currentBrowser] database] uniquePathForNewDataFileWithExtension:@"dcm"];
        
        [[self readData:fileSize] writeToFile:dstPath atomically:YES];
        
        [savedFiles addObject: dstPath];
        
        [self _unstack];
    }
    
    DicomDatabase* idatabase = [self _stackIndependentDatabase];
    
    NSArray *objects = [idatabase addFilesAtPaths: savedFiles postNotifications: YES dicomOnly: YES rereadExistingItems: YES generatedByOsiriX:(_mode == SENDG)];
    
    NSMutableData* representationToSend = [NSMutableData data];
    N2PerformManagedObjectContextBlockAndWait(idatabase.managedObjectContext, ^{
        NSArray *images = [idatabase objectsWithIDs:objects];
        unsigned int count = NSSwapHostIntToBig([images count]);
        [representationToSend appendBytes:&count length:4];
        for (DicomImage* image in images) {
            unsigned int pathNumber = NSSwapHostIntToBig(image.pathNumber.intValue);
            [representationToSend appendBytes:&pathNumber length:4];
        }
    });
    
    [self writeData:representationToSend];
    
    _mode = DONE;
}

- (void)NEWMS { // is this used ? nah
    int size = [self _stackReadInt];
    
    [self _requireDataSize:size];
    
    _mode = DONE;
}

- (void)ADDAL {
    NSString* object = [self _stackReadString];
    
    NSDictionary* d = (NSDictionary*)[NSPropertyListSerialization
                                      propertyListWithData:[NSData dataWithBytesNoCopy:(void*)object.UTF8String length:strlen(object.UTF8String) freeWhenDone:NO]
                                      options:NSPropertyListImmutable
                                      format:NULL
                                      error:NULL];
    
    if (!d) [NSException raise:NSGenericException format:@"can't parse parameters"];
    
    NSArray *studies = [d objectForKey:@"albumStudies"];
    NSString *albumUID = [d objectForKey:@"albumUID"];
    
    DicomDatabase* idatabase = [self _stackIndependentDatabase];
    
    N2PerformManagedObjectContextBlockAndWait(idatabase.managedObjectContext, ^{
        @try
        {
        DicomAlbum* album = [idatabase objectWithID:albumUID]; // [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: albumUID]]];
        NSMutableSet* albumStudies = [album mutableSetValueForKey:@"studies"];
        
        for (NSString* uri in studies)
        {
            DicomStudy* study = [idatabase objectWithID:uri]; // (DicomStudy*) [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: uri]]];
            [albumStudies addObject:study];
            [study archiveAnnotationsAsDICOMSR];
        }
        
        [idatabase save:nil];
        
        [[BrowserController currentBrowser] performSelectorOnMainThread:@selector(refreshDatabase:) withObject:self waitUntilDone:NO];
        }
        @catch (NSException * e)
        {
            N2LogExceptionWithStackTrace(e);
        }
    });
    
    _mode = DONE;
}

- (void)REMAL {
    NSString* object = [self _stackReadString];
    
    NSDictionary* d = (NSDictionary*)[NSPropertyListSerialization
                                      propertyListWithData:[NSData dataWithBytesNoCopy:(void*)object.UTF8String length:strlen(object.UTF8String) freeWhenDone:NO]
                                      options:NSPropertyListImmutable
                                      format:NULL
                                      error:NULL];
    
    if (!d) [NSException raise:NSGenericException format:@"can't parse parameters"];
    
    NSArray *studies = [d objectForKey:@"albumStudies"];
    NSString *albumUID = [d objectForKey:@"albumUID"];
    
    DicomDatabase* idatabase = [self _stackIndependentDatabase];
    
    N2PerformManagedObjectContextBlockAndWait(idatabase.managedObjectContext, ^{
        @try
        {
        DicomAlbum* album = [idatabase objectWithID:albumUID]; // [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: albumUID]]];
        NSMutableSet* albumStudies = [album mutableSetValueForKey: @"studies"];
        
        for (NSString* uri in studies)
        {
            DicomStudy* study = [idatabase objectWithID:uri]; // (DicomStudy*) [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: uri]]];
            [albumStudies removeObject:study];
            [study archiveAnnotationsAsDICOMSR];
        }
        
        [idatabase save:nil];
        
        [[BrowserController currentBrowser] performSelectorOnMainThread:@selector(refreshDatabase:) withObject:self waitUntilDone:NO];
        }
        @catch (NSException * e)
        {
            N2LogExceptionWithStackTrace(e);
        }
    });
    
    _mode = DONE;
    
}

- (void)SETVA {
    NSString* objectId = [self _stackReadString];
    __block NSString* value = [self _stackReadString];
    NSString* key = [self _stackReadString];
    
    DicomDatabase* idatabase = [self _stackIndependentDatabase];
    
    N2PerformManagedObjectContextBlockAndWait(idatabase.managedObjectContext, ^{
        @try
        {
        NSManagedObject* item = [idatabase objectWithID:objectId]; // [context objectWithID: [[context persistentStoreCoordinator] managedObjectIDForURIRepresentation: [NSURL URLWithString: object]]];
        
        if( item)
        {
            if( [[item valueForKeyPath: key] isKindOfClass: [NSNumber class]]) [item setValue: [NSNumber numberWithInt: [value intValue]] forKeyPath: key];
            else
            {
                if( [key isEqualToString: @"reportURL"])
                {
                    if( value == nil)
                    {
                        [[NSFileManager defaultManager] removeItemAtPath:[item valueForKeyPath: key] error:NULL];
                    }
                    else if( [[key pathComponents] count] == 1)
                    {
                        value = [[idatabase reportsDirPath] stringByAppendingPathComponent: [value lastPathComponent]];
                    }
                }
                
                [item setValue: value forKeyPath: key];
            }
        }
        
        [idatabase save:NULL];
        }
        @catch (NSException *e)
        {
        N2LogExceptionWithStackTrace(e);
        }
    });
    
    [[BrowserController currentBrowser] performSelectorOnMainThread:@selector(refreshDatabase:) withObject:self waitUntilDone:NO];
    
    _mode = DONE;
}

- (void)MFILE {
    NSString* path = [self _stackReadString];
    
    if( [path length])
    {
        if( [path characterAtIndex: 0] != '/')
            path = [[[DicomDatabase defaultDatabase] baseDirPath] stringByAppendingPathComponent: path];
    }
    
    NSDictionary *fattrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    
    NSData	*content = [[[fattrs objectForKey:NSFileModificationDate] description] dataUsingEncoding: NSUnicodeStringEncoding];
    
    [self writeData:content];
    
    _mode = DONE;
}

- (void)DCMSE {
    NSString* AETitle = [self _stackReadString];
    NSString* Address = [self _stackReadString];
    NSString* Port = [self _stackReadString];
    NSString* TransferSyntax = [self _stackReadString];
    
    int noOfFiles = [self _stackReadInt];
    
    NSMutableArray* localPaths = [self _stackedObject];
    if (!localPaths) [self _stackObject:(localPaths = [NSMutableArray array])];
    
    while (localPaths.count < noOfFiles)
    {
        NSString* path = [self _stackReadString];
        
        if( [path UTF8String] [0] != '/')
        {
            int val = [[path stringByDeletingPathExtension] intValue];
            
            NSString *dbLocation = [[DicomDatabase defaultDatabase] sqlFilePath];
            
            val /= [BrowserController DefaultFolderSizeForDB];
            val++;
            val *= [BrowserController DefaultFolderSizeForDB];
            
            path = [[dbLocation stringByDeletingLastPathComponent] stringByAppendingFormat:@"/DATABASE.noindex/%d/%@", val, path];
        }
        
        [localPaths addObject: path];
        
        [self _unstack]; // the string
    }
    
    if( [Address isEqualToString: @"127.0.0.1"])
    {
        Address = _peer.address;
    }
    
    NSDictionary *todo = [NSDictionary dictionaryWithObjectsAndKeys: Address, @"Address", TransferSyntax, @"TransferSyntax", Port, @"Port", AETitle, @"AETitle", localPaths, @"Files", nil];
    
    [NSThread detachNewThreadSelector:@selector(sendDICOMFilesToOsiriXNode:) toTarget:[[AppController sharedAppController] bonjourPublisher] withObject: todo];
    
    _mode = DONE;
}

- (void)DICOM
{
    @synchronized( self)
    {
        int noOfFiles = [self _stackReadInt];
        
        NSMutableArray* localPaths = [self _stackedObject];
        if (!localPaths) [self _stackObject:(localPaths = [NSMutableArray array])];
        NSMutableArray* dstPaths = [self _stackedObject];
        if (!dstPaths) [self _stackObject:(dstPaths = [NSMutableArray array])];
        
        while (localPaths.count < noOfFiles)
        {
            NSString* path = [self _stackReadString];
            
            if( [path UTF8String] [ 0] != '/')
            {
                if( [[[path pathComponents] objectAtIndex: 0] isEqualToString:@"ROIs"])
                {
                    //It's a ROI !
                    NSString	*local = [[[DicomDatabase defaultDatabase] sqlFilePath] stringByDeletingLastPathComponent];
                    
                    path = [[local stringByAppendingPathComponent:@"/ROIs/"] stringByAppendingPathComponent: [path lastPathComponent]];
                }
                else
                {
                    
                    int val = [[path stringByDeletingPathExtension] intValue];
                    
                    val /= [BrowserController DefaultFolderSizeForDB];
                    val++;
                    val *= [BrowserController DefaultFolderSizeForDB];
                    
                    NSString	*local = [[[DicomDatabase defaultDatabase] sqlFilePath] stringByDeletingLastPathComponent];
                    
                    path = [[[local stringByAppendingPathComponent:@"/DATABASE.noindex/"] stringByAppendingPathComponent: [NSString stringWithFormat:@"%d", val]] stringByAppendingPathComponent: path];
                }
            }
            
            [localPaths addObject: path];
            
            
            [self _unstack]; // the string
        }
        
        while (dstPaths.count < noOfFiles)
        {
            NSString* path = [self _stackReadString];
            
            [dstPaths addObject: path];
            
            
            [self _unstack]; // the string
        }
        
        int temp = NSSwapHostIntToBig(noOfFiles);
        [self writeData:[NSData dataWithBytesNoCopy:&temp length:4 freeWhenDone:NO]];
        for (int i = 0; i < noOfFiles; i++)
        {
            NSString* path = [localPaths objectAtIndex: i];
            
            
            NSData *content = [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:path] options:NSDataReadingMappedIfSafe error:nil];
            int size = NSSwapHostIntToBig([content length]);
            [self writeData:[NSData dataWithBytesNoCopy:&size length:4 freeWhenDone:NO]];
            [self writeData:content];
            
            const char* string = [[dstPaths objectAtIndex:i] UTF8String];
            int stringSize = NSSwapHostIntToBig( strlen( string)+1);	// +1 to include the last 0 !
            [self writeData:[NSData dataWithBytesNoCopy:&stringSize length:4 freeWhenDone:NO]];
            [self writeData:[NSData dataWithBytesNoCopy:(void*)string length:strlen(string)+1 freeWhenDone:NO]];
        }
        
        _mode = DONE;
    }
}






@end
