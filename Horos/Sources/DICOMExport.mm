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

#import "DICOMExport.h"
#import "DCMCalendarDate.h"
#import "BrowserController.h"
#import "DicomFile.h"
#import "DCMPix.h"
#import "DICOMToNSString.h"
#import "DicomDatabase+DCMTK.h"
#include <dlfcn.h>

typedef char* (*HorosModernDCMTKCopyGeneratedUIDFn)(void);
typedef char* (*HorosModernDCMTKCopyFieldFn)(const char* path, const char* fieldName);
typedef void (*HorosModernDCMTKFreeStringFn)(char* value);

static void* HorosDICOMExportBridgeHandle()
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
    });
    return handle;
}

template <typename FunctionType>
static FunctionType HorosDICOMExportSymbol(const char* name)
{
    void* handle = HorosDICOMExportBridgeHandle();
    if (handle == NULL)
        return NULL;
    return reinterpret_cast<FunctionType>(dlsym(handle, name));
}

static NSString* HorosDICOMExportGeneratedUID()
{
    HorosModernDCMTKCopyGeneratedUIDFn copyUIDFn =
        HorosDICOMExportSymbol<HorosModernDCMTKCopyGeneratedUIDFn>("HorosModernDCMTKCopyGeneratedUID");
    if (copyUIDFn == NULL)
        return nil;

    char *value = copyUIDFn();
    if (value == NULL)
        return nil;

    NSString *string = [NSString stringWithUTF8String:value];
    HorosModernDCMTKFreeStringFn freeFn =
        HorosDICOMExportSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
    if (freeFn)
        freeFn(value);
    return string;
}

static NSString* HorosDICOMExportCopyField(NSString *path, NSString *fieldName)
{
    if (path.length == 0 || fieldName.length == 0)
        return nil;

    HorosModernDCMTKCopyFieldFn copyFieldFn =
        HorosDICOMExportSymbol<HorosModernDCMTKCopyFieldFn>("HorosModernDCMTKCopyField");
    if (copyFieldFn == NULL)
        return nil;

    char *value = copyFieldFn(path.fileSystemRepresentation, fieldName.UTF8String);
    if (value == NULL)
        return nil;

    NSString *string = [NSString stringWithUTF8String:value];
    HorosModernDCMTKFreeStringFn freeFn =
        HorosDICOMExportSymbol<HorosModernDCMTKFreeStringFn>("HorosModernDCMTKFreeString");
    if (freeFn)
        freeFn(value);

    return string;
}

static NSString* HorosDICOMExportGeneratedSeriesUID()
{
    return HorosDICOMExportGeneratedUID();
}

static float deg2rad = M_PI / 180.0f; 

@implementation DICOMExport

@synthesize rotateRawDataBy90degrees, metaDataDict;

+ (NSInteger)currentTimeSeriesNumberOffset
{
    NSDateComponents *components = [[NSCalendar currentCalendar] components:NSCalendarUnitMinute | NSCalendarUnitSecond
                                                                    fromDate:[NSDate date]];
    return components.minute + components.second;
}

- (NSString*) seriesDescription
{
	return exportSeriesDescription;
}

- (void) setSeriesDescription: (NSString*) desc
{
	if( desc != exportSeriesDescription)
	{
		[exportSeriesDescription release];
		exportSeriesDescription = [desc retain];
	}
}

- (void) setSeriesNumber: (long) no
{
	if( exportSeriesNumber != no)
	{
		exportSeriesNumber = no;
		
		[exportSeriesUID release];
		exportSeriesUID = [HorosDICOMExportGeneratedSeriesUID() retain];
	}
}

- (id)init
{
	self = [super init];
	if (self)
	{
		dcmSourcePath = nil;
		
		data = nil;
		width = height = spp = bps = 0;
		
		image = nil;
		imageData = nil;
		freeImageData = NO;
		imageRepresentation = nil;
		
		ww = wl = -1;
		
		exportInstanceNumber = 1;
		exportSeriesNumber = 5000;
		
		exportSeriesUID = [HorosDICOMExportGeneratedSeriesUID() retain];
		exportSeriesDescription = [@"OsiriX SC" retain];
		
		spacingX = 0;
		spacingY = 0;
		sliceThickness = 0;
		sliceInterval = 0;
		slicePosition = 0;
		slope = 1;
		
		int i;
		for( i = 0; i < 6; i++) orientation[ i] = 0;
		for( i = 0; i < 3; i++) position[ i] = 0;
        
        NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone = [NSTimeZone localTimeZone];
        NSDateComponents *birthdateComponents = [[[NSDateComponents alloc] init] autorelease];
        birthdateComponents.year = 1900;
        birthdateComponents.month = 1;
        birthdateComponents.day = 1;
        birthdateComponents.hour = 1;
        birthdateComponents.minute = 1;
        birthdateComponents.second = 1;

        metaDataDict = [[NSMutableDictionary dictionaryWithObjectsAndKeys:@"unknown", @"patientsName",
         @"unknown ID", @"patientID",
         [calendar dateFromComponents:birthdateComponents], @"patientsBirthdate",
         @"M", @"patientsSex",
         [NSDate date], @"studyDate",
         nil] retain];
	}
	
	return self;
}

