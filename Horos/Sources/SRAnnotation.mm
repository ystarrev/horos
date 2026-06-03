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

#import "AppController.h"
#import "SRAnnotation.h"
#import "DCMView.h"
#import "DCMPix.h"
#import "BrowserController.h"
#import "DicomFile.h"
#import "DCMCalendarDate.h"
#import "DicomStudy.h"
#import "DicomSeries.h"
#import "ModernDCMTKBridge.h"
#import "N2Debug.h"
#import "DICOMToNSString.h"

#include <dlfcn.h>
#include <dcmtk/config/osconfig.h>   /* make sure OS specific configuration is included first */
#define DicomImage DCMTKDicomImage
#include <dcmtk/dcmsr/dsrdoc.h>
#include <dcmtk/dcmsr/dsrtypes.h>
#undef DicomImage

typedef char* (*HorosModernDCMTKCopyFieldFn)(const char* path, const char* fieldName);
typedef int (*HorosModernDCMTKCopyEncapsulatedDocumentFn)(const char* path, unsigned char** buffer, unsigned long* length);
typedef char* (*HorosModernDCMTKCopyStructuredReportXMLFn)(const char* path);
typedef int (*HorosModernDCMTKWriteStructuredReportFromXMLFn)(const char* xmlPath, const char* dicomPath);
typedef char* (*HorosModernDCMTKCopyStructuredReportKeyObjectTypeFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportRootCodeMeaningFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportPrimaryReferenceFn)(const char* path);
typedef int (*HorosModernDCMTKCopyBufferByTagFn)(const char* path, unsigned short group, unsigned short element, unsigned char** buffer, unsigned long* length);
typedef int (*HorosModernDCMTKWriteBufferByTagFn)(const char* path, unsigned short group, unsigned short element, const unsigned char* buffer, unsigned long length);
typedef int (*HorosModernDCMTKReplaceTagValueFn)(const char* path, unsigned short group, unsigned short element, const char* value, int removeIfEmpty);
typedef int (*HorosModernDCMTKWriteCompatibilityROIStructuredReportFn)(const char* path,
                                                                       const char* sopInstanceUID,
                                                                       const char* seriesInstanceUID,
                                                                       const char* studyInstanceUID,
                                                                       const char* studyDescription,
                                                                       const char* patientName,
                                                                       const char* patientBirthDate,
                                                                       const char* patientSex,
                                                                       const char* patientID,
                                                                       const char* referringPhysician,
                                                                       const char* studyID,
                                                                       const char* accessionNumber,
                                                                       const char* seriesDescription,
                                                                       const char* seriesNumber,
                                                                       const char* manufacturer,
                                                                       const char* contentDate,
                                                                       const char* contentTime,
                                                                       const char* referencedSOPClassUID,
                                                                       const char* referencedSOPInstanceUID,
                                                                       const char* referencedFrameNumber,
                                                                       const unsigned char* roiArchiveBytes,
                                                                       unsigned long roiArchiveLength);
typedef int (*HorosModernDCMTKWriteCompatibilityStructuredReportFn)(const char* path,
                                                                    const char* sopInstanceUID,
                                                                    const char* seriesInstanceUID,
                                                                    const char* studyInstanceUID,
                                                                    const char* studyDescription,
                                                                    const char* patientName,
                                                                    const char* patientBirthDate,
                                                                    const char* patientSex,
                                                                    const char* patientID,
                                                                    const char* referringPhysician,
                                                                    const char* studyID,
                                                                    const char* accessionNumber,
                                                                    const char* seriesDescription,
                                                                    const char* seriesNumber,
                                                                    const char* manufacturer,
                                                                    const char* contentDate,
                                                                    const char* contentTime,
                                                                    const char* referencedSOPClassUID,
                                                                    const char* referencedSOPInstanceUID,
                                                                    const char* referencedFrameNumber,
                                                                    const char* rootCodeMeaning,
                                                                    const char* childTextValue,
                                                                    const unsigned char* encapsulatedBytes,
                                                                    unsigned long encapsulatedLength);
typedef void (*HorosModernDCMTKFreeBufferFn)(void* buffer);
typedef void (*HorosModernDCMTKFreeStringFn)(char* value);

static void* HorosSRAnnotationBridgeHandle()
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
static FunctionType HorosSRAnnotationSymbol(const char* name)
{
	void* handle = HorosSRAnnotationBridgeHandle();
	if (handle == NULL)
		return NULL;
	return reinterpret_cast<FunctionType>(dlsym(handle, name));
}

@implementation SRAnnotation

static NSString* HorosSRAnnotationBridgeString(char* value)
{
	if (value == NULL)
		return nil;
	NSString* string = [NSString stringWithUTF8String:value];
	HorosModernDCMTKFreeStringFn freeFn = HorosSRAnnotationSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
	if (freeFn)
		freeFn(value);
	return string;
}

