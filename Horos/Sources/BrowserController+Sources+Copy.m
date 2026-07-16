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

#import "BrowserController+Sources+Copy.h"
#import "DicomImage.h"
#import "DicomFile.h"
#import "DicomDatabase.h"
#import "DataNodeIdentifier.h"
#import "MutableArrayCategory.h"
#import "ThreadsManager.h"
#import "RemoteDicomDatabase.h"
#import "SendController.h"
#import "NSThread+N2.h"
#import "N2Debug.h"
#import "N2Stuff.h"
#import <errno.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>

static uint64_t HorosHostToNetwork64(uint64_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return __builtin_bswap64(value);
#else
    return value;
#endif
}

static BOOL HorosPhoneSendAll(int socketFD, const void *bytes, size_t length)
{
    const uint8_t *cursor = (const uint8_t*)bytes;
    size_t remaining = length;
    while (remaining > 0)
    {
        ssize_t sent = send(socketFD, cursor, remaining, 0);
        if (sent < 0 && errno == EINTR)
            continue;
        if (sent <= 0)
            return NO;
        cursor += sent;
        remaining -= sent;
    }

    return YES;
}

static NSDictionary *HorosDICOMSendNodeDictionaryFromSource(DicomNodeIdentifier *destination)
{
    if (!destination)
        return nil;

    NSString *address = destination.location;
    NSNumber *port = [NSNumber numberWithUnsignedInteger:destination.port];
    NSString *aetitle = [destination.dictionary objectForKey:@"AETitle"];
    if (!aetitle.length)
        aetitle = destination.aetitle;
    if (!aetitle.length)
        aetitle = destination.description;
    NSString *description = destination.description;
    if (!description.length)
        description = aetitle;
    id transferSyntax = [destination.dictionary objectForKey:@"TransferSyntax"];
    if (!transferSyntax)
        transferSyntax = [NSNumber numberWithInt:SendExplicitLittleEndian];

    if (!address.length || !port.integerValue || !aetitle.length)
        return nil;

    NSMutableDictionary *node = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                 address, @"Address",
                                 port, @"Port",
                                 aetitle, @"AETitle",
                                 description, @"Description",
                                 transferSyntax, @"TransferSyntax",
                                 [NSNumber numberWithBool:YES], @"HorosRetryTransientStoreSCU",
                                 [NSNumber numberWithBool:YES], @"HorosSuppressDuplicateStoreSCUAlerts",
                                 nil];

    id concurrentThreads = [destination.dictionary objectForKey:@"SendControllerConcurrentThreads"];
    if (concurrentThreads)
        [node setObject:concurrentThreads forKey:@"SendControllerConcurrentThreads"];

    return node;
}

static int HorosPhoneConnect(NSString *host, NSUInteger port)
{
    if (!host.length || !port)
        return -1;

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    NSString *portString = [NSString stringWithFormat:@"%lu", (unsigned long)port];
    struct addrinfo *result = NULL;
    if (getaddrinfo(host.UTF8String, portString.UTF8String, &hints, &result) != 0)
        return -1;

    int socketFD = -1;
    for (struct addrinfo *candidate = result; candidate; candidate = candidate->ai_next)
    {
        socketFD = socket(candidate->ai_family, candidate->ai_socktype, candidate->ai_protocol);
        if (socketFD < 0)
            continue;

#ifdef SO_NOSIGPIPE
        int noSigPipe = 1;
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif

        if (connect(socketFD, candidate->ai_addr, candidate->ai_addrlen) == 0)
            break;

        close(socketFD);
        socketFD = -1;
    }

    freeaddrinfo(result);
    return socketFD;
}

static int HorosPhoneConnectWithRetry(NSString *host, NSUInteger port, NSThread *thread)
{
    if (!host.length || !port)
        return -1;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    int socketFD = -1;

    while (!thread.isCancelled)
    {
        socketFD = HorosPhoneConnect(host, port);
        if (socketFD >= 0)
            return socketFD;

        if ([[NSDate date] compare:deadline] != NSOrderedAscending)
            break;

        thread.status = NSLocalizedString(@"Waiting for iPhone planning app...", nil);
        [NSThread sleepForTimeInterval:0.25];
    }

    return socketFD;
}