- (void) dealloc
{
	NSLog(@"DICOMExport released");
	
	if( localData)
		free( localData);
	localData = nil;
	
	[image release];
	[imageRepresentation release];
	if( freeImageData) free( imageData);

	[exportSeriesUID release];
	[exportSeriesDescription release];
	
	[dcmSourcePath release];
	
	if( dcmtkFileFormat)
		delete dcmtkFileFormat;
	
    [metaDataDict release];
    
	[super dealloc];
}


- (void) setSourceFile:(NSString*) isource
{
	[dcmSourcePath release];
	dcmSourcePath = [isource retain];
}

- (void) setSigned: (BOOL) s
{
	isSigned = s;
}

- (void) setOffset: (int) o
{
	offset = o;
}

- (void) setSlope: (float) s
{
	slope = s;
}

- (long) setPixelData:		(unsigned char*) idata
		samplesPerPixel:	(int) ispp
		bitsPerSample:		(int) ibps
		width:				(long) iwidth
		height:				(long) iheight
{
	if( localData)
		free( localData);
	localData = nil;
	
	spp = ispp;
	bps = ibps;
	width = iwidth;
	height = iheight;
	data = idata;
	
	isSigned = NO;
	offset = -1024;
	
	if( spp == 4 && bps == 8)
	{
		localData = (unsigned char*) malloc( width * height * 3);
		if( localData)
		{
			spp = 3;
			
			for( int y = 0; y < height; y++)
			{
				for( int x = 0; x < width; x++)
				{
                    float alpha = (float)data[ 3+ x*4 + y*width*4] / 255.;
                    
					localData[ 0 + x*3 + y*width*3] = data[ 0+ x*4 + y*width*4]*alpha;
					localData[ 1 + x*3 + y*width*3] = data[ 1+ x*4 + y*width*4]*alpha;
					localData[ 2 + x*3 + y*width*3] = data[ 2+ x*4 + y*width*4]*alpha;
				}
			}
			
			data = localData;
		}
	}
	return 0;
}


- (long) setPixelData:		(unsigned char*) idata
		samplePerPixel:		(long) ispp
		bitsPerPixel:		(long) ibps
		width:				(long) iwidth
		height:				(long) iheight
{
	return [self setPixelData:idata samplesPerPixel:ispp bitsPerSample:ibps width:iwidth height:iheight];
}

- (long) setPixelNSImage:	(NSImage*) iimage
{
	if( image != iimage)
	{
		[image release];
		image = [iimage retain];
	}

	[imageRepresentation release];
	imageRepresentation = nil;
	if( freeImageData)
		free( imageData);
	freeImageData = NO;
	imageData = nil;

	if( image)
	{
		NSData *tiffRep = [image TIFFRepresentation];
		
		if( tiffRep)
		{
			imageRepresentation = [[NSBitmapImageRep alloc] initWithData:tiffRep];
			if( imageRepresentation == nil || imageRepresentation.isPlanar)
				return -1;

			long w = imageRepresentation.pixelsWide;
			long h = imageRepresentation.pixelsHigh;
			NSInteger samplesPerPixel = imageRepresentation.samplesPerPixel;
			if( w <= 0 || h <= 0 || samplesPerPixel <= 0 || imageRepresentation.bitsPerPixel <= 0)
				return -1;
			NSInteger bitsPerSample = imageRepresentation.bitsPerPixel / samplesPerPixel;
			NSInteger packedBytesPerRow = (w * imageRepresentation.bitsPerPixel + 7) / 8;
			
			if( imageRepresentation.bytesPerRow != packedBytesPerRow)
			{
				imageData = (unsigned char*) malloc( h * packedBytesPerRow);
				if( imageData == nil)
					return -1;
				freeImageData = YES;
				
				for( long row = 0; row < h; row++)
				{
					memcpy( imageData + row * packedBytesPerRow,
					        imageRepresentation.bitmapData + row * imageRepresentation.bytesPerRow,
					        packedBytesPerRow);
				}
			}
			else imageData = [imageRepresentation bitmapData];
			
			return [self setPixelData:		imageData
						samplesPerPixel:	(int)samplesPerPixel
						bitsPerSample:		(int)bitsPerSample
						width:				w
						height:				h];
		}
		else return -1;
	}
	else return -1;
}

- (void) setDefaultWWWL: (long) iww :(long) iwl
{
	wl = iwl;
	ww = iww;
}

- (void) setPixelSpacing: (float) x :(float) y;
{
	spacingX = x;
	spacingY = y;
}

- (void) setSliceThickness: (double) t
{
	sliceThickness = t;
}

- (void) setOrientation: (float*) o
{
	for( int i = 0; i < 6; i++) orientation[ i] = o[ i];
}

