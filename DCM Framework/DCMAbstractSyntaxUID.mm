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

#import "DCMAbstractSyntaxUID.h"

#include <dcmtk/dcmdata/dcuid.h>

static NSArray *imagesSyntaxes = nil;
static NSArray *hiddenImagesSyntaxes = nil;
static NSArray *allSupportedSyntaxes = nil;

// DCMTK supplies standard identifiers; retain Horos's vendor-specific extensions.
static NSString * const DCM_Verification = @UID_VerificationSOPClass;
static NSString * const ComputedRadiographyImageStorage = @UID_ComputedRadiographyImageStorage;
static NSString * const DigitalXRayImageStorageForPresentation = @UID_DigitalXRayImageStorageForPresentation;
static NSString * const DigitalXRayImageStorageForProcessing = @UID_DigitalXRayImageStorageForProcessing;
static NSString * const DigitalMammographyXRayImageStorageForPresentation = @UID_DigitalMammographyXRayImageStorageForPresentation;
static NSString * const DigitalMammographyXRayImageStorageForProcessing = @UID_DigitalMammographyXRayImageStorageForProcessing;
static NSString * const DigitalIntraoralXRayImageStorageForPresentation = @UID_DigitalIntraOralXRayImageStorageForPresentation;
static NSString * const DigitalIntraoralXRayImageStorageForProcessing = @UID_DigitalIntraOralXRayImageStorageForProcessing;
static NSString * const CTImageStorage = @UID_CTImageStorage;
static NSString * const EnhancedCTImageStorage = @UID_EnhancedCTImageStorage;
static NSString * const EnhancedPETImageStorage = @UID_EnhancedPETImageStorage;
static NSString * const UltrasoundMultiframeImageStorageRetired = @UID_RETIRED_UltrasoundMultiframeImageStorage;
static NSString * const UltrasoundMultiframeImageStorage = @UID_UltrasoundMultiframeImageStorage;
static NSString * const MRImageStorage = @UID_MRImageStorage;
static NSString * const EnhancedMRImageStorage = @UID_EnhancedMRImageStorage;
static NSString * const NuclearMedicineImageStorageRetired = @UID_RETIRED_NuclearMedicineImageStorage;
static NSString * const UltrasoundImageStorageRetired = @UID_RETIRED_UltrasoundImageStorage;
static NSString * const UltrasoundImageStorage = @UID_UltrasoundImageStorage;
static NSString * const EnhancedUSVolumeStorage = @UID_EnhancedUSVolumeStorage;
static NSString * const SecondaryCaptureImageStorage = @UID_SecondaryCaptureImageStorage;
static NSString * const MultiframeSingleBitSecondaryCaptureImageStorage = @UID_MultiframeSingleBitSecondaryCaptureImageStorage;
static NSString * const MultiframeGrayscaleByteSecondaryCaptureImageStorage = @UID_MultiframeGrayscaleByteSecondaryCaptureImageStorage;
static NSString * const MultiframeGrayscaleWordSecondaryCaptureImageStorage = @UID_MultiframeGrayscaleWordSecondaryCaptureImageStorage;
static NSString * const MultiframeTrueColorSecondaryCaptureImageStorage = @UID_MultiframeTrueColorSecondaryCaptureImageStorage;
static NSString * const XrayAngiographicImageStorage = @UID_XRayAngiographicImageStorage;
static NSString * const EnhancedXAImageStorage = @UID_EnhancedXAImageStorage;
static NSString * const XrayRadioFlouroscopicImageStorage = @UID_XRayRadiofluoroscopicImageStorage;
static NSString * const EnhancedXRFImageStorage = @UID_EnhancedXRFImageStorage;
static NSString * const XRay3DAngiographicImageStorage = @UID_XRay3DAngiographicImageStorage;
static NSString * const XRay3DCraniofacialImageStorage = @UID_XRay3DCraniofacialImageStorage;
static NSString * const BreastTomosynthesisImageStorage = @UID_BreastTomosynthesisImageStorage;
static NSString * const GE3DModelStorage = @"1.2.840.113619.4.26";
static NSString * const GECollageStorage = @"1.2.528.1.1001.5.1.1.1";
static NSString * const GEeNTEGRAProtocolOrNMGenieStorage = @"1.2.840.113619.4.27";
static NSString * const GEPETRawDataStorage = @"1.2.840.113619.4.30";
static NSString * const PhilipsCTSyntheticImageStorage = @"1.3.46.670589.5.0.9";
static NSString * const PhilipsCXImageStorage = @"1.3.46.670589.2.4.1.1";
static NSString * const PhilipsCXSyntheticImageStorage = @"1.3.46.670589.5.0.12";
static NSString * const PhilipsMRColorImageStorage = @"1.3.46.670589.11.0.0.12.3";
static NSString * const PhilipsMRSyntheticImageStorage = @"1.3.46.670589.5.0.10";
static NSString * const PhilipsPerfusionImageStorage = @"1.3.46.670589.5.0.14";
static NSString * const PhilipsPrivateXRayMFStorage = @"1.3.46.670589.7.8.1618510091";
static NSString * const PhilipsPrivatePrefixStorage = @"1.3.46.670589";
static NSString * const SiemensCSAPrivateNonImageStorage = @"1.3.12.2.1107.5.9.1";
static NSString * const XrayAngiographicBiplaneImageStorage = @UID_RETIRED_XRayAngiographicBiPlaneImageStorage;
static NSString * const NuclearMedicineImageStorage = @UID_NuclearMedicineImageStorage;
static NSString * const VisibleLightDraftImageStorage = @UID_RETIRED_VLImageStorage;
static NSString * const VisibleLightMultiFrameDraftImageStorage = @UID_RETIRED_VLMultiframeImageStorage;
static NSString * const VisibleLightEndoscopicImageStorage = @UID_VLEndoscopicImageStorage;
static NSString * const VideoEndoscopicImageStorage = @UID_VideoEndoscopicImageStorage;
static NSString * const VisibleLightMicroscopicImageStorage = @UID_VLMicroscopicImageStorage;
static NSString * const VideoMicroscopicImageStorage = @UID_VideoMicroscopicImageStorage;
static NSString * const VisibleLightSlideCoordinatesMicroscopicImageStorage = @UID_VLSlideCoordinatesMicroscopicImageStorage;
static NSString * const VisibleLightPhotographicImageStorage = @UID_VLPhotographicImageStorage;
static NSString * const VideoPhotographicImageStorage = @UID_VideoPhotographicImageStorage;
static NSString * const PETImageStorage = @UID_PositronEmissionTomographyImageStorage;
static NSString * const RTImageStorage = @UID_RTImageStorage;
static NSString * const MediaStorageDirectoryStorage = @UID_MediaStorageDirectoryStorage;
static NSString * const BasicTextSRStorage = @UID_BasicTextSRStorage;
static NSString * const EnhancedSRStorage = @UID_EnhancedSRStorage;
static NSString * const ComprehensiveSRStorage = @UID_ComprehensiveSRStorage;
static NSString * const ProcedureLogStorage = @UID_ProcedureLogStorage;
static NSString * const MammographyCADSRStorage = @UID_MammographyCADSRStorage;
static NSString * const ChestCADSR = @UID_ChestCADSRStorage;
static NSString * const XRayRadiationDoseSR = @UID_XRayRadiationDoseSRStorage;
static NSString * const KeyObjectSelectionDocumentStorage = @UID_KeyObjectSelectionDocumentStorage;
static NSString * const GrayscaleSoftcopyPresentationStateStorage = @UID_GrayscaleSoftcopyPresentationStateStorage;
static NSString * const ColorSoftcopyPresentationStateStorage = @UID_ColorSoftcopyPresentationStateStorage;
static NSString * const PseudoColorSoftcopyPresentationStateStorage = @UID_PseudoColorSoftcopyPresentationStateStorage;
static NSString * const BlendingSoftcopyPresentationStateStorage = @UID_BlendingSoftcopyPresentationStateStorage;
static NSString * const TwelveLeadECGStorage = @UID_TwelveLeadECGWaveformStorage;
static NSString * const GeneralECGStorage = @UID_GeneralECGWaveformStorage;
static NSString * const AmbulatoryECGStorage = @UID_AmbulatoryECGWaveformStorage;
static NSString * const HemodynamicWaveformStorage = @UID_HemodynamicWaveformStorage;
static NSString * const CardiacElectrophysiologyWaveformStorage = @UID_CardiacElectrophysiologyWaveformStorage;
static NSString * const BasicVoiceStorage = @UID_BasicVoiceAudioWaveformStorage;
static NSString * const StandaloneOverlayStorage = @UID_RETIRED_StandaloneOverlayStorage;
static NSString * const StandaloneCurveStorage = @UID_RETIRED_StandaloneCurveStorage;
static NSString * const StandaloneModalityLUTStorage = @UID_RETIRED_StandaloneModalityLUTStorage;
static NSString * const StandaloneVOILUTStorage = @UID_RETIRED_StandaloneVOILUTStorage;
static NSString * const StandalonePETCurveStorage = @UID_RETIRED_StandalonePETCurveStorage;
static NSString * const RTDoseStorage = @UID_RTDoseStorage;
static NSString * const RTStructureSetStorage = @UID_RTStructureSetStorage;
static NSString * const RTBeamsTreatmentRecordStorage = @UID_RTBeamsTreatmentRecordStorage;
static NSString * const RTPlanStorage = @UID_RTPlanStorage;
static NSString * const RTBrachyTreatmentRecordStorage = @UID_RTBrachyTreatmentRecordStorage;
static NSString * const RTTreatmentSummaryRecordStorage = @UID_RTTreatmentSummaryRecordStorage;
static NSString * const MRSpectroscopyStorage = @UID_MRSpectroscopyStorage;
static NSString * const RawDataStorage = @UID_RawDataStorage;
static NSString * const SegmentationStorage = @UID_SegmentationStorage;
static NSString * const StudyRootQueryRetrieveInformationModelFind = @UID_FINDStudyRootQueryRetrieveInformationModel;
static NSString * const StudyRootQueryRetrieveInformationModelMove = @UID_MOVEStudyRootQueryRetrieveInformationModel;
static NSString * const PDFStorageClassUID = @UID_EncapsulatedPDFStorage;
static NSString * const EncapsulatedCDAStorage = @UID_EncapsulatedCDAStorage;
static NSString * const BasicGrayscalePrintManagementMetaSOPClassUID = @UID_BasicGrayscalePrintManagementMetaSOPClass;
static NSString * const BasicColorPrintManagementMetaSOPClassUID = @UID_BasicColorPrintManagementMetaSOPClass;
static NSString * const OphthalmicPhotography8BitImageStorage = @UID_OphthalmicPhotography8BitImageStorage;
static NSString * const OphthalmicPhotography16BitImageStorage = @UID_OphthalmicPhotography16BitImageStorage;
static NSString * const FujiPrivateCR = @"1.2.392.200036.9125.1.1.2";
static NSString * const OphthalmicTomographyImageStorage = @UID_OphthalmicTomographyImageStorage;

