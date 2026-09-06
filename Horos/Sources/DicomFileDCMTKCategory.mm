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

#import "DicomFileDCMTKCategory.h"
#import "DCMAbstractSyntaxUID.h"
#import "DICOMToNSString.h"
#import "MutableArrayCategory.h"
#import "DicomStudy.h"
#import "SRAnnotation.h"
#import "N2Debug.h"
#import "ModernDCMTKBridge.h"
#import "HorosDICOMMetadata.h"

#include <dlfcn.h>

#include <string.h>
#include <array>
#include <string>

typedef int (*HorosModernDCMTKIsDICOMFileFn)(const char* path);
typedef char* (*HorosModernDCMTKCopySpecificCharacterSetFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyFieldFn)(const char* path, const char* fieldName);
typedef char* (*HorosModernDCMTKCopyFieldByTagFn)(const char* path, unsigned short group, unsigned short element);
typedef int (*HorosModernDCMTKGetBasicMetadataFn)(const char* path, HorosModernDCMTKBasicMetadata* metadata);
typedef int (*HorosModernDCMTKCopyImageGeometryFn)(const char* path, double* origin3, double* orientation9);
typedef int (*HorosModernDCMTKCopyFrameGeometryFn)(const char* path, double** sliceLocations, int* sliceCount, double** triggerDelays, int* triggerCount);
typedef int (*HorosModernDCMTKCopyEncapsulatedDocumentFn)(const char* path, unsigned char** buffer, unsigned long* length);
typedef void (*HorosModernDCMTKFreeBasicMetadataFn)(HorosModernDCMTKBasicMetadata* metadata);
typedef void (*HorosModernDCMTKFreeStringFn)(char* value);
typedef void (*HorosModernDCMTKFreeBufferFn)(void* buffer);

static NSDateFormatter *HorosDICOMDateFormatter(NSString *format)
{
    NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
    formatter.calendar = [[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian] autorelease];
    formatter.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    formatter.timeZone = [NSTimeZone defaultTimeZone];
    formatter.dateFormat = format;
    formatter.lenient = NO;
    return formatter;
}

static NSDate *HorosDateFromDICOMString(NSString *value, NSString *format, NSUInteger expectedLength)
{
    if (value.length < expectedLength)
        return nil;
    return [HorosDICOMDateFormatter(format) dateFromString:[value substringToIndex:expectedLength]];
}

static NSDate *HorosDICOMFallbackDate(void)
{
    NSDateComponents *components = [[[NSDateComponents alloc] init] autorelease];
    components.year = 1901;
    components.month = 1;
    components.day = 1;
    components.timeZone = [NSTimeZone defaultTimeZone];
    return [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian] dateFromComponents:components];
}

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
        {
            handle = dlopen(resolvedPath.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
            if (handle == nullptr)
                NSLog(@"Modern DCMTK bridge failed to load at %@: %s", resolvedPath, dlerror());
        }
        else
        {
            NSLog(@"Modern DCMTK bridge not found in bundle search paths.");
        }
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
    NSString *string = [NSString stringWithCString:value encoding:NSISOLatin1StringEncoding];
    if (freeStringFn)
        freeStringFn(value);
    return string;
}

static NSString* HorosModernDCMTKBridgeString(const char* value, NSStringEncoding encoding)
{
    if (value == nullptr)
        return nil;
    return [NSString stringWithCString:value encoding:encoding];
}

