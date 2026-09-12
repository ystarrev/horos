/*=========================================================================
  Program:   OsiriX

  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.

     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
=========================================================================*/

#import "KeyObjectReport.h"
#import "DicomStudy.h"
#import "ModernDCMTKBridge.h"
#import "HorosDCMTKBridgeLoader.h"

typedef __typeof__(&HorosModernDCMTKCopyGeneratedUID) HorosModernDCMTKCopyGeneratedUIDFn;
typedef __typeof__(&HorosModernDCMTKCopyStructuredReportHTML) HorosModernDCMTKCopyStructuredReportHTMLFn;
typedef __typeof__(&HorosModernDCMTKWriteKeyObjectReport) HorosModernDCMTKWriteKeyObjectReportFn;
typedef __typeof__(&HorosModernDCMTKFreeString) HorosModernDCMTKFreeStringFn;

static NSString* HorosISODateStringFromDate(NSDate* date)
{
	if (date == nil)
		return nil;
	static NSDateFormatter* formatter = nil;
	if (formatter == nil)
	{
		formatter = [[NSDateFormatter alloc] init];
		[formatter setDateFormat:@"yyyyMMdd"];
	}
	return [formatter stringFromDate:date];
}

static NSArray* HorosKeyObjectValidImageDictionaries(NSArray* keyImages)
{
	NSMutableArray* rows = [NSMutableArray array];
	for (id image in keyImages)
	{
		NSString* imagePath = [image valueForKey:@"completePath"];
		NSString* imageSeriesUID = [image valueForKeyPath:@"series.seriesDICOMUID"];
		NSString* imageSOPInstanceUID = [image valueForKey:@"sopInstanceUID"];
		if (imagePath.length == 0 || imageSeriesUID.length == 0 || imageSOPInstanceUID.length == 0)
			continue;
		[rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:
			imagePath, @"path",
			imageSeriesUID, @"seriesUID",
			imageSOPInstanceUID, @"sopInstanceUID",
			nil]];
	}
	return rows;
}

@implementation KeyObjectReport

- (id)initWithStudy:(id)study title:(int)title description:(NSString *)keyDescription seriesUID:(NSString *)seriesUID
{
	if (self = [super init])
	{
		_study = [study retain];
		_keyDescription = [keyDescription retain];
		_title = title;
		_seriesUID = [seriesUID retain];
		[self createKO];
	}
	return self;
}

- (void)createKO
{
	[_keyImages release];
	_keyImages = [[[(DicomStudy*)_study keyImages] allObjects] retain];

	[_sopInstanceUID release];
	_sopInstanceUID = nil;

	HorosModernDCMTKCopyGeneratedUIDFn generateUIDFn = HorosDCMTKFunction(HorosModernDCMTKCopyGeneratedUID);
	HorosModernDCMTKFreeStringFn freeStringFn = HorosDCMTKFunction(HorosModernDCMTKFreeString);
	char* generatedUID = generateUIDFn ? generateUIDFn() : NULL;
	if (generatedUID != NULL)
	{
		_sopInstanceUID = [[NSString stringWithUTF8String:generatedUID] retain];
		if (freeStringFn)
			freeStringFn(generatedUID);
	}
}

- (void)dealloc
{
	[_study release];
	[_keyImages release];
	[_keyDescription release];
	[_seriesUID release];
	[_sopInstanceUID release];
	[super dealloc];
}

- (BOOL)writeFileAtPath:(NSString *)path
{
	NSArray* imageRows = HorosKeyObjectValidImageDictionaries(_keyImages);
	const int imageCount = (int)[imageRows count];

	const char** imagePaths = imageCount > 0 ? (const char**)calloc(imageCount, sizeof(const char*)) : NULL;
	const char** imageSeriesUIDs = imageCount > 0 ? (const char**)calloc(imageCount, sizeof(const char*)) : NULL;
	const char** imageSOPInstanceUIDs = imageCount > 0 ? (const char**)calloc(imageCount, sizeof(const char*)) : NULL;

	for (int index = 0; index < imageCount; ++index)
	{
		NSDictionary* row = [imageRows objectAtIndex:index];
		imagePaths[index] = [[row objectForKey:@"path"] UTF8String];
		imageSeriesUIDs[index] = [[row objectForKey:@"seriesUID"] UTF8String];
		imageSOPInstanceUIDs[index] = [[row objectForKey:@"sopInstanceUID"] UTF8String];
	}

	HorosModernDCMTKWriteKeyObjectReportFn writeReportFn = HorosDCMTKFunction(HorosModernDCMTKWriteKeyObjectReport);
	if (writeReportFn == NULL)
	{
		free(imagePaths);
		free(imageSeriesUIDs);
		free(imageSOPInstanceUIDs);
		return NO;
	}

	const int success = writeReportFn(
		[path UTF8String],
		[_sopInstanceUID UTF8String],
		[_seriesUID UTF8String],
		[[_study valueForKey:@"studyInstanceUID"] UTF8String],
		[[_study valueForKey:@"studyName"] UTF8String],
		[[_study valueForKey:@"name"] UTF8String],
		[HorosISODateStringFromDate([_study valueForKey:@"dateOfBirth"]) UTF8String],
		[[_study valueForKey:@"patientSex"] UTF8String],
		[[_study valueForKey:@"patientID"] UTF8String],
		[[_study valueForKey:@"referringPhysician"] UTF8String],
		[[[_study valueForKey:@"id"] description] UTF8String],
		[[_study valueForKey:@"accessionNumber"] UTF8String],
		_title,
		[_keyDescription UTF8String],
		imagePaths,
		imageSeriesUIDs,
		imageSOPInstanceUIDs,
		imageCount);

	free(imagePaths);
	free(imageSeriesUIDs);
	free(imageSOPInstanceUIDs);

	if (success)
		return YES;

	NSLog(@"KO Write failed");
	return NO;
}

- (BOOL)writeHTMLAtPath:(NSString *)path
{
	NSString* temporaryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"horos-ko-%@.dcm", _sopInstanceUID ?: @"tmp"]];
	if (![self writeFileAtPath:temporaryPath])
		return NO;

	HorosModernDCMTKCopyStructuredReportHTMLFn renderHTMLFn = HorosDCMTKFunction(HorosModernDCMTKCopyStructuredReportHTML);
	HorosModernDCMTKFreeStringFn freeStringFn = HorosDCMTKFunction(HorosModernDCMTKFreeString);
	char* html = renderHTMLFn ? renderHTMLFn([temporaryPath UTF8String]) : NULL;
	[[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
	if (html == NULL)
		return NO;

	NSString* htmlString = [NSString stringWithUTF8String:html];
	if (freeStringFn)
		freeStringFn(html);
	if (htmlString == nil)
		return NO;

	return [htmlString writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)sopInstanceUID
{
	return _sopInstanceUID;
}

@end