static NSString* HorosPhoneTransferFileName(NSString *path, NSUInteger index)
{
    NSString *baseName = path.lastPathComponent;
    if (!baseName.length)
        baseName = @"image.dcm";

    return [NSString stringWithFormat:@"%06lu-%@", (unsigned long)(index + 1), baseName];
}

@implementation BrowserController (SourcesCopy)

-(void)copyImagesToLocalBrowserSourceThread:(NSArray*)io
{
    @autoreleasepool
    {
        if( io.count < 4)
        {
            NSLog( @"******* copyImagesToLocalBrowserSourceThread : io.count < 4");
            return;
        }

        DicomDatabase *srcIndependentDatabase = nil;
        NSArray* dicomImages = nil;
        DicomDatabase* dstDatabase = nil;
        @try
        {
            NSThread* thread = [NSThread currentThread];

            DicomDatabase *srcDatabase = [io objectAtIndex:2];
            srcIndependentDatabase = [[srcDatabase independentDatabase] retain];
            NSMutableArray* imagePaths = [NSMutableArray array];
            N2PerformManagedObjectContextBlockAndWait(srcIndependentDatabase.managedObjectContext, ^{
                NSArray *images = [srcIndependentDatabase objectsWithIDs:[io objectAtIndex:0]];
                for (DicomImage* image in images)
                    if (![imagePaths containsObject:image.completePath])
                        [imagePaths addObject:image.completePath];
            });
            [srcIndependentDatabase release];
            srcIndependentDatabase = nil;

            thread.status = NSLocalizedString(@"Opening database...", nil);
            dstDatabase = [[[io objectAtIndex:3] independentDatabase] retain];

            thread.status = [NSString stringWithFormat:NSLocalizedString(@"Copying %@ %@...", nil), N2LocalizedDecimal( imagePaths.count), (imagePaths.count == 1 ? NSLocalizedString(@"file", nil) : NSLocalizedString(@"files", nil)) ];
            NSMutableArray* dstPaths = [NSMutableArray array];

            NSTimeInterval fiveSeconds = [NSDate timeIntervalSinceReferenceDate] + 5;
            NSTimeInterval oneSecond = [NSDate timeIntervalSinceReferenceDate] + 1;

            for (NSInteger i = 0; i < imagePaths.count; ++i)
            {
                thread.progress = 1.0*i/imagePaths.count;

                if (thread.isCancelled)
                    break;

                NSString* srcPath = [imagePaths objectAtIndex:i];
                NSString* dstPath = [dstDatabase uniquePathForNewDataFileWithExtension: @"dcm"];

                if( dstPath.length)
                {
                    static NSString *oneCopyAtATime = @"oneCopyAtATime";
                    @synchronized( oneCopyAtATime)
                    {
                        if( srcDatabase.isReadOnly)
                        {
                            NSTask *t = HorosLaunchTaskAtPath(@"/bin/cp", @[srcPath, dstPath]);
                            while( [t isRunning]){};
                        }
                        else if( [[NSFileManager defaultManager] copyItemAtPath: srcPath toPath: dstPath error: nil] == NO)
                            NSLog( @"**** copyItemAtPath failed: %@", dstPath);

                        if( [[NSFileManager defaultManager] fileExistsAtPath: dstPath])
                        {
                            if( [DicomFile isDICOMFile: dstPath] == NO)
                                [[NSFileManager defaultManager] moveItemAtPath: dstPath toPath: [[dstPath stringByDeletingPathExtension] stringByAppendingPathExtension: [srcPath pathExtension]] error: nil];

                            [dstPaths addObject:dstPath];
                        }
                    }
                }

                if( fiveSeconds < [NSDate timeIntervalSinceReferenceDate])
                {
                    thread.status = [NSString stringWithFormat:NSLocalizedString(@"Indexing %@ %@...", nil), N2LocalizedDecimal( dstPaths.count), (dstPaths.count == 1 ? NSLocalizedString(@"file", nil) : NSLocalizedString(@"files", nil))];

                    [dstDatabase addFilesAtPaths: dstPaths postNotifications: YES dicomOnly: [[NSUserDefaults standardUserDefaults] boolForKey: @"onlyDICOM"] rereadExistingItems:NO  generatedByOsiriX: NO importedFiles: YES returnArray: NO];

                    [dstPaths removeAllObjects];

                    fiveSeconds = [NSDate timeIntervalSinceReferenceDate] + 5;
                }

                if( oneSecond < [NSDate timeIntervalSinceReferenceDate])
                {
                    thread.status = [NSString stringWithFormat:NSLocalizedString(@"Copying %@ %@...", nil), N2LocalizedDecimal( (long)imagePaths.count-i), ((long)imagePaths.count-i == 1 ? NSLocalizedString(@"file", nil) : NSLocalizedString(@"files", nil))];

                    oneSecond = [NSDate timeIntervalSinceReferenceDate] + 1;
                }
            }

            thread.status = [NSString stringWithFormat:NSLocalizedString(@"Indexing %@ %@...", nil), N2LocalizedDecimal( dstPaths.count), (dstPaths.count == 1 ? NSLocalizedString(@"file", nil) : NSLocalizedString(@"files", nil))];
            thread.progress = -1;
            [dstDatabase addFilesAtPaths: dstPaths postNotifications: YES dicomOnly: [[NSUserDefaults standardUserDefaults] boolForKey: @"onlyDICOM"] rereadExistingItems:NO  generatedByOsiriX: NO importedFiles: YES returnArray: NO];
        }
        @catch (NSException *exception) {
            N2LogException( exception);
        }
        @finally {
            [dicomImages release];
            [srcIndependentDatabase release];
            [dstDatabase release];
        }
	}
}

