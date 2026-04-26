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

#import "BrowserControllerDCMTKCategory.h"
#import "DicomFileDCMTKCategory.h"
#import "DCMObject.h"
#import "DCM.h"
#import "DCMTransferSyntax.h"
#import "DCMAbstractSyntaxUID.h"
#import "AppController.h"
#import "DCMPix.h"
#import "WaitRendering.h"
#import "DicomDatabase+DCMTK.h"
#import "DicomFile.h"
#import <dlfcn.h>


typedef int (*HorosModernDCMTKCopyFileDataInTransferSyntaxFn)(const char*, const char*, int, unsigned char**, unsigned long*);
typedef void (*HorosModernDCMTKFreeBufferFn)(void*);

template <typename SymbolType>
static SymbolType HorosBrowserControllerDCMTKSymbol(const char* name)
{
    static void* handle = dlopen("libHorosModernDCMTKBridge.dylib", RTLD_LAZY | RTLD_LOCAL);
    return handle != NULL ? reinterpret_cast<SymbolType>(dlsym(handle, name)) : NULL;
}

static NSData* HorosBrowserControllerCopyFileDataInTransferSyntax(NSString* file, NSString* syntax, int quality)
{
    HorosModernDCMTKCopyFileDataInTransferSyntaxFn copyFn = HorosBrowserControllerDCMTKSymbol<HorosModernDCMTKCopyFileDataInTransferSyntaxFn>("HorosModernDCMTKCopyFileDataInTransferSyntax");
    HorosModernDCMTKFreeBufferFn freeBufferFn = HorosBrowserControllerDCMTKSymbol<HorosModernDCMTKFreeBufferFn>("HorosModernDCMTKFreeBuffer");
    if (copyFn == NULL || freeBufferFn == NULL)
        return nil;

    unsigned char* bytes = NULL;
    unsigned long length = 0;
    if (!copyFn(file.fileSystemRepresentation, syntax.UTF8String, quality, &bytes, &length) || bytes == NULL)
        return nil;

    NSData* data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    freeBufferFn(bytes);
    return data;
}

extern NSRecursiveLock *PapyrusLock;

@implementation BrowserController (BrowserControllerDCMTKCategory)

+ (NSString*) compressionString: (NSString*) string
{
	if( [string isEqualToString: @"1.2.840.10008.1.2"])
		return NSLocalizedString( @"Uncompressed", nil);
	if( [string isEqualToString: @"1.2.840.10008.1.2.1"])
		return NSLocalizedString( @"Uncompressed", nil);
	if( [string isEqualToString: @"1.2.840.10008.1.2.2"])
		return NSLocalizedString( @"Uncompressed BigEndian", nil);
	if( [string isEqualToString: @"1.2.840.10008.1.2.4.70"])
		return @"JPEG Lossless, Non-Hierarchical, First-Order Prediction";
	if( [string isEqualToString: @"1.2.840.10008.1.2.4.50"])
		return @"JPEG Baseline (Process 1)";
	if( [string isEqualToString: @"1.2.840.10008.1.2.4.51"])
		return @"JPEG Extended (Process 2 & 4)";
	if( [string isEqualToString: @"1.2.840.10008.1.2.5"])
		return @"RLE Lossless";
	if( [string isEqualToString: @"1.2.840.10008.1.2.4.90"])
		return @"JPEG 2000 Lossless";
	if( [string isEqualToString: @"1.2.840.10008.1.2.4.91"])
		return @"JPEG 2000";
	if( [string isEqualToString: @"1.2.840.10008.1.2.4.80"])
		return @"JPEG-LS Lossless";
	if( [string isEqualToString: @"1.2.840.10008.1.2.4.81"])
		return @"JPEG-LS Near-Lossless";
	return string.length ? string : NSLocalizedString( @"Unknown UID", nil);
}

- (NSData*) getDICOMFile:(NSString*) file inSyntax:(NSString*) syntax quality: (int) quality
{
    if (file == nil || syntax == nil)
        return nil;

    NSString *transferSyntaxUID = [DicomFile getDicomField:@"TransferSyntaxUID" forFile:file];
    if ([transferSyntaxUID isEqualToString:syntax] ||
        ([transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.91"] && [syntax isEqualToString:@"1.2.840.10008.1.2.4.90"]) ||
        ([transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.90"] && [syntax isEqualToString:@"1.2.840.10008.1.2.4.91"]) ||
        ([transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.81"] && [syntax isEqualToString:@"1.2.840.10008.1.2.4.80"]) ||
        ([transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.80"] && [syntax isEqualToString:@"1.2.840.10008.1.2.4.81"]))
        return [NSData dataWithContentsOfFile:file];

    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"useDCMTKForJP2K"])
        return [NSData dataWithContentsOfFile:file];

    NSData *data = HorosBrowserControllerCopyFileDataInTransferSyntax(file, syntax, quality);
    if (data == nil)
        data = [NSData dataWithContentsOfFile:file];

    return data;
}

-(BOOL)needToCompressFile:(NSString*)path { // __deprecated
	return [DicomDatabase fileNeedsDecompression:path];
}


-(BOOL)compressDICOMWithJPEG:(NSArray*)paths { // __deprecated
	return [_database compressFilesAtPaths:paths];
}

-(BOOL)compressDICOMWithJPEG:(NSArray*)paths to:(NSString*)dest { // __deprecated
	return [_database compressFilesAtPaths:paths intoDirAtPath:dest];
}

-(BOOL)decompressDICOMList:(NSArray*)files to:(NSString*)dest { // __deprecated
	return [_database decompressFilesAtPaths:files intoDirAtPath:dest];
}

-(BOOL)testFiles:(NSArray*)files {
	return [DicomDatabase testFiles:files];
}


@end
