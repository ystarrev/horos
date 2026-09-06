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

#import "DicomDatabase+DCMTK.h"
#import "DCMAbstractSyntaxUID.h"
#import "DCMPix.h"
#import "AppController.h"
#import "BrowserController.h"
#import "SRAnnotation.h"
#import "NSThread+N2.h"
#import "N2Debug.h"
#import "WaitRendering.h"

#include <dlfcn.h>

#define CHUNK_SUBPROCESS 200
#define TIMEOUT 20UL

// Maximum of 200 files: no more than 10 min...

typedef int (*HorosModernDCMTKGetDecompressionInfoFn)(const char* path, int* isEncapsulated, unsigned short* rows, unsigned short* columns, char** modality, char** sopClassUID);
typedef char* (*HorosModernDCMTKCopyFieldByTagFn)(const char* path, unsigned short group, unsigned short element);
typedef int (*HorosModernDCMTKWriteFileInTransferSyntaxFn)(const char* inputPath, const char* outputPath, const char* transferSyntaxUID, int quality);
typedef void (*HorosModernDCMTKFreeStringFn)(char* value);

static void* HorosModernDCMTKBridgeHandle()
{
    static void* handle = nullptr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bridgePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"libHorosModernDCMTKBridge.dylib"];
        handle = dlopen(bridgePath.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
        if (handle == nullptr)
            NSLog(@"Modern DCMTK bridge unavailable at %@: %s", bridgePath, dlerror());
    });
    return handle;
}

template <typename FunctionType>
static FunctionType HorosModernDCMTKSymbol(const char* name)
{
    void* handle = HorosModernDCMTKBridgeHandle();
    if (handle == nullptr)
        return nullptr;
    return reinterpret_cast<FunctionType>(dlsym(handle, name));
}

static NSString* HorosModernDCMTKCopiedString(char* value)
{
    if (value == nullptr)
        return nil;

    HorosModernDCMTKFreeStringFn freeStringFn = HorosModernDCMTKSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
    NSString *string = [NSString stringWithCString:value encoding:NSASCIIStringEncoding];
    if (freeStringFn)
        freeStringFn(value);
    return string;
}

static NSString* HorosModernDCMTKCopyTagString(NSString *sourcePath, unsigned short group, unsigned short element)
{
    HorosModernDCMTKCopyFieldByTagFn copyFn = HorosModernDCMTKSymbol<HorosModernDCMTKCopyFieldByTagFn>("HorosModernDCMTKCopyFieldByTag");
    if (copyFn == nullptr)
        return nil;

    return HorosModernDCMTKCopiedString(copyFn(sourcePath.fileSystemRepresentation, group, element));
}

static BOOL HorosModernDCMTKWriteTransferSyntax(NSString *sourcePath, NSString *destinationPath, NSString *transferSyntaxUID, int quality)
{
    HorosModernDCMTKWriteFileInTransferSyntaxFn writeFn = HorosModernDCMTKSymbol<HorosModernDCMTKWriteFileInTransferSyntaxFn>("HorosModernDCMTKWriteFileInTransferSyntax");
    if (writeFn == nullptr)
        return NO;

    return writeFn(sourcePath.fileSystemRepresentation,
                   destinationPath.fileSystemRepresentation,
                   transferSyntaxUID.UTF8String,
                   quality) ? YES : NO;
}

static BOOL HorosModernDCMTKMoveFile(NSString *sourcePath, NSString *destinationPath)
{
    if ([sourcePath isEqualToString:destinationPath])
        return YES;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtPath:destinationPath error:nil];

    NSError *moveError = nil;
    if ([fileManager moveItemAtPath:sourcePath toPath:destinationPath error:&moveError])
        return YES;

    NSLog(@"failed to move file %@ to %@: %@", sourcePath, destinationPath, moveError);
    return NO;
}

static NSString* HorosModernDCMTKCompressionTransferSyntax(int compression, int quality)
{
    if (compression == compression_JPEG)
        return @"1.2.840.10008.1.2.4.70";

    if (compression == compression_JPEG2000)
        return (quality == 0) ? @"1.2.840.10008.1.2.4.90" : @"1.2.840.10008.1.2.4.91";

    if (compression == compression_JPEGLS)
        return (quality == 0) ? @"1.2.840.10008.1.2.4.80" : @"1.2.840.10008.1.2.4.81";

    return nil;
}