-(void)copyImagesToRemoteBrowserSourceThread:(NSArray*)io
{
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	NSThread* thread = [NSThread currentThread];

	DataNodeIdentifier* destination = [io objectAtIndex:1];
	DicomDatabase *srcDatabase = [io objectAtIndex:2];
	NSMutableArray* imagePaths = [NSMutableArray array];
    DicomDatabase *independentDatabase = srcDatabase.independentDatabase;
    N2PerformManagedObjectContextBlockAndWait(independentDatabase.managedObjectContext, ^{
        for (DicomImage* image in [independentDatabase objectsWithIDs:[io objectAtIndex:0]])
            if (![imagePaths containsObject:image.completePath])
                [imagePaths addObject:image.completePath];
    });

	thread.status = NSLocalizedString(@"Opening database...", nil);

    @try
    {
        RemoteDicomDatabase* dstDatabase = [RemoteDicomDatabase databaseForLocation:destination.location port:destination.port name:destination.description update:NO];

        thread.status = [NSString stringWithFormat:NSLocalizedString(@"Sending %@ %@...", nil), N2LocalizedDecimal( imagePaths.count), (imagePaths.count == 1 ? NSLocalizedString(@"file", nil) : NSLocalizedString(@"files", nil)) ];


        [dstDatabase uploadFilesAtPaths:imagePaths imageObjects:nil];
    }
    @catch (NSException* e)
    {
        thread.status = NSLocalizedString(@"Error: destination is unavailable", nil);
        N2LogExceptionWithStackTrace(e);
        [NSThread sleepForTimeInterval:1];
    }

	[pool release];
}

