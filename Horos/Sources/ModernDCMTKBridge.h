#ifndef HOROS_MODERN_DCMTK_BRIDGE_H
#define HOROS_MODERN_DCMTK_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HorosModernDCMTKBasicMetadata {
    char* transferSyntaxUID;
    char* privateInformationCreatorUID;
    char* specificCharacterSet;
    char* sopClassUID;
    char* imageType;
    char* sopInstanceUID;
    char* modality;
    char* acquisitionDate;
    char* contentDate;
    char* seriesDate;
    char* studyDate;
    char* acquisitionTime;
    char* contentTime;
    char* seriesTime;
    char* studyTime;
    char* scanOptions;
    char* echoTime;
    char* instanceNumber;
    char* seriesNumber;
    char* seriesInstanceUID;
    char* studyInstanceUID;
    char* studyID;
    unsigned short rows;
    unsigned short columns;
    int numberOfFrames;
} HorosModernDCMTKBasicMetadata;

typedef struct HorosModernDCMTKDecodedFrame {
    float* pixels;
    unsigned long pixelCount;
    unsigned short rows;
    unsigned short columns;
    unsigned short bitsAllocated;
    unsigned short bitsStored;
    unsigned short pixelRepresentation;
    double slope;
    double intercept;
    double windowCenter;
    double windowWidth;
    double pixelSpacingX;
    double pixelSpacingY;
    double sliceThickness;
    double spacingBetweenSlices;
    double origin[3];
    double orientation[9];
    int isOriginDefined;
    int isRGB;
    char* failureReason;
} HorosModernDCMTKDecodedFrame;

int HorosModernDCMTKIsDICOMFile(const char* path);
char* HorosModernDCMTKCopyGeneratedUID(void);
char* HorosModernDCMTKCopySpecificCharacterSet(const char* path);
char* HorosModernDCMTKCopyField(const char* path, const char* fieldName);
char* HorosModernDCMTKCopyFieldByTag(const char* path, unsigned short group, unsigned short element);
int HorosModernDCMTKCopyBufferByTag(const char* path, unsigned short group, unsigned short element, unsigned char** buffer, unsigned long* length);
int HorosModernDCMTKWriteBufferByTag(const char* path, unsigned short group, unsigned short element, const unsigned char* buffer, unsigned long length);
int HorosModernDCMTKGetDecompressionInfo(const char* path, int* isEncapsulated, unsigned short* rows, unsigned short* columns, char** modality, char** sopClassUID);
int HorosModernDCMTKGetBasicMetadata(const char* path, HorosModernDCMTKBasicMetadata* metadata);
int HorosModernDCMTKCopyImageGeometry(const char* path, double* origin3, double* orientation9);
int HorosModernDCMTKCopyFrameGeometry(const char* path, double** sliceLocations, int* sliceCount, double** triggerDelays, int* triggerCount);
int HorosModernDCMTKCopyDecodedFrame(const char* path, unsigned long frameIndex, HorosModernDCMTKDecodedFrame* frame);
int HorosModernDCMTKCopyEncapsulatedDocument(const char* path, unsigned char** buffer, unsigned long* length);
int HorosModernDCMTKCopyFileDataInTransferSyntax(const char* path,
                                                 const char* transferSyntaxUID,
                                                 int quality,
                                                 unsigned char** buffer,
                                                 unsigned long* length);
int HorosModernDCMTKWriteFileInTransferSyntax(const char* inputPath,
                                              const char* outputPath,
                                              const char* transferSyntaxUID,
                                              int quality);
char* HorosModernDCMTKCopyStructuredReportHTML(const char* path);
char* HorosModernDCMTKCopyStructuredReportXML(const char* path);
char* HorosModernDCMTKCopyStructuredReportKeyObjectType(const char* path);
char* HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDs(const char* path);
char* HorosModernDCMTKCopyStructuredReportRootCodeMeaning(const char* path);
char* HorosModernDCMTKCopyStructuredReportPrimaryReference(const char* path);
char* HorosModernDCMTKCopyStructuredReportNamedTextValue(const char* path,
                                                         const char* codeValue,
                                                         const char* codingSchemeDesignator,
                                                         const char* codeMeaning);
char* HorosModernDCMTKCopyStructuredReportNamedTextValues(const char* path,
                                                          const char* codeValue,
                                                          const char* codingSchemeDesignator,
                                                          const char* codeMeaning);
int HorosModernDCMTKWriteCompatibilityROIStructuredReport(const char* path,
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
int HorosModernDCMTKWriteCompatibilityStructuredReport(const char* path,
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
int HorosModernDCMTKWriteKeyObjectReport(const char* path,
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
                                         int titleCode,
                                         const char* keyDescription,
                                         const char* const* imagePaths,
                                         const char* const* imageSeriesInstanceUIDs,
                                         const char* const* imageSOPInstanceUIDs,
                                         int imageCount);
int HorosModernDCMTKWriteStructuredReportFromXML(const char* xmlPath, const char* dicomPath);
int HorosModernDCMTKReplaceTagValue(const char* path, unsigned short group, unsigned short element, const char* value, int removeIfEmpty);
void HorosModernDCMTKFreeBasicMetadata(HorosModernDCMTKBasicMetadata* metadata);
void HorosModernDCMTKFreeDecodedFrame(HorosModernDCMTKDecodedFrame* frame);
void HorosModernDCMTKFreeString(char* value);
void HorosModernDCMTKFreeBuffer(void* buffer);

#ifdef __cplusplus
}
#endif

#endif
