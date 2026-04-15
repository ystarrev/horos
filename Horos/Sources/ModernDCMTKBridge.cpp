#include "ModernDCMTKBridge.h"

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcdicent.h>
#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmsr/dsrdoc.h>
#include <dcmtk/dcmsr/dsrtypes.h>
#include <dcmtk/ofstd/ofstd.h>
#include <dcmtk/ofstd/ofstrutl.h>

#include <cstdlib>
#include <cstring>
#include <sstream>
#include <vector>

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

char* HorosModernDCMTKCopyFieldByTag(const char* path, unsigned short group, unsigned short element)
{
    if (path == nullptr || path[0] == '\0')
        return nullptr;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return nullptr;

    DcmTagKey key(group, element);
    OFString value;
    DcmDataset* dataset = fileformat.getDataset();
    if (dataset != nullptr && dataset->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateCString(value.c_str());

    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (metaInfo != nullptr && metaInfo->findAndGetOFString(key, value, OFFalse).good() && !value.empty())
        return HorosModernDCMTKDuplicateCString(value.c_str());

    return nullptr;
}

int HorosModernDCMTKReplaceTagValue(const char* path, unsigned short group, unsigned short element, const char* value, int removeIfEmpty)
{
    if (path == nullptr || path[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    OFCondition status = fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    const DcmTagKey key(group, element);
    const bool shouldRemove = (removeIfEmpty != 0) && (value == nullptr || value[0] == '\0');

    if (shouldRemove)
        status = dataset->findAndDeleteElement(key);
    else
        status = dataset->putAndInsertString(key, value != nullptr ? value : "", OFTrue);

    if (status.bad())
        return 0;

    E_TransferSyntax originalXfer = dataset->getOriginalXfer();
    status = fileformat.saveFile(path, originalXfer, EET_UndefinedLength, EGL_recalcGL, EPD_withoutPadding);
    return status.good() ? 1 : 0;
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

int HorosModernDCMTKCopyImageGeometry(const char* path, double* origin3, double* orientation9)
{
    if (origin3)
        std::memset(origin3, 0, sizeof(double) * 3);
    if (orientation9)
        std::memset(orientation9, 0, sizeof(double) * 9);

    if (path == nullptr || path[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    int found = 0;
    if (origin3)
    {
        int count = 0;
        while (count < 3 && dataset->findAndGetFloat64(DCM_ImagePositionPatient, origin3[count], count, OFFalse).good())
            count++;
        if (count == 3)
            found = 1;
    }

    if (orientation9)
    {
        int count = 0;
        while (count < 6 && dataset->findAndGetFloat64(DCM_ImageOrientationPatient, orientation9[count], count, OFFalse).good())
            count++;
        if (count == 6)
            found = 1;
    }

    return found;
}

int HorosModernDCMTKCopyFrameGeometry(const char* path, double** sliceLocations, int* sliceCount, double** triggerDelays, int* triggerCount)
{
    if (sliceLocations)
        *sliceLocations = nullptr;
    if (sliceCount)
        *sliceCount = 0;
    if (triggerDelays)
        *triggerDelays = nullptr;
    if (triggerCount)
        *triggerCount = 0;

    if (path == nullptr || path[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    std::vector<double> locations;
    std::vector<double> triggers;

    double orientationMultiFrame[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    double originMultiFrame[3] = {0, 0, 0};

    DcmItem* sharedItem = nullptr;
    if (dataset->findAndGetSequenceItem(DCM_SharedFunctionalGroupsSequence, sharedItem, 0).good())
    {
        DcmItem* eitem = nullptr;
        if (sharedItem->findAndGetSequenceItem(DCM_PlanePositionVolumeSequence, eitem, 0).good())
        {
            int count = 0;
            while (count < 6 && eitem->findAndGetFloat64(DCM_ImageOrientationVolume, orientationMultiFrame[count], count, OFFalse).good())
                count++;
        }
    }

    int frameIndex = 0;
    DcmItem* perFrameItem = nullptr;
    while (dataset->findAndGetSequenceItem(DCM_PerFrameFunctionalGroupsSequence, perFrameItem, frameIndex++).good())
    {
        int x = 0;
        DcmItem* eitem = nullptr;
        while (true)
        {
            if (perFrameItem->findAndGetSequenceItem(DCM_CardiacTriggerSequence, eitem, x).good())
            {
                Float64 trigger = 0;
                if (eitem->findAndGetFloat64(DCM_TriggerDelayTime, trigger, 0, OFFalse).good())
                    triggers.push_back(trigger);
            }

            bool succeed = true;
            if (perFrameItem->findAndGetSequenceItem(DCM_PlanePositionVolumeSequence, eitem, x).good())
            {
                int count = 0;
                while (count < 3 && eitem->findAndGetFloat64(DCM_ImagePositionVolume, originMultiFrame[count], count, OFFalse).good())
                    count++;
                if (count != 3)
                    succeed = false;
            }
            else
            {
                succeed = false;
            }

            if (!succeed)
            {
                succeed = true;
                if (perFrameItem->findAndGetSequenceItem(DCM_PlanePositionSequence, eitem, x).good())
                {
                    int count = 0;
                    while (count < 3 && eitem->findAndGetFloat64(DCM_ImagePositionPatient, originMultiFrame[count], count, OFFalse).good())
                        count++;
                    if (count != 3)
                        succeed = false;
                }
                else
                {
                    succeed = false;
                }

                if (perFrameItem->findAndGetSequenceItem(DCM_PlaneOrientationSequence, eitem, x).good())
                {
                    int count = 0;
                    while (count < 6 && eitem->findAndGetFloat64(DCM_ImageOrientationPatient, orientationMultiFrame[count], count, OFFalse).good())
                        count++;
                    if (count != 6 && count != 0)
                        succeed = false;
                }
                else
                {
                    succeed = false;
                }
            }

            if (succeed)
            {
                orientationMultiFrame[6] = orientationMultiFrame[1] * orientationMultiFrame[5] - orientationMultiFrame[2] * orientationMultiFrame[4];
                orientationMultiFrame[7] = orientationMultiFrame[2] * orientationMultiFrame[3] - orientationMultiFrame[0] * orientationMultiFrame[5];
                orientationMultiFrame[8] = orientationMultiFrame[0] * orientationMultiFrame[4] - orientationMultiFrame[1] * orientationMultiFrame[3];

                double location = 0;
                if (fabs(orientationMultiFrame[6]) > fabs(orientationMultiFrame[7]) && fabs(orientationMultiFrame[6]) > fabs(orientationMultiFrame[8]))
                    location = originMultiFrame[0];
                if (fabs(orientationMultiFrame[7]) > fabs(orientationMultiFrame[6]) && fabs(orientationMultiFrame[7]) > fabs(orientationMultiFrame[8]))
                    location = originMultiFrame[1];
                if (fabs(orientationMultiFrame[8]) > fabs(orientationMultiFrame[6]) && fabs(orientationMultiFrame[8]) > fabs(orientationMultiFrame[7]))
                    location = originMultiFrame[2];

                locations.push_back(location);
            }

            x++;
            if (eitem == nullptr)
                break;
        }
    }

    if (sliceLocations && !locations.empty())
    {
        *sliceLocations = static_cast<double*>(std::malloc(sizeof(double) * locations.size()));
        if (*sliceLocations)
            std::memcpy(*sliceLocations, locations.data(), sizeof(double) * locations.size());
        if (sliceCount)
            *sliceCount = static_cast<int>(locations.size());
    }

    if (triggerDelays && !triggers.empty())
    {
        *triggerDelays = static_cast<double*>(std::malloc(sizeof(double) * triggers.size()));
        if (*triggerDelays)
            std::memcpy(*triggerDelays, triggers.data(), sizeof(double) * triggers.size());
        if (triggerCount)
            *triggerCount = static_cast<int>(triggers.size());
    }

    return (locations.empty() && triggers.empty()) ? 0 : 1;
}

int HorosModernDCMTKCopyEncapsulatedDocument(const char* path, unsigned char** buffer, unsigned long* length)
{
    if (buffer)
        *buffer = nullptr;
    if (length)
        *length = 0;

    if (path == nullptr || path[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    const Uint8* data = nullptr;
    unsigned long dataLength = 0;
    if (dataset->findAndGetUint8Array(DCM_EncapsulatedDocument, data, &dataLength, OFFalse).good() && data != nullptr && dataLength > 0)
    {
        unsigned char* copy = static_cast<unsigned char*>(std::malloc(dataLength));
        if (copy == nullptr)
            return 0;
        std::memcpy(copy, data, dataLength);
        if (buffer)
            *buffer = copy;
        if (length)
            *length = dataLength;
        return 1;
    }

    return 0;
}

char* HorosModernDCMTKCopyStructuredReportHTML(const char* path)
{
    if (path == nullptr || path[0] == '\0')
        return nullptr;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return nullptr;

    const char* sopClassUID = nullptr;
    if (fileformat.getDataset()->findAndGetString(DCM_SOPClassUID, sopClassUID, OFFalse).bad() ||
        sopClassUID == nullptr ||
        !DSRTypes::isDocumentStorageUID(sopClassUID)) {
        return nullptr;
    }

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

static bool HorosModernDCMTKLoadStructuredReport(const char* path, DcmFileFormat& fileformat, DSRDocument& document)
{
    if (path == nullptr || path[0] == '\0')
        return false;

    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return false;

    const char* sopClassUID = nullptr;
    if (fileformat.getDataset()->findAndGetString(DCM_SOPClassUID, sopClassUID, OFFalse).bad() ||
        sopClassUID == nullptr ||
        !DSRTypes::isDocumentStorageUID(sopClassUID))
        return false;

    const size_t readFlags =
        DSRTypes::RF_acceptUnknownRelationshipType |
        DSRTypes::RF_ignoreRelationshipConstraints |
        DSRTypes::RF_ignoreContentItemErrors |
        DSRTypes::RF_skipInvalidContentItems;

    return document.read(*fileformat.getDataset(), readFlags).good();
}

char* HorosModernDCMTKCopyStructuredReportKeyObjectType(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    document.getTree().gotoRoot();
    const OFString codeMeaning = document.getTree().getCurrentContentItem().getConceptName().getCodeMeaning();
    if (codeMeaning.empty())
        return nullptr;

    return HorosModernDCMTKDuplicateCString(codeMeaning.c_str());
}

char* HorosModernDCMTKCopyStructuredReportReferencedSOPInstanceUIDs(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    std::vector<OFString> uids;
    DSRDocumentTree& tree = document.getTree();
    tree.gotoRoot();
    do
    {
        DSRDocumentTreeNode* node = OFstatic_cast(DSRDocumentTreeNode*, tree.getNode());
        if (node != nullptr && node->getValueType() == DSRTypes::VT_Image)
        {
            DSRImageTreeNode* imageNode = OFstatic_cast(DSRImageTreeNode*, node);
            OFString sopInstance = imageNode->getSOPInstanceUID();
            if (!sopInstance.empty())
                uids.push_back(sopInstance);
        }
    } while (tree.iterate());

    if (uids.empty())
        return nullptr;

    OFString joined;
    for (size_t index = 0; index < uids.size(); ++index)
    {
        if (index > 0)
            joined += "\\";
        joined += uids[index];
    }

    return HorosModernDCMTKDuplicateCString(joined.c_str());
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

void HorosModernDCMTKFreeBuffer(void* buffer)
{
    std::free(buffer);
}

void HorosModernDCMTKFreeString(char* value)
{
    std::free(value);
}
