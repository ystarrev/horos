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

#import "StructuredReport.h"
#import "browserController.h"
#import "DicomImage.h"
#import "DICOMToNSString.h"
#import "ModernDCMTKBridge.h"

#include <dlfcn.h>
#undef verify

#include <dcmtk/config/osconfig.h>    /* make sure OS specific configuration is included first */
#include <dcmtk/ofstd/ofstream.h>
#define DicomImage DCMTKDicomImage
#include <dcmtk/dcmsr/dsrdoc.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmsr/dsrtypes.h>
#include <dcmtk/dcmsr/dsrimgtn.h>
#include <dcmtk/dcmsr/dsrdoctr.h>
#undef DicomImage

typedef char* (*HorosModernDCMTKCopyStructuredReportHTMLFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportXMLFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn)(const char* path);
typedef char* (*HorosModernDCMTKCopyStructuredReportNamedTextValueFn)(const char* path, const char* codeValue, const char* codingSchemeDesignator, const char* codeMeaning);
typedef char* (*HorosModernDCMTKCopyStructuredReportNamedTextValuesFn)(const char* path, const char* codeValue, const char* codingSchemeDesignator, const char* codeMeaning);
typedef char* (*HorosModernDCMTKCopyFieldFn)(const char* path, const char* fieldName);
typedef int (*HorosModernDCMTKWriteStructuredReportFromXMLFn)(const char* xmlPath, const char* dicomPath);
typedef void (*HorosModernDCMTKFreeStringFn)(char* value);

static void* HorosStructuredReportBridgeHandle()
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
static FunctionType HorosStructuredReportSymbol(const char* name)
{
	void* handle = HorosStructuredReportBridgeHandle();
	if (handle == NULL)
		return NULL;
	return reinterpret_cast<FunctionType>(dlsym(handle, name));
}

static NSString* HorosStructuredReportBridgeString(char* value)
{
	if (value == NULL)
		return nil;
	NSString* string = [NSString stringWithUTF8String:value];
	HorosModernDCMTKFreeStringFn freeFn = HorosStructuredReportSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
	if (freeFn)
		freeFn(value);
	return string;
}

static NSString* HorosStructuredReportCopyField(NSString* path, NSString* fieldName)
{
	if (path == nil || fieldName == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return nil;

	HorosModernDCMTKCopyFieldFn copyFieldFn =
		HorosStructuredReportSymbol<HorosModernDCMTKCopyFieldFn>("HorosModernDCMTKCopyField");
	if (copyFieldFn == NULL)
		return nil;

	return HorosStructuredReportBridgeString(copyFieldFn(path.fileSystemRepresentation, fieldName.UTF8String));
}

static NSString* HorosStructuredReportCopyNamedTextValue(NSString* path, NSString* codeValue, NSString* codingSchemeDesignator, NSString* codeMeaning)
{
	if (path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return nil;

	HorosModernDCMTKCopyStructuredReportNamedTextValueFn copyValueFn =
		HorosStructuredReportSymbol<HorosModernDCMTKCopyStructuredReportNamedTextValueFn>("HorosModernDCMTKCopyStructuredReportNamedTextValue");
	if (copyValueFn == NULL)
		return nil;

	return HorosStructuredReportBridgeString(copyValueFn(path.fileSystemRepresentation,
	                                                     codeValue.UTF8String,
	                                                     codingSchemeDesignator.UTF8String,
	                                                     codeMeaning.UTF8String));
}

static NSArray* HorosStructuredReportCopyNamedTextValues(NSString* path, NSString* codeValue, NSString* codingSchemeDesignator, NSString* codeMeaning, NSString* dictionaryKey)
{
	if (path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return nil;

	HorosModernDCMTKCopyStructuredReportNamedTextValuesFn copyValuesFn =
		HorosStructuredReportSymbol<HorosModernDCMTKCopyStructuredReportNamedTextValuesFn>("HorosModernDCMTKCopyStructuredReportNamedTextValues");
	if (copyValuesFn == NULL)
		return nil;

	NSString *joinedValues = HorosStructuredReportBridgeString(copyValuesFn(path.fileSystemRepresentation,
	                                                                        codeValue.UTF8String,
	                                                                        codingSchemeDesignator.UTF8String,
	                                                                        codeMeaning.UTF8String));
	if (joinedValues.length == 0)
		return nil;

	NSMutableArray *results = [NSMutableArray array];
	for (NSString *value in [joinedValues componentsSeparatedByString:@"\\"])
	{
		if (value.length)
			[results addObject:[NSDictionary dictionaryWithObject:value forKey:dictionaryKey]];
	}

	return results.count ? results : nil;
}

static BOOL HorosStructuredReportWriteDocumentToPath(DSRDocument* document, NSString* path)
{
	if (document == NULL || path == nil)
		return NO;

	HorosModernDCMTKWriteStructuredReportFromXMLFn writeFn =
		HorosStructuredReportSymbol<HorosModernDCMTKWriteStructuredReportFromXMLFn>("HorosModernDCMTKWriteStructuredReportFromXML");
	if (writeFn == NULL)
		return NO;

	NSString *tempXMLPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]] stringByAppendingPathExtension:@"xml"];
	size_t writeFlags = 0;
	ofstream stream([tempXMLPath UTF8String]);
	document->writeXML(stream, writeFlags);
	stream.close();

	BOOL success = writeFn([tempXMLPath UTF8String], [path UTF8String]) != 0;
	[[NSFileManager defaultManager] removeItemAtPath:tempXMLPath error:nil];
	return success;
}

