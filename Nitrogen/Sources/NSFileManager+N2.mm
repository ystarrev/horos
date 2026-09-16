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


#import "NSFileManager+N2.h"
#import "NSString+N2.h"
#import "NSString+SymlinksAndAliases.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#import <sys/stat.h>
#include <unistd.h>

static NSUInteger N2FileSizeAtURL(NSURL *url)
{
    NSNumber *size = nil;
    if ([url getResourceValue:&size forKey:NSURLTotalFileSizeKey error:NULL] && size)
        return [size unsignedIntegerValue];
    if ([url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL] && size)
        return [size unsignedIntegerValue];
    return 0;
}

@implementation NSFileManager (N2)

- (void)moveItemAtPathToTrash: (NSString*) path
{
    if (path.length == 0)
        return;

    NSError *error = nil;
    if (![self trashItemAtURL:[NSURL fileURLWithPath:path] resultingItemURL:NULL error:&error])
        NSLog(@"Could not move %@ to Trash: %@", path, error.localizedDescription);
}

-(NSString*)userApplicationSupportFolderForApp {
    NSURL *url = [[self URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
	NSString* path = url.path;
	[self confirmDirectoryAtPath:path];
	return path;
}

-(NSString*)tmpFilePathInDir:(NSString*)dirPath {
    if (dirPath.length == 0)
        return nil;

    NSString *templatePath = [dirPath stringByAppendingPathComponent:@"Horos_XXXXXX"];
    const char *fileSystemPath = templatePath.fileSystemRepresentation;
    char *temp = fileSystemPath ? strdup(fileSystemPath) : NULL;
    if (temp == NULL)
        return nil;

    // Reserve the name atomically; callers need the path, not an open descriptor.
    int descriptor = mkstemp(temp);
    if (descriptor == -1) {
        int errorCode = errno;
        free(temp);
        NSLog(@"Could not create temporary file in %@: %@", dirPath,
              [NSError errorWithDomain:NSPOSIXErrorDomain code:errorCode userInfo:nil].localizedDescription);
        return nil;
    }
    close(descriptor);

    NSString *result = [self stringWithFileSystemRepresentation:temp length:strlen(temp)];
    free(temp);
    return result;
}

-(NSString*)tmpDirPath {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString*)kCFBundleNameKey], NSUserName()]];
    [self confirmDirectoryAtPath:path];
    return path;
}

-(NSString*)tmpFilePathInTmp {
	return [self tmpFilePathInDir:[self tmpDirPath]];
}

-(NSString*)confirmDirectoryAtPath:(NSString*)dirPath subDirectory: (BOOL) subDirectory
{
	if( dirPath == nil) return nil;
	NSString* parentDirPath = [dirPath stringByDeletingLastPathComponent];
    
	if (![dirPath isEqualToString:parentDirPath])
		[self confirmDirectoryAtPath:parentDirPath subDirectory: YES];
    
	BOOL isDir, create = NO;
	NSError* error = NULL;
    
    //NSLog(@"==> %@",dirPath);
    
	if (![self fileExistsAtPath:dirPath isDirectory:&isDir])
		create = YES;
	else
    {
        if (!isDir)
        {
            if ([dirPath isEqualToString:@"/tmp"] == NO)
            {
                [self removeItemAtPath:dirPath error:&error];
                
                if (error)
                    [NSException raise:NSGenericException format:@"Couldn't unlink file: %@ - %@", dirPath, [error localizedDescription]];
                
                create = YES;
            }
            else
            {
                NSLog(@"/tmp issue workaround");
            }
        }
    }
	
	if (create) {
		[self createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:NULL error:&error];
		if (error) [NSException raise:NSGenericException format:@"Couldn't create directory: %@", [error localizedDescription]];
	}
    
    if( subDirectory == NO && [self isWritableFileAtPath: dirPath] == NO)
        NSLog( @"-------- confirmDirectoryAtPath %@ is writable == NO", dirPath);
    
	return dirPath;
}

-(NSString*)confirmDirectoryAtPath:(NSString*)dirPath
{
    return [self confirmDirectoryAtPath: dirPath subDirectory: NO];
}

-(NSString*)confirmNoIndexDirectoryAtPath:(NSString*)path {
	if (path.length == 0)
		return nil;

	NSString* pathWithExt;
	NSString* pathWithoutExt;
	NSString* const ext = @".noindex";
	
	if ([path hasSuffix:ext]) {
		pathWithExt = path;
		pathWithoutExt = [path substringToIndex:path.length-ext.length];
	} else {
		pathWithoutExt = path;
		pathWithExt = [path stringByAppendingString:ext];
	}
	
	BOOL pathWithoutExtIsDir = YES, pathWithoutExtExists = [self fileExistsAtPath:pathWithoutExt isDirectory:&pathWithoutExtIsDir];
	BOOL pathWithExtIsDir = YES, pathWithExtExists = [self fileExistsAtPath:pathWithExt isDirectory:&pathWithExtIsDir];
	
	if (pathWithExtExists && !pathWithExtIsDir) {
		[NSException raise:NSGenericException format:@"Cannot create directory at %@: a file already exists", pathWithExt];
	}
	
	if (!pathWithExtExists && pathWithoutExtExists && pathWithoutExtIsDir) {
		NSError *error = nil;
		[self moveItemAtPath:pathWithoutExt toPath:pathWithExt error:&error];
		pathWithExtExists = [self fileExistsAtPath:pathWithExt isDirectory:&pathWithExtIsDir];
		if (!pathWithExtExists || !pathWithExtIsDir)
			[NSException raise:NSGenericException format:@"Could not rename directory at %@ to %@: %@", pathWithoutExt, pathWithExt, error.localizedDescription];
	}
	
	return [self confirmDirectoryAtPath:pathWithExt];
}

	-(NSUInteger)sizeAtPath:(NSString*)path {
	    if (path == nil)
	        return 0;

	    NSURL *url = [NSURL fileURLWithPath:path];
	    NSArray *keys = [NSArray arrayWithObjects:NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLTotalFileSizeKey, nil];
	    NSNumber *isDirectory = nil;
	    if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL] && [isDirectory boolValue] == NO)
	        return N2FileSizeAtURL(url);

	    NSUInteger totalSize = 0;
	    NSDirectoryEnumerator *enumerator = [self enumeratorAtURL:url includingPropertiesForKeys:keys options:0 errorHandler:^BOOL(NSURL *itemURL, NSError *error) {
	        NSLog(@"[NSFileManager sizeAtPath:] error for %@: %@", itemURL.path, error.localizedDescription);
	        return YES;
	    }];

	    for (NSURL *itemURL in enumerator)
	    {
	        NSNumber *itemIsDirectory = nil;
	        if ([itemURL getResourceValue:&itemIsDirectory forKey:NSURLIsDirectoryKey error:NULL] && [itemIsDirectory boolValue])
	            continue;
	        totalSize += N2FileSizeAtURL(itemURL);
	    }

	    return totalSize;
	}