@implementation DCMAbstractSyntaxUID

+ (NSArray*) allSupportedSyntaxes
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *syntaxes = [NSMutableArray array];
        [syntaxes addObjectsFromArray: [DCMAbstractSyntaxUID imageSyntaxes]];
        [syntaxes addObjectsFromArray: [DCMAbstractSyntaxUID radiotherapySyntaxes]];
        [syntaxes addObjectsFromArray: [DCMAbstractSyntaxUID structuredReportSyntaxes]];
        [syntaxes addObject: KeyObjectSelectionDocumentStorage];
        [syntaxes addObjectsFromArray: [DCMAbstractSyntaxUID presentationStateSyntaxes]];
        [syntaxes addObjectsFromArray: [DCMAbstractSyntaxUID supportedPrivateClasses]];
        [syntaxes addObjectsFromArray: [DCMAbstractSyntaxUID waveformSyntaxes]];
        [syntaxes addObjectsFromArray: [DCMAbstractSyntaxUID hiddenImageSyntaxes]];
        allSupportedSyntaxes = [syntaxes copy];
    });
    
    return  allSupportedSyntaxes;
}

+ (NSString *)verificationClassUID{
	return DCM_Verification;
}

+ (NSString *)computedRadiographyImageStorage{
	return ComputedRadiographyImageStorage;
}