-(void)copyImagesToPhoneVolumeRenderThread:(NSArray*)io
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    NSThread* thread = [NSThread currentThread];
    int socketFD = -1;

    @try
    {
        if (io.count < 3)
            return;

        DataNodeIdentifier* destination = [io objectAtIndex:1];
        DicomDatabase *srcDatabase = [io objectAtIndex:2];
        NSMutableArray* imagePaths = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];
        DicomDatabase *independentDatabase = srcDatabase.independentDatabase;
        N2PerformManagedObjectContextBlockAndWait(independentDatabase.managedObjectContext, ^{
            for (DicomImage* image in [independentDatabase objectsWithIDs:[io objectAtIndex:0]])
            {
                NSString *path = image.completePath;
                BOOL isDirectory = NO;
                if (path.length && ![imagePaths containsObject:path] && [fm fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory)
                    [imagePaths addObject:path];
            }
        });

        if (!imagePaths.count)
        {
            thread.status = NSLocalizedString(@"No files to send.", nil);
            [NSThread sleepForTimeInterval:1];
            return;
        }

        thread.status = [NSString stringWithFormat:NSLocalizedString(@"Connecting to %@...", nil), destination.description ?: NSLocalizedString(@"iPhone", nil)];
        socketFD = HorosPhoneConnectWithRetry(destination.location, destination.port, thread);
        if (socketFD < 0)
        {
            thread.status = NSLocalizedString(@"Error: iPhone planning app is unavailable", nil);
            [NSThread sleepForTimeInterval:1];
            return;
        }

        const char magic[8] = {'H', 'V', 'R', 'S', 'T', 'D', 'Y', '1'};
        uint32_t fileCount = htonl((uint32_t)imagePaths.count);
        if (!HorosPhoneSendAll(socketFD, magic, sizeof(magic)) || !HorosPhoneSendAll(socketFD, &fileCount, sizeof(fileCount)))
            @throw [NSException exceptionWithName:NSGenericException reason:@"Phone transfer handshake failed" userInfo:nil];

        thread.status = [NSString stringWithFormat:NSLocalizedString(@"Sending %@ %@ to iPhone...", nil), N2LocalizedDecimal(imagePaths.count), (imagePaths.count == 1 ? NSLocalizedString(@"file", nil) : NSLocalizedString(@"files", nil))];

        for (NSUInteger i = 0; i < imagePaths.count; ++i)
        {
            if (thread.isCancelled)
                break;

            NSString *path = [imagePaths objectAtIndex:i];
            NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
            unsigned long long fileSize = [attributes fileSize];
            NSString *transferName = HorosPhoneTransferFileName(path, i);
            NSData *nameData = [transferName dataUsingEncoding:NSUTF8StringEncoding];
            if (!nameData.length || nameData.length > UINT32_MAX)
                @throw [NSException exceptionWithName:NSGenericException reason:@"Invalid transfer file name" userInfo:nil];

            uint32_t nameLength = htonl((uint32_t)nameData.length);
            uint64_t networkFileSize = HorosHostToNetwork64((uint64_t)fileSize);
            if (!HorosPhoneSendAll(socketFD, &nameLength, sizeof(nameLength)) ||
                !HorosPhoneSendAll(socketFD, nameData.bytes, nameData.length) ||
                !HorosPhoneSendAll(socketFD, &networkFileSize, sizeof(networkFileSize)))
                @throw [NSException exceptionWithName:NSGenericException reason:@"Phone transfer header failed" userInfo:nil];

            NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
            if (!file)
                @throw [NSException exceptionWithName:NSGenericException reason:@"Unable to open image file for transfer" userInfo:nil];

            unsigned long long bytesSentForFile = 0;
            while (bytesSentForFile < fileSize)
            {
                if (thread.isCancelled)
                    break;

                @autoreleasepool
                {
                    NSData *chunk = [file readDataOfLength:1024 * 1024];
                    if (!chunk.length)
                        break;

                    if (!HorosPhoneSendAll(socketFD, chunk.bytes, chunk.length))
                        @throw [NSException exceptionWithName:NSGenericException reason:@"Phone transfer data failed" userInfo:nil];

                    bytesSentForFile += chunk.length;
                }
            }
            [file closeFile];

            thread.progress = (double)(i + 1) / (double)imagePaths.count;
            thread.status = [NSString stringWithFormat:NSLocalizedString(@"Sending %@ of %@ files to iPhone...", nil), N2LocalizedDecimal(i + 1), N2LocalizedDecimal(imagePaths.count)];
        }

        if (thread.isCancelled)
            thread.status = NSLocalizedString(@"Cancelled iPhone transfer.", nil);
        else
            thread.status = NSLocalizedString(@"Sent study to iPhone.", nil);

        thread.progress = 1;
        [NSThread sleepForTimeInterval:0.5];
    }
    @catch (NSException *exception)
    {
        thread.status = NSLocalizedString(@"Error: iPhone transfer failed", nil);
        N2LogExceptionWithStackTrace(exception);
        [NSThread sleepForTimeInterval:1];
    }
    @finally
    {
        if (socketFD >= 0)
            close(socketFD);
        [pool release];
    }
}

