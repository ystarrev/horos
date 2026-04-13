#include "ModernDCMTKBridge.h"

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcdicent.h>
#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmsr/dsrdoc.h>
#include <dcmtk/ofstd/ofstd.h>
#include <dcmtk/ofstd/ofstrutl.h>

#include <cstdlib>
#include <cstring>
#include <sstream>

static char* HorosModernDCMTKDuplicateCString(const char* value)
{
    if (value == nullptr)
        return nullptr;

    const size_t length = std::strlen(value);
    char* copy = static_cast<char*>(std::malloc(length + 1));
    if (copy == nullptr)
        return nullptr;

    std::memcpy(copy, value, length + 1);
    return copy;
}

static DcmMetaInfo* HorosModernDCMTKMetaInfo(DcmFileFormat& fileformat)
{
    return fileformat.getMetaInfo();
}

static void HorosModernDCMTKClearBasicMetadata(HorosModernDCMTKBasicMetadata* metadata)
{
    if (metadata == nullptr)
        return;

    std::memset(metadata, 0, sizeof(*metadata));
}

static void HorosModernDCMTKAssignTagString(DcmItem* item, const DcmTagKey& key, char** destination)
{
    if (item == nullptr || destination == nullptr)
        return;

    const char* value = nullptr;
    if (item->findAndGetString(key, value, OFFalse).good() && value != nullptr)
        *destination = HorosModernDCMTKDuplicateCString(value);
}

int HorosModernDCMTKIsDICOMFile(const char* path)
{
    if (path == nullptr || path[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    return fileformat.loadFile(path).good() ? 1 : 0;
}

char* HorosModernDCMTKCopySpecificCharacterSet(const char* path)
{
    if (path == nullptr || path[0] == '\0')
        return nullptr;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path).good())
        return nullptr;

    DcmDataset* dataset = fileformat.getDataset();
    const char* value = nullptr;
    if (dataset != nullptr && dataset->findAndGetString(DCM_SpecificCharacterSet, value, OFFalse).good() && value != nullptr)
        return HorosModernDCMTKDuplicateCString(value);

    return nullptr;
}