+ (NSString *)digitalXRayImageStorageForPresentation{
	return DigitalXRayImageStorageForPresentation;
}

+ (NSString *)digitalXRayImageStorageForProcessing{
	return DigitalXRayImageStorageForProcessing;
}

+ (NSString *)digitalMammographyXRayImageStorageForPresentation{
	return DigitalMammographyXRayImageStorageForPresentation;
}

+ (NSString *)digitalMammographyXRayImageStorageForProcessing{
	return DigitalMammographyXRayImageStorageForProcessing;
}

+ (NSString *)digitalIntraoralXRayImageStorageForPresentation{
	return DigitalIntraoralXRayImageStorageForPresentation;
}


+ (NSString *)digitalIntraoralXRayImageStorageForProcessing{
	return DigitalIntraoralXRayImageStorageForProcessing;
}

+ (NSString *)CTImageStorage{
	return CTImageStorage;
}

+ (NSString *)EnhancedXAImageStorage{
	return EnhancedXAImageStorage;
}

+ (NSString *)XrayAngiographicImageStorage{
	return XrayAngiographicImageStorage;
}

+ (NSString *)XrayRadioFlouroscopicImageStorage{
	return XrayRadioFlouroscopicImageStorage;
}

+ (NSString *)EnhancedXRFImageStorage{
	return EnhancedXRFImageStorage;
}

+ (NSString *)XrayAngiographicBiplaneImageStorage{
	return XrayAngiographicBiplaneImageStorage;
}

+ (NSString *)XRay3DAngiographicImageStorage{
	return XRay3DAngiographicImageStorage;
}

+ (NSString *)XRay3DCraniofacialImageStorage{
	return XRay3DCraniofacialImageStorage;
}

+ (NSString *)enhancedCTImageStorage{
	return EnhancedCTImageStorage;
}

+ (NSString *)enhancedPETImageStorage{
	return EnhancedPETImageStorage;
}

