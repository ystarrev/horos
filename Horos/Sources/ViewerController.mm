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

#import "ViewerController.h"
#import "AppController.h"
#import "DicomDatabase.h"
#import "DicomStudy.h"
#import "DicomSeries.h"
#import "DicomImage.h"
#import "NSThread+N2.h"
#include <dlfcn.h>

typedef int (*HorosModernDCMTKReplaceTagValueFn)(const char* path, unsigned short group, unsigned short element, const char* value, int removeIfEmpty);

static void* HorosViewerControllerBridgeHandle()
{
    static void* handle = NULL;
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
                    if (handle == NULL)
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
static FunctionType HorosViewerControllerBridgeSymbol(const char* name)
{
    void* handle = HorosViewerControllerBridgeHandle();
    if (handle == NULL)
        return NULL;
    return reinterpret_cast<FunctionType>(dlsym(handle, name));
}

static void HorosViewerControllerReplaceTagValue(NSString* path, unsigned short group, unsigned short element, NSString* value)
{
    if (path.length == 0)
        return;

    HorosModernDCMTKReplaceTagValueFn replaceTagValueFn =
        HorosViewerControllerBridgeSymbol<HorosModernDCMTKReplaceTagValueFn>("HorosModernDCMTKReplaceTagValue");
    if (replaceTagValueFn == NULL)
        return;

    replaceTagValueFn(path.fileSystemRepresentation, group, element, value.UTF8String, 0);
}

@implementation ViewerController (MM)

- (IBAction)captureAndSetKeyImage:(id)sender
{
    [[AppController sharedAppController] playGrabSound];
    
    DicomStudy* study = [self currentStudy];
    
    // export the reconstruction as a new DICOM file
    NSDictionary* result = [self exportDICOMFileInt:1 withName:O2ScreenCapturesSeriesName allViewers:NO];
    NSString* path = [result objectForKey:@"file"];
    
    // if a "OsiriX KOS Plugin Reconstructions" series already existed, put it in that series
    DicomSeries* series = nil;
    for (DicomSeries* iseries in study.series)
        if ([iseries.name isEqualToString:O2ScreenCapturesSeriesName])
            series = iseries;
    if (series) {
        // Clone series identifiers into the capture via the modern bridge instead of app-side DCMTK dataset editing.
        HorosViewerControllerReplaceTagValue(path, 0x0020, 0x000E, series.seriesDICOMUID);
        HorosViewerControllerReplaceTagValue(path, 0x0020, 0x0011, series.id.stringValue);
        
        // find highest instanceNumber in the series
        NSInteger instanceNumber = 0;
        for (DicomImage* image in series.images)
            if (image.instanceNumber.integerValue > instanceNumber)
                instanceNumber = image.instanceNumber.integerValue;
        ++instanceNumber;
        
        NSNumber* instanceNumberString = [NSNumber numberWithInteger:instanceNumber];
        HorosViewerControllerReplaceTagValue(path, 0x0020, 0x0013, instanceNumberString.stringValue);
        HorosViewerControllerReplaceTagValue(path, 0x0020, 0x0012, instanceNumberString.stringValue);
    }
    
    // import the file into our DB
    DicomDatabase* database = [DicomDatabase databaseForContext:study.managedObjectContext];
    NSArray* imageIDs = [database addFilesAtPaths:[NSArray arrayWithObject:path]
                                postNotifications:YES
                                        dicomOnly:YES
                              rereadExistingItems:YES
                                generatedByOsiriX:YES];
    
    // upload the new file to the DICOM node
    /*if (NO)
        [NSThread performBlockInBackground: ^{
            NSString* myAET = [NSUserDefaults.standardUserDefaults stringForKey:@"AETITLE"];
            NSString* tAET = [NSUserDefaults.standardUserDefaults stringForKey:KOSAETKey];
            NSString* tHost = [NSUserDefaults.standardUserDefaults stringForKey:KOSNodeHostKey];
            NSInteger tPort = [NSUserDefaults.standardUserDefaults integerForKey:KOSNodePortKey];
            
            NSThread* thread = [NSThread currentThread];
            thread.name = [NSString stringWithFormat:NSLocalizedString(@"KeyObjects for %@", nil), study.name];
            thread.status = [NSString stringWithFormat:NSLocalizedString(@"Saving reconstruction to %@...", nil), tAET];
            [ThreadsManager.defaultManager addThreadAndStart:thread];
            
            DCMTKStoreSCU* storescu = [[[DCMTKStoreSCU alloc] initWithCallingAET:myAET
                                                                       calledAET:tAET
                                                                        hostname:tHost
                                                                            port:tPort
                                                                     filesToSend:[NSArray arrayWithObject:path]
                                                                  transferSyntax:0
                                                                     compression:1.0
                                                                 extraParameters:nil] autorelease];
            [storescu run: nil];
        }];*/
    
    // set the new images as key images
    for (DicomImage* imageID in imageIDs)
        [[database objectWithID:imageID] setIsKeyImage:[NSNumber numberWithBool:YES]];
}

@end