static NSString* HorosModernDCMTKDecodeHexDumpString(NSString *value)
{
    if (value.length == 0)
        return nil;

    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSArray<NSString *> *tokens = [value componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableData *data = [NSMutableData data];
    BOOL sawByte = NO;

    for (NSString *token in tokens)
    {
        if (token.length == 0)
            continue;
        if ([token rangeOfCharacterFromSet:[hexSet invertedSet]].location != NSNotFound)
            return nil;
        if (token.length == 8 && data.length > 0)
            continue;
        if (token.length != 2)
            return nil;

        unsigned int byte = 0;
        if ([[NSScanner scannerWithString:token] scanHexInt:&byte] == NO || byte > 0xff)
            return nil;
        if (byte == 0)
            continue;
        unsigned char c = (unsigned char)byte;
        [data appendBytes:&c length:1];
        sawByte = YES;
    }

    if (sawByte == NO || data.length == 0)
        return nil;

    while (data.length > 0)
    {
        unsigned char last = 0;
        [data getBytes:&last range:NSMakeRange(data.length - 1, 1)];
        if (last != 0 && last != ' ')
            break;
        [data setLength:data.length - 1];
    }

    if (data.length == 0)
        return nil;

    return [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
}

static NSString* HorosModernDCMTKCopyFieldString(const char* path,
                                                 NSString *fieldName,
                                                 NSStringEncoding encoding,
                                                 HorosModernDCMTKCopyFieldFn copyFieldFn,
                                                 HorosModernDCMTKFreeStringFn freeStringFn)
{
    if (path == nullptr || fieldName.length == 0 || copyFieldFn == NULL)
        return nil;
    char *value = copyFieldFn(path, fieldName.UTF8String);
    if (value == NULL)
        return nil;
    NSString *stringValue = [NSString stringWithCString:value encoding:encoding];
    if (freeStringFn)
        freeStringFn(value);
    return stringValue;
}

static NSString* HorosModernDCMTKDecodeFieldString(const char* path,
                                                   NSString *fieldName,
                                                   NSStringEncoding *encodings,
                                                   HorosModernDCMTKCopyFieldFn copyFieldFn,
                                                   HorosModernDCMTKFreeStringFn freeStringFn)
{
    if (path == nullptr || fieldName.length == 0 || copyFieldFn == NULL)
        return nil;
    char *value = copyFieldFn(path, fieldName.UTF8String);
    if (value == NULL)
        return nil;
    NSString *stringValue = [DicomFile stringWithBytes:value encodings:encodings];
    if (freeStringFn)
        freeStringFn(value);
    return stringValue;
}

static NSString* HorosModernDCMTKCopyFieldByTagString(const char* path,
                                                      int group,
                                                      int element,
                                                      NSStringEncoding *encodings,
                                                      HorosModernDCMTKCopyFieldByTagFn copyFieldByTagFn,
                                                      HorosModernDCMTKFreeStringFn freeStringFn)
{
    if (path == nullptr || group <= 0 || element <= 0 || copyFieldByTagFn == NULL)
        return nil;
    char *value = copyFieldByTagFn(path, (unsigned short)group, (unsigned short)element);
    if (value == NULL)
        return nil;
    NSString *stringValue = [DicomFile stringWithBytes:value encodings:encodings];
    NSString *decodedHexValue = HorosModernDCMTKDecodeHexDumpString(stringValue);
    if (decodedHexValue)
        stringValue = [DicomFile stringWithBytes:(char *)[decodedHexValue UTF8String] encodings:encodings];
    if (freeStringFn)
        freeStringFn(value);
    return stringValue;
}

@implementation DicomFile (DicomFileDCMTKCategory)

+ (NSString *)generatedDICOMUID
{
    auto generate = HorosModernDCMTKSymbol<decltype(&HorosModernDCMTKCopyGeneratedUID)>("HorosModernDCMTKCopyGeneratedUID");
    return generate ? HorosModernDCMTKCopiedString(generate()) : nil;
}

+ (BOOL)writeRawSecondaryCapture:(const HorosModernDCMTKRawImage *)image toFile:(NSString *)path error:(NSError **)error
{
    if (error) *error = nil;
    auto write = HorosModernDCMTKSymbol<decltype(&HorosModernDCMTKWriteRawSecondaryCapture)>("HorosModernDCMTKWriteRawSecondaryCapture");
    auto freeString = HorosModernDCMTKSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
    // Keep incomplete files hidden from the incoming-directory scanner.
    NSString *temporary = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [@"." stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *reason = @"The DCMTK raw image writer is unavailable. Rebuild the bundled bridge.";
    if (write && freeString)
    {
        char *failure = nullptr;
        BOOL success = write(temporary.fileSystemRepresentation, image, &failure) != 0;
        reason = failure ? [NSString stringWithUTF8String:failure] : @"Cannot write the raw image.";
        freeString(failure);
        if (success && [[NSFileManager defaultManager] moveItemAtPath:temporary toPath:path error:error])
            return YES;
    }
    [[NSFileManager defaultManager] removeItemAtPath:temporary error:NULL];
    if (error && !*error)
        *error = [NSError errorWithDomain:@"HorosDICOMMetadata" code:4
            userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Cannot write the raw image."}];
    return NO;
}

+ (NSXMLDocument *)metadataDocumentForFile:(NSString *)path error:(NSError **)error
{
    if (error != NULL)
        *error = nil;
    typedef char* (*CopyMetadataFn)(const char*, char**);
    CopyMetadataFn copyMetadata = HorosModernDCMTKSymbol<CopyMetadataFn>("HorosModernDCMTKCopyMetadataXML");
    HorosModernDCMTKFreeStringFn freeString = HorosModernDCMTKSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
    NSString *reason = @"The DCMTK metadata reader is unavailable. Rebuild the bundled bridge.";
    if (copyMetadata && freeString)
    {
        char *failure = nullptr;
        char *xml = copyMetadata(path.fileSystemRepresentation, &failure);
        NSString *xmlString = xml ? [NSString stringWithUTF8String:xml] : nil;
        reason = failure ? [NSString stringWithUTF8String:failure] : @"Cannot read DICOM metadata as UTF-8.";
        freeString(xml);
        freeString(failure);
        if (xmlString != nil)
            return HorosDICOMMetadataDocument(xmlString, error);
    }
    if (error != NULL)
        *error = [NSError errorWithDomain:@"HorosDICOMMetadata" code:2
                                userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Cannot read DICOM metadata."}];
    return nil;
}

+ (NSData *)encapsulatedPDFForFile:(NSString *)path documentTitle:(NSString **)title error:(NSError **)error
{
    if (title != NULL)
        *title = nil;
    if (error != NULL)
        *error = nil;
    typedef int (*CopyPDFFn)(const char*, unsigned char**, unsigned long*, char**, char**);
    CopyPDFFn copyPDF = HorosModernDCMTKSymbol<CopyPDFFn>("HorosModernDCMTKCopyEncapsulatedPDF");
    HorosModernDCMTKFreeBufferFn freeBuffer = HorosModernDCMTKSymbol<HorosModernDCMTKFreeBufferFn>("HorosModernDCMTKFreeBuffer");
    HorosModernDCMTKFreeStringFn freeString = HorosModernDCMTKSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
    NSString *reason = @"The DCMTK PDF reader is unavailable. Rebuild the bundled bridge.";
    if (copyPDF && freeBuffer && freeString)
    {
        unsigned char *buffer = nullptr;
        unsigned long length = 0;
        char *documentTitle = nullptr, *failure = nullptr;
        int success = copyPDF(path.fileSystemRepresentation, &buffer, &length, title ? &documentTitle : nullptr, &failure);
        NSData *data = success && buffer && length ? [NSData dataWithBytes:buffer length:length] : nil;
        if (data && title != NULL && documentTitle != nullptr)
            *title = [NSString stringWithUTF8String:documentTitle];
        reason = failure ? [NSString stringWithUTF8String:failure] : @"Cannot read the embedded PDF.";
        freeBuffer(buffer);
        freeString(documentTitle);
        freeString(failure);
        if (data != nil)
            return data;
    }
    if (error != NULL)
        *error = [NSError errorWithDomain:@"HorosDICOMMetadata" code:3
                                userInfo:@{NSLocalizedDescriptionKey: reason ?: @"Cannot read the embedded PDF."}];
    return nil;
}

+ (NSArray*) getEncodingArrayForFile: (NSString*) file
{
    HorosModernDCMTKCopySpecificCharacterSetFn bridgeFn = HorosModernDCMTKSymbol<HorosModernDCMTKCopySpecificCharacterSetFn>("HorosModernDCMTKCopySpecificCharacterSet");
    if (bridgeFn)
    {
        NSString *characterSet = HorosModernDCMTKCopiedString(bridgeFn(file.UTF8String));
        if (characterSet.length > 0)
            return [characterSet componentsSeparatedByString:@"\\"];
        return [NSArray arrayWithObject: @"ISO_IR 100"];
    }
    return [NSArray arrayWithObject: @"ISO_IR 100"];
}

+ (BOOL) isDICOMFileDCMTK:(NSString *) file{
    HorosModernDCMTKIsDICOMFileFn bridgeFn = HorosModernDCMTKSymbol<HorosModernDCMTKIsDICOMFileFn>("HorosModernDCMTKIsDICOMFile");
    if (bridgeFn)
        return bridgeFn(file.UTF8String) != 0;
    return NO;
}

+ (NSString*) getDicomField: (NSString*) field forFile: (NSString*) path
{
    if( field.length <= 0)
        return nil;

    HorosModernDCMTKCopyFieldFn bridgeFn = HorosModernDCMTKSymbol<HorosModernDCMTKCopyFieldFn>("HorosModernDCMTKCopyField");
    if (bridgeFn)
    {
        NSString *value = HorosModernDCMTKCopiedString(bridgeFn(path.UTF8String, field.UTF8String));
        if (value)
            return value;
    }
    return nil;
}

-(short) getDicomFileDCMTK
{
    int i;
    long cardiacTime = -1;
    
    std::array<NSStringEncoding, 10> encoding;
    NSString *echoTime = nil;
    NSString *institution = nil;
    NSString *referringPhysician = nil;
    NSString *performingPhysician = nil;
    NSString *accessionNumber = nil;
    NSString *patientName = nil;
    NSString *patientAge = nil;
    NSString *patientBirthDate = nil;
    NSString *patientSex = nil;
    NSString *scanOptions = nil;
    NSString *protocol = nil;
    double location = 0.0;
    NSMutableArray *imageTypeArray = nil;
    HorosModernDCMTKBasicMetadata bridgeMetadata;
    memset(&bridgeMetadata, 0, sizeof(bridgeMetadata));
    BOOL hasBridgeMetadata = NO;
    HorosModernDCMTKGetBasicMetadataFn bridgeFn = HorosModernDCMTKSymbol<HorosModernDCMTKGetBasicMetadataFn>("HorosModernDCMTKGetBasicMetadata");
    HorosModernDCMTKFreeBasicMetadataFn freeBridgeMetadataFn = HorosModernDCMTKSymbol<HorosModernDCMTKFreeBasicMetadataFn>("HorosModernDCMTKFreeBasicMetadata");
    if (bridgeFn)
        hasBridgeMetadata = bridgeFn(filePath.UTF8String, &bridgeMetadata) != 0;
    
    HorosModernDCMTKCopyFieldFn copyFieldFn = HorosModernDCMTKSymbol<HorosModernDCMTKCopyFieldFn>("HorosModernDCMTKCopyField");
    HorosModernDCMTKCopyFieldByTagFn copyFieldByTagFn = HorosModernDCMTKSymbol<HorosModernDCMTKCopyFieldByTagFn>("HorosModernDCMTKCopyFieldByTag");
    HorosModernDCMTKCopyImageGeometryFn copyGeometryFn = HorosModernDCMTKSymbol<HorosModernDCMTKCopyImageGeometryFn>("HorosModernDCMTKCopyImageGeometry");
    HorosModernDCMTKCopyFrameGeometryFn copyFrameGeometryFn = HorosModernDCMTKSymbol<HorosModernDCMTKCopyFrameGeometryFn>("HorosModernDCMTKCopyFrameGeometry");
    HorosModernDCMTKCopyEncapsulatedDocumentFn copyEncapsulatedDocumentFn = HorosModernDCMTKSymbol<HorosModernDCMTKCopyEncapsulatedDocumentFn>("HorosModernDCMTKCopyEncapsulatedDocument");
    HorosModernDCMTKFreeStringFn freeStringFn = HorosModernDCMTKSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
    HorosModernDCMTKFreeBufferFn freeBufferFn = HorosModernDCMTKSymbol<HorosModernDCMTKFreeBufferFn>("HorosModernDCMTKFreeBuffer");
    
    if (hasBridgeMetadata == NO && copyFieldFn == NULL && copyFieldByTagFn == NULL)
    {
        if (hasBridgeMetadata && freeBridgeMetadataFn)
            freeBridgeMetadataFn(&bridgeMetadata);
        return -1;
    }
    
    encoding.fill(0);
    encoding[0] = NSISOLatin1StringEncoding;
    
    NSString *transferSyntaxUID = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.transferSyntaxUID, NSASCIIStringEncoding) : nil;
    if (transferSyntaxUID == nil)
        transferSyntaxUID = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"TransferSyntaxUID", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    if ([transferSyntaxUID isEqualToString:@"1.2.840.10008.1.2.4.100"])
    {
        fileType = [@"DICOMMPEG2" retain];
        [dicomElements setObject:fileType forKey:@"fileType"];
    }
    else
    {
        fileType = [@"DICOM" retain];
        [dicomElements setObject:fileType forKey:@"fileType"];
    }
    
    NSString *privateInformationCreatorUID = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.privateInformationCreatorUID, NSISOLatin1StringEncoding) : nil;
    if (privateInformationCreatorUID == nil)
        privateInformationCreatorUID = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"PrivateInformationCreatorUID", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (privateInformationCreatorUID)
        [dicomElements setObject:privateInformationCreatorUID forKey:@"PrivateInformationCreatorUID"];
    
    NSString *specificCharacterSet = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.specificCharacterSet, NSISOLatin1StringEncoding) : nil;
    if (specificCharacterSet == nil)
        specificCharacterSet = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"SpecificCharacterSet", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (specificCharacterSet)
    {
        NSArray	*c = [specificCharacterSet componentsSeparatedByString:@"\\"];
        if( [c count] >= 10) NSLog( @"Encoding number >= 10 ???");
        if( [c count] < 10)
        {
            for( i = 0; i < [c count]; i++) encoding[ i] = [NSString encodingForDICOMCharacterSet: [c objectAtIndex: i]];
            for( i = (int)[c count]; i < 10; i++) encoding[ i] = [NSString encodingForDICOMCharacterSet: [c lastObject]];
        }
    }
    
    if ([self autoFillComments] == YES && [self autoFillComments])
    {
        NSString *commentsField = nil;
        if ([self commentsGroup] && [self commentsElement])
            commentsField = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, [self commentsGroup], [self commentsElement], encoding.data(), copyFieldByTagFn, freeStringFn);
        
        if ([self commentsGroup2] && [self commentsElement2])
        {
            NSString *commentsPart = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, [self commentsGroup2], [self commentsElement2], encoding.data(), copyFieldByTagFn, freeStringFn);
            if (commentsPart)
                commentsField = commentsField ? [commentsField stringByAppendingFormat:@" / %@", commentsPart] : commentsPart;
        }
        
        if ([self commentsGroup3] && [self commentsElement3])
        {
            NSString *commentsPart = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, [self commentsGroup3], [self commentsElement3], encoding.data(), copyFieldByTagFn, freeStringFn);
            if (commentsPart)
                commentsField = commentsField ? [commentsField stringByAppendingFormat:@" / %@", commentsPart] : commentsPart;
        }
        
        if ([self commentsGroup4] && [self commentsElement4])
        {
            NSString *commentsPart = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, [self commentsGroup4], [self commentsElement4], encoding.data(), copyFieldByTagFn, freeStringFn);
            if (commentsPart)
                commentsField = commentsField ? [commentsField stringByAppendingFormat:@" / %@", commentsPart] : commentsPart;
        }
        
        if (commentsField)
            [dicomElements setObject:commentsField forKey:@"commentsAutoFill"];
    }
    
    NSString *sopClassUID = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.sopClassUID, NSASCIIStringEncoding) : nil;
    if (sopClassUID == nil)
        sopClassUID = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"SOPClassUID", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    if (sopClassUID == nil)
        sopClassUID = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x0016, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (sopClassUID)
        [dicomElements setObject:sopClassUID forKey:@"SOPClassUID"];
    
    NSString *imageTypeString = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.imageType, NSISOLatin1StringEncoding) : nil;
    if (imageTypeString == nil)
        imageTypeString = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ImageType", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (imageTypeString)
    {
        imageTypeArray = [NSMutableArray arrayWithArray:[imageTypeString componentsSeparatedByString:@"\\"]];
        if( [imageTypeArray count] > 2)
        {
            imageType = [[imageTypeArray objectAtIndex: 2] retain];
            [dicomElements setObject:imageType forKey:@"imageType"];
        }
    }
    else
        imageType = nil;
    if( imageType) [dicomElements setObject:imageType forKey:@"imageType"];
    
    NSString *sopInstanceUID = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.sopInstanceUID, NSISOLatin1StringEncoding) : nil;
    if (sopInstanceUID == nil)
        sopInstanceUID = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"SOPInstanceUID", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (sopInstanceUID == nil)
        sopInstanceUID = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x0018, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (sopInstanceUID)
        SOPUID = [sopInstanceUID retain];
    else
        SOPUID = nil;
    if (SOPUID) [dicomElements setObject:SOPUID forKey:@"SOPUID"];
    
    NSString *studyValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"StudyDescription", encoding.data(), copyFieldFn, freeStringFn);
    if (studyValue == nil)
        studyValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x1030, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (studyValue)
        study = [studyValue retain];
    if( !study)
        study = [[NSString alloc] initWithString: @"unnamed"];
    [dicomElements setObject:study forKey: @"studyDescription"];
    
    NSString *modalityString = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.modality, NSASCIIStringEncoding) : nil;
    if (modalityString == nil)
        modalityString = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"Modality", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    if (modalityString == nil)
        modalityString = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x0060, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (modalityString)
        Modality = [[NSString alloc] initWithString:modalityString];
    else if ([DCMAbstractSyntaxUID isStructuredReport:sopClassUID])
        Modality = [[NSString alloc] initWithString:@"SR"];
    else
        Modality = [[NSString alloc] initWithString:@"OT"];
    [dicomElements setObject:Modality forKey:@"modality"];
    
    NSString *studyDate = nil;
    if (hasBridgeMetadata && bridgeMetadata.acquisitionDate != NULL && bridgeMetadata.acquisitionDate[0] != '\0')
        studyDate = HorosModernDCMTKBridgeString(bridgeMetadata.acquisitionDate, NSASCIIStringEncoding);
    else if (hasBridgeMetadata && bridgeMetadata.contentDate != NULL && bridgeMetadata.contentDate[0] != '\0')
        studyDate = HorosModernDCMTKBridgeString(bridgeMetadata.contentDate, NSASCIIStringEncoding);
    else if (hasBridgeMetadata && bridgeMetadata.seriesDate != NULL && bridgeMetadata.seriesDate[0] != '\0')
        studyDate = HorosModernDCMTKBridgeString(bridgeMetadata.seriesDate, NSASCIIStringEncoding);
    else if (hasBridgeMetadata && bridgeMetadata.studyDate != NULL && bridgeMetadata.studyDate[0] != '\0')
        studyDate = HorosModernDCMTKBridgeString(bridgeMetadata.studyDate, NSASCIIStringEncoding);
    else
        studyDate = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"AcquisitionDate", NSASCIIStringEncoding, copyFieldFn, freeStringFn) ?:
                    HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ContentDate", NSASCIIStringEncoding, copyFieldFn, freeStringFn) ?:
                    HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"SeriesDate", NSASCIIStringEncoding, copyFieldFn, freeStringFn) ?:
                    HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"StudyDate", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    
    if( [studyDate length] != 8) studyDate = [studyDate stringByReplacingOccurrencesOfString:@"." withString:@""];
    
    NSString* studyTime = nil;
    if (hasBridgeMetadata && bridgeMetadata.acquisitionTime != NULL && bridgeMetadata.acquisitionTime[0] != '\0' && atof(bridgeMetadata.acquisitionTime) > 0)
        studyTime = HorosModernDCMTKBridgeString(bridgeMetadata.acquisitionTime, NSASCIIStringEncoding);
    else if (hasBridgeMetadata && bridgeMetadata.contentTime != NULL && bridgeMetadata.contentTime[0] != '\0' && atof(bridgeMetadata.contentTime) > 0)
        studyTime = HorosModernDCMTKBridgeString(bridgeMetadata.contentTime, NSASCIIStringEncoding);
    else if (hasBridgeMetadata && bridgeMetadata.seriesTime != NULL && bridgeMetadata.seriesTime[0] != '\0' && atof(bridgeMetadata.seriesTime) > 0)
        studyTime = HorosModernDCMTKBridgeString(bridgeMetadata.seriesTime, NSASCIIStringEncoding);
    else if (hasBridgeMetadata && bridgeMetadata.studyTime != NULL && bridgeMetadata.studyTime[0] != '\0' && atof(bridgeMetadata.studyTime) > 0)
        studyTime = HorosModernDCMTKBridgeString(bridgeMetadata.studyTime, NSASCIIStringEncoding);
    else
        studyTime = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"AcquisitionTime", NSASCIIStringEncoding, copyFieldFn, freeStringFn) ?:
                    HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ContentTime", NSASCIIStringEncoding, copyFieldFn, freeStringFn) ?:
                    HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"SeriesTime", NSASCIIStringEncoding, copyFieldFn, freeStringFn) ?:
                    HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"StudyTime", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    
    studyTime = [studyTime stringByReplacingOccurrencesOfString:@":" withString:@""];
    
    if( studyDate && studyTime)
    {
        NSString *completeDate = [studyDate stringByAppendingString:studyTime];
        if ([studyTime length] >= 6)
            date = [HorosDateFromDICOMString(completeDate, @"yyyyMMddHHmmss", 14) retain];
        else
            date = [HorosDateFromDICOMString(completeDate, @"yyyyMMddHHmm", 12) retain];
    }
    else if( studyDate)
    {
        studyDate = [studyDate stringByAppendingString: @"120000"];
        date = [HorosDateFromDICOMString(studyDate, @"yyyyMMddHHmmss", 14) retain];
    }
    else
        date = [HorosDICOMFallbackDate() retain];
    
    if( date)
        [dicomElements setObject:date forKey:@"studyDate"];
    
    NSString *seriesDescriptionValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"SeriesDescription", encoding.data(), copyFieldFn, freeStringFn);
    if (seriesDescriptionValue == nil)
        seriesDescriptionValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x103e, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (seriesDescriptionValue == nil)
        seriesDescriptionValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"PerformedProcedureStepDescription", encoding.data(), copyFieldFn, freeStringFn);
    if (seriesDescriptionValue == nil)
        seriesDescriptionValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"AcquisitionDeviceProcessingDescription", encoding.data(), copyFieldFn, freeStringFn);
    if (seriesDescriptionValue == nil && [DCMAbstractSyntaxUID isStructuredReport:sopClassUID])
        seriesDescriptionValue = @"Structured Report";
    if (seriesDescriptionValue)
        serie = [seriesDescriptionValue retain];
    
    if( serie == nil)
        serie = [[NSString alloc] initWithString: @"unnamed"];
    [dicomElements setObject:serie forKey:@"seriesDescription"];
    
    NSString *institutionValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"InstitutionName", encoding.data(), copyFieldFn, freeStringFn);
    if (institutionValue == nil)
        institutionValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x0080, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (institutionValue)
        institution = [institutionValue retain];
    if( institution) [dicomElements setObject: institution forKey:@"institutionName"];
    
    NSString *referringValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"ReferringPhysiciansName", encoding.data(), copyFieldFn, freeStringFn);
    if (referringValue == nil)
        referringValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"ReferringPhysicianName", encoding.data(), copyFieldFn, freeStringFn);
    if (referringValue == nil)
        referringValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x0090, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (referringValue)
        referringPhysician = [referringValue retain];
    if( referringPhysician)
    {
        [dicomElements setObject:referringPhysician forKey:@"referringPhysician"];
        [dicomElements setObject:referringPhysician forKey:@"referringPhysiciansName"];
    }
    
    NSString *performingValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"PerformingPhysiciansName", encoding.data(), copyFieldFn, freeStringFn);
    if (performingValue == nil)
        performingValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"PerformingPhysicianName", encoding.data(), copyFieldFn, freeStringFn);
    if (performingValue == nil)
        performingValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x1050, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (performingValue)
        performingPhysician = [performingValue retain];
    if( performingPhysician)
    {
        [dicomElements setObject:performingPhysician forKey:@"performingPhysician"];
        [dicomElements setObject:performingPhysician forKey:@"performingPhysiciansName"];
    }
    
    NSString *accessionValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"AccessionNumber", encoding.data(), copyFieldFn, freeStringFn);
    if (accessionValue == nil)
        accessionValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0008, 0x0050, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (accessionValue)
        accessionNumber = [accessionValue retain];
    if( accessionNumber) [dicomElements setObject:accessionNumber forKey:@"accessionNumber"];
    
    NSString *patientNameValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"PatientName", encoding.data(), copyFieldFn, freeStringFn);
    if (patientNameValue == nil)
        patientNameValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"PatientsName", encoding.data(), copyFieldFn, freeStringFn);
    if (patientNameValue == nil)
        patientNameValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0010, 0x0010, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (patientNameValue)
        patientName = [patientNameValue retain];
    if (patientName)
        name = [patientName retain];
    else if (patientID)
        name = [patientID retain];
    else
        name = [[NSString alloc] initWithString:@"No name"];
    if( patientName) [dicomElements setObject:patientName forKey:@"patientName"];
    
    NSString *patientIDValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"PatientID", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (patientIDValue == nil)
        patientIDValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0010, 0x0020, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (patientIDValue)
        patientID = [[NSString alloc] initWithString:patientIDValue];
    if( patientID) [dicomElements setObject:patientID forKey:@"patientID"];
    
    NSString *patientAgeValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"PatientsAge", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (patientAgeValue == nil)
        patientAgeValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"PatientAge", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (patientAgeValue == nil)
        patientAgeValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0010, 0x1010, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (patientAgeValue)
        patientAge = [[NSString alloc] initWithString:patientAgeValue];
    if( patientAge) [dicomElements setObject:patientAge forKey:@"patientAge"];
    
    NSString *patientBirthDateValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"PatientsBirthDate", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (patientBirthDateValue == nil)
        patientBirthDateValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"PatientBirthDate", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (patientBirthDateValue == nil)
        patientBirthDateValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0010, 0x0030, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (patientBirthDateValue)
    {
        NSDate *DOB = HorosDateFromDICOMString(patientBirthDateValue, @"yyyyMMdd", 8);
        if (DOB)
            patientBirthDate = [[HorosDICOMDateFormatter(@"yyyyMMdd") stringFromDate:DOB] retain];
    }
    if( patientBirthDate)
    {
        NSDate *DOB = HorosDateFromDICOMString(patientBirthDate, @"yyyyMMdd", 8);
        if (DOB)
            [dicomElements setObject:DOB forKey:@"patientBirthDate"];
    }
    
    NSString *patientSexValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"PatientsSex", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (patientSexValue == nil)
        patientSexValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"PatientSex", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (patientSexValue == nil)
        patientSexValue = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0010, 0x0040, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (patientSexValue)
        patientSex = [[NSString alloc] initWithString:patientSexValue];
    if( patientSex) [dicomElements setObject:patientSex forKey:@"patientSex"];
    
    if (scanOptions == nil)
    {
        NSString *scanOptionsValue = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.scanOptions, NSISOLatin1StringEncoding) : nil;
        if (scanOptionsValue == nil)
            scanOptionsValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ScanOptions", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
        if (scanOptionsValue)
            scanOptions = [[NSString alloc] initWithString:scanOptionsValue];
    }
    if( scanOptions) [dicomElements setObject:scanOptions forKey:@"scanOptions"];
    
    NSString *protocolValue = HorosModernDCMTKDecodeFieldString(filePath.UTF8String, @"ProtocolName", encoding.data(), copyFieldFn, freeStringFn);
    if (protocolValue)
        protocol = [protocolValue retain];
    if( protocol) [dicomElements setObject: protocol forKey:@"protocolName"];
    
    NSString *echoTimeString = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.echoTime, NSISOLatin1StringEncoding) : nil;
    if (echoTimeString == nil)
        echoTimeString = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"EchoTime", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (echoTimeString) echoTime = [[NSString alloc] initWithString: echoTimeString];
    if( echoTime) [dicomElements setObject: echoTime forKey:@"echoTime"];
    
    NSString *instanceNumber = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.instanceNumber, NSISOLatin1StringEncoding) : nil;
    if (instanceNumber == nil)
        instanceNumber = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"InstanceNumber", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
    if (instanceNumber)
    {
        imageID = [[NSString alloc] initWithString: instanceNumber];
        [dicomElements setObject:[NSNumber numberWithLong: [imageID intValue]] forKey:@"imageID"];
    }
    
    if( imageID == nil || [imageID intValue] >= 99999)
    {
        if( [Modality isEqualToString:@"MR"] || [Modality isEqualToString:@"CT"] || [Modality isEqualToString:@"US"])
        {
            NSString *sliceLocationValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"SliceLocation", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
            if (sliceLocationValue)
            {
                int val = 10000 + [sliceLocationValue floatValue] * 10.;
                imageID = [[NSString alloc] initWithFormat:@"%5d", val];
                [dicomElements setObject:[NSNumber numberWithLong: [imageID intValue]] forKey:@"imageID"];
            }
        }
    }
    
    unsigned short rows = bridgeMetadata.rows;
    if (rows == 0)
    {
        NSString *rowsValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"Rows", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
        if (rowsValue)
            rows = (unsigned short)[rowsValue intValue];
    }
    if (rows > 0)
        height = rows;
    
    unsigned short columns = bridgeMetadata.columns;
    if (columns == 0)
    {
        NSString *columnsValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"Columns", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
        if (columnsValue)
            columns = (unsigned short)[columnsValue intValue];
    }
    if (columns > 0)
        width = columns;
    
    if (bridgeMetadata.numberOfFrames > 0)
        NoOfFrames = bridgeMetadata.numberOfFrames;
    else
    {
        NSString *framesValue = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"NumberOfFrames", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
        if (framesValue)
            NoOfFrames = [framesValue intValue];
    }
    
    double origin[ 3] = {0, 0, 0};
    double orientation[ 9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    if (copyGeometryFn)
        copyGeometryFn(filePath.UTF8String, origin, orientation);
    
    orientation[6] = orientation[1]*orientation[5] - orientation[2]*orientation[4];
    orientation[7] = orientation[2]*orientation[3] - orientation[0]*orientation[5];
    orientation[8] = orientation[0]*orientation[4] - orientation[1]*orientation[3];
    
    if( fabs( orientation[6]) > fabs(orientation[7]) && fabs( orientation[6]) > fabs(orientation[8])) location = origin[ 0];
    if( fabs( orientation[7]) > fabs(orientation[6]) && fabs( orientation[7]) > fabs(orientation[8])) location = origin[ 1];
    if( fabs( orientation[8]) > fabs(orientation[6]) && fabs( orientation[8]) > fabs(orientation[7])) location = origin[ 2];
    
    [dicomElements setObject:[NSNumber numberWithDouble: (double)location] forKey:@"sliceLocation"];
    
    if( imageID == nil || [imageID intValue] >= 99999)
    {
        int val = 10000 + location*10.;
        [imageID release];
        imageID = [[NSString alloc] initWithFormat:@"%5d", val];
    }
    [dicomElements setObject:[NSNumber numberWithLong: [imageID intValue]] forKey:@"imageID"];
    
    NSString *seriesNumber = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.seriesNumber, NSASCIIStringEncoding) : nil;
    if (seriesNumber == nil)
        seriesNumber = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"SeriesNumber", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    if (seriesNumber)
        seriesNo = [[NSString alloc] initWithString:seriesNumber];
    else
        seriesNo = [[NSString alloc] initWithString: @"0"];
    if( seriesNo) [dicomElements setObject:[NSNumber numberWithInt:[seriesNo intValue]]  forKey:@"seriesNumber"];
    
    NSString *seriesInstanceUID = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.seriesInstanceUID, NSASCIIStringEncoding) : nil;
    if (seriesInstanceUID == nil)
        seriesInstanceUID = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"SeriesInstanceUID", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    if (seriesInstanceUID == nil)
        seriesInstanceUID = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0020, 0x000e, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (seriesInstanceUID)
    {
        self.serieID = seriesInstanceUID;
        [dicomElements setObject:self.serieID forKey:@"seriesDICOMUID"];
    }
    else
        self.serieID = name;
    
    if( cardiacTime != -1 && [self separateCardiac4D] == YES && [Modality isEqualToString: @"SC"] == NO)
        self.serieID = [NSString stringWithFormat:@"%@ %2.2d", self.serieID , (int) cardiacTime];
    
    if( seriesNo)
        self.serieID = [NSString stringWithFormat:@"%8.8d %@", [seriesNo intValue] , self.serieID];
    
    if( imageType != 0 && [self useSeriesDescription])
        self.serieID = [NSString stringWithFormat:@"%@ %@", self.serieID , imageType];
    
    if( serie != nil && [self useSeriesDescription])
        self.serieID = [NSString stringWithFormat:@"%@ %@", self.serieID , serie];
    
    if( sopClassUID != nil && [[DCMAbstractSyntaxUID hiddenImageSyntaxes] containsObject: sopClassUID])
        self.serieID = [NSString stringWithFormat:@"%@ %@", self.serieID , sopClassUID];
    
    if( echoTime != nil && [self splitMultiEchoMR])
        self.serieID = [NSString stringWithFormat:@"%@ TE-%@", self.serieID , echoTime];
    
    NSString *studyInstanceUID = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.studyInstanceUID, NSASCIIStringEncoding) : nil;
    if (studyInstanceUID == nil)
        studyInstanceUID = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"StudyInstanceUID", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    if (studyInstanceUID == nil)
        studyInstanceUID = HorosModernDCMTKCopyFieldByTagString(filePath.UTF8String, 0x0020, 0x000d, encoding.data(), copyFieldByTagFn, freeStringFn);
    if (studyInstanceUID)
        studyID = [[NSString alloc] initWithString:studyInstanceUID];
    else
        studyID = [[NSString alloc] initWithString:name];
    
    [dicomElements setObject:studyID forKey:@"studyID"];
    
    NSString *studyIdentifier = hasBridgeMetadata ? HorosModernDCMTKBridgeString(bridgeMetadata.studyID, NSASCIIStringEncoding) : nil;
    if (studyIdentifier == nil)
        studyIdentifier = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"StudyID", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
    if (studyIdentifier)
        studyIDs = [[NSString alloc] initWithString:studyIdentifier];
    else
        studyIDs = [[NSString alloc] initWithString:@"0"];
    
    if( studyIDs)
        [dicomElements setObject:studyIDs forKey:@"studyNumber"];
    
    if( [self commentsFromDICOMFiles])
    {
        NSString *studyComments = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"StudyComments", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
        if (studyComments)
            [dicomElements setObject: studyComments forKey:@"studyComments"];
        
        NSString *seriesComments = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ImageComments", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
        if (seriesComments)
            [dicomElements setObject: seriesComments forKey:@"seriesComments"];
        
        NSString *stateText = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"InterpretationStatusID", NSASCIIStringEncoding, copyFieldFn, freeStringFn);
        if (stateText)
            [dicomElements setObject: [NSNumber numberWithInt:[stateText intValue]] forKey:@"stateText"];
    }
    
    NSMutableArray *sliceLocationArray = [NSMutableArray array];
    NSMutableArray *imageCardiacTriggerArray = [NSMutableArray array];
    if (copyFrameGeometryFn)
    {
        double *sliceLocations = nullptr;
        double *triggerDelays = nullptr;
        int sliceCount = 0;
        int triggerCount = 0;
        if (copyFrameGeometryFn(filePath.UTF8String, &sliceLocations, &sliceCount, &triggerDelays, &triggerCount))
        {
            for (int index = 0; index < sliceCount; index++)
                [sliceLocationArray addObject:[NSNumber numberWithDouble:sliceLocations[index]]];
            for (int index = 0; index < triggerCount; index++)
                [imageCardiacTriggerArray addObject:[NSString stringWithFormat:@"%lf", triggerDelays[index]]];
        }
        if (freeBufferFn)
        {
            if (sliceLocations)
                freeBufferFn(sliceLocations);
            if (triggerDelays)
                freeBufferFn(triggerDelays);
        }
    }
    
    if( sliceLocationArray.count)
    {
        if( NoOfFrames == sliceLocationArray.count)
            [dicomElements setObject: sliceLocationArray forKey:@"sliceLocationArray"];
        else
            NSLog( @"*** NoOfFrames != sliceLocationArray.count for MR/CT/US multiframe sliceLocation computation (%d, %d)", (int) NoOfFrames, (int) sliceLocationArray.count);
    }
    if( imageCardiacTriggerArray.count)
    {
        if( NoOfFrames == imageCardiacTriggerArray.count)
            [dicomElements setObject: imageCardiacTriggerArray forKey:@"imageCommentPerFrame"];
        else
            NSLog( @"*** NoOfFrames != imageCardiacTriggerArray.count for MR/CT multiframe image type frame computation (%d, %d)", (int) NoOfFrames, (int) imageCardiacTriggerArray.count);
        
    }
    
    if( [sopClassUID isEqualToString:[DCMAbstractSyntaxUID pdfStorageClassUID]])
    {
        unsigned char *buffer = nullptr;
        unsigned long length = 0;
        if (copyEncapsulatedDocumentFn && copyEncapsulatedDocumentFn(filePath.UTF8String, &buffer, &length) && length > 0)
        {
            NSData *pdfData = [NSData dataWithBytes:buffer length:(unsigned)length];
            NSPDFImageRep *rep = [NSPDFImageRep imageRepWithData:pdfData];
            
            NoOfFrames = [rep pageCount];
            
            NSImage *pdfImage = [[[NSImage alloc] init] autorelease];
            [pdfImage addRepresentation: rep];
            
            NSBitmapImageRep *bitRep = [NSBitmapImageRep imageRepWithData: [pdfImage TIFFRepresentation]];
            
            if( bitRep.pixelsWide > pdfImage.size.width)
            {
                height = bitRep.pixelsHigh;
                width = bitRep.pixelsWide;
            }
            else
            {
                height = pdfImage.size.height;
                width = pdfImage.size.width;
            }
        }
        if (freeBufferFn && buffer)
            freeBufferFn(buffer);
    }
    
