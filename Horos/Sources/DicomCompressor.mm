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

#import "DicomCompressor.h"
#import "DicomDatabase+DCMTK.h"
#import "NSFileManager+N2.h"

@implementation DicomCompressor

+(void)executeDecompressOnFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptionsPath:(NSString*)optionsPlistPath action:(Compression)action {
	if (!dirPath) dirPath = @"sameAsDestination";
    (void)optionsPlistPath;

	switch (action) {
		case CompressionDecompress:
            [DicomDatabase decompressDicomFilesAtPaths:filePaths intoDirAtPath:dirPath];
            return;
		case CompressionCompress:
            [DicomDatabase compressDicomFilesAtPaths:filePaths intoDirAtPath:dirPath];
            return;
		default: [NSException raise:NSGenericException format:@"Invalid action for [DicomCompressorDecompressor executeDecompressOnFiles:toDirectory:withOptionsPath:action:]"];
	}
}

+(void)decompressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath {
	[self decompressFiles:filePaths toDirectory:dirPath withOptions:NULL];
}

+(void)decompressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptions:(NSDictionary*)options {
	NSString* optionsPlistPath = [[NSFileManager defaultManager] tmpFilePathInTmp];
	[options writeToFile:optionsPlistPath atomically:YES];
	[self decompressFiles:filePaths toDirectory:dirPath withOptionsPath:optionsPlistPath];
	[[NSFileManager defaultManager] removeItemAtPath:optionsPlistPath error:NULL];
}

+(void)decompressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptionsPath:(NSString*)optionsPlistPath {
	[self executeDecompressOnFiles:filePaths toDirectory:dirPath withOptionsPath:optionsPlistPath action:CompressionDecompress];
}

+(void)compressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath {
	[self compressFiles:filePaths toDirectory:dirPath withOptions:NULL];
}

+(void)compressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptions:(NSDictionary*)options {
	NSString* optionsPlistPath = [[NSFileManager defaultManager] tmpFilePathInTmp];
	[options writeToFile:optionsPlistPath atomically:YES];
	[self compressFiles:filePaths toDirectory:dirPath withOptionsPath:optionsPlistPath];
	[[NSFileManager defaultManager] removeItemAtPath:optionsPlistPath error:NULL];
}

+(void)compressFiles:(NSArray*)filePaths toDirectory:(NSString*)dirPath withOptionsPath:(NSString*)optionsPlistPath {
	return [self executeDecompressOnFiles:filePaths toDirectory:dirPath withOptionsPath:optionsPlistPath action:CompressionCompress];
}


@end