static BOOL HorosStructuredReportReadDocumentFromPath(DSRDocument* document, NSString* path)
{
	if (document == NULL || path == nil || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return NO;

	HorosModernDCMTKCopyStructuredReportXMLFn copyXMLFn =
		HorosStructuredReportSymbol<HorosModernDCMTKCopyStructuredReportXMLFn>("HorosModernDCMTKCopyStructuredReportXML");
	if (copyXMLFn == NULL)
		return NO;

	NSString *xmlString = HorosStructuredReportBridgeString(copyXMLFn(path.fileSystemRepresentation));
	if (xmlString.length == 0)
		return NO;

	NSString *tempXMLPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]] stringByAppendingPathExtension:@"xml"];
	BOOL wroteXML = [xmlString writeToFile:tempXMLPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
	BOOL success = NO;
	if (wroteXML)
		success = document->readXML([tempXMLPath UTF8String], 0).good();
	[[NSFileManager defaultManager] removeItemAtPath:tempXMLPath error:nil];
	return success;
}

@implementation StructuredReport

- (id)initWithStudy:(id)study{
	return [self initWithStudy:(id)study contentsOfFile:nil];
}

- (id)initWithStudy:(id)study contentsOfFile:(NSString *)file{
	if (self = [super init]){
		_doc = new DSRDocument();
		_study = [study retain];
		_reportHasChanged = NO;
		_isEditable = YES;
		_path = [file retain];

		if ([[NSFileManager defaultManager] fileExistsAtPath:file]) {
			_reportHasChanged = NO;			
			BOOL loaded = HorosStructuredReportReadDocumentFromPath(_doc, file);

			// If we are the manfacturer we can edit.
			NSString *manufacturer = HorosStructuredReportCopyField(file, @"Manufacturer");
			const char *manf = manufacturer ? [manufacturer UTF8String] : NULL;
			//_doc->print(cout, NULL);
			if (loaded && manf != NULL && strcmp("OsiriX", manf) == 0){
				
				//completion flag
				if (_doc->getCompletionFlag() == DSRTypes::CF_Complete)
					[self setComplete:YES];
				else
					[self setComplete:NO];
					
				//Verification Flag
				if (_doc->getVerificationFlag()  == DSRTypes::VF_Verified)
					[self setVerified:YES];
				else
					[self setVerified:NO];
					
				NSString *physician = HorosStructuredReportCopyNamedTextValue(file, @"121008", @"DCM", @"Person Observer Name");
				if (physician)
					[self setPhysician:physician];

				NSString *institution = HorosStructuredReportCopyNamedTextValue(file, @"121009", @"DCM", @"Person Observer's Organization Name");
				if (institution)
					[self setInstitution:institution];
				
				NSString *history = HorosStructuredReportCopyNamedTextValue(file, @"121060", @"DCM", @"History");
				if (history)
					[self setHistory:history];
				
				NSString *request = HorosStructuredReportCopyNamedTextValue(file, @"121062", @"DCM", @"Request");
				if (request)
					[self setRequest:request];
				
				NSString *procedureDescription = HorosStructuredReportCopyNamedTextValue(file, @"121065", @"DCM", @"Procedure Description");
				if (procedureDescription)
					[self setProcedureDescription:procedureDescription];
				
				NSArray *findings = HorosStructuredReportCopyNamedTextValues(file, @"121071", @"DCM", @"Finding", @"finding");
				if (findings)
					_findings = [findings retain];
				
				NSArray *impressions = HorosStructuredReportCopyNamedTextValues(file, @"121073", @"DCM", @"Impression", @"conclusion");
				if (impressions)
					_conclusions = [impressions retain];
				
				//get key Images. If none load from study
				// get KeyImages
				_keyImages = [[self referencedObjects] retain];
			}
			else {
				_isEditable = NO;
			}

		}
		else {
			NSPersonNameComponentsFormatter *formatter = [[[NSPersonNameComponentsFormatter alloc] init] autorelease];
			NSPersonNameComponents *name = [formatter personNameComponentsFromString:NSFullUserName()];
			if (name.familyName.length || name.givenName.length)
				[self setPhysician:[NSString stringWithFormat:@"%@^%@", name.familyName ?: @"", name.givenName ?: @""]];
			[self setInstitution:[_study valueForKey:@"institutionName"]];
			[self setRequest:[NSString stringWithFormat:@"%@ %@", [_study valueForKey:@"modality"], [_study valueForKey:@"studyName"]]];
			//Not sure what to suggest for history and technique
			   
			_doc->createNewDocument(DSRTypes::DT_BasicTextSR);
			_doc->setSpecificCharacterSet("ISO_IR 192"); //UTF 8 string encoding
			_doc->createNewSeriesInStudy([[_study valueForKey:@"studyInstanceUID"] UTF8String]);
			//Study Description
			if ([_study valueForKey:@"studyName"])
				_doc->setStudyDescription([[_study valueForKey:@"studyName"] UTF8String]);
			//Series Description
			_doc->setSeriesDescription("OsiriX Structured Report");
			//Patient Name
			if ([_study valueForKey:@"name"] )
				_doc->setPatientsName([[_study valueForKey:@"name"] UTF8String]);
			// Patient DOB
			if ([_study valueForKey:@"dateOfBirth"])
				_doc->setPatientsBirthDate([[[_study valueForKey:@"dateOfBirth"] descriptionWithCalendarFormat:@"%Y%m%d" timeZone:nil locale:nil] UTF8String]);
			//Patient Sex
			if ([_study valueForKey:@"patientSex"])
				_doc->setPatientsSex([[_study valueForKey:@"patientSex"] UTF8String]);
			//Patient ID
			NSString *patientID = [_study valueForKey:@"patientID"];
			if (patientID)
				_doc->setPatientID([patientID UTF8String]);
			//Referring Physician
			if ([_study valueForKey:@"referringPhysician"])
				_doc->setReferringPhysiciansName([[_study valueForKey:@"referringPhysician"] UTF8String]);
			//StudyID	
			if ([_study valueForKey:@"id"]) {
				NSString *studyID = [_study valueForKey:@"id"];
				_doc->setStudyID([studyID UTF8String]);
			}
			//Accession Number
			if ([_study valueForKey:@"accessionNumber"])
				_doc->setAccessionNumber([[_study valueForKey:@"accessionNumber"] UTF8String]);
			//Series Number
			_doc->setSeriesNumber("5001");
			
			_doc->setManufacturer("OsiriX");
			
			// get KeyImages
			//_keyImages = [[[_study keyImages] allObjects] retain];
			
		}	
	}
	return self;
}