- (void) setPosition: (float*) p
{
	for( int i = 0; i < 3; i++) position[ i] = p[ i];
}

- (void) setSlicePosition: (float) p
{
	slicePosition = p;
}

- (void) setModalityAsSource: (BOOL) v
{
	modalityAsSource = v;
}

- (BOOL) createDICOMHeader: (DcmItem *) dataset dictionary: (NSDictionary*) dict
{
	OFCondition result = EC_Normal;
    NSString *generatedUID = nil;
	
	// insert empty type 2 attributes
	if (result.good()) result = dataset->insertEmptyElement(DCM_StudyDate);
	if (result.good()) result = dataset->insertEmptyElement(DCM_StudyTime);
	if (result.good()) result = dataset->insertEmptyElement(DCM_AccessionNumber);
	if (result.good()) result = dataset->insertEmptyElement(DCM_Manufacturer);
	if (result.good()) result = dataset->insertEmptyElement(DCM_ReferringPhysiciansName);
	if (result.good()) result = dataset->insertEmptyElement(DCM_StudyID);
	if (result.good()) result = dataset->insertEmptyElement(DCM_ContentDate);
	if (result.good()) result = dataset->insertEmptyElement(DCM_ContentTime);
	if (result.good()) result = dataset->insertEmptyElement(DCM_AcquisitionDate);
	if (result.good()) result = dataset->insertEmptyElement(DCM_AcquisitionTime);
	if (result.good()) result = dataset->insertEmptyElement(DCM_AcquisitionDatetime);
	if (result.good()) result = dataset->insertEmptyElement(DCM_ConceptNameCodeSequence);
	
    if (result.good()) result = dataset->putAndInsertString(DCM_SOPClassUID, UID_SecondaryCaptureImageStorage);
    
	// insert const value attributes
	if (result.good()) result = dataset->putAndInsertString(DCM_SpecificCharacterSet, "ISO_IR 100");
	
	// there is no way we could determine a meaningful series number, so we just use a constant.
	if (result.good()) result = dataset->putAndInsertString(DCM_SeriesNumber, "1");
	
	// insert variable value attributes
	if (result.good() && [dict objectForKey: @"patientsName"])
        result = dataset->putAndInsertString(DCM_PatientsName, [[dict objectForKey: @"patientsName"] UTF8String]);
    
	if (result.good() && [dict objectForKey: @"patientID"])
        result = dataset->putAndInsertString(DCM_PatientID, [[dict objectForKey: @"patientID"] UTF8String]);
    
	if (result.good() && [dict objectForKey: @"patientsBirthdate"])
        result = dataset->putAndInsertString(DCM_PatientsBirthDate, [[[DCMCalendarDate dicomDateWithDate: [dict objectForKey: @"patientsBirthdate"]] dateString] UTF8String]);
    
	if (result.good() && [dict objectForKey: @"patientsSex"])
        result = dataset->putAndInsertString(DCM_PatientsSex, [[dict objectForKey: @"patientsSex"] UTF8String]);
    
	if (result.good() && [dict objectForKey: @"studyDate"])
        result = dataset->putAndInsertString(DCM_AcquisitionDate, [[[DCMCalendarDate dicomDateWithDate: [dict objectForKey: @"studyDate"]] dateString] UTF8String]);
	
    if (result.good() && [dict objectForKey: @"studyDate"])
        result = dataset->putAndInsertString(DCM_AcquisitionTime, [[[DCMCalendarDate dicomTimeWithDate: [dict objectForKey: @"studyDate"]] timeString] UTF8String]);
    
    if (result.good() && [dict objectForKey: @"studyDescription"])
        result = dataset->putAndInsertString(DCM_StudyDescription, [[dict objectForKey: @"studyDescription"] UTF8String]);
    
    if (result.good() && [(NSString*)[dict objectForKey: @"modality"] length])
        result = dataset->putAndInsertString(DCM_Modality, [[dict objectForKey: @"modality"] UTF8String]);
    else
        result = dataset->putAndInsertString(DCM_Modality, "OT");
    
    generatedUID = HorosDICOMExportGeneratedUID();
	if (result.good())
    {
        if( [dict objectForKey: @"studyUID"])
            result = dataset->putAndInsertString(DCM_StudyInstanceUID, [[dict objectForKey: @"studyUID"] UTF8String]);
        else if (generatedUID.length)
            result = dataset->putAndInsertString(DCM_StudyInstanceUID, [generatedUID UTF8String]);
    }
	
    generatedUID = HorosDICOMExportGeneratedUID();
	if (result.good())
    {
        if( [dict objectForKey: @"seriesUID"])
            result = dataset->putAndInsertString(DCM_SeriesInstanceUID, [[dict objectForKey: @"seriesUID"] UTF8String]);
        else if (generatedUID.length)
            result = dataset->putAndInsertString(DCM_SeriesInstanceUID, [generatedUID UTF8String]);
    }
	
    generatedUID = HorosDICOMExportGeneratedUID();
	if (result.good() && generatedUID.length) result = dataset->putAndInsertString(DCM_SOPInstanceUID, [generatedUID UTF8String]);
	
	// set instance creation date and time
	OFString s;
	if (result.good()) result = DcmDate::getCurrentDate(s);
	if (result.good()) result = dataset->putAndInsertOFStringArray(DCM_InstanceCreationDate, s);
	if (result.good()) result = DcmTime::getCurrentTime(s);
	if (result.good()) result = dataset->putAndInsertOFStringArray(DCM_InstanceCreationTime, s);
	
	return result.good();
}