-(void)copyRemoteImagesToLocalBrowserSourceThread:(NSArray*)io
{
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	NSThread* thread = [NSThread currentThread];
    DicomDatabase *srcIndependentDatabase = nil;
    DicomDatabase* idatabase = nil;

    @try
    {
        DataNodeIdentifier* destination = [io objectAtIndex:1];
        RemoteDicomDatabase* srcDatabase = [io objectAtIndex:2];
        srcIndependentDatabase = [[srcDatabase independentDatabase] retain];

        thread.status = NSLocalizedString(@"Opening database...", nil);

        idatabase = [[[DicomDatabase databaseAtPath:destination.location name:destination.description] independentDatabase] retain];
        NSMutableArray* dstPaths = [NSMutableArray array];
        N2PerformManagedObjectContextBlockAndWait(srcIndependentDatabase.managedObjectContext, ^{
            NSMutableArray* dicomImages = [[[srcIndependentDatabase objectsWithIDs:[io objectAtIndex:0]] mutableCopy] autorelease];
            NSMutableArray* imagePaths = [[[dicomImages valueForKey:@"completePath"] mutableCopy] autorelease];
            [imagePaths removeDuplicatedStringsInSyncWithThisArray:dicomImages];

            thread.status = [NSString stringWithFormat:NSLocalizedString(@"Fetching %@ %@...", nil), N2LocalizedDecimal(dicomImages.count), (dicomImages.count == 1 ? NSLocalizedString(@"file", nil) : NSLocalizedString(@"files", nil))];
            for (NSInteger i = 0; i < dicomImages.count; ++i)
            {
                @try
                {
                    DicomImage* dicomImage = [dicomImages objectAtIndex:i];
                    NSString* srcPath = [srcDatabase cacheDataForImage:dicomImage maxFiles:0];

                    if (srcPath)
                    {
                        NSString* ext = [DicomFile isDICOMFile:srcPath]? @"dcm" : srcPath.pathExtension;
                        NSString* dstPath = [idatabase uniquePathForNewDataFileWithExtension:ext];

                        if( dstPath.length)
                            if ([[NSFileManager defaultManager] moveItemAtPath:srcPath toPath:dstPath error:NULL])
                                [dstPaths addObject:dstPath];
                    }
                }
                @catch (NSException *exception)
                {
                    N2LogExceptionWithStackTrace( exception);
                }
                thread.progress = 1.0*i/dicomImages.count;

                if (thread.isCancelled)
                    break;
            }
        });

        thread.status = NSLocalizedString(@"Indexing files...", nil);
        thread.progress = -1;
        [idatabase addFilesAtPaths: dstPaths postNotifications: YES dicomOnly: [[NSUserDefaults standardUserDefaults] boolForKey: @"onlyDICOM"] rereadExistingItems:NO generatedByOsiriX: NO importedFiles: YES returnArray: NO];
    }
    @catch (NSException *exception)
    {
        N2LogExceptionWithStackTrace(exception);
    }
    @finally
    {
        [idatabase release];
        [srcIndependentDatabase release];
    }

	[pool release];
}