+ (NSString *)ultrasoundMultiframeImageStorageRetired{
	return UltrasoundMultiframeImageStorageRetired;
}

+ (NSString *)ultrasoundMultiframeImageStorage{
	return UltrasoundMultiframeImageStorage;
}

+ (NSString *)MRImageStorage{
	return MRImageStorage;
}


+ (NSString *)enhancedMRImageStorage{
	return EnhancedMRImageStorage;
}

+ (NSString *)nuclearMedicineImageStorageRetired{
	return NuclearMedicineImageStorageRetired;
}

+ (NSString *)ultrasoundImageStorageRetired{
	return UltrasoundImageStorageRetired;
}

+ (NSString *)ultrasoundImageStorage{
	return UltrasoundImageStorage;
}

+ (NSString *)enhancedUSVolumeStorage{
	return EnhancedUSVolumeStorage;
}

+ (NSString *)secondaryCaptureImageStorage{
	return SecondaryCaptureImageStorage;
}

+ (NSString *)multiframeSingleBitSecondaryCaptureImageStorage{
	return MultiframeSingleBitSecondaryCaptureImageStorage;
}

+ (NSString *)multiframeGrayscaleByteSecondaryCaptureImageStorage{
	return MultiframeGrayscaleByteSecondaryCaptureImageStorage;
}

+ (NSString *)multiframeGrayscaleWordSecondaryCaptureImageStorage{
	return MultiframeGrayscaleWordSecondaryCaptureImageStorage;
}

+ (NSString *)multiframeTrueColorSecondaryCaptureImageStorage{
	return MultiframeTrueColorSecondaryCaptureImageStorage;
}

+ (NSString *)xrayAngiographicImageStorage{
	return XrayAngiographicImageStorage;
}

+ (NSString *)xrayRadioFlouroscopicImageStorage{
	return XrayRadioFlouroscopicImageStorage;
}

+ (NSString *)xrayAngiographicBiplaneImageStorage{
	return XrayAngiographicBiplaneImageStorage;
}

+ (NSString *)nuclearMedicineImageStorage{
	return NuclearMedicineImageStorage;
}

+ (NSString *)visibleLightDraftImageStorage{
	return VisibleLightDraftImageStorage;
}

+ (NSString *)visibleLightMultiFrameDraftImageStorage{
	return VisibleLightMultiFrameDraftImageStorage;
}

+ (NSString *)visibleLightEndoscopicImageStorage{
	return VisibleLightEndoscopicImageStorage;
}

+ (NSString *)videoEndoscopicImageStorage{
	return VideoEndoscopicImageStorage;
}

+ (NSString *)visibleLightMicroscopicImageStorage{
	return VisibleLightMicroscopicImageStorage;
}

+ (NSString *)videoMicroscopicImageStorage{
	return VideoMicroscopicImageStorage;
}

+ (NSString *)visibleLightSlideCoordinatesMicroscopicImageStorage{
	return VisibleLightSlideCoordinatesMicroscopicImageStorage;
}

+ (NSString *)visibleLightPhotographicImageStorage{
	return VisibleLightPhotographicImageStorage;
}

+ (NSString *)videoPhotographicImageStorage{
	return VideoPhotographicImageStorage;
}

+ (NSString *)PETImageStorage{
	return PETImageStorage;
}

+ (NSString *)RTImageStorage{
	return RTImageStorage;
}

+ (BOOL)isVerification:(NSString *)sopClassUID
{
		return sopClassUID != nil && (
		       [sopClassUID isEqualToString:DCM_Verification]
		);
	}