char* HorosModernDCMTKCopyField(const char* path, const char* fieldName)
{
    if (path == nullptr || path[0] == '\0' || fieldName == nullptr || fieldName[0] == '\0')
        return nullptr;

    DcmTagKey key(0xffff, 0xffff);

    const DcmDataDictionary& globalDataDict = dcmDataDict.rdlock();
    const DcmDictEntry* entry = globalDataDict.findEntry(fieldName);
    if (entry != nullptr)
        key = entry->getKey();
    dcmDataDict.rdunlock();

    if (key.getGroup() == 0xffff && key.getElement() == 0xffff)
        return nullptr;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return nullptr;

    OFString value;
    DcmDataset* dataset = fileformat.getDataset();
    if (dataset != nullptr && dataset->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateCString(value.c_str());

    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (metaInfo != nullptr && metaInfo->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateCString(value.c_str());

    return nullptr;
}

int HorosModernDCMTKGetDecompressionInfo(const char* path, int* isEncapsulated, unsigned short* rows, unsigned short* columns, char** modality, char** sopClassUID)
{
    if (isEncapsulated)
        *isEncapsulated = 0;
    if (rows)
        *rows = 0;
    if (columns)
        *columns = 0;
    if (modality)
        *modality = nullptr;
    if (sopClassUID)
        *sopClassUID = nullptr;

    if (path == nullptr || path[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    if (isEncapsulated)
    {
        DcmXfer originalXfer(dataset->getOriginalXfer());
        *isEncapsulated = (originalXfer.usesEncapsulatedFormat() && originalXfer.isPixelDataCompressed()) ? 1 : 0;
    }

    if (rows)
    {
        Uint16 value = 0;
        if (dataset->findAndGetUint16(DCM_Rows, value, OFFalse).good())
            *rows = value;
    }

    if (columns)
    {
        Uint16 value = 0;
        if (dataset->findAndGetUint16(DCM_Columns, value, OFFalse).good())
            *columns = value;
    }

    const char* stringValue = nullptr;
    if (modality && dataset->findAndGetString(DCM_Modality, stringValue, OFFalse).good() && stringValue != nullptr)
        *modality = HorosModernDCMTKDuplicateCString(stringValue);

    stringValue = nullptr;
    if (sopClassUID && dataset->findAndGetString(DCM_SOPClassUID, stringValue, OFFalse).good() && stringValue != nullptr)
        *sopClassUID = HorosModernDCMTKDuplicateCString(stringValue);

    return 1;
}

int HorosModernDCMTKGetBasicMetadata(const char* path, HorosModernDCMTKBasicMetadata* metadata)
{
    HorosModernDCMTKClearBasicMetadata(metadata);

    if (path == nullptr || path[0] == '\0' || metadata == nullptr)
        return 0;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    HorosModernDCMTKAssignTagString(metaInfo, DCM_TransferSyntaxUID, &metadata->transferSyntaxUID);
    HorosModernDCMTKAssignTagString(metaInfo, DCM_PrivateInformationCreatorUID, &metadata->privateInformationCreatorUID);

    HorosModernDCMTKAssignTagString(dataset, DCM_SpecificCharacterSet, &metadata->specificCharacterSet);
    HorosModernDCMTKAssignTagString(dataset, DCM_SOPClassUID, &metadata->sopClassUID);
    HorosModernDCMTKAssignTagString(dataset, DCM_ImageType, &metadata->imageType);
    HorosModernDCMTKAssignTagString(dataset, DCM_SOPInstanceUID, &metadata->sopInstanceUID);
    HorosModernDCMTKAssignTagString(dataset, DCM_Modality, &metadata->modality);
    HorosModernDCMTKAssignTagString(dataset, DCM_AcquisitionDate, &metadata->acquisitionDate);
    HorosModernDCMTKAssignTagString(dataset, DCM_ContentDate, &metadata->contentDate);
    HorosModernDCMTKAssignTagString(dataset, DCM_SeriesDate, &metadata->seriesDate);
    HorosModernDCMTKAssignTagString(dataset, DCM_StudyDate, &metadata->studyDate);
    HorosModernDCMTKAssignTagString(dataset, DCM_AcquisitionTime, &metadata->acquisitionTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_ContentTime, &metadata->contentTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_SeriesTime, &metadata->seriesTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_StudyTime, &metadata->studyTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_ScanOptions, &metadata->scanOptions);
    HorosModernDCMTKAssignTagString(dataset, DCM_EchoTime, &metadata->echoTime);
    HorosModernDCMTKAssignTagString(dataset, DCM_InstanceNumber, &metadata->instanceNumber);
    HorosModernDCMTKAssignTagString(dataset, DCM_SeriesNumber, &metadata->seriesNumber);
    HorosModernDCMTKAssignTagString(dataset, DCM_SeriesInstanceUID, &metadata->seriesInstanceUID);
    HorosModernDCMTKAssignTagString(dataset, DCM_StudyInstanceUID, &metadata->studyInstanceUID);
    HorosModernDCMTKAssignTagString(dataset, DCM_StudyID, &metadata->studyID);

    Uint16 rows = 0;
    if (dataset->findAndGetUint16(DCM_Rows, rows, OFFalse).good())
        metadata->rows = rows;

    Uint16 columns = 0;
    if (dataset->findAndGetUint16(DCM_Columns, columns, OFFalse).good())
        metadata->columns = columns;

    const char* numberOfFrames = nullptr;
    if (dataset->findAndGetString(DCM_NumberOfFrames, numberOfFrames, OFFalse).good() && numberOfFrames != nullptr)
        metadata->numberOfFrames = std::atoi(numberOfFrames);

    return 1;
}

char* HorosModernDCMTKCopyStructuredReportHTML(const char* path)
{
    if (path == nullptr || path[0] == '\0')
        return nullptr;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return nullptr;

    DSRDocument document;
    const size_t readFlags =
        DSRTypes::RF_acceptUnknownRelationshipType |
        DSRTypes::RF_ignoreRelationshipConstraints |
        DSRTypes::RF_ignoreContentItemErrors |
        DSRTypes::RF_skipInvalidContentItems;

    if (document.read(*fileformat.getDataset(), readFlags).bad())
        return nullptr;

    const size_t renderFlags =
        DSRTypes::HF_renderDcmtkFootnote |
        DSRTypes::HF_XHTML11Compatibility |
        DSRTypes::HF_addDocumentTypeReference;

    std::ostringstream output;
    if (document.renderHTML(output, renderFlags, nullptr, nullptr).bad())
        return nullptr;

    const std::string html = output.str();
    return HorosModernDCMTKDuplicateCString(html.c_str());
}

void HorosModernDCMTKFreeBasicMetadata(HorosModernDCMTKBasicMetadata* metadata)
{
    if (metadata == nullptr)
        return;

    std::free(metadata->transferSyntaxUID);
    std::free(metadata->privateInformationCreatorUID);
    std::free(metadata->specificCharacterSet);
    std::free(metadata->sopClassUID);
    std::free(metadata->imageType);
    std::free(metadata->sopInstanceUID);
    std::free(metadata->modality);
    std::free(metadata->acquisitionDate);
    std::free(metadata->contentDate);
    std::free(metadata->seriesDate);
    std::free(metadata->studyDate);
    std::free(metadata->acquisitionTime);
    std::free(metadata->contentTime);
    std::free(metadata->seriesTime);
    std::free(metadata->studyTime);
    std::free(metadata->scanOptions);
    std::free(metadata->echoTime);
    std::free(metadata->instanceNumber);
    std::free(metadata->seriesNumber);
    std::free(metadata->seriesInstanceUID);
    std::free(metadata->studyInstanceUID);
    std::free(metadata->studyID);
    HorosModernDCMTKClearBasicMetadata(metadata);
}

void HorosModernDCMTKFreeString(char* value)
{
    std::free(value);
}
