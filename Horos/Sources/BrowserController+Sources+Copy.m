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

#import "BrowserController+Sources+Copy.h"
#import "DicomImage.h"
#import "DicomSeries.h"
#import "DicomStudy.h"
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
#import "HorosSwiftInterop.h"
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

    id fastStoreVersion = [destination.dictionary objectForKey:@"HorosFastStoreVersion"];
    if (fastStoreVersion)
        [node setObject:fastStoreVersion forKey:@"HorosFastStoreVersion"];

    id fastStorePDU = [destination.dictionary objectForKey:@"HorosFastStorePDU"];
    if (fastStorePDU)
        [node setObject:fastStorePDU forKey:@"HorosFastStorePDU"];

    for (NSString *key in @[@"HorosDirectTransferVersion", @"HorosDirectTransferPort", @"HorosDirectTransferToken"])
    {
        id value = [destination.dictionary objectForKey:key];
        if (value)
            [node setObject:value forKey:key];
    }

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

-(void)copyImagesToHorosDirectSessionThread:(NSArray*)io
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSThread *thread = [NSThread currentThread];

    @try
    {
        HorosDirectNodeIdentifier *destination = [io objectAtIndex:1];
        DicomDatabase *sourceDatabase = [io objectAtIndex:2];
        NSMutableArray *queryItems = [NSMutableArray array];
        NSMutableSet *seriesKeys = [NSMutableSet set];
        DicomDatabase *workerDatabase = sourceDatabase.independentDatabase;
        N2PerformManagedObjectContextBlockAndWait(workerDatabase.managedObjectContext, ^{
            for (DicomImage *image in [workerDatabase objectsWithIDs:[io objectAtIndex:0]])
            {
                DicomSeries *series = image.series;
                NSString *studyUID = series.study.studyInstanceUID;
                NSString *seriesUID = series.seriesDICOMUID;
                if (!seriesUID.length)
                    seriesUID = series.seriesInstanceUID;
                if (!studyUID.length || !seriesUID.length)
                    continue;

                NSString *key = [NSString stringWithFormat:@"%@|%@", studyUID, seriesUID];
                if ([seriesKeys containsObject:key])
                    continue;

                [seriesKeys addObject:key];
                [queryItems addObject:@{
                    @"level": @"SERIES",
                    @"studyUID": studyUID,
                    @"seriesUID": seriesUID
                }];
            }
        });

        if (queryItems.count)
        {
            // The checked-in Mac may be behind NAT. Send only the selected
            // series UIDs and let that Mac pull them over the proven C-GET path.
            BOOL sent = [[HorosDirectTransferService sharedService]
                requestRetrieveQueryItems:queryItems
                toSession:destination.sessionIdentifier
                activityThread:thread];
            thread.status = sent ? NSLocalizedString(@"Transfer complete", nil) : NSLocalizedString(@"Direct Horos transfer failed", nil);
            if (sent)
                thread.progress = 1;
        }
        else
            thread.status = NSLocalizedString(@"No DICOM series to send.", nil);
    }
    @catch (NSException *exception)
    {
        thread.status = NSLocalizedString(@"Direct Horos transfer failed", nil);
        N2LogExceptionWithStackTrace(exception);
    }

    [pool release];
}