static NSData* HorosSRAnnotationBridgeEncapsulatedDocument(NSString* path)
{
	if (path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return nil;

	HorosModernDCMTKCopyEncapsulatedDocumentFn copyDocumentFn =
		HorosSRAnnotationSymbol<HorosModernDCMTKCopyEncapsulatedDocumentFn>("HorosModernDCMTKCopyEncapsulatedDocument");
	if (copyDocumentFn == NULL)
		return nil;

	unsigned char* buffer = NULL;
	unsigned long length = 0;
	if (!copyDocumentFn(path.fileSystemRepresentation, &buffer, &length) || buffer == NULL || length == 0)
		return nil;

	NSData* data = [NSData dataWithBytes: buffer length: (NSUInteger) length];
	HorosModernDCMTKFreeBufferFn freeBufferFn = HorosSRAnnotationSymbol<HorosModernDCMTKFreeBufferFn>("HorosModernDCMTKFreeBuffer");
	if (freeBufferFn)
		freeBufferFn(buffer);
	else
		free(buffer);

	return data;
}

static NSData* HorosSRAnnotationArchiveDataByRemovingDICOMPadding(NSData* data)
{
	if (data.length < 2 || (data.length % 2) != 0)
		return data;

	const unsigned char* bytes = (const unsigned char*)data.bytes;
	if (bytes[data.length - 1] != 0)
		return data;

	return [data subdataWithRange:NSMakeRange(0, data.length - 1)];
}

static NSString* HorosSRAnnotationCopyField(NSString* path, NSString* fieldName)
{
	if (path == nil || fieldName == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return nil;

	HorosModernDCMTKCopyFieldFn copyFieldFn =
		HorosSRAnnotationSymbol<HorosModernDCMTKCopyFieldFn>("HorosModernDCMTKCopyField");
	if (copyFieldFn == NULL)
		return nil;

	return HorosSRAnnotationBridgeString(copyFieldFn(path.fileSystemRepresentation, fieldName.UTF8String));
}

static BOOL HorosSRAnnotationReadDocumentFromPath(DSRDocument* document, NSString* path)
{
	if (document == NULL || path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return NO;

	HorosModernDCMTKCopyStructuredReportXMLFn copyXMLFn =
		HorosSRAnnotationSymbol<HorosModernDCMTKCopyStructuredReportXMLFn>("HorosModernDCMTKCopyStructuredReportXML");
	if (copyXMLFn == NULL)
		return NO;

	NSString *xmlString = HorosSRAnnotationBridgeString(copyXMLFn(path.fileSystemRepresentation));
	if (xmlString.length == 0)
		return NO;

	NSString *tempXMLPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]] stringByAppendingPathExtension:@"xml"];
	BOOL wroteXML = [xmlString writeToFile:tempXMLPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	BOOL success = NO;
	if (wroteXML)
		success = document->readXML(tempXMLPath.fileSystemRepresentation, 0).good();
	[[NSFileManager defaultManager] removeItemAtPath:tempXMLPath error:nil];
	return success;
}

static BOOL HorosSRAnnotationWriteDocumentToPath(DSRDocument* document, NSString* path)
{
	if (document == NULL || path == nil)
		return NO;

	HorosModernDCMTKWriteStructuredReportFromXMLFn writeFn =
		HorosSRAnnotationSymbol<HorosModernDCMTKWriteStructuredReportFromXMLFn>("HorosModernDCMTKWriteStructuredReportFromXML");
	if (writeFn == NULL)
		return NO;

	NSString *tempXMLPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]] stringByAppendingPathExtension:@"xml"];
	size_t writeFlags = 0;
	std::ofstream stream([tempXMLPath UTF8String]);
	document->writeXML(stream, writeFlags);
	stream.close();

	BOOL success = writeFn(tempXMLPath.fileSystemRepresentation, path.fileSystemRepresentation) != 0;
	[[NSFileManager defaultManager] removeItemAtPath:tempXMLPath error:nil];
	return success;
}

+ (NSData *)roiFromDICOM:(NSString *)path
{
	if( path == nil)
		return nil;
	NSData *archiveData = HorosSRAnnotationBridgeEncapsulatedDocument(path);
	if (archiveData)
		return HorosSRAnnotationArchiveDataByRemovingDICOMPadding(archiveData);

	HorosModernDCMTKCopyBufferByTagFn copyBufferFn =
		HorosSRAnnotationSymbol<HorosModernDCMTKCopyBufferByTagFn>("HorosModernDCMTKCopyBufferByTag");
	if (copyBufferFn != NULL)
	{
		unsigned char *buffer = NULL;
		unsigned long length = 0;
		if (copyBufferFn(path.fileSystemRepresentation, 0x0071, 0x0011, &buffer, &length) && buffer != NULL && length > 0)
		{
			NSData *data = HorosSRAnnotationArchiveDataByRemovingDICOMPadding([NSData dataWithBytes:buffer length:(NSUInteger)length]);
			HorosModernDCMTKFreeBufferFn freeBufferFn = HorosSRAnnotationSymbol<HorosModernDCMTKFreeBufferFn>("HorosModernDCMTKFreeBuffer");
			if (freeBufferFn)
				freeBufferFn(buffer);
			else
				free(buffer);
			return data;
		}
	}

	return nil;
}

//All the ROIs for an image are archived as an NSArray.  We will need to extract all the necessary ROI info to create the basic SR before adding archived data. 
+ (NSString*) archiveROIsAsDICOM: (NSArray *) rois toPath: (NSString *) path forImage: (id) image
{
	SRAnnotation *sr = [[[SRAnnotation alloc] initWithROIs:rois path:path forImage:image] autorelease];
	id study = [image valueForKeyPath:@"series.study"];
	
	NSManagedObject *roiSRSeries = [study roiSRSeries];
	
	NSString *seriesInstanceUID = [roiSRSeries valueForKey:@"seriesDICOMUID"];
	
	if( seriesInstanceUID)
		[sr setSeriesInstanceUID: seriesInstanceUID];
	
	[sr writeToFileAtPath: path];
	
	return nil;
}