- (void) removeAllFieldsOfGroup: (Uint16) groupNumber dataset: (DcmItem *) dset
{
	DcmStack stack;
	DcmObject *dobj = NULL;
	DcmTagKey tag;
	OFCondition status = dset->nextObject(stack, OFTrue);
	
	while (status.good())
	{
		dobj = stack.top();
		tag = dobj->getTag();
		if (tag.getGroup() == groupNumber)
		{
			stack.pop();
			delete ((DcmItem *)(stack.top()))->remove(dobj);
		}
		status = dset->nextObject(stack, OFTrue);
	}
}

- (NSString*) writeDCMFile: (NSString*) dstPath
{
    
	if( spp != 1 && spp != 3)
	{
		NSLog( @"**** DICOM Export: sample per pixel not supported: %ld", spp);
		return nil;
	}
	
	if( spp == 3)
	{
		if( bps != 8)
		{
			NSLog( @"**** DICOM Export: for RGB images, only 8 bits per sample is supported: %ld", bps);
			return nil;
		}
	}
	
	if( bps != 8 && bps != 16 && bps != 32)
	{
		NSLog( @"**** DICOM Export: unknown bits per sample: %ld", bps);
		return nil;
	}
	
	if( width != 0 && height != 0 && data != nil)
	{
		@try
		{
			if( [[NSUserDefaults standardUserDefaults] boolForKey: @"useDCMTKForDicomExport"])
			{
				const char *modality = nil;
				unsigned char *squaredata = nil;
				
				if( spacingX != 0 && spacingY != 0)
				{
					if( spacingX != spacingY)	// Convert to square pixels
					{
						if( bps == 16)
						{
							vImage_Buffer	srcVimage, dstVimage;
							long			newHeight = ((float) height * spacingY) / spacingX;
							
							newHeight /= 2;
							newHeight *= 2;
							
							squaredata = (unsigned char*) malloc( newHeight * width * bps/8);
							
							float	*tempFloatSrc = (float*) malloc( height * width * sizeof( float));
							float	*tempFloatDst = (float*) malloc( newHeight * width * sizeof( float));
							
							if( squaredata != nil && tempFloatSrc != nil && tempFloatDst != nil)
							{
								long err;
								
								// Convert Source to float
								srcVimage.data = data;
								srcVimage.height =  height;
								srcVimage.width = width;
								srcVimage.rowBytes = width* bps/8;
								
								dstVimage.data = tempFloatSrc;
								dstVimage.height =  height;
								dstVimage.width = width;
								dstVimage.rowBytes = width*sizeof( float);
								
								if( isSigned)
									err = vImageConvert_16SToF(&srcVimage, &dstVimage, 0,  1, 0);
								else
									err = vImageConvert_16UToF(&srcVimage, &dstVimage, 0,  1, 0);
								
								// Scale the image
								srcVimage.data = tempFloatSrc;
								srcVimage.height =  height;
								srcVimage.width = width;
								srcVimage.rowBytes = width*sizeof( float);
								
								dstVimage.data = tempFloatDst;
								dstVimage.height =  newHeight;
								dstVimage.width = width;
								dstVimage.rowBytes = width*sizeof( float);
								
								err = vImageScale_PlanarF( &srcVimage, &dstVimage, nil, kvImageHighQualityResampling);
							//	if( err) NSLog(@"%d", err);
								
								// Convert Destination to 16 bits
								srcVimage.data = tempFloatDst;
								srcVimage.height =  newHeight;
								srcVimage.width = width;
								srcVimage.rowBytes = width*sizeof( float);
								
								dstVimage.data = squaredata;
								dstVimage.height =  newHeight;
								dstVimage.width = width;
								dstVimage.rowBytes = width* bps/8;
								
								if( isSigned)
									err = vImageConvert_FTo16S( &srcVimage, &dstVimage, 0,  1, 0);
								else
									err = vImageConvert_FTo16U( &srcVimage, &dstVimage, 0,  1, 0);
								
								spacingY = spacingX;
								height = newHeight;
								
								data = squaredata;
								
								free( tempFloatSrc);
								free( tempFloatDst);
							}
						}
					}
				}
                
                if( rotateRawDataBy90degrees)
				{
                    float copySpacingX = spacingX;
                    spacingX = spacingY;
                    spacingY = copySpacingX;
                    
                    long copyWidth = width;
                    width = height;
                    height = copyWidth;
                    
                    //Origin and vector
                    if( orientation[ 0] != 0 || orientation[ 1] != 0 || orientation[ 2] != 0)
                    {
                        float x = 0, y = width;
                        float newOrigin[ 3];
                        
                        if( spacingX != 0 && spacingY != 0)
                        {
                            newOrigin[0] = position[0] + y*orientation[3]*spacingY + x*orientation[0]*spacingX;
                            newOrigin[1] = position[1] + y*orientation[4]*spacingY + x*orientation[1]*spacingX;
                            newOrigin[2] = position[2] + y*orientation[5]*spacingY + x*orientation[2]*spacingX;
                        }
                        else
                        {
                            newOrigin[0] = position[0] + y*orientation[3] + x*orientation[0];
                            newOrigin[1] = position[1] + y*orientation[4] + x*orientation[1];
                            newOrigin[2] = position[2] + y*orientation[5] + x*orientation[2];
                        }
                        
                        position[0] = newOrigin[0];
                        position[1] = newOrigin[1];
                        position[2] = newOrigin[2];
                        
                        float o[ 9];
                        
                        o[0] = orientation[0];  o[1] = orientation[1];  o[2] = orientation[2];
                        o[3] = orientation[3];  o[4] = orientation[4];  o[5] = orientation[5];
                        
                        // Compute normal vector
                        o[6] = o[1]*o[5] - o[2]*o[4];
                        o[7] = o[2]*o[3] - o[0]*o[5];
                        o[8] = o[0]*o[4] - o[1]*o[3];
                        
                        XYZ vector, rotationVector; 
                        
                        rotationVector.x = o[ 6];	rotationVector.y = o[ 7];	rotationVector.z = o[ 8];
                        
                        vector.x = o[ 0];	vector.y = o[ 1];	vector.z = o[ 2];
                        vector =  ArbitraryRotate(vector, -90*deg2rad, rotationVector);
                        o[ 0] = vector.x;	o[ 1] = vector.y;	o[ 2] = vector.z;
                        
                        vector.x = o[ 3];	vector.y = o[ 4];	vector.z = o[ 5];
                        vector =  ArbitraryRotate(vector, -90*deg2rad, rotationVector);
                        o[ 3] = vector.x;	o[ 4] = vector.y;	o[ 5] = vector.z;
                        
                        // Compute normal vector
                        o[6] = o[1]*o[5] - o[2]*o[4];
                        o[7] = o[2]*o[3] - o[0]*o[5];
                        o[8] = o[0]*o[4] - o[1]*o[3];
                        
                        orientation[0] = o[0];  orientation[1] = o[1];  orientation[2] = o[2];
                        orientation[3] = o[3];  orientation[4] = o[4];  orientation[5] = o[5];
                    }
                    
                    //Pixels data
                    switch( bps)
                    {
                        case 8:
                            if (spp == 3)
                            {
                                unsigned char *olddata = (unsigned char*) data;
                                unsigned char *newdata = (unsigned char*) malloc( height * width * bps*spp / 8);
                                
                                for( long x = 0 ; x < width; x++)
                                {
                                    for( long y = 0 ; y < height; y++)
                                    {
                                        *(newdata+y*width*3+x +0) = *(olddata+(width-x-1)*height*3+y +0);
                                        *(newdata+y*width*3+x +1) = *(olddata+(width-x-1)*height*3+y +1);
                                        *(newdata+y*width*3+x +2) = *(olddata+(width-x-1)*height*3+y +2);
                                    }
                                }
                                
                                memcpy( olddata, newdata, height * width * bps*spp / 8);
                                free( newdata);
                            }
                            else
                            {
                                unsigned char *olddata = (unsigned char*) data;
                                unsigned char *newdata = (unsigned char*) malloc( height * width * bps / 8);
                                
                                for( long x = 0 ; x < width; x++)
                                {
                                    for( long y = 0 ; y < height; y++)
                                    {
                                        *(newdata+y*width+x) = *(olddata+(width-x-1)*height+y);
                                    }
                                }
                                
                                memcpy( olddata, newdata, height * width * bps / 8);
                                free( newdata);
                            }
                        break;
                        
                        case 16:
                        {
                            unsigned short *olddata = (unsigned short*) data;
                            unsigned short *newdata = (unsigned short*) malloc( height * width * bps / 8);
                            
                            for( long x = 0 ; x < width; x++)
                            {
                                for( long y = 0 ; y < height; y++)
                                {
                                    *(newdata+y*width+x) = *(olddata+(width-x-1)*height+y);
                                }
                            }
                            
                            memcpy( olddata, newdata, height * width * bps / 8);
                            free( newdata);
                        }
                        break;
                        
                        case 32:
                        {
                            float *olddata = (float*) data;
                            float *newdata = (float*) malloc( height * width * bps / 8);
                            
                            for( long x = 0 ; x < width; x++)
                            {
                                for( long y = 0 ; y < height; y++)
                                {
                                    *(newdata+y*width+x) = *(olddata+(width-x-1)*height+y);
                                }
                            }
                            
                            memcpy( olddata, newdata, height * width * bps / 8);
                            free( newdata);
                        }
                        break;
                            
                        default:
                            NSLog( @"**** unknown bps during rotate90 DICOMExport");
                        break;
                    }
                }
                
				int elemLength = height * width * spp * bps / 8;
				
				if( elemLength%2 != 0)
				{
					height--;
					elemLength = height * width * spp * bps / 8;
					
					if( elemLength%2 != 0) NSLog( @"***************** ODD element !!!!!!!!!!");
				}
				
				int highBit;
				int bitsAllocated;
				float numberBytes;
				
				switch( bps)
				{
					case 8:			
						highBit = 7;
						bitsAllocated = 8;
						numberBytes = 1;
					break;
					
					case 16:			
						highBit = 15;
						bitsAllocated = 16;
						numberBytes = 2;
					break;
					
					case 32:  // float support
						highBit = 31;
						bitsAllocated = 32;
						numberBytes = 4;
					break;
					
					default:
						NSLog(@"Unsupported bps: %ld", bps);
						return nil;
					break;
				}
				
				NSString *photometricInterpretation = @"MONOCHROME2";
				if (spp == 3) photometricInterpretation = @"RGB";
				
				if( dcmtkFileFormat)
					delete dcmtkFileFormat;
				
				dcmtkFileFormat = new DcmFileFormat();
				
				BOOL succeed = NO;
				
				if( dcmSourcePath)
				{
					if( [DicomFile isDICOMFile: dcmSourcePath])
					{
						OFCondition cond = dcmtkFileFormat->loadFile( [dcmSourcePath UTF8String], EXS_Unknown, EGL_noChange);
						succeed =  (cond.good()) ? YES : NO;
					}
					else
					{
						DicomFile* file = [[[DicomFile alloc] init:dcmSourcePath] autorelease];
						
						if( file)
						{
							succeed = [self createDICOMHeader: dcmtkFileFormat->getDataset()
												   dictionary: [NSDictionary dictionaryWithObjectsAndKeys:
																[file elementForKey: @"patientName"], @"patientsName",
																[file elementForKey: @"patientID"], @"patientID",
																[file elementForKey: @"patientBirthDate"], @"patientsBirthdate",
																[file elementForKey: @"patientSex"], @"patientsSex",
																[file elementForKey: @"studyDate"], @"studyDate",
																nil]];
                            
                            dcmtkFileFormat->getMetaInfo()->putAndInsertString(DCM_MediaStorageSOPClassUID, UID_SecondaryCaptureImageStorage);
						}
					}
				}
				
				if( succeed == NO)
				{
					succeed = [self createDICOMHeader: dcmtkFileFormat->getDataset() dictionary: metaDataDict];
                    dcmtkFileFormat->getMetaInfo()->putAndInsertString(DCM_MediaStorageSOPClassUID, UID_SecondaryCaptureImageStorage);
				}
				
				if( succeed)
				{
					NSStringEncoding encoding[ 10];
					for( int i = 0; i < 10; i++) encoding[ i] = 0;
					encoding[ 0] = NSISOLatin1StringEncoding;
					
					dcmtkFileFormat->loadAllDataIntoMemory();
					
					DcmItem *dataset = dcmtkFileFormat->getDataset();
					DcmMetaInfo *metaInfo = dcmtkFileFormat->getMetaInfo();
					
					[self removeAllFieldsOfGroup: 0x0028 dataset: dataset];
					[self removeAllFieldsOfGroup: 0x5200 dataset: dataset];     //We don't support multiframe export
					
					NSString *specificCharacterSet = HorosDICOMExportCopyField(dcmSourcePath, @"SpecificCharacterSet");
					if (specificCharacterSet.length)
					{
						NSArray	*c = [specificCharacterSet componentsSeparatedByString:@"\\"];
						
						if( [c count] >= 10) NSLog( @"Encoding number >= 10 ???");
						
						if( [c count] < 10)
						{
							for( int i = 0; i < [c count]; i++) encoding[ i] = [NSString encodingForDICOMCharacterSet: [c objectAtIndex: i]];
							for( int i = [c count]; i < 10; i++) encoding[ i] = [NSString encodingForDICOMCharacterSet: [c lastObject]];
						}
					}
					
					if( exportSeriesUID)
						dataset->putAndInsertString( DCM_SeriesInstanceUID, [exportSeriesUID UTF8String]);
					
					if( exportSeriesDescription)
						dataset->putAndInsertString( DCM_SeriesDescription, [exportSeriesDescription cStringUsingEncoding: encoding[ 0]]);
					
					if( exportSeriesNumber != -1)
						dataset->putAndInsertString( DCM_SeriesNumber, [[NSString stringWithFormat: @"%d", exportSeriesNumber] UTF8String]);
					
					if( modalityAsSource == NO || spp == 3)
                    {
						dataset->putAndInsertString( DCM_Modality, "SC");
                        metaInfo->putAndInsertString( DCM_MediaStorageSOPClassUID, UID_SecondaryCaptureImageStorage);
                        dataset->putAndInsertString( DCM_SOPClassUID, UID_SecondaryCaptureImageStorage);
                    }
                    else
                        delete dataset->remove( DCM_MediaStorageSOPClassUID);
                    
					dataset->putAndInsertString( DCM_ManufacturersModelName, "Horos");
					dataset->putAndInsertString( DCM_InstanceNumber, [[NSString stringWithFormat: @"%d", exportInstanceNumber++] UTF8String]);
					dataset->putAndInsertString( DCM_AcquisitionNumber, "1");
					
					dataset->putAndInsertString( DCM_Rows, [[NSString stringWithFormat: @"%d", (int) height] UTF8String]);
					dataset->putAndInsertString( DCM_Columns, [[NSString stringWithFormat: @"%d", (int) width] UTF8String]);
					dataset->putAndInsertString( DCM_SamplesPerPixel, [[NSString stringWithFormat: @"%d", (int) spp] UTF8String]);
					dataset->putAndInsertString( DCM_PhotometricInterpretation, [photometricInterpretation UTF8String]);
					dataset->putAndInsertString( DCM_PixelRepresentation, [[NSString stringWithFormat: @"%d", isSigned] UTF8String]);
				
					dataset->putAndInsertString( DCM_HighBit, [[NSString stringWithFormat: @"%d", highBit] UTF8String]);
					dataset->putAndInsertString( DCM_BitsAllocated, [[NSString stringWithFormat: @"%d", bitsAllocated] UTF8String]);
					dataset->putAndInsertString( DCM_BitsStored, [[NSString stringWithFormat: @"%d", bitsAllocated] UTF8String]);
					
					delete dataset->remove( DCM_ImagerPixelSpacing);
					delete dataset->remove( DCM_EstimatedRadiographicMagnificationFactor);
                    
					if( spacingX != 0 && spacingY != 0)
						dataset->putAndInsertString( DCM_PixelSpacing, [[NSString stringWithFormat: @"%f\\%f", spacingY, spacingX] UTF8String]);
					
					delete dataset->remove( DCM_SliceThickness);
					if( sliceThickness != 0)
						dataset->putAndInsertString( DCM_SliceThickness, [[NSString stringWithFormat: @"%f", sliceThickness] UTF8String]);
					
					delete dataset->remove( DCM_ImageOrientationPatient);
					if( orientation[ 0] != 0 || orientation[ 1] != 0 || orientation[ 2] != 0)
						dataset->putAndInsertString( DCM_ImageOrientationPatient, [[NSString stringWithFormat: @"%f\\%f\\%f\\%f\\%f\\%f", orientation[ 0], orientation[ 1], orientation[ 2], orientation[ 3], orientation[ 4], orientation[ 5]] UTF8String]);
					
					delete dataset->remove( DCM_ImagePositionPatient);
					if( position[ 0] != 0 || position[ 1] != 0 || position[ 2] != 0)
					{
						dataset->putAndInsertString( DCM_ImagePositionPatient, [[NSString stringWithFormat: @"%f\\%f\\%f", position[ 0], position[ 1], position[ 2]] UTF8String]);
					}
					
					delete dataset->remove( DCM_SliceLocation);
					if( slicePosition != 0)
						dataset->putAndInsertString( DCM_SliceLocation, [[NSString stringWithFormat: @"%f", slicePosition] UTF8String]);
					
					delete dataset->remove( DCM_PlanarConfiguration);
					if( spp == 3)
						dataset->putAndInsertString( DCM_PlanarConfiguration, "0");
					
					NSString *sourceModality = HorosDICOMExportCopyField(dcmSourcePath, @"Modality");
					if (sourceModality.length)
						modality = [sourceModality UTF8String];
					
					delete dataset->remove( DCM_PixelData);
                    delete dataset->remove( DcmTagKey( 0x0009, 0x1110)); // "GEIIS" The problematic private group, containing a *always* JPEG compressed PixelData
                    
					if( bps == 32) // float support
					{
						dataset->putAndInsertString( DCM_RescaleIntercept, "0");
						dataset->putAndInsertString( DCM_RescaleSlope, "1");
						
						if( modality && strcmp( modality, "CT") == 0)
							dataset->putAndInsertString( DCM_RescaleType, "HU");
						else
							dataset->putAndInsertString( DCM_RescaleType, "US");
						
						if( ww != -1 && ww != -1)
						{
							dataset->putAndInsertString( DCM_WindowCenter, [[NSString stringWithFormat: @"%d", (int) wl] UTF8String]);
							dataset->putAndInsertString( DCM_WindowWidth, [[NSString stringWithFormat: @"%d", (int) ww] UTF8String]);
						}
						
						dataset->putAndInsertUint8Array(DCM_PixelData, OFstatic_cast(Uint8 *, OFconst_cast(void *, (void*) data)), height*width*4);
					}
					else if( bps == 16)
					{
						if( isSigned == NO)
							dataset->putAndInsertString( DCM_RescaleIntercept, [[NSString stringWithFormat: @"%d", offset] UTF8String]);
						else
							dataset->putAndInsertString( DCM_RescaleIntercept, "0");
						
						dataset->putAndInsertString( DCM_RescaleSlope, [[NSString stringWithFormat: @"%f", slope] UTF8String]);
						
						if( modality && strcmp( modality, "CT") == 0)
							dataset->putAndInsertString( DCM_RescaleType, "HU");
						else
							dataset->putAndInsertString( DCM_RescaleType, "US");
						
						if( ww != -1 && ww != -1)
						{
							dataset->putAndInsertString( DCM_WindowCenter, [[NSString stringWithFormat: @"%d", (int) wl] UTF8String]);
							dataset->putAndInsertString( DCM_WindowWidth, [[NSString stringWithFormat: @"%d", (int) ww] UTF8String]);
						}
						
						dataset->putAndInsertUint16Array(DCM_PixelData, OFstatic_cast(Uint16 *, OFconst_cast(void *, (void*) data)), height*width*spp);
						
					}
					else
					{
						delete dataset->remove( DCM_WindowWidth);
						delete dataset->remove( DCM_WindowCenter);
						
						if( spp != 3)
						{
							dataset->putAndInsertString( DCM_RescaleIntercept, "0");
							dataset->putAndInsertString( DCM_RescaleSlope, "1");
							dataset->putAndInsertString( DCM_RescaleType, "US");
						}
						else
						{
							delete dataset->remove( DCM_RescaleIntercept);
							delete dataset->remove( DCM_RescaleSlope);
							delete dataset->remove( DCM_WindowCenterWidthExplanation);
						}
						
						dataset->putAndInsertUint8Array(DCM_PixelData, OFstatic_cast(Uint8 *, OFconst_cast(void *, (void*) data)), height*width*spp);
					}
					
					delete dataset->remove( DCM_SmallestImagePixelValue);
					delete dataset->remove( DCM_LargestImagePixelValue);
					delete dataset->remove( DCM_MediaStorageSOPInstanceUID);
                    delete dataset->remove( DCM_PerFrameFunctionalGroupsSequence);
                    delete dataset->remove( DCM_IconImageSequence); // GE bug
                    
                    NSString *generatedUID = HorosDICOMExportGeneratedUID();
                    if (generatedUID.length)
                    {
                        dataset->putAndInsertString(DCM_SOPInstanceUID, [generatedUID UTF8String]);
                        metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, [generatedUID UTF8String]);
                    }
					
                    dcmtkFileFormat->chooseRepresentation( EXS_LittleEndianExplicit, NULL);
					if( dcmtkFileFormat->canWriteXfer( EXS_LittleEndianExplicit))
					{
						// Add to the current DB
						if( dstPath == nil)
							dstPath = [[[BrowserController currentBrowser] database] uniquePathForNewDataFileWithExtension:@"dcm"];
						
						OFCondition cond = dcmtkFileFormat->saveFile( [dstPath UTF8String], EXS_LittleEndianExplicit, EET_ExplicitLength, EGL_recalcGL, EPD_withoutPadding);
						OFBool fileWriteSucceeded =  (cond.good()) ? YES : NO;
                        
                        if( fileWriteSucceeded == NO)
                            NSLog( @"******* dcmtkFileFormat->saveFile failed");
					}
                    else if( triedToDecompress == NO)
                    {
                        NSLog( @"------ dcmtkFileFormat->canWriteXfer( EXS_LittleEndianExplicit) failed: try to decompress the file");
                        
                        // Try to decompress the file
                        
                        NSString *tmpFile = [@"/tmp" stringByAppendingPathComponent: dcmSourcePath.lastPathComponent];
                        [[NSFileManager defaultManager] removeItemAtPath: tmpFile error: nil];
                        [[NSFileManager defaultManager] copyItemAtPath: dcmSourcePath toPath: tmpFile error: nil];
                        [DicomDatabase decompressDicomFilesAtPaths: @[tmpFile]];
                        
                        if( [[NSFileManager defaultManager] fileExistsAtPath: tmpFile])
                        {
                            if( squaredata)
                                free( squaredata);
                            squaredata = nil;
                            
                            triedToDecompress = YES;
                            
                            [dcmSourcePath release];
                            dcmSourcePath = [tmpFile retain];
                            
                            NSString *f = [self writeDCMFile: dstPath];
                            
                            [[NSFileManager defaultManager] removeItemAtPath: tmpFile error: nil];
                            
                            triedToDecompress = YES;
                            
                            return f;
                        }
					}
                    
					if( squaredata)
						free( squaredata);
					squaredata = nil;
					
					return dstPath;
				}
			}
		}
		@catch (NSException *e)
		{
			NSLog( @"*********** WriteDCMFile failed : %@", e);
			return nil;
		}
	}
	else return nil;
	
	return nil;
}
@end