#ifdef OSIRIX_VIEWER
    if( [sopClassUID hasPrefix: @"1.2.840.10008.5.1.4.1.1.88"])
    {
        NSString *referencedSOPInstanceUID = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ReferencedSOPInstanceUID", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
        NSString *referencedFrameNumber = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ReferencedFrameNumber", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
        if (referencedSOPInstanceUID.length == 0)
            referencedSOPInstanceUID = [SRAnnotation getImageRefSOPInstanceUID: filePath];
        else if (referencedFrameNumber.length && referencedFrameNumber.intValue > 0)
            referencedSOPInstanceUID = [referencedSOPInstanceUID stringByAppendingFormat:@"-%d", referencedFrameNumber.intValue];
        
        if( referencedSOPInstanceUID)
            [dicomElements setObject: referencedSOPInstanceUID forKey: @"referencedSOPInstanceUID"];
        
        @try
        {
            if( [[dicomElements objectForKey: @"seriesDescription"] hasPrefix: @"OsiriX ROI SR"])
            {
                NSString *referencedSOPInstanceUID = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ReferencedSOPInstanceUID", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
                NSString *referencedFrameNumber = HorosModernDCMTKCopyFieldString(filePath.UTF8String, @"ReferencedFrameNumber", NSISOLatin1StringEncoding, copyFieldFn, freeStringFn);
                if (referencedSOPInstanceUID.length == 0)
                    referencedSOPInstanceUID = [SRAnnotation getImageRefSOPInstanceUID: filePath];
                else if (referencedFrameNumber.length && referencedFrameNumber.intValue > 0)
                    referencedSOPInstanceUID = [referencedSOPInstanceUID stringByAppendingFormat:@"-%d", referencedFrameNumber.intValue];
                if( referencedSOPInstanceUID)
                    [dicomElements setObject: referencedSOPInstanceUID forKey: @"referencedSOPInstanceUID"];
                
                int numberOfROIs = [[SRAnnotation unarchiveROIsFromCompatibilityData:[SRAnnotation roiFromDICOM:filePath]] count];
                [dicomElements setObject: [NSNumber numberWithInt: numberOfROIs] forKey: @"numberOfROIs"];
            }
        }
        @catch (NSException * e)
        {
            N2LogExceptionWithStackTrace(e);
        }
    }