/*
 these are also multiframe, says DCMTK 
 compare(mediaSOPClassUID, UID_XRayFluoroscopyImageStorage) ||
 compare(mediaSOPClassUID, UID_NuclearMedicineImageStorage) ||
 compare(mediaSOPClassUID, UID_RTImageStorage) ||
 compare(mediaSOPClassUID, UID_RTDoseStorage) ||
 compare(mediaSOPClassUID, UID_VideoEndoscopicImageStorage) ||
 compare(mediaSOPClassUID, UID_VideoMicroscopicImageStorage) ||
 compare(mediaSOPClassUID, UID_VideoPhotographicImageStorage) ||
 compare(mediaSOPClassUID, UID_OphthalmicPhotography8BitImageStorage) ||
 compare(mediaSOPClassUID, UID_OphthalmicPhotography16BitImageStorage);
*/
+(BOOL)isMultiframe:(NSString*)sopClassUID {
    return [sopClassUID isEqualToString:[DCMAbstractSyntaxUID enhancedMRImageStorage]]
        || [sopClassUID isEqualToString:UltrasoundMultiframeImageStorage]
        || [sopClassUID isEqualToString:EnhancedCTImageStorage]
        || [sopClassUID isEqualToString:MultiframeSingleBitSecondaryCaptureImageStorage]
        || [sopClassUID isEqualToString:MultiframeGrayscaleByteSecondaryCaptureImageStorage]
        || [sopClassUID isEqualToString:MultiframeGrayscaleWordSecondaryCaptureImageStorage]
        || [sopClassUID isEqualToString:MultiframeTrueColorSecondaryCaptureImageStorage]
        || [sopClassUID isEqualToString:EnhancedXAImageStorage]
        || [sopClassUID isEqualToString:XrayAngiographicImageStorage]
        || [sopClassUID isEqualToString:XrayRadioFlouroscopicImageStorage]
        || [sopClassUID isEqualToString:EnhancedXRFImageStorage]
        || [sopClassUID isEqualToString:XrayAngiographicBiplaneImageStorage]
        || [sopClassUID isEqualToString:XRay3DAngiographicImageStorage]
        || [sopClassUID isEqualToString:XRay3DCraniofacialImageStorage]
        || [sopClassUID isEqualToString:EnhancedPETImageStorage]
        || [sopClassUID isEqualToString:BreastTomosynthesisImageStorage]
        || [sopClassUID isEqualToString:UltrasoundMultiframeImageStorageRetired];
}

+ (BOOL)isImageStorage:(NSString *)sopClassUID
{
	if( sopClassUID)
	{
		for( NSString *sopUID in [DCMAbstractSyntaxUID imageSyntaxes])
		{
			if( [sopClassUID isEqualToString: sopUID])
                return YES;
		}
	}
	
	return NO;
}

+ (BOOL) isHiddenImageStorage:(NSString *)sopClassUID
{
    if( sopClassUID)
	{
		for( NSString *sopUID in [DCMAbstractSyntaxUID hiddenImageSyntaxes])
		{
			if( [sopClassUID isEqualToString: sopUID]) return YES;
		}
	}
	
	return NO;
}

+ (NSArray *)hiddenImageSyntaxes
{
    [self imageSyntaxes];
    return hiddenImagesSyntaxes;
}

+ (NSArray *)imageSyntaxes
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
		imagesSyntaxes = [NSArray arrayWithObjects:
            ComputedRadiographyImageStorage ,
		    DigitalXRayImageStorageForPresentation ,
		    DigitalXRayImageStorageForProcessing ,
		    DigitalMammographyXRayImageStorageForPresentation ,
		    DigitalMammographyXRayImageStorageForProcessing ,
		    DigitalIntraoralXRayImageStorageForPresentation ,
		    DigitalIntraoralXRayImageStorageForProcessing ,
		    CTImageStorage ,
		    EnhancedCTImageStorage ,
			EnhancedPETImageStorage,
		    UltrasoundMultiframeImageStorageRetired ,
		    UltrasoundMultiframeImageStorage ,
		    MRImageStorage ,
		    EnhancedMRImageStorage ,
		    NuclearMedicineImageStorageRetired ,
		    UltrasoundImageStorageRetired ,
            EnhancedUSVolumeStorage,
		    UltrasoundImageStorage ,
		    SecondaryCaptureImageStorage ,
		    MultiframeSingleBitSecondaryCaptureImageStorage ,
		    MultiframeGrayscaleByteSecondaryCaptureImageStorage ,
		    MultiframeGrayscaleWordSecondaryCaptureImageStorage ,
		    MultiframeTrueColorSecondaryCaptureImageStorage,
		    XrayAngiographicImageStorage ,
		    XrayRadioFlouroscopicImageStorage ,
		    XrayAngiographicBiplaneImageStorage ,
		    NuclearMedicineImageStorage ,
		    VisibleLightDraftImageStorage ,
			VideoEndoscopicImageStorage,
		    VisibleLightMultiFrameDraftImageStorage ,
		    VisibleLightEndoscopicImageStorage ,
		    VisibleLightMicroscopicImageStorage ,
		    VisibleLightSlideCoordinatesMicroscopicImageStorage ,
		    VisibleLightPhotographicImageStorage ,
		    PETImageStorage ,
		    RTImageStorage ,
			PDFStorageClassUID ,
            EncapsulatedCDAStorage,
			OphthalmicPhotography8BitImageStorage,
			OphthalmicPhotography16BitImageStorage,
			OphthalmicTomographyImageStorage,
			FujiPrivateCR,
			EnhancedXAImageStorage,
			EnhancedXRFImageStorage,
			XRay3DAngiographicImageStorage,
			XRay3DCraniofacialImageStorage,
            PhilipsPrivateXRayMFStorage,
            PhilipsCTSyntheticImageStorage,
            PhilipsCXImageStorage,
            PhilipsCXSyntheticImageStorage,
            PhilipsMRColorImageStorage,
            PhilipsMRSyntheticImageStorage,
            PhilipsPerfusionImageStorage,
            BreastTomosynthesisImageStorage,
			nil];
		
		@try 
		{
			if( [[NSUserDefaults standardUserDefaults] arrayForKey: @"additionalDisplayedStorageSOPClassUIDArray"])
				imagesSyntaxes = [imagesSyntaxes arrayByAddingObjectsFromArray: [[NSUserDefaults standardUserDefaults] arrayForKey: @"additionalDisplayedStorageSOPClassUIDArray"]];
		}
		@catch (NSException * e) 
		{
            NSLog(@"Exception in %s: %@", __PRETTY_FUNCTION__, e.reason);
		}
        
        @try 
		{
			if( [[NSUserDefaults standardUserDefaults] arrayForKey: @"hiddenDisplayedStorageSOPClassUIDArray"])
            {
                [hiddenImagesSyntaxes release];
                hiddenImagesSyntaxes = [[[NSUserDefaults standardUserDefaults] arrayForKey: @"hiddenDisplayedStorageSOPClassUIDArray"] retain];
                
                NSMutableArray *mutableArray = [NSMutableArray arrayWithArray: imagesSyntaxes];
                
				[mutableArray removeObjectsInArray: hiddenImagesSyntaxes];
                
                imagesSyntaxes = mutableArray;
            }
		}
		@catch (NSException * e) 
		{
			NSLog( @"***** exception in %s: %@", __PRETTY_FUNCTION__, e);
		}
		
        if (!hiddenImagesSyntaxes)
            hiddenImagesSyntaxes = [[NSArray alloc] init];
        imagesSyntaxes = [imagesSyntaxes copy];
    });
	
	return imagesSyntaxes;
}
	/**
	 * @param	sopClassUID	UID of the SOP Class, as a String without trailing zero padding
	 * @return			true if the UID argument matches the Media Storage Directory Storage SOP Class (used for the DICOMDIR)
	 */
	 