-(void)copyRemoteImagesToRemoteBrowserSourceThread:(NSArray*)io
{
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	NSThread* thread = [NSThread currentThread];

    DataNodeIdentifier* destination = [io objectAtIndex:1];
    RemoteDicomDatabase* srcDatabase = [io objectAtIndex:2];
    DicomDatabase *srcIndependentDatabase = srcDatabase.independentDatabase;

	NSString* dstAddress = nil;
	NSString* dstAET = nil;
	NSInteger dstPort = 0;
	NSInteger dstSyntax = 0;
	if ([destination isKindOfClass:[RemoteDatabaseNodeIdentifier class]])
    {
		[RemoteDatabaseNodeIdentifier location:destination.location port:destination.port toAddress:&dstAddress port:NULL];
		dstPort = [[destination.dictionary objectForKey:@"port"] integerValue];
		dstAET = [destination.dictionary objectForKey:@"AETitle"];
		if (!dstAET || !dstPort || !dstSyntax)
        {
			thread.status = NSLocalizedString(@"Fetching destination information...", nil);
            NSDictionary* dstInfo = nil;
            @try
            {
                RemoteDicomDatabase* dstDatabase = [RemoteDicomDatabase databaseForLocation:destination.location port:destination.port name:destination.description update:NO];

                dstInfo = [dstDatabase fetchDicomDestinationInfo];
            } @catch (NSException* e)
            {
                thread.status = NSLocalizedString(@"Error: destination is unavailable", nil);
                N2LogExceptionWithStackTrace(e);
                [NSThread sleepForTimeInterval:1];
            }
			if ([dstInfo objectForKey:@"AETitle"]) dstAET = [dstInfo objectForKey:@"AETitle"];
			if ([dstInfo objectForKey:@"Port"]) dstPort = [[dstInfo objectForKey:@"Port"] integerValue];
			if ([dstInfo objectForKey:@"TransferSyntax"]) dstSyntax = [[dstInfo objectForKey:@"TransferSyntax"] integerValue];
		}
	} else if ([destination isKindOfClass:[DicomNodeIdentifier class]])
    {
		[DicomNodeIdentifier location:destination.location port:destination.port toAddress:&dstAddress port:&dstPort aet:&dstAET];
		dstSyntax = [[destination.dictionary objectForKey:@"TransferSyntax"] integerValue];
	}

	N2PerformManagedObjectContextBlockAndWait(srcIndependentDatabase.managedObjectContext, ^{
        NSMutableArray* dicomImages = [[[srcIndependentDatabase objectsWithIDs:[io objectAtIndex:0]] mutableCopy] autorelease];
        thread.status = [NSString stringWithFormat:NSLocalizedString(@"Sending SCU request...", nil), dicomImages.count];
        [srcDatabase storeScuImages:dicomImages toDestinationAETitle:dstAET address:dstAddress port:dstPort transferSyntax:dstSyntax];
    });

	[pool release];
}