- (void)dealloc{
	delete _doc;
	[_study release];
	[_findings release];
	[_conclusions release];
	[_physician release];
	[_history release];
	[_xmlDoc release];
	[_sopInstanceUID release];
	[_request release];
	[_procedureDescription release];
	[_institution release];
	[_verifyOberverOrganization release];
	[_verifyOberverName release];
	[_keyImages release];
	[_path release];
	[super dealloc];
}


- (NSArray *)findings{	
	if (!_findings)
		_findings = [[NSArray alloc] init];
	return _findings;
}

- (void)setFindings:(NSMutableArray *)findings{
	[_findings release];
	_findings = [findings retain];
	_reportHasChanged = YES;
}

- (NSArray *)conclusions{
	if (!_conclusions)
		_conclusions = [[NSMutableArray alloc] init];
	return _conclusions;
}

- (void)setConclusions:(NSMutableArray *)conclusions{
	[_conclusions release];
	_conclusions = [conclusions retain];
	_reportHasChanged = YES;
}

- (NSString *)physician{
	return _physician;
}
- (void)setPhysician:(NSString *)physician{
	[_physician release];
	_physician = [physician retain];
	_reportHasChanged = YES;
}

- (NSString *)history{
	return _history;
}

- (void)setHistory:(NSString *)history{
	[_history release];
	_history = [history retain];
	_reportHasChanged = YES;
}