static BOOL HorosModernDCMTKTransferSyntaxAlreadyMatchesCompression(NSString *transferSyntaxUID, int compression)
{
    if (transferSyntaxUID.length == 0)
        return NO;

    if (compression == compression_JPEG)
        return [transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.70"];

    if (compression == compression_JPEG2000)
        return [transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.90"] || [transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.91"];

    if (compression == compression_JPEGLS)
        return [transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.80"] || [transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.81"];

    return NO;
}

static BOOL HorosModernDCMTKProcessCompressedFile(NSString *sourcePath, NSString *destinationDirectory)
{
    if (sourcePath.length == 0)
        return NO;

    BOOL replaceSource = (destinationDirectory == nil || [destinationDirectory isEqualToString:@"sameAsDestination"]);
    NSString *finalPath = replaceSource ? sourcePath : [destinationDirectory stringByAppendingPathComponent:sourcePath.lastPathComponent];

    int isEncapsulated = 0;
    unsigned short rows = 0;
    unsigned short columns = 0;
    char *modalityCString = nullptr;
    char *sopClassUIDCString = nullptr;
    HorosModernDCMTKGetDecompressionInfoFn infoFn = HorosModernDCMTKSymbol<HorosModernDCMTKGetDecompressionInfoFn>("HorosModernDCMTKGetDecompressionInfo");
    if (infoFn == nullptr || infoFn(sourcePath.fileSystemRepresentation, &isEncapsulated, &rows, &columns, &modalityCString, &sopClassUIDCString) == 0)
        return NO;

    NSString *modality = HorosModernDCMTKCopiedString(modalityCString) ?: @"OT";
    NSString *SOPClassUID = HorosModernDCMTKCopiedString(sopClassUIDCString) ?: @"";
    if ([DCMAbstractSyntaxUID isImageStorage:SOPClassUID] == NO ||
        [SOPClassUID isEqualToString:[DCMAbstractSyntaxUID pdfStorageClassUID]] ||
        [SOPClassUID isEqualToString:[DCMAbstractSyntaxUID EncapsulatedCDAStorage]] ||
        [DCMAbstractSyntaxUID isStructuredReport:SOPClassUID])
    {
        return replaceSource ? YES : HorosModernDCMTKMoveFile(sourcePath, finalPath);
    }

    int resolution = 0;
    if (resolution == 0 || resolution > rows)
        resolution = rows;
    if (resolution == 0 || resolution > columns)
        resolution = columns;

    int quality = 0;
    int compression = [BrowserController compressionForModality:modality quality:&quality resolution:resolution];
    NSString *targetSyntax = HorosModernDCMTKCompressionTransferSyntax(compression, quality);
    if (targetSyntax == nil)
        return replaceSource ? YES : HorosModernDCMTKMoveFile(sourcePath, finalPath);

    NSString *currentSyntax = HorosModernDCMTKCopyTagString(sourcePath, 0x0002, 0x0010);
    if (isEncapsulated)
        return replaceSource ? YES : HorosModernDCMTKMoveFile(sourcePath, finalPath);

    if (HorosModernDCMTKTransferSyntaxAlreadyMatchesCompression(currentSyntax, compression))
        return replaceSource ? YES : HorosModernDCMTKMoveFile(sourcePath, finalPath);

    NSString *temporaryPath = [finalPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.tmp", finalPath.lastPathComponent, [[NSProcessInfo processInfo] globallyUniqueString]]];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtPath:temporaryPath error:nil];

    if (HorosModernDCMTKWriteTransferSyntax(sourcePath, temporaryPath, targetSyntax, quality) == NO)
    {
        [fileManager removeItemAtPath:temporaryPath error:nil];
        NSLog(@"failed to compress file: %@", sourcePath);
        return NO;
    }

    if (HorosModernDCMTKMoveFile(temporaryPath, finalPath) == NO)
        return NO;

    if (replaceSource == NO)
        [fileManager removeItemAtPath:sourcePath error:nil];

    return YES;
}

static BOOL HorosModernDCMTKDecompressFile(NSString *sourcePath, NSString *destinationDirectory)
{
    if (sourcePath.length == 0)
        return NO;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL replaceSource = (destinationDirectory == nil || [destinationDirectory isEqualToString:@"sameAsDestination"]);
    NSString *finalPath = replaceSource ? sourcePath : [destinationDirectory stringByAppendingPathComponent:sourcePath.lastPathComponent];
    NSString *temporaryPath = [finalPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.tmp", finalPath.lastPathComponent, [[NSProcessInfo processInfo] globallyUniqueString]]];

    [fileManager removeItemAtPath:temporaryPath error:nil];
    if (HorosModernDCMTKWriteTransferSyntax(sourcePath, temporaryPath, @"1.2.840.10008.1.2.1", 100) == NO)
    {
        [fileManager removeItemAtPath:temporaryPath error:nil];
        NSLog(@"failed to decompress file: %@", sourcePath);
        return NO;
    }

    [fileManager removeItemAtPath:finalPath error:nil];
    NSError *moveError = nil;
    if ([fileManager moveItemAtPath:temporaryPath toPath:finalPath error:&moveError] == NO)
    {
        [fileManager removeItemAtPath:temporaryPath error:nil];
        NSLog(@"failed to move decompressed file %@ to %@: %@", temporaryPath, finalPath, moveError);
        return NO;
    }

    if (replaceSource == NO)
        [fileManager removeItemAtPath:sourcePath error:nil];

    return YES;
}

@implementation DicomDatabase (DCMTK)

+(BOOL)fileNeedsDecompression:(NSString*)path {
    HorosModernDCMTKGetDecompressionInfoFn bridgeFn = HorosModernDCMTKSymbol<HorosModernDCMTKGetDecompressionInfoFn>("HorosModernDCMTKGetDecompressionInfo");
    if (bridgeFn)
    {
        int isEncapsulated = 0;
        unsigned short rows = 0;
        unsigned short columns = 0;
        char *modalityCString = nullptr;
        char *sopClassUIDCString = nullptr;

        if (bridgeFn(path.UTF8String, &isEncapsulated, &rows, &columns, &modalityCString, &sopClassUIDCString))
        {
            if (isEncapsulated)
                return NO;

            NSString *modality = HorosModernDCMTKCopiedString(modalityCString) ?: @"OT";
            NSString *SOPClassUID = HorosModernDCMTKCopiedString(sopClassUIDCString) ?: @"";

            if( [DCMAbstractSyntaxUID isImageStorage: SOPClassUID] == YES &&
               [SOPClassUID isEqualToString:[DCMAbstractSyntaxUID pdfStorageClassUID]] == NO &&
               [SOPClassUID isEqualToString:[DCMAbstractSyntaxUID EncapsulatedCDAStorage]] == NO &&
               [DCMAbstractSyntaxUID isStructuredReport: SOPClassUID] == NO)
            {
                int resolution = 0;
                if( resolution == 0 || resolution > rows)
                    resolution = rows;
                if( resolution == 0 || resolution > columns)
                    resolution = columns;

                int quality, compression = [BrowserController compressionForModality: modality quality: &quality resolution: resolution];
                return compression != compression_none;
            }

            return NO;
        }
    }
    return NO;
}


+(BOOL)compressDicomFilesAtPaths:(NSArray*)paths {
    return [self compressDicomFilesAtPaths:paths intoDirAtPath:nil];
}

+(BOOL)decompressDicomFilesAtPaths:(NSArray*)paths {
    return [self decompressDicomFilesAtPaths:paths intoDirAtPath:nil];
}

+(BOOL)compressDicomFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)dest
{
    if (dest == nil)
        dest = @"sameAsDestination";
    
    int total = [paths count];
    NSThread* thread = [NSThread currentThread];
    [thread enterOperation];
    
    for( int i = 0; i < total;)
    {
        int no;
        if( i + CHUNK_SUBPROCESS >= total) no = total - i;
        else no = CHUNK_SUBPROCESS;
        
        if (i || i+no<total)
            thread.progress = 1.0*i/total;
        
        NSRange range = NSMakeRange( i, no);
        for (NSUInteger fileIndex = range.location; fileIndex < NSMaxRange(range); fileIndex++)
        {
            @try
            {
                HorosModernDCMTKProcessCompressedFile([paths objectAtIndex:fileIndex], dest);
            }
            @catch (NSException *e)
            {
                N2LogExceptionWithStackTrace(e);
            }
        }
        
        i += no;
    }
    
    [thread exitOperation];
    return YES;
    
}

+(BOOL)decompressDicomFilesAtPaths:(NSArray*)files intoDirAtPath:(NSString*)dest
{
    if (dest == nil)
        dest = @"sameAsDestination";
    
    int total = [files count];
    NSThread* thread = [NSThread currentThread];
    [thread enterOperation];
    
    for( int i = 0; i < total;)
    {
        int no;
        if( i + CHUNK_SUBPROCESS >= total) no = total - i;
        else no = CHUNK_SUBPROCESS;
        
        if (i || i+no<total)
            thread.progress = 1.0*i/total;
        
        NSRange range = NSMakeRange( i, no);
        
        for (NSUInteger fileIndex = range.location; fileIndex < NSMaxRange(range); fileIndex++)
        {
            @try
            {
                HorosModernDCMTKDecompressFile([files objectAtIndex:fileIndex], dest);
            }
            @catch (NSException *e)
            {
                N2LogExceptionWithStackTrace(e);
            }
        }
        
        i += no;
    }
    
    [thread exitOperation];
    return YES;
    
}

+(NSString*)extractReportSR:(NSString*)dicomSR contentDate:(NSDate*)date {
    NSString* destPath = nil;
    NSString* uidName = [SRAnnotation getReportFilenameFromSR: dicomSR];
    if( [uidName length] > 0)
    {
        NSString *zipFile = [@"/tmp/" stringByAppendingPathComponent: uidName];
        
        // Extract the CONTENT to the REPORTS folder
        SRAnnotation *r = [[[SRAnnotation alloc] initWithContentsOfFile: dicomSR] autorelease];
        [[NSFileManager defaultManager] removeItemAtPath: zipFile error:NULL];
        
        // Check for http/https !
        if( [[r reportURL] length] > 8 && ([[r reportURL] hasPrefix: @"http://"] || [[r reportURL] hasPrefix: @"https://"]))
            destPath = [[[r reportURL] copy] autorelease];
        else
        {
            if( [[r dataEncapsulated] length] > 0)
            {
                [[r dataEncapsulated] writeToFile: zipFile atomically: YES];
                
                [[NSFileManager defaultManager] removeItemAtPath: @"/tmp/zippedFile/" error:NULL];
                [BrowserController unzipFile: zipFile withPassword: nil destination: @"/tmp/zippedFile/" showGUI: NO];
                [[NSFileManager defaultManager] removeItemAtPath: zipFile error:NULL];
                
                for( NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath: @"/tmp/zippedFile/" error: nil])
                {
                    if( [f hasPrefix: @"."] == NO)
                    {
                        if( destPath)
                            NSLog( @"*** multiple files in Report decompression ?");
                        
                        destPath = [@"/tmp/" stringByAppendingPathComponent: f];
                        if( destPath)
                        {
                            [[NSFileManager defaultManager] removeItemAtPath: destPath error: nil];
                            [[NSFileManager defaultManager] moveItemAtPath: [@"/tmp/zippedFile/" stringByAppendingPathComponent: f] toPath: destPath error: nil];
                        }
                    }
                }
            }
        }
    }
    
    [[NSFileManager defaultManager] removeItemAtPath: @"/tmp/zippedFile/" error:NULL];
    
    if( destPath)
        [[NSFileManager defaultManager] setAttributes: [NSDictionary dictionaryWithObjectsAndKeys: date, NSFileModificationDate, nil] ofItemAtPath: destPath error: nil];
    
    return destPath;
}

+(BOOL)testFiles:(NSArray*)files {

    NSString *validatorPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"DICOMValidator"];
    if( [[NSFileManager defaultManager] fileExistsAtPath: validatorPath] == NO)
        return YES;
    
    WaitRendering *splash = nil;
    NSMutableArray *tasksArray = [NSMutableArray array];
    int CHUNK_SIZE;
    
    if ([NSThread isMainThread]) {
        splash = [[WaitRendering alloc] init: NSLocalizedString( @"Validating files...", nil)];
        [splash showWindow:self];
        [splash setCancel: YES];
        [splash start];
    }
    
    BOOL succeed = YES;
    
    int total = [files count];
    
    CHUNK_SIZE = total / [[NSProcessInfo processInfo] processorCount];
    if( CHUNK_SIZE > 500)
        CHUNK_SIZE = 500;
    else
        CHUNK_SIZE += 20;
    
    @try
    {
        for( int i = 0; i < total;)
        {
            int no;
            
            if( i + CHUNK_SIZE >= total) no = total - i; 
            else no = CHUNK_SIZE;
            
            NSRange range = NSMakeRange( i, no);
            
            id *objs = (id*) malloc( no * sizeof( id));
            if( objs)
            {
                [files getObjects: objs range: range];
                
                NSArray *subArray = [NSArray arrayWithObjects: objs count: no];
                
                NSTask *theTask = [[[NSTask alloc] init] autorelease];
                
                [tasksArray addObject: theTask];
                
                NSArray *parameters = [[NSArray arrayWithObject: @"--files"] arrayByAddingObjectsFromArray: subArray];
                
                [theTask setArguments: parameters];
                [theTask setExecutableURL:[NSURL fileURLWithPath:validatorPath]];
                HorosLaunchTaskOrRaise(theTask);
                
                free( objs);
            }
            
            i += no;
        }
    }
    @catch ( NSException *e)
    {
        NSLog( @"***** testList exception : %@", e);
        succeed = NO;
    }
    
    @try
    {
        for( NSTask *t in tasksArray)
        {
            while( [t isRunning] && [splash aborted] == NO)
            {
                [NSThread sleepForTimeInterval: 0.05];
                [splash run];
            }
            
            if( [splash aborted])
                break;
            
            if( [t terminationStatus] != 0)
                succeed = NO;
        }
        
        if( [splash aborted])
        {
            for( NSTask *t in tasksArray)
                [t interrupt];
        }
    }
    @catch (NSException * e)
    {
        NSLog( @"***** testList exception 2 : %@", e);
    }
    [splash end];
    [splash close];
    [splash autorelease];
    
    if( succeed == NO)
        NSLog( @"******* test Files FAILED : one of more of these files are corrupted : %@", files);
    
    return succeed;
    
}


@end