+ (NSString*) getImageRefSOPInstanceUID:(NSString*) path;
{
	if (path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return nil;

	HorosModernDCMTKCopyStructuredReportPrimaryReferenceFn bridgeFn =
		HorosSRAnnotationSymbol<HorosModernDCMTKCopyStructuredReportPrimaryReferenceFn>("HorosModernDCMTKCopyStructuredReportPrimaryReference");
	if (bridgeFn != NULL)
	{
		NSString *value = HorosSRAnnotationBridgeString(bridgeFn([path UTF8String]));
		if (value.length)
			return value;
	}

	return nil;
}

+ (NSString*) getReportFilenameFromSR:(NSString*) path;
{
	if (path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return nil;

	HorosModernDCMTKCopyFieldFn copyFieldFn = HorosSRAnnotationSymbol<HorosModernDCMTKCopyFieldFn>("HorosModernDCMTKCopyField");
	if (copyFieldFn == NULL)
		return nil;

	NSString* accessionNumber = HorosSRAnnotationBridgeString(copyFieldFn([path UTF8String], "AccessionNumber"));
	NSString* studyInstanceUID = HorosSRAnnotationBridgeString(copyFieldFn([path UTF8String], "StudyInstanceUID"));
	NSString* patientName = HorosSRAnnotationBridgeString(copyFieldFn([path UTF8String], "PatientName"));
	NSString* patientID = HorosSRAnnotationBridgeString(copyFieldFn([path UTF8String], "PatientID"));
	NSString* patientDOB = HorosSRAnnotationBridgeString(copyFieldFn([path UTF8String], "PatientBirthDate"));
	NSCalendarDate* DOB = [NSCalendarDate dateWithString:patientDOB calendarFormat:@"%Y%m%d"];

	if (accessionNumber == nil)
		accessionNumber = @"";
	if (patientID == nil)
		patientID = @"";
	if (patientName == nil)
		patientName = @"No name";
	if (studyInstanceUID == nil)
		studyInstanceUID = patientName;

	return [DicomFile patientUID:[NSDictionary dictionaryWithObjectsAndKeys:
		patientName, @"patientName",
		accessionNumber, @"accessionNumber",
		patientID, @"patientID",
		studyInstanceUID, @"studyInstanceUID",
		DOB, @"patientBirthDate",
		nil]];
}


#pragma mark -
#pragma mark basics

- (id)init
{
	self = [super init];

	document = new DSRDocument();
	document->createNewDocument(DSRTypes::DT_ComprehensiveSR);
				
	document->getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
	document->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("1", "99HUG", "Annotations"));
	_seriesInstanceUID = nil;
	_newSR = YES;
	
	return self;
}

- (id)initWithDictionary:(NSDictionary *) dict path:(NSString *) path forImage: (DicomImage*) im
{
	if (self = [super init])
	{
		_seriesInstanceUID = nil;
		_DICOMSRDescription =  @"OsiriX Annotations SR";
		_DICOMSeriesNumber = @"5004";
		
		[_DICOMSRDescription retain];
		[_DICOMSeriesNumber retain];
		
		document = new DSRDocument();
		_newSR = NO;
		OFCondition status = EC_Normal;
		
		// load old SR and replace as needed
		if ([[NSFileManager defaultManager] fileExistsAtPath: path])
		{
			status = HorosSRAnnotationReadDocumentFromPath(document, path) ? EC_Normal : EC_IllegalCall;
			
			//clear old content	Don't want to UIDs if already created
			if (status.good()) 
				document->getTree().clear();
		}
		
		// create new Doc 
		if (![[NSFileManager defaultManager] fileExistsAtPath: path] || !status.good())
		{
			_newSR = YES;
			document->createNewDocument(DSRTypes::DT_BasicTextSR);	
		}
			
		document->getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
		document->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("1", "99HUG", "Annotations"));
		
		document->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent);
		document->getTree().getCurrentContentItem().setConceptName( DSRCodedEntryValue("CODE_01", OFFIS_CODING_SCHEME_DESIGNATOR, "Description"));
		document->getTree().getCurrentContentItem().setStringValue( [[NSString stringWithFormat: @"%@", dict] UTF8String]);
		
		image = [im retain];
		
		_dataEncapsulated = [[NSPropertyListSerialization dataFromPropertyList:dict format:NSPropertyListXMLFormat_v1_0 errorDescription: nil] retain];
	}
	
	return self;
}

- (id)initWithWindowsState:(NSData *) dict path:(NSString *) path forImage: (DicomImage*) im
{
	if (self = [super init])
	{
		_seriesInstanceUID = nil;
		_DICOMSRDescription =  @"OsiriX WindowsState SR";
		_DICOMSeriesNumber = @"5006";
		
		[_DICOMSRDescription retain];
		[_DICOMSeriesNumber retain];
		
		document = new DSRDocument();
		_newSR = NO;
		OFCondition status = EC_Normal;
		
		// load old SR and replace as needed
		if ([[NSFileManager defaultManager] fileExistsAtPath: path])
		{
			status = HorosSRAnnotationReadDocumentFromPath(document, path) ? EC_Normal : EC_IllegalCall;
			
			//clear old content	Don't want to UIDs if already created
			if (status.good())
				document->getTree().clear();
		}
		
		// create new Doc
		if (![[NSFileManager defaultManager] fileExistsAtPath: path] || !status.good())
		{
			_newSR = YES;
			document->createNewDocument(DSRTypes::DT_BasicTextSR);
		}
        
		document->getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
		document->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("1", "99HUG", "Windows State"));
		
		document->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent);
		document->getTree().getCurrentContentItem().setConceptName( DSRCodedEntryValue("CODE_01", OFFIS_CODING_SCHEME_DESIGNATOR, "Description"));
		
		image = [im retain];
		
		_dataEncapsulated = [dict retain];
	}
	
	return self;
}

- (id)initWithFileReport:(NSString *) file path:(NSString *) path forImage: (DicomImage*) im contentDate: (NSDate*) d
{
	if (self = [super init])
	{
		_seriesInstanceUID = nil;
		_DICOMSRDescription =  @"OsiriX Report SR";
		_DICOMSeriesNumber = @"5003";
		
		if( file)
		{
			_dataEncapsulated = [[NSData dataWithContentsOfFile: file] retain];
			_contentDate = [d retain];
		}
		
		[_DICOMSRDescription retain];
		[_DICOMSeriesNumber retain];
		
		document = new DSRDocument();
		_newSR = NO;
		OFCondition status = EC_Normal;
		
		// load old SR and replace as needed
		if ([[NSFileManager defaultManager] fileExistsAtPath: path])
		{
			status = HorosSRAnnotationReadDocumentFromPath(document, path) ? EC_Normal : EC_IllegalCall;
			
			//clear old content	Don't want to UIDs if already created
			if (status.good()) 
				document->getTree().clear();
		}
		
		// create new Doc 
		if (![[NSFileManager defaultManager] fileExistsAtPath: path] || !status.good())
		{
			_newSR = YES;
			document->createNewDocument(DSRTypes::DT_BasicTextSR);	
		}
			
		document->getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
		document->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("1", "99HUG", [[NSString stringWithFormat: @"Study Report - %@ File Format", [file pathExtension]] UTF8String]));
		
		image = [im retain];
	}
	
	return self;
}