- (NSString *)request{
	return _request;
}
- (void)setRequest:(NSString *)request{
	[_request release];
	_request = [request retain];
	_reportHasChanged = YES;
}

- (NSString *)procedureDescription{
	return _procedureDescription;
}

- (void)setProcedureDescription:(NSString *)procedureDescription{
	[_procedureDescription release];
	_procedureDescription = [procedureDescription retain];
	_reportHasChanged = YES;
}
	
- (NSString *)institution{
	return _institution;
}

- (void)setInstitution:(NSString *)institution{
	[_institution release];
	_institution = [institution retain];
	_reportHasChanged = YES;
}

- (NSString *)verifyOberverName{
	return _verifyOberverName;
}

- (void)setVerifyOberverName:(NSString *)verifyOberverName{
	[_verifyOberverName release];
	_verifyOberverName = [verifyOberverName retain];
}

- (NSString *)verifyOberverOrganization{
	return _verifyOberverOrganization;
}

- (void)setVerifyOberverOrganization:(NSString *)verifyOberverOrganization{
	[_verifyOberverOrganization release];
	_verifyOberverOrganization = [verifyOberverOrganization retain];
}

- (BOOL)complete{
	return _complete;
}

- (void)setComplete:(BOOL)complete{
	if (_complete == YES && complete == NO) {
		[_path release];
		_path = nil;
	}
	_complete = complete;
	_reportHasChanged = YES;
	if (_complete == NO)
		[self setVerified:NO];
}

- (BOOL)verified{
	return _verified;
}

- (void)setVerified:(BOOL)verified{
	if (_verified == YES && verified == NO) {
		[_path release];
		_path = nil;
	}
	_verified = verified;
	_reportHasChanged = YES;
	if (_verified == YES)
		[self setComplete:YES];
}

- (NSArray *)keyImages{
	if (!_keyImages)
		_keyImages = [[NSArray alloc] init];
	return _keyImages;
}

- (void)setKeyImages:(NSArray *)keyImages{
	[_keyImages release];
	_keyImages = [keyImages retain];
	_reportHasChanged = YES;
	[self setComplete:NO];
}