+ (NSString *)mediaStorageDirectoryStorage{
	return MediaStorageDirectoryStorage;
}

+ (BOOL) isDirectory:(NSString *) sopClassUID {
		return sopClassUID != nil && (
		       [sopClassUID isEqualToString:MediaStorageDirectoryStorage]
		);
	}
	
		// Structured Report ...


+ (NSString *)basicTextSRStorage{
	return BasicTextSRStorage;
}

+ (NSString *)enhancedSRStorage{
	return EnhancedSRStorage;
}

+ (NSString *)comprehensiveSRStorage{
	return ComprehensiveSRStorage;
}

+ (NSString *)mammographyCADSRStorage{
	return MammographyCADSRStorage;
}

+ (NSString *)keyObjectSelectionDocumentStorage{
	return KeyObjectSelectionDocumentStorage;
}

+ (BOOL) isKeyObjectDocument:(NSString *)sopClassUID 
{
	return (sopClassUID != nil && [sopClassUID isEqualToString: KeyObjectSelectionDocumentStorage]);
}

+ (NSArray*) structuredReportSyntaxes
{
    return [NSArray arrayWithObjects: BasicTextSRStorage, EnhancedSRStorage, ComprehensiveSRStorage, MammographyCADSRStorage, ProcedureLogStorage, ChestCADSR, XRayRadiationDoseSR, nil];
}

+ (BOOL) isStructuredReport:(NSString *)sopClassUID
{
		if( sopClassUID != nil && [[DCMAbstractSyntaxUID structuredReportSyntaxes] containsObject: sopClassUID])
			return YES;
		
	return NO;
}

	// Presentation State ...
+ (NSString *)grayscaleSoftcopyPresentationStateStorage{
	return GrayscaleSoftcopyPresentationStateStorage;
}

+(NSArray*) presentationStateSyntaxes
{
    return [NSArray arrayWithObjects: GrayscaleSoftcopyPresentationStateStorage, ColorSoftcopyPresentationStateStorage, PseudoColorSoftcopyPresentationStateStorage, BlendingSoftcopyPresentationStateStorage, nil];
}

+ (BOOL) isPresentationState:(NSString *)sopClassUID {
		return sopClassUID != nil && [[DCMAbstractSyntaxUID presentationStateSyntaxes] containsObject: sopClassUID];
}

+ (NSArray*) supportedPrivateClasses
{
    return [NSArray arrayWithObjects:
            MRSpectroscopyStorage,
            RawDataStorage,
            PhilipsPrivatePrefixStorage,
            SiemensCSAPrivateNonImageStorage,
            GE3DModelStorage,
            GECollageStorage,
            GEeNTEGRAProtocolOrNMGenieStorage,
            GEPETRawDataStorage,
            nil];
}