#endif
    
    NoOfSeries = 1;
    
    if( patientID == nil) patientID = [[NSString alloc] initWithString:@""];
    
    if( NoOfFrames > 1) // SERIES ID MUST BE UNIQUE!!!!!
        self.serieID = [NSString stringWithFormat:@"%@-%@-%@", self.serieID, imageID, [dicomElements objectForKey:@"SOPUID"]];
    
    if( NoOfFrames <= 1 && [self noLocalizer] && ([self containsString: @"LOCALIZER" inArray: imageTypeArray] || [self containsString: @"REF" inArray: imageTypeArray] || [self containsLocalizerInString: serie]) && [DCMAbstractSyntaxUID isImageStorage: sopClassUID])
    {
        self.serieID = @"LOCALIZER";
        
        [serie release];
        serie = [[NSString alloc] initWithString: @"Localizers"];
        [dicomElements setObject:serie forKey:@"seriesDescription"];
        
        [dicomElements setObject: [self.serieID stringByAppendingString: studyID] forKey: @"seriesDICOMUID"];
    }
    
    [dicomElements setObject:[self patientUID] forKey:@"patientUID"];
    
    if( self.serieID == nil) self.serieID = name;
    
    if( [Modality isEqualToString:@"US"] && [self oneFileOnSeriesForUS])
    {
        [dicomElements setObject: [self.serieID stringByAppendingString: [filePath lastPathComponent]] forKey:@"seriesID"];
    }
    else if ( [self combineProjectionSeries] && ([Modality isEqualToString:@"MG"] || [Modality isEqualToString:@"CR"] || [Modality isEqualToString:@"DR"] || [Modality isEqualToString:@"DX"] || [Modality  isEqualToString:@"RF"]))
    {
        if( [self combineProjectionSeriesMode] == 0)
        {
            if( sopClassUID != nil && [[DCMAbstractSyntaxUID hiddenImageSyntaxes] containsObject: sopClassUID])
                [dicomElements setObject:self.serieID forKey:@"seriesID"];
            else
                [dicomElements setObject:studyID forKey:@"seriesID"];
            
            [dicomElements setObject:[NSNumber numberWithLong: [self.serieID intValue] * 1000 + [imageID intValue]] forKey:@"imageID"];
        }
        else if( [self combineProjectionSeriesMode] == 1)
        {
            [dicomElements setObject: [self.serieID stringByAppendingString: imageID] forKey:@"seriesID"];
        }
        else NSLog( @"ARG! ERROR !? Unknown combineProjectionSeriesMode");
    }
    else
        [dicomElements setObject:self.serieID forKey:@"seriesID"];
    
    if( studyID == nil)
    {
        studyID = [[NSString alloc] initWithString:name];
        [dicomElements setObject:studyID forKey:@"studyID"];
    }
    
    if( imageID == nil)
    {
        imageID = [[NSString alloc] initWithString:name];
        [dicomElements setObject:imageID forKey:@"SOPUID"];
    }
    
    if( date == nil)
    {
        date = [HorosDICOMFallbackDate() retain];
        [dicomElements setObject:date forKey:@"studyDate"];
    }
    
    [dicomElements setObject:[NSNumber numberWithBool:YES] forKey:@"hasDICOM"];

    if (([DCMAbstractSyntaxUID isNonImageStorage: sopClassUID] || [DCMAbstractSyntaxUID isKeyObjectDocument: sopClassUID]) && (width == 0 || height == 0))
    {
        // Non-image DICOM objects such as SR/KO may not yield a rasterized preview during parse,
        // but they still need a real database entry so retrieve/import does not drop them.
        width = 1;
        height = 1;
    }
    
    if( name != nil && studyID != nil && self.serieID != nil && imageID != nil && width != 0 && height != 0)
    {
        if (hasBridgeMetadata && freeBridgeMetadataFn)
            freeBridgeMetadataFn(&bridgeMetadata);
        return 0;
    }
    
    if (hasBridgeMetadata && freeBridgeMetadataFn)
        freeBridgeMetadataFn(&bridgeMetadata);
    
    return -1;
}
@end