-(void)copyImagesToPhoneVolumeRenderThread:(NSArray*)io
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    NSThread* thread = [NSThread currentThread];
    int socketFD = -1;
    NSURL* packageDirectory = nil;
    HorosPhoneVolumeExporter* exporter = nil;
    @try
    {
        if (io.count < 3) return;
        DataNodeIdentifier* destination = io[1];
        NSString* protocol = destination.dictionary[@"Protocol"];
        if (![protocol isKindOfClass:NSString.class] || ![protocol isEqualToString:@"HVRVOL02"])
            @throw [NSException exceptionWithName:NSGenericException reason:@"Update the iPhone app before sending a prepared volume." userInfo:nil];
        // Snapshot live annotations on the main thread before taking a database-context lock.
        __block HorosPhoneVolumeExporter* snapshot = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ snapshot = [[HorosPhoneVolumeExporter alloc] init]; });
        exporter = snapshot;
        exporter.transferThread = thread;
        packageDirectory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[@"HorosPhone-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError* directoryError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:packageDirectory withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions:@0700} error:&directoryError])
            @throw [NSException exceptionWithName:NSGenericException reason:directoryError.localizedDescription userInfo:nil];
        thread.status = NSLocalizedString(@"Preparing image volume and ROIs for iPhone...", nil);
        DicomDatabase* database = [io[2] independentDatabase];
        __block NSArray* fileNames = nil;
        __block NSString* preparationError = nil;
        N2PerformManagedObjectContextBlockAndWait(database.managedObjectContext, ^{
            NSError* error = nil;
            fileNames = [[exporter writeImages:[database objectsWithIDs:io[0]] toDirectory:packageDirectory error:&error] retain];
            preparationError = [error.localizedDescription copy];
        });
        [fileNames autorelease];
        [preparationError autorelease];
        if (fileNames.count == 0)
            @throw [NSException exceptionWithName:NSGenericException reason:preparationError ?: @"Unable to prepare the selected image." userInfo:nil];
        if (thread.isCancelled) return;
        thread.status = NSLocalizedString(@"Connecting to iPhone...", nil);
        socketFD = HorosPhoneConnectWithRetry(destination.location, destination.port, thread);
        if (socketFD < 0)
            @throw [NSException exceptionWithName:NSGenericException reason:@"The iPhone planning app is unavailable." userInfo:nil];
        struct timeval timeout = {30, 0};
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        const char magic[8] = {'H','V','R','V','O','L','0','2'};
        uint32_t count = htonl((uint32_t)fileNames.count);
        if (!HorosPhoneSendAll(socketFD, magic, sizeof(magic)) || !HorosPhoneSendAll(socketFD, &count, sizeof(count)))
            @throw [NSException exceptionWithName:NSGenericException reason:@"Volume transfer handshake failed." userInfo:nil];
        uint64_t totalBytes = 0, sentBytes = 0;
        for (NSString* name in fileNames)
            totalBytes += [[[NSFileManager defaultManager] attributesOfItemAtPath:[packageDirectory URLByAppendingPathComponent:name].path error:nil] fileSize];
        for (NSString* name in fileNames)
        {
            if (thread.isCancelled) break;
            NSURL* url = [packageDirectory URLByAppendingPathComponent:name];
            uint64_t length = [[[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil] fileSize];
            NSData* nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
            uint32_t nameLength = htonl((uint32_t)nameData.length);
            uint64_t networkLength = HorosHostToNetwork64(length);
            if (!HorosPhoneSendAll(socketFD, &nameLength, 4) || !HorosPhoneSendAll(socketFD, nameData.bytes, nameData.length) ||
                !HorosPhoneSendAll(socketFD, &networkLength, 8))
                @throw [NSException exceptionWithName:NSGenericException reason:@"Volume transfer header failed." userInfo:nil];
            NSFileHandle* file = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
            if (!file) @throw [NSException exceptionWithName:NSGenericException reason:@"Cannot open a prepared asset." userInfo:nil];
            @try
            {
                while (length && !thread.isCancelled)
                {
                    @autoreleasepool
                    {
                        NSData* bytes = [file readDataUpToLength:(NSUInteger)MIN(length, 1024 * 1024) error:nil];
                        if (!bytes.length || !HorosPhoneSendAll(socketFD, bytes.bytes, bytes.length))
                            @throw [NSException exceptionWithName:NSGenericException reason:@"Volume transfer was interrupted." userInfo:nil];
                        length -= bytes.length;
                        sentBytes += bytes.length;
                        thread.progress = totalBytes ? (double)sentBytes / totalBytes : 0;
                        thread.status = NSLocalizedString(@"Sending image volume and ROIs to iPhone...", nil);
                    }
                }
            }
            @finally { [file closeFile]; }
        }
        if (thread.isCancelled)
            thread.status = NSLocalizedString(@"Cancelled iPhone transfer.", nil);
        else
        {
            uint8_t acknowledgement = 0;
            ssize_t received;
            do { received = recv(socketFD, &acknowledgement, 1, 0); } while (received < 0 && errno == EINTR);
            if (received != 1 || acknowledgement != 1)
                @throw [NSException exceptionWithName:NSGenericException reason:@"The iPhone did not accept the volume. Check its transfer message." userInfo:nil];
            thread.status = NSLocalizedString(@"Sent image volume and ROIs to iPhone.", nil);
            thread.progress = 1;
        }
    }
    @catch (NSException* exception)
    {
        thread.status = exception.reason ?: NSLocalizedString(@"iPhone transfer failed.", nil);
        [NSThread sleepForTimeInterval:3];
    }
    @finally
    {
        if (socketFD >= 0) close(socketFD);
        if (packageDirectory) [[NSFileManager defaultManager] removeItemAtURL:packageDirectory error:nil];
        [exporter release];
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
        } else if ([destination isKindOfClass:[HorosDirectNodeIdentifier class]]) { // live Horos check-in
            NSThread *thread = [[[ThreadsManager defaultManager] newActivityThreadWithTarget:self selector:@selector(copyImagesToHorosDirectSessionThread:) object:@[[dicomImages valueForKey:@"objectID"], destination, _database]] autorelease];
            thread.supportsCancel = YES;
            thread.name = NSLocalizedString(@"Sending images directly...", nil);
            [[ThreadsManager defaultManager] addThreadAndStart:thread];
            return YES;
        } else if ([destination isKindOfClass:[DicomNodeIdentifier class]]) { // local Horos to remote DICOM
            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DICOMSENDALLOWED"] == NO)
            {
                HorosPresentCriticalAlert(NSLocalizedString(@"DICOM Send", nil),
                                        NSLocalizedString(@"DICOM Sending is not activated. Contact your PACS manager for more information about DICOM Send.", nil),
                                        NSLocalizedString(@"OK", nil),
                                        nil,
                                        nil);
                return NO;
            }

            NSDictionary *node = HorosDICOMSendNodeDictionaryFromSource((DicomNodeIdentifier*)destination);
            if (!node)
            {
                HorosPresentCriticalAlert(NSLocalizedString(@"DICOM Send", nil),
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