- (id)initWithROIs:(NSArray *)ROIs path:(NSString *) path forImage: (DicomImage*) im
{
	if (self = [super init])
	{
		_seriesInstanceUID = nil;
		_DICOMSRDescription =  @"OsiriX ROI SR";
		_DICOMSeriesNumber = @"5002";
		
		[_DICOMSRDescription retain];
		[_DICOMSeriesNumber retain];
		
		document = new DSRDocument();
		_newSR = NO;
		OFCondition status = EC_Normal;
		
		// load old ROI SR and replace as needed
		if ([[NSFileManager defaultManager] fileExistsAtPath: path])
		{
			status = HorosSRAnnotationReadDocumentFromPath(document, path) ? EC_Normal : EC_IllegalCall;
			
			//clear old content	Don't want to UIDs if already created
			if (status.good()) 
				document->getTree().clear();
		}
		
		// create new Doc 
		if (![[NSFileManager defaultManager] fileExistsAtPath: path] || !status.good())
		{
			_newSR = YES;
			document->createNewDocument(DSRTypes::DT_BasicTextSR);	
		}
		
		document->getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
		document->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("1", "99HUG", "ROI Annotations"));
		
		image = [im retain];
		
		[self addROIs: ROIs];
	}
	return self;
}

- (id) initWithContentsOfFile:(NSString *)path
{
    if( path == nil)
    {
        N2LogStackTrace( @"SRAnnotation initWithContentsOfFile, path == nil", path);
        return nil;
    }
    
	if (self = [super init])
	{
		document = new DSRDocument();
		OFCondition status = EC_Normal;
		
		// load data
		if ([[NSFileManager defaultManager] fileExistsAtPath:path])
		{
			HorosModernDCMTKCopyStructuredReportRootCodeMeaningFn rootMeaningFn =
				HorosSRAnnotationSymbol<HorosModernDCMTKCopyStructuredReportRootCodeMeaningFn>("HorosModernDCMTKCopyStructuredReportRootCodeMeaning");

			status = HorosSRAnnotationReadDocumentFromPath(document, path) ? EC_Normal : EC_IllegalCall;

			NSData *encapsulated = HorosSRAnnotationBridgeEncapsulatedDocument(path);
			if (encapsulated)
			{
				@try
				{
					_dataEncapsulated = [encapsulated retain];
				}
				
				@catch( NSException *ne)
				{
					NSLog( @"******* SRAnnotation exception: %@", [ne description]);
				}
			}
			
			_reportURL = (rootMeaningFn != NULL) ? [HorosSRAnnotationBridgeString(rootMeaningFn([path UTF8String])) retain] : nil;
			if (_reportURL == nil)
			{
				const char *codeMeaning = document->getTree().getCurrentContentItem().getConceptName().getCodeMeaning().c_str();
				if (codeMeaning)
					_reportURL = [[NSString stringWithUTF8String: codeMeaning] retain];
			}
			
			NSString *prefix = @"URL:";
			
			if( [_reportURL hasPrefix: prefix])
				_reportURL = [[_reportURL substringFromIndex: [prefix length]] retain];
			else
				_reportURL = nil;
		}
	}
	return self;
}

- (NSDictionary*) annotations
{
	NSDictionary *dict = nil;
	
	@try
	{
        dict = [NSPropertyListSerialization propertyListFromData: _dataEncapsulated  mutabilityOption: NSPropertyListImmutable format: nil errorDescription: nil];
	}
	@catch( NSException *e)
	{
		N2LogExceptionWithStackTrace(e);
	}
	
	return dict;
}

- (NSString*) reportURL
{
	return _reportURL;
}

- (id)initWithURLReport:(NSString *) s path:(NSString *) path forImage: (DicomImage*) im
{
	if (self = [super init])
	{
		_seriesInstanceUID = nil;
		_DICOMSRDescription =  @"OsiriX Report SR";
		_DICOMSeriesNumber = @"5003";
		
		[_DICOMSRDescription retain];
		[_DICOMSeriesNumber retain];
		
		_contentDate = [[NSDate date] retain];
		
		document = new DSRDocument();
		_newSR = NO;
		OFCondition status = EC_Normal;
		
		// load old SR and replace as needed
		if ([[NSFileManager defaultManager] fileExistsAtPath: path])
		{
			status = HorosSRAnnotationReadDocumentFromPath(document, path) ? EC_Normal : EC_IllegalCall;
			
			//clear old content	Don't want to UIDs if already created
			if (status.good()) 
				document->getTree().clear();
		}
		
		// create new Doc 
		if (![[NSFileManager defaultManager] fileExistsAtPath: path] || !status.good())
		{
			_newSR = YES;
			document->createNewDocument(DSRTypes::DT_BasicTextSR);	
		}
			
		document->getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
		document->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("1", "99HUG", [[NSString stringWithFormat: @"URL:%@", s] UTF8String]));
		
		image = [im retain];
	}
	
	return self;
}

- (void)dealloc
{
	delete document;
	[_DICOMSRDescription release];
	[_contentDate release];
	[_DICOMSeriesNumber release];
	[image release];
	[_dataEncapsulated release];
	[_seriesInstanceUID release];
	[super dealloc];
}

- (NSData*) dataEncapsulated
{
	return _dataEncapsulated;
}

#pragma mark -
#pragma mark ROIs

- (void) addROIs: (NSArray *) someROIs;
{
	if( !_dataEncapsulated)
		_dataEncapsulated = [[NSArchiver archivedDataWithRootObject: [NSArray array]] retain];
		
	NSArray *preExistingROIs = [NSUnarchiver unarchiveObjectWithData: _dataEncapsulated];
	
//	for( ROI *aROI in someROIs)
//	{
//		NSData *newROIData = [aROI data];
//		
//		BOOL newROI = YES;
//		for( ROI *roi in preExistingROIs)
//		{
//			if ([newROIData isEqualToData: [roi data]])
//			{
//				newROI = NO;
//				break;
//			}
//		}
//	}
	
	NSArray *newROIs = [preExistingROIs arrayByAddingObjectsFromArray: someROIs];
	
	[_dataEncapsulated release];
	_dataEncapsulated = [[NSArchiver archivedDataWithRootObject: newROIs] retain];
}