- (NSDate *)contentDate{
	NSDate *date = nil;
	NSString *dateString = nil;
	NSString *reportPath = [self srPath];
	if (!_reportHasChanged && [[NSFileManager defaultManager] fileExistsAtPath:reportPath])
		dateString = HorosStructuredReportCopyField(reportPath, @"ContentDate");
	else
	{
		const char *contentDate = _doc->getContentDate();
		if (contentDate != NULL)
			dateString = [NSString stringWithUTF8String:contentDate];
	}
	if (dateString != nil) {
		date = [NSCalendarDate dateWithString:dateString calendarFormat:@"%Y%m%d"];
	}
	
	return date;
}

- (void)setContentDate:(NSDate *)date{
}

- (NSString *)title{
	NSString *title = nil;
	NSString *reportPath = [self srPath];
	if (!_reportHasChanged && [[NSFileManager defaultManager] fileExistsAtPath:reportPath])
		title = HorosStructuredReportCopyField(reportPath, @"SeriesDescription");
	else
	{
		const char *seriesDescription = _doc->getSeriesDescription();
		if (seriesDescription != NULL)
			title = [NSString stringWithUTF8String:seriesDescription];
	}
	return title;
}

- (void)setTitle:(NSString *)title{

}
	
- (BOOL)fileExists{
	if ([_study valueForKey:@"reportURL"] && [[NSFileManager defaultManager] fileExistsAtPath:[_study valueForKey:@"reportURL"]])
		return YES;
	return NO;
}

- (BOOL)isEditable{
	// if the verify flags are both verified we cannot edit
	if (_verified && _doc->getVerificationFlag() == DSRTypes::VF_Verified)
		return NO;
	return _isEditable;
}

- (void)checkCharacterSet
{ // check extended character set
	const char *defaultCharset = "latin-1";
	const char *charset = _doc->getSpecificCharacterSet();
	if ((charset == NULL || strlen(charset) == 0) && _doc->containsExtendedCharacters())
	{
	  // we have an unspecified extended character set
		OFString charset(defaultCharset);
		if (charset == "latin-1") _doc->setSpecificCharacterSetType(DSRTypes::CS_Latin1);
		else if (charset == "latin-2") _doc->setSpecificCharacterSetType(DSRTypes::CS_Latin2);
		else if (charset == "latin-3") _doc->setSpecificCharacterSetType(DSRTypes::CS_Latin3);
		else if (charset == "latin-4") _doc->setSpecificCharacterSetType(DSRTypes::CS_Latin4);
		else if (charset == "latin-5") _doc->setSpecificCharacterSetType(DSRTypes::CS_Latin5);
		else if (charset == "cyrillic") _doc->setSpecificCharacterSetType(DSRTypes::CS_Cyrillic);
		else if (charset == "arabic") _doc->setSpecificCharacterSetType(DSRTypes::CS_Arabic);
		else if (charset == "greek") _doc->setSpecificCharacterSetType(DSRTypes::CS_Greek);
		else if (charset == "hebrew") _doc->setSpecificCharacterSetType(DSRTypes::CS_Hebrew);

	}
}