-(BOOL)copyItemAtPath:(NSString*)srcPath toPath:(NSString*)dstPath byReplacingExisting:(BOOL)replace error:(NSError**)err {
	BOOL success = YES;
	NSMutableArray* pairs = [NSMutableArray arrayWithObject:[NSArray arrayWithObjects: srcPath, dstPath, NULL]];
	
	while (pairs.count) {
		NSArray* pair = [pairs objectAtIndex:0];
		[pairs removeObjectAtIndex:0];
		srcPath = [pair objectAtIndex:0];
		dstPath = [pair objectAtIndex:1];
		
		NSString* srcPathRes = [srcPath stringByExpandingTildeInPath];	//[srcPath resolvedPathString];
		NSString* dstPathRes = [dstPath stringByExpandingTildeInPath];	//[dstPath resolvedPathString];
		if (!dstPathRes)
			dstPathRes = [[dstPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:[dstPath lastPathComponent]];
		
		/*BOOL srcPathIsDir, srcPathExists = [self fileExistsAtPath:srcPathRes isDirectory:&srcPathIsDir]*/;
		BOOL dstPathIsDir, dstPathExists = [self fileExistsAtPath:dstPathRes isDirectory:&dstPathIsDir];
		
		if (dstPathExists && replace) {
			[self removeItemAtPath:dstPath error:NULL];
			dstPathRes = dstPath;
			dstPathExists = [self fileExistsAtPath:dstPathRes isDirectory:&dstPathIsDir];
		}
	
		if (!dstPathExists)
			success = [self copyItemAtPath:srcPathRes toPath:dstPathRes error:err] && success;
		else if (dstPathIsDir)
			for (NSString* subPath in [self contentsOfDirectoryAtPath:srcPathRes error:NULL])
				[pairs addObject:[NSArray arrayWithObjects: [srcPath stringByAppendingPathComponent:subPath], [dstPath stringByAppendingPathComponent:subPath], NULL]];
	}

	return success;
}

-(BOOL)applyFileModeOfParentToItemAtPath:(NSString*)path {
    struct stat st;
    if (stat([[path stringByDeletingLastPathComponent] fileSystemRepresentation], &st) == -1)
        return NO;
    
    if (chmod(path.fileSystemRepresentation, st.st_mode&0777) == -1)
        return NO;
        
    return YES;
}

-(NSString*)destinationOfAliasAtPath:(NSString*)inPath {
    return [inPath stringByConditionallyResolvingAlias];
}

-(NSString*)destinationOfAliasOrSymlinkAtPath:(NSString*)path {
	return [self destinationOfAliasOrSymlinkAtPath:path resolved:NULL];
}

-(NSString*)destinationOfAliasOrSymlinkAtPath:(NSString*)path resolved:(BOOL*)r {
	//if (![self fileExistsAtPath:path]) {
		NSString* temp = [path stringByConditionallyResolvingAlias];
		if (temp) {
			if (r) *r = YES;
			return temp;
		}
		
	//	if (r) *r = NO;
	//	return path;
	//}
	
	NSDictionary* attrs = [self attributesOfItemAtPath:path error:NULL];
	if ([[attrs objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
		if (r) *r = YES;
		return [self destinationOfSymbolicLinkAtPath:path error:NULL];
	}
	
	if (r) *r = NO;
	return path;
}

-(NSDirectoryEnumerator*)enumeratorAtPath:(NSString*)path limitTo:(NSInteger)maxNumberOfFiles {
	return [[[N2DirectoryEnumerator alloc] initWithPath:path maxNumberOfFiles:maxNumberOfFiles] autorelease];
}

-(N2DirectoryEnumerator*)enumeratorAtPath:(NSString*)path filesOnly:(BOOL)filesOnly {
	return [self enumeratorAtPath:path filesOnly:filesOnly recursive:YES];
}


-(N2DirectoryEnumerator*)enumeratorAtPath:(NSString*)path filesOnly:(BOOL)filesOnly recursive:(BOOL)recursive {
	N2DirectoryEnumerator* de = [[[N2DirectoryEnumerator alloc] initWithPath:path maxNumberOfFiles:-1] autorelease];
	de.filesOnly = filesOnly;
	de.recursive = recursive;
	return de;
}


@end
