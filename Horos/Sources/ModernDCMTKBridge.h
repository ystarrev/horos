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

int HorosModernDCMTKIsDICOMFile(const char* path);
char* HorosModernDCMTKCopySpecificCharacterSet(const char* path);
char* HorosModernDCMTKCopyField(const char* path, const char* fieldName);
char* HorosModernDCMTKCopyFieldByTag(const char* path, unsigned short group, unsigned short element);
int HorosModernDCMTKGetDecompressionInfo(const char* path, int* isEncapsulated, unsigned short* rows, unsigned short* columns, char** modality, char** sopClassUID);
int HorosModernDCMTKGetBasicMetadata(const char* path, HorosModernDCMTKBasicMetadata* metadata);
int HorosModernDCMTKCopyImageGeometry(const char* path, double* origin3, double* orientation9);
int HorosModernDCMTKCopyFrameGeometry(const char* path, double** sliceLocations, int* sliceCount, double** triggerDelays, int* triggerCount);
int HorosModernDCMTKCopyEncapsulatedDocument(const char* path, unsigned char** buffer, unsigned long* length);
char* HorosModernDCMTKCopyStructuredReportHTML(const char* path);
char* HorosModernDCMTKCopyStructuredReportKeyObjectType(const char* path);
char* HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDs(const char* path);
int HorosModernDCMTKReplaceTagValue(const char* path, unsigned short group, unsigned short element, const char* value, int removeIfEmpty);
void HorosModernDCMTKFreeBasicMetadata(HorosModernDCMTKBasicMetadata* metadata);
void HorosModernDCMTKFreeString(char* value);
void HorosModernDCMTKFreeBuffer(void* buffer);

#ifdef __cplusplus
}
#endif

#endif