-(BOOL)initiateCopyImages:(NSArray*)dicomImages toSource:(DataNodeIdentifier*)destination
{
	if (_database.isLocal)
    {
		if ([destination isKindOfClass:[LocalDatabaseNodeIdentifier class]]) { // local Horos to local Horos

            DicomDatabase *dst = [DicomDatabase databaseAtPath:destination.location]; // Create the mainDatabase on the MAIN thread, if necessary !

            NSThread* thread = [[[ThreadsManager defaultManager] newActivityThreadWithTarget:self selector:@selector(copyImagesToLocalBrowserSourceThread:) object:[NSArray arrayWithObjects: [dicomImages valueForKey:@"objectID"], destination, _database, dst, NULL]] autorelease];
            thread.name = NSLocalizedString(@"Copying images...", nil);
            thread.supportsCancel = YES;
            [[ThreadsManager defaultManager] addThreadAndStart:thread];
            return YES;
        } else if ([destination isKindOfClass:[RemoteDatabaseNodeIdentifier class]]) { // local Horos to remote Horos
            NSThread* thread = [[[ThreadsManager defaultManager] newActivityThreadWithTarget:self selector:@selector(copyImagesToRemoteBrowserSourceThread:) object:[NSArray arrayWithObjects: [dicomImages valueForKey:@"objectID"], destination, _database, NULL]] autorelease];
            thread.supportsCancel = YES;
            thread.name = NSLocalizedString(@"Sending images...", nil);
            [[ThreadsManager defaultManager] addThreadAndStart:thread];
            return YES;
        } else if ([destination isKindOfClass:[PhoneVolumeRenderNodeIdentifier class]]) { // local Horos to iPhone planning app
            NSThread* thread = [[[ThreadsManager defaultManager] newActivityThreadWithTarget:self selector:@selector(copyImagesToPhoneVolumeRenderThread:) object:[NSArray arrayWithObjects: [dicomImages valueForKey:@"objectID"], destination, _database, NULL]] autorelease];
            thread.supportsCancel = YES;
            thread.name = NSLocalizedString(@"Sending study to iPhone...", nil);
            [[ThreadsManager defaultManager] addThreadAndStart:thread];
            return YES;
        } else if ([destination isKindOfClass:[DicomNodeIdentifier class]]) { // local Horos to remote DICOM
            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DICOMSENDALLOWED"] == NO)
            {
                NSRunCriticalAlertPanel(NSLocalizedString(@"DICOM Send", nil),
                                        NSLocalizedString(@"DICOM Sending is not activated. Contact your PACS manager for more information about DICOM Send.", nil),
                                        NSLocalizedString(@"OK", nil),
                                        nil,
                                        nil);
                return NO;
            }

            NSDictionary *node = HorosDICOMSendNodeDictionaryFromSource((DicomNodeIdentifier*)destination);
            if (!node)
            {
                NSRunCriticalAlertPanel(NSLocalizedString(@"DICOM Send", nil),
                                        NSLocalizedString(@"The selected DICOM destination is missing its address, port, or AE title.", nil),
                                        NSLocalizedString(@"OK", nil),
                                        nil,
                                        nil);
                return NO;
            }

            [SendController sendFiles:dicomImages toNode:node usingSyntax:[[node objectForKey:@"TransferSyntax"] intValue]];
            return YES;
            // [_database storeScuImages:dicomImages toDestinationAETitle:(NSString*)aet address:(NSString*)address port:(NSInteger)port transferSyntax:(int)exsTransferSyntax];
		}
	}
    else
    {
		if ([destination isKindOfClass:[LocalDatabaseNodeIdentifier class]])
        { // remote Horos to local Horos

            [DicomDatabase databaseAtPath:destination.location]; // Create the mainDatabase on the MAIN thread, if necessary !

            NSThread* thread = [[[ThreadsManager defaultManager] newActivityThreadWithTarget:self selector:@selector(copyRemoteImagesToLocalBrowserSourceThread:) object:[NSArray arrayWithObjects: [dicomImages valueForKey:@"objectID"], destination, _database, NULL]] autorelease];
            thread.name = NSLocalizedString(@"Copying images...", nil);
            thread.supportsCancel = YES;
            [[ThreadsManager defaultManager] addThreadAndStart:thread];
            return YES;
		} else if ([destination isKindOfClass:[RemoteDatabaseNodeIdentifier class]] || [destination isKindOfClass:[DicomNodeIdentifier class]]) { // remote Horos to remote Horos // remote Horos to remote DICOM
				NSThread* thread = [[[ThreadsManager defaultManager] newActivityThreadWithTarget:self selector:@selector(copyRemoteImagesToRemoteBrowserSourceThread:) object:[NSArray arrayWithObjects: [dicomImages valueForKey:@"objectID"], destination, _database, NULL]] autorelease];
				thread.name = NSLocalizedString(@"Initiating image transfer...", nil);
                thread.supportsCancel = YES;
				[[ThreadsManager defaultManager] addThreadAndStart:thread];
				return YES;
		}
	}

	return NO;
}

@end
