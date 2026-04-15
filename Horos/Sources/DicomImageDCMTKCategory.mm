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

#import "DicomImageDCMTKCategory.h"
#import "ModernDCMTKBridge.h"

#undef verify

#include <dlfcn.h>

typedef char* (*HorosModernDCMTKCopyStructuredReportKeyObjectTypeFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn)(const char* path);
typedef void (*HorosModernDCMTKFreeStringFn)(char* value);

static void* HorosModernDCMTKBridgeHandle()
{
    static void* handle = nullptr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        NSArray<NSString *> *basePaths = @[
            bundle.resourcePath ?: @"",
            bundle.privateFrameworksPath ?: @"",
            bundle.sharedFrameworksPath ?: @"",
            bundle.builtInPlugInsPath ?: @""
        ];
        NSArray<NSString *> *relativePaths = @[
            @"libHorosModernDCMTKBridge.dylib",
            @"DCMTK/libHorosModernDCMTKBridge.dylib"
        ];
        NSString *resolvedPath = nil;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSString *basePath in basePaths)
        {
            if (basePath.length == 0)
                continue;
            for (NSString *relativePath in relativePaths)
            {
                NSString *candidate = [basePath stringByAppendingPathComponent:relativePath];
                if ([fileManager fileExistsAtPath:candidate])
                {
                    resolvedPath = candidate;
                    break;
                }
            }
            if (resolvedPath)
                break;
        }

        if (resolvedPath)
            handle = dlopen(resolvedPath.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
        if (handle == nullptr)
            NSLog(@"Modern DCMTK bridge unavailable: %s", dlerror());
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
    NSString *string = [NSString stringWithUTF8String:value];
    if (freeStringFn)
        freeStringFn(value);
    return string;
}

@implementation DicomImage(DicomImageDCMTKCategory)

- (NSString*) keyObjectType
{
    HorosModernDCMTKCopyStructuredReportKeyObjectTypeFn bridgeFn =
        HorosModernDCMTKSymbol<HorosModernDCMTKCopyStructuredReportKeyObjectTypeFn>("HorosModernDCMTKCopyStructuredReportKeyObjectType");
    if (bridgeFn == nullptr)
        return nil;
    NSString *type = HorosModernDCMTKCopiedString(bridgeFn([[self completePath] UTF8String]));
    return type;
}

- (NSArray*) referencedObjects
{
    HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn bridgeFn =
        HorosModernDCMTKSymbol<HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn>("HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDs");
    if (bridgeFn == nullptr)
        return [NSArray array];

    NSString *uids = HorosModernDCMTKCopiedString(bridgeFn([[self completePath] UTF8String]));
    if (uids.length == 0)
        return [NSArray array];

    NSArray *parts = [uids componentsSeparatedByString:@"\\"];
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id  _Nullable evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
        return [evaluatedObject isKindOfClass:[NSString class]] && [evaluatedObject length] > 0;
    }];
    return [parts filteredArrayUsingPredicate:predicate];
}



@end