+ (BOOL) isSupportedPrivateClasses:(NSString *)sopClassUID
{
    if( sopClassUID != nil)
    {
        for( NSString *s in [DCMAbstractSyntaxUID supportedPrivateClasses])
        {
            if( [sopClassUID hasPrefix: s])
                return YES;
        }
    }
	return NO; 
}

		// Waveforms ...
+ (NSString *)twelveLeadECGStorage {
	return TwelveLeadECGStorage;
}

+ (NSString *)generalECGStorage{
	return GeneralECGStorage;
}

+ (NSString *)ambulatoryECGStorage{
	return AmbulatoryECGStorage;
}

+ (NSString *)hemodynamicWaveformStorage{
	return HemodynamicWaveformStorage;
}

+ (NSString *)cardiacElectrophysiologyWaveformStorage{
	return CardiacElectrophysiologyWaveformStorage;
}

+ (NSString *)basicVoiceStorage{
	return BasicVoiceStorage;
}

+ (NSArray*) waveformSyntaxes
{
    return [NSArray arrayWithObjects: TwelveLeadECGStorage, GeneralECGStorage, AmbulatoryECGStorage, HemodynamicWaveformStorage,CardiacElectrophysiologyWaveformStorage, BasicVoiceStorage, nil];
}

+ (BOOL) isWaveform:(NSString *)sopClassUID {
		return sopClassUID != nil && [[DCMAbstractSyntaxUID waveformSyntaxes] containsObject: sopClassUID];
}
	
		// Standalone ...
+ (NSString *)standaloneOverlayStorage{
	return StandaloneOverlayStorage;
}

+ (NSString *)standaloneCurveStorage{
	return StandaloneCurveStorage;
}

+ (NSString *)standaloneModalityLUTStorage{
	return StandaloneModalityLUTStorage;
}

+ (NSString *)standaloneVOILUTStorage{
	return StandaloneVOILUTStorage;
}

+ (NSString *)standalonePETCurveStorage{
	return StandalonePETCurveStorage;
}

	/**
	 * @param	sopClassUID	UID of the SOP Class, as a String without trailing zero padding
	 * @return			true if the UID argument matches one of the known standard Standalone Storage SOP Classes (overlay, curve (including PET curve), and LUTs)
	 */
+ (BOOL) isStandalone:(NSString *)sopClassUID {
		return sopClassUID != nil && (
		       [sopClassUID isEqualToString:StandaloneOverlayStorage]
		    || [sopClassUID isEqualToString:StandaloneCurveStorage]
		    || [sopClassUID isEqualToString:StandaloneModalityLUTStorage]
		    || [sopClassUID isEqualToString:StandaloneVOILUTStorage]
		    || [sopClassUID isEqualToString:StandalonePETCurveStorage]
		);
	}

// Radiotherapy ...
+ (NSString *)RTDoseStorage{
	return RTDoseStorage;
}

+ (NSString *)RTStructureSetStorage{
	return RTStructureSetStorage;
}

+ (NSString *)RTBeamsTreatmentRecordStorage{
	return RTBeamsTreatmentRecordStorage;
}

+ (NSString *)RTPlanStorage{
	return RTPlanStorage;
}

+ (NSString *)RTBrachyTreatmentRecordStorage{
	return RTBrachyTreatmentRecordStorage;
}

+ (NSString *)RTTreatmentSummaryRecordStorage{
	return RTTreatmentSummaryRecordStorage;
}

+(NSArray*) radiotherapySyntaxes
{
    return [NSArray arrayWithObjects: RTDoseStorage, RTStructureSetStorage, RTBeamsTreatmentRecordStorage, RTPlanStorage, RTBrachyTreatmentRecordStorage, RTTreatmentSummaryRecordStorage, nil];
}

+ (BOOL)isRadiotherapy: (NSString *)sopClassUID
{
		return sopClassUID != nil && [[DCMAbstractSyntaxUID radiotherapySyntaxes] containsObject: sopClassUID];
}

// Spectroscopy ...
+ (NSString *)MRSpectroscopyStorage{
	return MRSpectroscopyStorage;
}


	/**
	 * @param	sopClassUID	UID of the SOP Class, as a String without trailing zero padding
	 * @return			true if the UID argument matches one of the known standard Spectroscopy Storage SOP Classes (currently just the MR Spectroscopy Storage SOP Class)
	 */
+ (BOOL) isSpectroscopy:(NSString *)sopClassUID {
		return sopClassUID != nil && (
		       [sopClassUID  isEqualToString:MRSpectroscopyStorage]
		);
	}


// Raw Data ...
+ (NSString *)rawDataStorage{
	return RawDataStorage;
}

	/**
	 * @param	sopClassUID	UID of the SOP Class, as a String without trailing zero padding
	 * @return			true if the UID argument matches the Raw Data Storage SOP Class
	 */
+ (BOOL) isRawData:(NSString *)sopClassUID {
		return sopClassUID != nil && (
		       [sopClassUID  isEqualToString:RawDataStorage]
		);
}