- (NSArray *) ROIs
{
	return [NSUnarchiver unarchiveObjectWithData: _dataEncapsulated];
}

#pragma mark -
#pragma mark DICOM write

- (BOOL)writeToFileAtPath:(NSString *)path
{
	id study = [image valueForKeyPath:@"series.study"];
	NSString *sourcePatientBirthDate = nil;
	NSString *sourcePatientID = nil;
	NSString *sourcePatientSex = nil;
	NSString *canonicalPatientName = nil;
	NSString *canonicalPatientID = nil;
	NSString *canonicalPatientBirthDate = nil;

	NSString *patientUID = [study valueForKey:@"patientUID"];
	if (patientUID.length)
	{
		NSRange lastDash = [patientUID rangeOfString:@"-" options:NSBackwardsSearch];
		if (lastDash.location != NSNotFound)
		{
			NSString *prefix = [patientUID substringToIndex:lastDash.location];
			canonicalPatientBirthDate = [[patientUID substringFromIndex:lastDash.location + 1] retain];

			NSRange secondLastDash = [prefix rangeOfString:@"-" options:NSBackwardsSearch];
			if (secondLastDash.location != NSNotFound)
			{
				canonicalPatientName = [[prefix substringToIndex:secondLastDash.location] retain];
				canonicalPatientID = [[prefix substringFromIndex:secondLastDash.location + 1] retain];
			}
		}
	}
	
	//	Don't want to UIDs if already created
	if( _newSR)
	{
		//add to Study
		document->createNewSeriesInStudy([[study valueForKey:@"studyInstanceUID"] UTF8String]);
	}
	
	NSNumber *v = [NSNumber numberWithInt: [[image valueForKey:@"frameID"] intValue]];
	
	document->setInstanceNumber( [[v stringValue] UTF8String]);
	
	// Add metadata for DICOM
    
    // We want the original patient's name
    if( [[NSFileManager defaultManager] fileExistsAtPath: image.completePath])
    {
        NSString *specificCharacterSet = HorosSRAnnotationCopyField(image.completePath, @"SpecificCharacterSet");
        if (specificCharacterSet.length)
        {
            document->setSpecificCharacterSet(specificCharacterSet.UTF8String);
        }

        NSArray *encodingArray = specificCharacterSet.length ? [specificCharacterSet componentsSeparatedByString:@"\\"] : nil;
        
        if( encodingArray == nil)
            encodingArray = [NSArray arrayWithObject: @"ISO_IR 100"];
        
        NSStringEncoding encoding = [NSString encodingForDICOMCharacterSet: [encodingArray objectAtIndex: 0]];

        NSString *patientName = HorosSRAnnotationCopyField(image.completePath, @"PatientsName");
        if (patientName.length)
            document->setPatientName(patientName.UTF8String);

        NSString *referringPhysician = HorosSRAnnotationCopyField(image.completePath, @"ReferringPhysiciansName");
        if (referringPhysician.length)
            document->setReferringPhysicianName(referringPhysician.UTF8String);

        NSString *studyDescription = HorosSRAnnotationCopyField(image.completePath, @"StudyDescription");
        if (studyDescription.length)
            document->setStudyDescription(studyDescription.UTF8String);

        sourcePatientBirthDate = [HorosSRAnnotationCopyField(image.completePath, @"PatientsBirthDate") retain];
        sourcePatientID = [HorosSRAnnotationCopyField(image.completePath, @"PatientID") retain];
        sourcePatientSex = [HorosSRAnnotationCopyField(image.completePath, @"PatientsSex") retain];
        
        if( _DICOMSRDescription.length)
        {
            NSMutableData *data = [NSMutableData dataWithData: [_DICOMSRDescription dataUsingEncoding:encoding allowLossyConversion: YES]];
            unsigned char zeroByte = 0;
            [data appendBytes:&zeroByte length:1];
            
            if( [data bytes])
                document->setSeriesDescription( (char*) [data bytes]);
        }
            
//            if ([[study valueForKey:@"studyName"] length])
//            {
//                NSMutableData *data = [NSMutableData dataWithData: [[study valueForKey:@"studyName"] dataUsingEncoding:encoding allowLossyConversion: YES]];
//                unsigned char zeroByte = 0;
//                [data appendBytes:&zeroByte length:1];
//                
//                if( [data bytes])
//                    document->setStudyDescription( (char*) [data bytes]);
//            }
    }
    else
    {
        document->setSpecificCharacterSet( "ISO_IR 192"); // UTF-8
        
        if( [study valueForKey:@"name"])
            document->setPatientName([[study valueForKey:@"name"] UTF8String]);
        
        if ([study valueForKey:@"referringPhysician"])
            document->setReferringPhysicianName([[study valueForKey:@"referringPhysician"] UTF8String]);
        
        if( _DICOMSRDescription)
            document->setSeriesDescription( [_DICOMSRDescription UTF8String]);
        
        if ([study valueForKey:@"studyName"])
            document->setStudyDescription([[study valueForKey:@"studyName"] UTF8String]);
    }
    
	if (canonicalPatientBirthDate.length)
		document->setPatientBirthDate([canonicalPatientBirthDate UTF8String]);
	else if ([study valueForKey:@"dateOfBirth"])
		document->setPatientBirthDate([[[study valueForKey:@"dateOfBirth"] descriptionWithCalendarFormat:@"%Y%m%d" timeZone:nil locale:nil] UTF8String]);
		
	if ([study valueForKey:@"patientSex"])
		document->setPatientSex([[study valueForKey:@"patientSex"] UTF8String]);
	
	NSString *patientID = [study valueForKey:@"patientID"];
	if (canonicalPatientID.length)
		patientID = canonicalPatientID;
	
	if (patientID)
		document->setPatientID([patientID UTF8String]);
	
	if ([study valueForKey:@"id"])
	{
		NSString *studyID = [study valueForKey:@"id"];
		document->setStudyID([studyID UTF8String]);
	}
	
	if ([study valueForKey:@"accessionNumber"])
		document->setAccessionNumber( [[study valueForKey:@"accessionNumber"] UTF8String]);
	
	document->setManufacturer( [@"Horos" UTF8String]);
	
	if( _DICOMSeriesNumber)
		document->setSeriesNumber( [_DICOMSeriesNumber UTF8String]);
	
	if( _contentDate)
	{
		document->setContentDate( [[[DCMCalendarDate dicomDateWithDate: _contentDate] dateString] UTF8String]);
		document->setContentTime( [[[DCMCalendarDate dicomTimeWithDate: _contentDate] timeString] UTF8String]);
	}
	else
	{
		if( [_DICOMSRDescription isEqualToString: @"OsiriX Report SR"] == NO)
		{
			document->setContentDate( [[[DCMCalendarDate date] dateString] UTF8String]);
			document->setContentTime( [[[DCMCalendarDate date] timeString] UTF8String]);
		}
		else if( [_dataEncapsulated length] > 0)
			NSLog( @"********** no date for Report SR ?");
	}
	
	// Image Reference
	OFString refsopClassUID = OFString([[image valueForKeyPath:@"series.seriesSOPClassUID"] UTF8String]);
	OFString refsopInstanceUID = OFString([[image valueForKey:@"sopInstanceUID"] UTF8String]);
	
	document->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, DSRTypes::AM_belowCurrent);
	document->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("IHE.10", "99HUG", "Image Reference"));

	DSRImageReferenceValue imageRef( refsopClassUID, refsopInstanceUID);
	
	// add frame reference
	imageRef.getFrameList().putString([[[image valueForKey: @"frameID"] stringValue] UTF8String]);
	document->getTree().getCurrentContentItem().setImageReference( imageRef);
	document->getTree().goUp(); // go up to the root element
	
	OFCondition status = EC_Normal;
	BOOL isROISR = [_DICOMSRDescription isEqualToString:@"OsiriX ROI SR"];
	BOOL isCompatibilityStructuredReport =
		[_DICOMSRDescription isEqualToString:@"OsiriX Annotations SR"] ||
		[_DICOMSRDescription isEqualToString:@"OsiriX WindowsState SR"] ||
		[_DICOMSRDescription isEqualToString:@"OsiriX Report SR"];
	BOOL writeSucceeded = NO;
	BOOL wroteViaBridge = NO;

	if (isROISR)
	{
		HorosModernDCMTKWriteCompatibilityROIStructuredReportFn writeROIFn =
			HorosSRAnnotationSymbol<HorosModernDCMTKWriteCompatibilityROIStructuredReportFn>("HorosModernDCMTKWriteCompatibilityROIStructuredReport");
		NSString *studyInstanceUID = [study valueForKey:@"studyInstanceUID"];
		NSString *seriesInstanceUID = _seriesInstanceUID ?: [self seriesInstanceUID];
		OFString generatedSOPInstanceUIDStorage;
		document->getSOPInstanceUID(generatedSOPInstanceUIDStorage);
		const char *generatedSOPInstanceUID = generatedSOPInstanceUIDStorage.c_str();
		NSString *studyDescription = [study valueForKey:@"studyName"];
		if (studyDescription.length == 0)
			studyDescription = [study valueForKey:@"name"];
		
		NSString *patientName = canonicalPatientName.length ? canonicalPatientName : [study valueForKey:@"name"];
		NSString *referringPhysician = [study valueForKey:@"referringPhysician"];
		NSString *referencedSOPInstanceUID = [image valueForKey:@"sopInstanceUID"];
		NSNumber *referencedFrameID = [image valueForKey:@"frameID"];
		NSString *studyID = [study valueForKey:@"id"];
		NSString *accessionNumber = [study valueForKey:@"accessionNumber"];
		NSString *seriesSOPClassUID = [image valueForKeyPath:@"series.seriesSOPClassUID"];
		NSString *resolvedPatientID = canonicalPatientID.length ? canonicalPatientID : patientID;
		if (sourcePatientID.length)
			resolvedPatientID = sourcePatientID;
		NSString *resolvedPatientBirthDate = canonicalPatientBirthDate;
		if (resolvedPatientBirthDate.length == 0 && sourcePatientBirthDate.length)
			resolvedPatientBirthDate = sourcePatientBirthDate;
		if (resolvedPatientBirthDate.length == 0 && [study valueForKey:@"dateOfBirth"])
			resolvedPatientBirthDate = [[study valueForKey:@"dateOfBirth"] descriptionWithCalendarFormat:@"%Y%m%d" timeZone:nil locale:nil];
		NSString *resolvedPatientSex = sourcePatientSex.length ? sourcePatientSex : [study valueForKey:@"patientSex"];
		NSString *contentDateString = nil;
		NSString *contentTimeString = nil;
		if (_contentDate)
		{
			contentDateString = [[DCMCalendarDate dicomDateWithDate:_contentDate] dateString];
			contentTimeString = [[DCMCalendarDate dicomTimeWithDate:_contentDate] timeString];
		}
		else
		{
			contentDateString = [[DCMCalendarDate date] dateString];
			contentTimeString = [[DCMCalendarDate date] timeString];
		}

		if (writeROIFn != NULL)
		{
			const unsigned char *buffer = _dataEncapsulated ? (const unsigned char *)[_dataEncapsulated bytes] : NULL;
			const char *sopUIDCString = (generatedSOPInstanceUID && generatedSOPInstanceUID[0] != 0) ? generatedSOPInstanceUID : NULL;
			writeSucceeded = writeROIFn(path.fileSystemRepresentation,
							sopUIDCString,
							seriesInstanceUID.UTF8String,
							studyInstanceUID.UTF8String,
							studyDescription.UTF8String,
							patientName.UTF8String,
							resolvedPatientBirthDate.UTF8String,
							resolvedPatientSex.UTF8String,
							resolvedPatientID.UTF8String,
							referringPhysician.UTF8String,
							studyID.UTF8String,
							accessionNumber.UTF8String,
							_DICOMSRDescription.UTF8String,
							_DICOMSeriesNumber.UTF8String,
							"Horos",
							contentDateString.UTF8String,
							contentTimeString.UTF8String,
							seriesSOPClassUID.UTF8String,
							referencedSOPInstanceUID.UTF8String,
							(referencedFrameID && [referencedFrameID intValue] > 0) ? [[referencedFrameID stringValue] UTF8String] : NULL,
							buffer,
							_dataEncapsulated ? [_dataEncapsulated length] : 0);
			wroteViaBridge = writeSucceeded;
		}
	}
	else if (isCompatibilityStructuredReport)
	{
		HorosModernDCMTKWriteCompatibilityStructuredReportFn writeCompatibilityFn =
			HorosSRAnnotationSymbol<HorosModernDCMTKWriteCompatibilityStructuredReportFn>("HorosModernDCMTKWriteCompatibilityStructuredReport");
		NSString *studyInstanceUID = [study valueForKey:@"studyInstanceUID"];
		NSString *seriesInstanceUID = _seriesInstanceUID ?: [self seriesInstanceUID];
		OFString generatedSOPInstanceUIDStorage;
		document->getSOPInstanceUID(generatedSOPInstanceUIDStorage);
		const char *generatedSOPInstanceUID = generatedSOPInstanceUIDStorage.c_str();
		NSString *studyDescription = [study valueForKey:@"studyName"];
		if (studyDescription.length == 0)
			studyDescription = [study valueForKey:@"name"];
		NSString *patientName = canonicalPatientName.length ? canonicalPatientName : [study valueForKey:@"name"];
		NSString *referringPhysician = [study valueForKey:@"referringPhysician"];
		NSString *referencedSOPInstanceUID = [image valueForKey:@"sopInstanceUID"];
		NSNumber *referencedFrameID = [image valueForKey:@"frameID"];
		NSString *studyID = [study valueForKey:@"id"];
		NSString *accessionNumber = [study valueForKey:@"accessionNumber"];
		NSString *seriesSOPClassUID = [image valueForKeyPath:@"series.seriesSOPClassUID"];
		NSString *resolvedPatientID = canonicalPatientID.length ? canonicalPatientID : patientID;
		if (sourcePatientID.length)
			resolvedPatientID = sourcePatientID;
		NSString *resolvedPatientBirthDate = canonicalPatientBirthDate;
		if (resolvedPatientBirthDate.length == 0 && sourcePatientBirthDate.length)
			resolvedPatientBirthDate = sourcePatientBirthDate;
		if (resolvedPatientBirthDate.length == 0 && [study valueForKey:@"dateOfBirth"])
			resolvedPatientBirthDate = [[study valueForKey:@"dateOfBirth"] descriptionWithCalendarFormat:@"%Y%m%d" timeZone:nil locale:nil];
		NSString *resolvedPatientSex = sourcePatientSex.length ? sourcePatientSex : [study valueForKey:@"patientSex"];
		NSString *contentDateString = nil;
		NSString *contentTimeString = nil;
		if (_contentDate)
		{
			contentDateString = [[DCMCalendarDate dicomDateWithDate:_contentDate] dateString];
			contentTimeString = [[DCMCalendarDate dicomTimeWithDate:_contentDate] timeString];
		}
		else
		{
			contentDateString = [[DCMCalendarDate date] dateString];
			contentTimeString = [[DCMCalendarDate date] timeString];
		}
		NSString *rootCodeMeaning = [NSString stringWithUTF8String:document->getTree().getCurrentContentItem().getConceptName().getCodeMeaning().c_str()];
		NSString *childTextValue = nil;
		if ([_DICOMSRDescription isEqualToString:@"OsiriX Annotations SR"])
			childTextValue = [NSString stringWithFormat:@"%@", [self annotations]];
		
		if (writeCompatibilityFn != NULL)
		{
			const unsigned char *buffer = _dataEncapsulated ? (const unsigned char *)[_dataEncapsulated bytes] : NULL;
			const char *sopUIDCString = (generatedSOPInstanceUID && generatedSOPInstanceUID[0] != 0) ? generatedSOPInstanceUID : NULL;
			writeSucceeded = writeCompatibilityFn(path.fileSystemRepresentation,
							  sopUIDCString,
							  seriesInstanceUID.UTF8String,
							  studyInstanceUID.UTF8String,
							  studyDescription.UTF8String,
							  patientName.UTF8String,
							  resolvedPatientBirthDate.UTF8String,
							  resolvedPatientSex.UTF8String,
							  resolvedPatientID.UTF8String,
							  referringPhysician.UTF8String,
							  studyID.UTF8String,
							  accessionNumber.UTF8String,
							  _DICOMSRDescription.UTF8String,
							  _DICOMSeriesNumber.UTF8String,
							  "Horos",
							  contentDateString.UTF8String,
							  contentTimeString.UTF8String,
							  seriesSOPClassUID.UTF8String,
							  referencedSOPInstanceUID.UTF8String,
							  (referencedFrameID && [referencedFrameID intValue] > 0) ? [[referencedFrameID stringValue] UTF8String] : NULL,
							  rootCodeMeaning.UTF8String,
							  childTextValue.UTF8String,
							  buffer,
							  _dataEncapsulated ? [_dataEncapsulated length] : 0);
			wroteViaBridge = writeSucceeded;
		}
	}
	else
	{
		document->getCodingSchemeIdentification().addPrivateDcmtkCodingScheme();
		writeSucceeded = HorosSRAnnotationWriteDocumentToPath(document, path);
		wroteViaBridge = writeSucceeded;
	}

	if (writeSucceeded && wroteViaBridge && !isROISR && !isCompatibilityStructuredReport)
	{
		HorosModernDCMTKReplaceTagValueFn replaceTagFn =
			HorosSRAnnotationSymbol<HorosModernDCMTKReplaceTagValueFn>("HorosModernDCMTKReplaceTagValue");
		HorosModernDCMTKWriteBufferByTagFn writeBufferFn =
			HorosSRAnnotationSymbol<HorosModernDCMTKWriteBufferByTagFn>("HorosModernDCMTKWriteBufferByTag");
		OFString generatedSOPInstanceUIDStorage;
		document->getSOPInstanceUID(generatedSOPInstanceUIDStorage);
		const char *generatedSOPInstanceUID = generatedSOPInstanceUIDStorage.c_str();
		NSString *studyInstanceUID = [study valueForKey:@"studyInstanceUID"];
		NSString *studyDescription = [study valueForKey:@"studyName"];
		if (studyDescription.length == 0)
			studyDescription = [study valueForKey:@"name"];
		NSString *patientName = canonicalPatientName.length ? canonicalPatientName : [study valueForKey:@"name"];
		NSString *referringPhysician = [study valueForKey:@"referringPhysician"];
		NSString *referencedSOPInstanceUID = [image valueForKey:@"sopInstanceUID"];
		NSNumber *referencedFrameID = [image valueForKey:@"frameID"];
		NSString *resolvedPatientID = canonicalPatientID.length ? canonicalPatientID : patientID;
		if (sourcePatientID.length)
			resolvedPatientID = sourcePatientID;
		NSString *resolvedPatientBirthDate = canonicalPatientBirthDate;
		if (resolvedPatientBirthDate.length == 0 && sourcePatientBirthDate.length)
			resolvedPatientBirthDate = sourcePatientBirthDate;
		if (resolvedPatientBirthDate.length == 0 && [study valueForKey:@"dateOfBirth"])
			resolvedPatientBirthDate = [[study valueForKey:@"dateOfBirth"] descriptionWithCalendarFormat:@"%Y%m%d" timeZone:nil locale:nil];

		if (replaceTagFn != NULL)
		{
			replaceTagFn(path.fileSystemRepresentation, 0x0020, 0x000D, studyInstanceUID.UTF8String, studyInstanceUID.length == 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0020, 0x000E, _seriesInstanceUID ? _seriesInstanceUID.UTF8String : NULL, _seriesInstanceUID == nil);
			replaceTagFn(path.fileSystemRepresentation, 0x0008, 0x0018, generatedSOPInstanceUID, generatedSOPInstanceUID == NULL || generatedSOPInstanceUID[0] == 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0008, 0x0060, "SR", 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0020, 0x0011, _DICOMSeriesNumber.UTF8String, _DICOMSeriesNumber == nil);
			replaceTagFn(path.fileSystemRepresentation, 0x0008, 0x103E, _DICOMSRDescription.UTF8String, _DICOMSRDescription == nil);
			replaceTagFn(path.fileSystemRepresentation, 0x0008, 0x1030, studyDescription.UTF8String, studyDescription.length == 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0010, 0x0010, patientName.UTF8String, patientName.length == 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0008, 0x0090, referringPhysician.UTF8String, referringPhysician.length == 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0010, 0x0020, resolvedPatientID.UTF8String, resolvedPatientID.length == 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0010, 0x0030, resolvedPatientBirthDate.UTF8String, resolvedPatientBirthDate.length == 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0010, 0x0040, sourcePatientSex.UTF8String, sourcePatientSex.length == 0);
			replaceTagFn(path.fileSystemRepresentation, 0x0020, 0x0010, [[study valueForKey:@"id"] UTF8String], [study valueForKey:@"id"] == nil);
			replaceTagFn(path.fileSystemRepresentation, 0x0008, 0x0050, [[study valueForKey:@"accessionNumber"] UTF8String], [study valueForKey:@"accessionNumber"] == nil);
			replaceTagFn(path.fileSystemRepresentation, 0x0008, 0x1155, referencedSOPInstanceUID.UTF8String, referencedSOPInstanceUID.length == 0);
			if (referencedFrameID && [referencedFrameID intValue] > 0)
				replaceTagFn(path.fileSystemRepresentation, 0x0008, 0x1160, [[referencedFrameID stringValue] UTF8String], 0);
		}

		if (_dataEncapsulated && writeBufferFn != NULL)
		{
			const unsigned char *buffer = (const unsigned char *)[_dataEncapsulated bytes];
			if (buffer)
				writeBufferFn(path.fileSystemRepresentation, 0x0042, 0x0011, buffer, (unsigned long)[_dataEncapsulated length]);
		}
	}
	[canonicalPatientName release];
	[canonicalPatientID release];
	[canonicalPatientBirthDate release];
	[sourcePatientBirthDate release];
	[sourcePatientID release];
	[sourcePatientSex release];
	
	return writeSucceeded;
}

