/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/

#import "XMLControllerDCMTKCategory.h"
#import "BrowserController.h"
#undef verify

#import "DicomFile.h"
#import "DICOMToNSString.h"
#import "DicomFileDCMTKCategory.h"
#import "DCMAttributeTag.h"
#import "DCMTagDictionary.h"
#import "DCMTagForNameDictionary.h"
#import "ModernDCMTKBridge.h"

#include <dlfcn.h>

typedef int (*HorosModernDCMTKReplaceTagValueFn)(const char* path, unsigned short group, unsigned short element, const char* value, int removeIfEmpty);

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
                    handle = dlopen(candidate.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
                    if (handle == nullptr)
                        NSLog(@"Modern DCMTK bridge failed to load at %@: %s", candidate, dlerror());
                    return;
                }
            }
        }

        NSLog(@"Modern DCMTK bridge not found in bundle search paths.");
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

static BOOL HorosParseTagString(NSString *tagString, int *group, int *element)
{
    if (tagString.length == 0 || group == NULL || element == NULL)
        return NO;

    NSString *normalized = [[tagString stringByReplacingOccurrencesOfString:@"(" withString:@""]
                            stringByReplacingOccurrencesOfString:@")" withString:@""];
    NSArray *parts = [normalized componentsSeparatedByString:@","];
    if (parts.count != 2)
        return NO;

    unsigned int uGroup = 0;
    unsigned int uElement = 0;
    NSScanner *scanner = [NSScanner scannerWithString:parts[0]];
    if (![scanner scanHexInt:&uGroup])
        return NO;
    scanner = [NSScanner scannerWithString:parts[1]];
    if (![scanner scanHexInt:&uElement])
        return NO;

    *group = (int)uGroup;
    *element = (int)uElement;
    return YES;
}

@implementation XMLController (XMLControllerDCMTKCategory)


+ (BOOL) modifyDicom:(NSArray*) tagAndValues dicomFiles:(NSArray*) dicomFiles
{
    HorosModernDCMTKReplaceTagValueFn replaceTagValueFn =
        HorosModernDCMTKSymbol<HorosModernDCMTKReplaceTagValueFn>("HorosModernDCMTKReplaceTagValue");
    if (replaceTagValueFn == nullptr)
        return NO;

    BOOL modifySuccess = YES;

    NSStringEncoding encoding = [NSString defaultCStringEncoding];
    NSString *referenceFile = [dicomFiles lastObject];
    if (referenceFile != nil)
    {
        NSArray *encodings = [DicomFile getEncodingArrayForFile:referenceFile];
        if (encodings.count > 0)
            encoding = [NSString encodingForDICOMCharacterSet:[encodings objectAtIndex:0]];
    }

    for (NSString* f in dicomFiles)
    {
        const char* filename = [f cStringUsingEncoding:[NSString defaultCStringEncoding]];

        if (filename == NULL)
        {
            modifySuccess = NO;
            continue;
        }

        for (NSArray* replacingItem in tagAndValues)
        {
            DCMAttributeTag* tag = ([replacingItem count] > 0 ? [replacingItem objectAtIndex:0] : nil);
            NSString *replacementValue = ([replacingItem count] >= 2 ? [replacingItem objectAtIndex:1] : nil);
            if (tag == nil)
            {
                modifySuccess = NO;
                continue;
            }

            const char *encodedValue = NULL;
            if (replacementValue != nil)
                encodedValue = [replacementValue cStringUsingEncoding:encoding];

            const int removeIfEmpty = (replacementValue == nil || replacementValue.length == 0) ? 1 : 0;
            if (!removeIfEmpty && encodedValue == NULL)
            {
                modifySuccess = NO;
                continue;
            }

            if (!replaceTagValueFn(filename, (unsigned short)tag.group, (unsigned short)tag.element, encodedValue, removeIfEmpty))
                modifySuccess = NO;
        }
    }

    return modifySuccess;
}


-(int) getGroupAndElementForName:(NSString*) name group:(int*) gp element:(int*) el
{
    if (gp == NULL || el == NULL || name.length == 0)
        return -1;

    NSString *tagString = [(NSDictionary *)[DCMTagForNameDictionary sharedTagForNameDictionary] objectForKey:name];
    if (tagString == nil)
        return -1;

    if (!HorosParseTagString(tagString, gp, el))
        return -1;

    return 0;
}

- (void) prepareDictionaryArray
{
    NSDictionary *tagDictionary = [DCMTagDictionary sharedTagDictionary];
    NSArray<NSString *> *allKeys = [tagDictionary allKeys];
    NSArray<NSString *> *sortedKeys = [allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
        int lhsGroup = 0, lhsElement = 0;
        int rhsGroup = 0, rhsElement = 0;
        if (!HorosParseTagString(lhs, &lhsGroup, &lhsElement) ||
            !HorosParseTagString(rhs, &rhsGroup, &rhsElement))
            return [lhs compare:rhs];
        if (lhsGroup == rhsGroup)
            return lhsElement < rhsElement ? NSOrderedAscending : (lhsElement > rhsElement ? NSOrderedDescending : NSOrderedSame);
        return lhsGroup < rhsGroup ? NSOrderedAscending : NSOrderedDescending;
    }];

    for (NSString *tagString in sortedKeys)
    {
        int group = 0;
        int element = 0;
        if (!HorosParseTagString(tagString, &group, &element))
            continue;
        if (group <= 0 || (group % 2) == 1)
            continue; // exclude private tags

        NSDictionary *entry = [tagDictionary objectForKey:tagString];
        NSString *description = [entry objectForKey:@"Description"];
        if (description.length == 0)
            description = @"Unknown";

        NSString *s = [NSString stringWithFormat:@"(0x%04x,0x%04x) %@", group, element, description];
        [dictionaryArray addObject:s];
    }
}
@end
