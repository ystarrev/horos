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
#import "HVRPSKTransport.h"
#import <CoreImage/CoreImage.h>
#import <CommonCrypto/CommonHMAC.h>
#import <errno.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <limits.h>
#import <netdb.h>
#import <poll.h>
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

static NSImage* HorosPhonePairingImage(NSString* payload)
{
    CIFilter* generator = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [generator setValue:[payload dataUsingEncoding:NSASCIIStringEncoding] forKey:@"inputMessage"];
    [generator setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage* output = generator.outputImage;
    if (!output) return nil;
    CGImageRef modules = [[CIContext contextWithOptions:nil] createCGImage:output fromRect:output.extent];
    if (!modules) return nil;
    const size_t scale = 12;
    const size_t margin = 4 * scale; // Standard four-module quiet zone.
    const size_t width = (CGImageGetWidth(modules) + 8) * scale;
    const size_t height = (CGImageGetHeight(modules) + 8) * scale;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace,
                                                (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (!bitmap) { CGImageRelease(modules); return nil; }
    CGContextSetRGBFillColor(bitmap, 1, 1, 1, 1);
    CGContextFillRect(bitmap, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationNone);
    CGContextDrawImage(bitmap, CGRectMake(margin, margin,
      CGImageGetWidth(modules) * scale, CGImageGetHeight(modules) * scale), modules);
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    CGImageRelease(modules);
    if (!image) return nil;
    NSImage* result = [[[NSImage alloc] initWithCGImage:image size:NSMakeSize(400, 400)] autorelease];
    CGImageRelease(image);
    return result;
}

// This unauthenticated message only opens the scanner; the QR supplies the actual secret.
static int HorosRequestPhonePairing(NSString* host, NSString* pairingID)
{
    if (!host.length || !pairingID.length) return -1;
    NSString* message = [@"HVRPAIR1:" stringByAppendingString:pairingID];
    NSData* data = [message dataUsingEncoding:NSASCIIStringEncoding];
    if (data.length != 45) return -1;
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICSERV;
    struct addrinfo* addresses = NULL;
    if (getaddrinfo(host.UTF8String, "59464", &hints, &addresses) != 0) return -1;
    int connectedFD = -1;
    for (struct addrinfo* address = addresses; address; address = address->ai_next)
    {
        int socketFD = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketFD < 0) continue;
        int noSignal = 1;
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        int flags = fcntl(socketFD, F_GETFL, 0);
        if (flags < 0 || fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) < 0)
        { close(socketFD); continue; }
        int result = connect(socketFD, address->ai_addr, address->ai_addrlen);
        if (result < 0 && errno == EINPROGRESS)
        {
            struct pollfd pending = {socketFD, POLLOUT, 0};
            result = poll(&pending, 1, 800);
            if (result > 0)
            {
                int error = 0;
                socklen_t errorLength = sizeof(error);
                result = getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0 && !error ? 0 : -1;
            }
            else result = -1;
        }
        if (result == 0)
        {
            fcntl(socketFD, F_SETFL, flags);
            struct timeval timeout = {1, 0};
            setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            const uint8_t* bytes = data.bytes;
            size_t remaining = data.length;
            while (remaining)
            {
                ssize_t sent = send(socketFD, bytes, remaining, 0);
                if (sent < 0 && errno == EINTR) continue;
                if (sent <= 0) break;
                bytes += sent;
                remaining -= sent;
            }
            if (!remaining && fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0)
            {
                connectedFD = socketFD;
                break;
            }
            close(socketFD);
        }
        else close(socketFD);
    }
    freeaddrinfo(addresses);
    return connectedFD;
}

static NSData* HorosPhonePairingKey(NSString* pairingID, NSString* host)
{
    if (!pairingID.length || ![[[NSUUID alloc] initWithUUIDString:pairingID] autorelease]) return nil;
    NSDictionary* query = [NSDictionary dictionaryWithObjectsAndKeys:
        (id)kSecClassGenericPassword, (id)kSecClass,
        @"org.horos.PhoneVolumeRender.Pairing", (id)kSecAttrService,
        pairingID, (id)kSecAttrAccount,
        (id)kCFBooleanTrue, (id)kSecReturnData, nil];
    CFTypeRef found = NULL;
    if (SecItemCopyMatching((CFDictionaryRef)query, &found) == errSecSuccess)
        return [(NSData*)found autorelease];
    uint8_t keyBytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(keyBytes), keyBytes) != errSecSuccess) return nil;
    NSData* key = [NSData dataWithBytes:keyBytes length:sizeof(keyBytes)];
    volatile uint8_t* wipe = keyBytes;
    for (size_t i = 0; i < sizeof(keyBytes); ++i) wipe[i] = 0;
    NSMutableString* hex = [NSMutableString stringWithCapacity:64];
    const uint8_t* bytes = key.bytes;
    for (NSUInteger i = 0; i < key.length; ++i) [hex appendFormat:@"%02X", bytes[i]];
    NSString* payload = [NSString stringWithFormat:@"HVRPAIR1:%@:%@", pairingID, hex];
    NSImage* image = HorosPhonePairingImage(payload);
    if (!image) return nil;
    int pairingSocket = HorosRequestPhonePairing(host, pairingID);
    if (pairingSocket < 0) return nil;
    NSString* acknowledgement = [@"HVRPAIR1-ACK:" stringByAppendingString:pairingID];
    NSData* acknowledgementData = [acknowledgement dataUsingEncoding:NSASCIIStringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length,
           acknowledgementData.bytes, acknowledgementData.length, digest);
    NSData* expectedReply = [NSData dataWithBytes:digest length:sizeof(digest)];
    __block BOOL confirmed = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert* alert = [[[NSAlert alloc] init] autorelease];
        alert.messageText = @"Pair with iPhonePlanner";
        alert.informativeText = @"Scan this code with iPhonePlanner. The dialog will close and the image will send automatically once pairing is confirmed. Keep the iPhone app open in the foreground. Do not photograph or share this code.";
        NSImageView* imageView = [[[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)] autorelease];
        imageView.image = image;
        imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        alert.accessoryView = imageView;
        [alert addButtonWithTitle:@"Cancel"];
        NSMutableData* reply = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
        __block NSUInteger received = 0;
        NSTimer* timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* activeTimer) {
            (void)activeTimer;
            ssize_t count = recv(pairingSocket, (uint8_t*)reply.mutableBytes + received,
                                 reply.length - received, 0);
            if (count > 0) received += (NSUInteger)count;
            else if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return;
            else
            {
                [NSApp stopModalWithCode:NSModalResponseCancel];
                [alert.window orderOut:nil];
                return;
            }
            if (received == reply.length)
            {
                const uint8_t* actual = reply.bytes;
                const uint8_t* expected = expectedReply.bytes;
                uint8_t difference = 0;
                for (NSUInteger index = 0; index < reply.length; ++index)
                    difference |= actual[index] ^ expected[index];
                confirmed = difference == 0;
                [NSApp stopModalWithCode:confirmed ? NSModalResponseOK : NSModalResponseCancel];
                [alert.window orderOut:nil];
            }
        }];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
        NSModalResponse response = [alert runModal];
        [timer invalidate];
        confirmed = confirmed && response == NSModalResponseOK;
    });
    close(pairingSocket);
    if (!confirmed) return nil;
    NSMutableDictionary* item = [NSMutableDictionary dictionaryWithDictionary:query];
    [item removeObjectForKey:(id)kSecReturnData];
    [item setObject:key forKey:(id)kSecValueData];
    if (SecItemAdd((CFDictionaryRef)item, NULL) != errSecSuccess) return nil;
    return key;
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