+ (NSString *)segmentationStorage {
	return SegmentationStorage;
}

+ (BOOL)isSegmentation:(NSString *)sopClassUID {
	return sopClassUID != nil && [sopClassUID isEqualToString:SegmentationStorage];
}

	/**
	 * @param	sopClassUID	UID of the SOP Class, as a String without trailing zero padding
	 * @return			true if the UID argument matches one of the known non-image Storage SOP Classes (directory, SR, presentation state, waveform, standalone, RT, spectroscopy or raw data)
	 */
+ (BOOL) isNonImageStorage:(NSString *)sopClassUID {
		return [DCMAbstractSyntaxUID isDirectory:sopClassUID] 
		    || [DCMAbstractSyntaxUID isStructuredReport:sopClassUID] 
		    || [DCMAbstractSyntaxUID isPresentationState:sopClassUID]
		    || [DCMAbstractSyntaxUID isWaveform:sopClassUID]
		    || [DCMAbstractSyntaxUID isStandalone:sopClassUID]
		    || [DCMAbstractSyntaxUID isRadiotherapy:sopClassUID]
		    || [DCMAbstractSyntaxUID isSpectroscopy:sopClassUID]
		    || [DCMAbstractSyntaxUID isRawData:sopClassUID]
		    || [DCMAbstractSyntaxUID isSegmentation:sopClassUID]
			|| [DCMAbstractSyntaxUID isPDF:sopClassUID]
            || [DCMAbstractSyntaxUID isHiddenImageStorage:sopClassUID]
		;
	}
	
+ (BOOL) isQuery:(NSString *)sopClassUID{
	return  ([sopClassUID isEqualToString:StudyRootQueryRetrieveInformationModelFind] ||
		[sopClassUID isEqualToString:StudyRootQueryRetrieveInformationModelMove]);
}
	


// Query-Retrieve SOP Classes ...
+ (NSString *)studyRootQueryRetrieveInformationModelFind{
	return StudyRootQueryRetrieveInformationModelFind;
}

+ (NSString *)studyRootQueryRetrieveInformationModelMove{
	return StudyRootQueryRetrieveInformationModelMove;
}

+ (NSString *)pdfStorageClassUID{
	return PDFStorageClassUID;
}

+ (NSString *)EncapsulatedCDAStorage{
	return EncapsulatedCDAStorage;
}
 
+ (BOOL)isPDF:(NSString *)sopClassUID{
	return [sopClassUID isEqualToString:PDFStorageClassUID];
}

- (id)initWithUID:(NSString *)uid  name:(NSString *)name  type:(NSString *)type{
	if (self = [super init]) {
		_uid = [uid retain];
		_name = [name retain];
		_type = [type retain];
	}
	return self;
}

- (void)dealloc{
	[_uid release];
	[_name release];
	[_type release];
	[super dealloc];
}
	
- (NSString *)uid{
	return _uid;
}
- (NSString *)name{
	return _name;
}
- (NSString *)type{
	return _type;
}
- (BOOL)isImageStorage{
	if ([_type isEqualToString: @"ImageStorage"])
		return YES;
	return NO;
}
- (BOOL) isDirectory{
if ([_type isEqualToString: @"Directory"])
		return YES;
	return NO;
}
- (BOOL) isStructuredReport{
	if ([_type isEqualToString: @"StructuredReport"])
		return YES;
	return NO;
}

- (BOOL) isPresentationState{
	if ([_type isEqualToString: @"PresentationState"])
		return YES;
	return NO;
}

- (BOOL) isWaveform{
	if ([_type isEqualToString: @"Waveform"])
		return YES;
	return NO;
}

- (BOOL) isStandalone{
	if ([_type isEqualToString: @"Standalone"])
		return YES;
	return NO;
}

- (BOOL)  isRadiotherapy{
	if ([_type isEqualToString: @"Radiotherapy"])
		return YES;
	return NO;
}

- (BOOL) isSpectroscopy{
	if ([_type isEqualToString: @"Spectroscopy"])
		return YES;
	return NO;
}

- (BOOL) isRawData{
	if ([_type isEqualToString: @"RawData"])
		return YES;
	return NO;
}

- (BOOL) isNonImageStorage{
	if ([_type isEqualToString: @"ImageStorage"])
		return NO;
	return YES;
}

	//Printing
+ (NSString *)basicGrayscalePrintManagementMetaSOPClassUID{
	return 	BasicGrayscalePrintManagementMetaSOPClassUID;
}

+ (NSString *)basicColorPrintManagementMetaSOPClassUID{
	return BasicColorPrintManagementMetaSOPClassUID;
}



- (NSString *)description{
	return [NSString stringWithFormat:@"Abstract Syntax:%@  name:%@  type:%@", _uid, _name, _type];
}



@end