- (void)createReport{
	if ([self isEditable]) {
			//set Completion flag
		// new a new reference if changing from complete to partial
		if (_doc->getCompletionFlag() == DSRTypes::CF_Complete && !_complete) {
			_doc->createRevisedVersion(OFTrue);
		}		
		else if (_complete){
			_doc->completeDocument("COMPLETE");
		}
		
		if (_verified && _doc->getVerificationFlag() != DSRTypes::VF_Verified) {
			//Need to add verification
			const OFString von = OFString([_verifyOberverName UTF8String]);
			const OFString voo = OFString([_verifyOberverOrganization UTF8String]);
			_doc->verifyDocument(von, voo);
			
		}
		else if (!_verified && _doc->getVerificationFlag()  == DSRTypes::VF_Verified) 
			_doc->createRevisedVersion(OFFalse);

		//clear old content	
		_doc->getTree().clear();
				
		_doc->getTree().addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container);
		_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("11528-7", "LN", "Radiology Report"));
		if (_physician) {
			_doc->getTree().addContentItem(DSRTypes::RT_hasObsContext, DSRTypes::VT_PName, DSRTypes::AM_belowCurrent);
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121008", "DCM", "Person Observer Name"));
			_doc->getTree().getCurrentContentItem().setStringValue([_physician UTF8String]);
		}
		
		if (_institution) {
			_doc->getTree().addContentItem(DSRTypes::RT_hasObsContext, DSRTypes::VT_Text);
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121009", "DCM", "Person Observer's Organization Name"));
			_doc->getTree().getCurrentContentItem().setStringValue([_institution UTF8String]);
		}
		
		if (_history) {
			_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text);
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121060", "DCM", "History"));
			_doc->getTree().getCurrentContentItem().setStringValue([_history UTF8String]);
		}
		
		if (_request){
			_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text);
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121062", "DCM", "Request"));
			_doc->getTree().getCurrentContentItem().setStringValue([_request UTF8String]);
		}
		
		if (_procedureDescription){
			_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Container);
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121064", "DCM", "Current Procedure Descriptions"));
			_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent);
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121065", "DCM", "Procedure Description"));
			_doc->getTree().getCurrentContentItem().setStringValue([_procedureDescription UTF8String]);
			//go back up in tree
			_doc->getTree().goUp();
			
		}
		
		if ([_findings count] > 0) {
			_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Container);
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121070", "DCM", "Findings"));
			NSEnumerator *enumerator = [_findings objectEnumerator];
			NSDictionary *dict;
			BOOL first = YES;
			
			while (dict = [enumerator nextObject]) {
				NSString *finding = [dict objectForKey:@"finding"];
				if (finding){
					if (first) {
						// go down one level if first Finding
						_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent);
						first = NO;
					}
					else
						_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text);
					_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121071", "DCM", "Finding"));
					_doc->getTree().getCurrentContentItem().setStringValue([finding UTF8String]);
				}
			}
			//go back up in tree
			_doc->getTree().goUp();
		}
			
		if ([_conclusions count] > 0) {
			_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Container);			
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121072", "DCM", "Impressions"));
			NSEnumerator *enumerator = [_conclusions objectEnumerator];
			NSDictionary *dict;
			BOOL first = YES;
			
			while (dict = [enumerator nextObject]) {
				if (first) {
					// go down one level if first Finding
					_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent);
					first = NO;
				}
				else
					_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text);
				NSString *conclusion = [dict objectForKey:@"conclusion"];			
				_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121073", "DCM", "Impression"));
				_doc->getTree().getCurrentContentItem().setStringValue([conclusion UTF8String]);
			}
			//go back up in tree
			_doc->getTree().goUp();
		}
		
		// add keyImages
		if ([_keyImages count] > 0){
			NSLog(@"Add key Images to report");
			_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Container);
			_doc->getTree().getCurrentContentItem().setConceptName(DSRCodedEntryValue("121180"," DCM", "Key Images"));
			NSEnumerator *enumerator = [_keyImages objectEnumerator];
			id image;
			BOOL first = YES;
			while (image = [enumerator nextObject]){
				//NSLog(@"key image %@", [image description]);
				OFString studyUID = OFString([[_study valueForKey:@"studyInstanceUID"] UTF8String]);
				OFString seriesUID = OFString([[image valueForKeyPath:@"series.seriesDICOMUID"]  UTF8String]);
				OFString instanceUID = OFString([[image valueForKey:@"sopInstanceUID"] UTF8String]);
				NSString *sopClass = [DicomFile getDicomField:@"SOPClassUID" forFile:[image valueForKey:@"completePath"]];
				OFString sopClassUID = OFString([sopClass UTF8String]);
				
				if (first) {
					_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, DSRTypes::AM_belowCurrent);
					first = NO;
				}
				else{
					_doc->getTree().addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image);
				}
				
				_doc->getTree().getCurrentContentItem().setImageReference(DSRImageReferenceValue(sopClassUID, instanceUID));
				_doc->getCurrentRequestedProcedureEvidence().addItem(studyUID, seriesUID, sopClassUID, instanceUID);
			}
			//go back up in tree
			_doc->getTree().goUp();
		}
				
		_reportHasChanged = NO;
	}
}