static nw_connection_t HorosSecurePhoneConnect(NSString *host, NSUInteger port, NSData *key)
{
    if (!host.length || !port || key.length != 32) return nil;
    nw_parameters_t parameters = HVRPSKParameters(key);
    if (!parameters) return nil;
    NSString* portString = [NSString stringWithFormat:@"%lu", (unsigned long)port];
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, portString.UTF8String);
    nw_connection_t connection = endpoint ? nw_connection_create(endpoint, parameters) : nil;
    if (connection)
    {
        nw_connection_set_queue(connection, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        if (!HVRWaitForReady(connection, 10.0))
        {
            nw_connection_cancel(connection);
            nw_release(connection);
            connection = nil;
        }
    }
    if (endpoint) nw_release(endpoint);
    nw_release(parameters);
    return connection;
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
    HorosActivityToken *activity = [[HorosActivityToken beginActivity] retain];
    NSThread* thread = [NSThread currentThread];
    nw_connection_t connection = nil;
    NSURL* packageDirectory = nil;
    HorosPhoneVolumeExporter* exporter = nil;
    @try
    {
        if (io.count < 3) return;
        DataNodeIdentifier* destination = io[1];
        NSString* protocol = destination.dictionary[@"Protocol"];
        if (![protocol isKindOfClass:NSString.class] || ![protocol isEqualToString:@"HVRVOL03"])
            @throw [NSException exceptionWithName:NSGenericException reason:@"This iPhone app does not support paired encrypted transfer. Update it before sending patient images." userInfo:nil];
        NSString* pairingID = destination.dictionary[@"PairingID"];
        thread.status = NSLocalizedString(@"Waiting for iPhone pairing if needed...", nil);
        NSData* pairingKey = HorosPhonePairingKey(pairingID, destination.location);
        if (pairingKey.length != 32)
            @throw [NSException exceptionWithName:NSGenericException reason:@"Pairing did not complete. Keep iPhonePlanner open in the foreground and retry the transfer." userInfo:nil];
        [self redrawSources];
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
        for (NSUInteger attempt = 0; attempt < 3 && !connection && !thread.isCancelled; ++attempt)
        {
            if (attempt) [NSThread sleepForTimeInterval:0.5];
            connection = HorosSecurePhoneConnect(destination.location, destination.port, pairingKey);
        }
        if (!connection)
        {
            NSDictionary* oldKey = [NSDictionary dictionaryWithObjectsAndKeys:
                (id)kSecClassGenericPassword, (id)kSecClass,
                @"org.horos.PhoneVolumeRender.Pairing", (id)kSecAttrService,
                pairingID, (id)kSecAttrAccount, nil];
            SecItemDelete((CFDictionaryRef)oldKey);
            [self redrawSources];
            @throw [NSException exceptionWithName:NSGenericException reason:@"Secure connection failed. Check the network, then try again; Horos will show a new pairing QR code." userInfo:nil];
        }
        const char magic[8] = {'H','V','R','V','O','L','0','3'};
        uint32_t count = htonl((uint32_t)fileNames.count);
        if (!HVRWrite(connection, magic, sizeof(magic), NO) || !HVRWrite(connection, &count, sizeof(count), NO))
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
            if (!HVRWrite(connection, &nameLength, 4, NO) || !HVRWrite(connection, nameData.bytes, nameData.length, NO) ||
                !HVRWrite(connection, &networkLength, 8, NO))
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
                        if (!bytes.length || !HVRWrite(connection, bytes.bytes, bytes.length, NO))
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
            if (!HVRRead(connection, &acknowledgement, 1) || acknowledgement != 1)
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
        if (connection) { nw_connection_cancel(connection); nw_release(connection); }
        if (packageDirectory) [[NSFileManager defaultManager] removeItemAtURL:packageDirectory error:nil];
        [exporter release];
        [activity stop];
        [activity release];
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