- (NSString *)seriesInstanceUID
{
	if (!_seriesInstanceUID)
	{
		OFString seriesInstanceUID;
		document->getSeriesInstanceUID(seriesInstanceUID);
		_seriesInstanceUID = [[NSString stringWithUTF8String:seriesInstanceUID.c_str()] retain];
	}
	return _seriesInstanceUID;
}

- (void)setSeriesInstanceUID: (NSString *)seriesInstanceUID
{
	[_seriesInstanceUID release];
	_seriesInstanceUID = [seriesInstanceUID retain];
}

- (NSString *)sopInstanceUID{
	OFString sopInstanceUID;
	document->getSOPInstanceUID(sopInstanceUID);
	return [NSString stringWithUTF8String:sopInstanceUID.c_str()];
}

- (NSString *)sopClassUID{
	OFString sopClassUID;
	document->getSOPClassUID(sopClassUID);
	return [NSString stringWithUTF8String:sopClassUID.c_str()];
}

- (NSString *)seriesDescription{
	OFString seriesDescription;
	if (document->getSeriesDescription(seriesDescription).good()) return [NSString stringWithUTF8String:seriesDescription.c_str()];
	else return @"";
}

- (NSString *)seriesNumber{
	OFString seriesNumber;
	if (document->getSeriesNumber(seriesNumber).good()) return [NSString stringWithUTF8String:seriesNumber.c_str()];
	else return @"";
}
@end