- (void)save
{
	if (_reportHasChanged)
		[self createReport];
	BOOL status = HorosStructuredReportWriteDocumentToPath(_doc, [self srPath]);
		
	if (status)
	{
		NSLog(@"Report saved: %@", [self srPath]);
		
		[[BrowserController currentBrowser] checkIncoming: self];
	}
	else
		NSLog(@"Report not saved: %@", [self srPath]);
}

- (void)export:(NSString *)path{
	if (_reportHasChanged)
		[self createReport];
	NSString *extension = [path pathExtension];
	if ([extension isEqualToString:@"dcm"]) {
		HorosStructuredReportWriteDocumentToPath(_doc, path);
	}
	else if ([extension isEqualToString:@"xml"]){
		size_t writeFlags = 0;		
		[self checkCharacterSet];
		ofstream stream([path UTF8String]);
		_doc->writeXML(stream, writeFlags);
	}
	else if ([extension isEqualToString:@"htm"] || [extension isEqualToString:@"html"]){
		NSString *tempSRPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]] stringByAppendingPathExtension:@"dcm"];
		HorosModernDCMTKCopyStructuredReportHTMLFn renderFn = HorosStructuredReportSymbol<HorosModernDCMTKCopyStructuredReportHTMLFn>("HorosModernDCMTKCopyStructuredReportHTML");
		if (renderFn != NULL && HorosStructuredReportWriteDocumentToPath(_doc, tempSRPath))
		{
			NSString *html = HorosStructuredReportBridgeString(renderFn([tempSRPath UTF8String]));
			if (html)
				[html writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
		}
		[[NSFileManager defaultManager] removeItemAtPath:tempSRPath error:nil];
	}
}

- (void)convertXMLToSR{
	if (_doc)
		delete _doc;
	_doc = new DSRDocument();
	_doc->readXML([[self xmlPath] UTF8String], nil);
}

- (void)writeHTML{
	if (_reportHasChanged) {
		[self createReport];
	}
	NSString *tempSRPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]] stringByAppendingPathExtension:@"dcm"];
	HorosModernDCMTKCopyStructuredReportHTMLFn renderFn = HorosStructuredReportSymbol<HorosModernDCMTKCopyStructuredReportHTMLFn>("HorosModernDCMTKCopyStructuredReportHTML");
	if (renderFn != NULL && HorosStructuredReportWriteDocumentToPath(_doc, tempSRPath))
	{
		NSString *html = HorosStructuredReportBridgeString(renderFn([tempSRPath UTF8String]));
		if (html)
			[html writeToFile:[self htmlPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}
	[[NSFileManager defaultManager] removeItemAtPath:tempSRPath error:nil];
}

- (void)writeXML{
	size_t writeFlags = 0;		
	[self checkCharacterSet];
	ofstream stream([[self xmlPath] UTF8String]);
	_doc->writeXML(stream, writeFlags);
}

- (void)readXML{
	[_xmlDoc release];
	NSURL *url = [NSURL fileURLWithPath:[self xmlPath]]; 
	NSError *error;
	_xmlDoc = [[NSXMLDocument alloc] initWithContentsOfURL:(NSURL *)url options:nil error:(NSError **)error];
}

- (NSString *)xmlPath{
	NSString *tempPath = @"/tmp";
	NSString *path = [[tempPath stringByAppendingPathComponent:[_study valueForKey:@"studyInstanceUID"]] stringByAppendingPathExtension:@"xml"];
	return path;
}
- (NSString *)htmlPath{
 	NSString *tempPath = @"/tmp";
	NSString *path = [[tempPath stringByAppendingPathComponent:[_study valueForKey:@"studyInstanceUID"]] stringByAppendingPathExtension:@"html"];
	return path;
}
- (NSString *)srPath{
	if (_path)
		return _path;

	NSString *dbPath = [[[BrowserController currentBrowser] documentsDirectory] stringByAppendingPathComponent:@"INCOMING.noindex"];
	NSString *path = [[dbPath stringByAppendingPathComponent:[_study valueForKey:@"studyInstanceUID"]] stringByAppendingPathExtension:@"dcm"];
	return path;

}

//- (NSMXLDocument *)xmlDoc{
//	return _xmlDoc;
//}

- (NSArray *)referencedObjects{
	NSMutableArray *references = [NSMutableArray array];
	NSArray *imagesArray = nil;
	NS_DURING
	NSString *reportPath = [self srPath];
	if (!_reportHasChanged && [[NSFileManager defaultManager] fileExistsAtPath:reportPath])
	{
		HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn copyRefsFn =
			HorosStructuredReportSymbol<HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDsFn>("HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDs");
		NSString *referencedUIDs = copyRefsFn ? HorosStructuredReportBridgeString(copyRefsFn([reportPath UTF8String])) : nil;
		for (NSString *uid in [referencedUIDs componentsSeparatedByString:@"\\"])
		{
			if ([uid length] > 0)
				[references addObject:uid];
		}
	}
	
	if ([references count] == 0)
	{
		DSRDocumentTreeNode *node = NULL; 
		_doc->getTree().gotoRoot ();
		do {
			node = OFstatic_cast(DSRDocumentTreeNode *, _doc->getTree().getNode());
			if (node != NULL && node->getValueType() == DSRTypes::VT_Image) {
				DSRImageTreeNode *imageNode = OFstatic_cast(DSRImageTreeNode *, node);
				OFString sopInstance = imageNode->getSOPInstanceUID();
				if (!sopInstance.empty()) {
					NSString *uid = [NSString stringWithUTF8String:sopInstance.c_str()];
					if (uid)
						[references addObject:uid];
				}
			}
		} while (_doc->getTree().iterate());
	}

	NSManagedObjectModel	*model = [[BrowserController currentBrowser] managedObjectModel];
	NSManagedObjectContext	*context = [[BrowserController currentBrowser] managedObjectContext];
	NSFetchRequest *dbRequest = [[[NSFetchRequest alloc] init] autorelease];
	[dbRequest setEntity: [[model entitiesByName] objectForKey:@"Image"]];
	NSPredicate *predicate = [NSPredicate predicateWithValue:NO];
	NSError *error = nil;
	
	NSEnumerator *enumerator = [references objectEnumerator];
	id reference;
	while (reference = [enumerator nextObject])
	{
		NSPredicate	*p = [NSComparisonPredicate predicateWithLeftExpression: [NSExpression expressionForKeyPath: @"compressedSopInstanceUID"] rightExpression: [NSExpression expressionForConstantValue: [DicomImage sopInstanceUIDEncodeString: reference]] customSelector: @selector( isEqualToSopInstanceUID:)];
		predicate = [NSCompoundPredicate orPredicateWithSubpredicates:[NSArray arrayWithObjects:predicate, p, nil]]; 
	}
	[dbRequest setPredicate: [NSPredicate predicateWithFormat:@"compressedSopInstanceUID != NIL"]];
	imagesArray = [context executeFetchRequest:dbRequest error:&error];
	imagesArray = [[imagesArray filteredArrayUsingPredicate: predicate] retain];
	
	NS_HANDLER
	NS_ENDHANDLER
	return imagesArray;
}

@end
