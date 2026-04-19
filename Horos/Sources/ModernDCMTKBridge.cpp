#include "ModernDCMTKBridge.h"

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcdicent.h>
#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmsr/dsrdoc.h>
#include <dcmtk/dcmsr/dsrtypes.h>
#include <dcmtk/dcmjpeg/djdecode.h>
#include <dcmtk/dcmjpeg/djencode.h>
#include <dcmtk/dcmjpeg/djrplol.h>
#include <dcmtk/dcmjpeg/djrploss.h>
#include <dcmtk/dcmjpls/djdecode.h>
#include <dcmtk/dcmjpls/djencode.h>
#include <dcmtk/dcmjpls/djrparam.h>
#if __has_include(<dcmtk/dcmj2k/djdecode.h>) && __has_include(<dcmtk/dcmj2k/djencode.h>) && __has_include(<dcmtk/dcmj2k/djrparam.h>)
#include <dcmtk/dcmj2k/djdecode.h>
#include <dcmtk/dcmj2k/djencode.h>
#include <dcmtk/dcmj2k/djrparam.h>
#define HOROS_HAS_DCMJ2K 1
#else
#define HOROS_HAS_DCMJ2K 0
#endif
#if __has_include(<dcmtk/dcmrle/dcrledrg.h>) && __has_include(<dcmtk/dcmrle/dcrleerg.h>) && __has_include(<dcmtk/dcmrle/dcrlerp.h>)
#include <dcmtk/dcmrle/dcrledrg.h>
#include <dcmtk/dcmrle/dcrleerg.h>
#include <dcmtk/dcmrle/dcrlerp.h>
#define HOROS_HAS_DCMRLE 1
#else
#define HOROS_HAS_DCMRLE 0
#endif
#include <dcmtk/ofstd/ofstd.h>
#include <dcmtk/ofstd/ofstrutl.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <vector>

static bool HorosModernDCMTKLoadStructuredReport(const char* path, DcmFileFormat& fileformat, DSRDocument& document);

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

static void HorosModernDCMTKEnsureCodecRegistration()
{
    static bool registered = false;
    if (registered)
        return;

    DJDecoderRegistration::registerCodecs();
    DJEncoderRegistration::registerCodecs();
#if HOROS_HAS_DCMRLE
    DcmRLEDecoderRegistration::registerCodecs();
    DcmRLEEncoderRegistration::registerCodecs();
#endif
    DJLSDecoderRegistration::registerCodecs();
    DJLSEncoderRegistration::registerCodecs();
#if HOROS_HAS_DCMJ2K
    DJ2KDecoderRegistration::registerCodecs();
    DJ2KEncoderRegistration::registerCodecs();
#endif

    registered = true;
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

static bool HorosModernDCMTKKeyObjectTitle(int titleCode, const char*& codeValue, const char*& codeMeaning)
{
    switch (titleCode)
    {
        case 113000: codeValue = "113000"; codeMeaning = "Of Interest"; return true;
        case 113001: codeValue = "113001"; codeMeaning = "Rejected for Quality Reasons"; return true;
        case 113002: codeValue = "113002"; codeMeaning = "For Referring Provider"; return true;
        case 113003: codeValue = "113003"; codeMeaning = "For Surgery"; return true;
        case 113004: codeValue = "113004"; codeMeaning = "For Teaching"; return true;
        case 113005: codeValue = "113005"; codeMeaning = "For Conference"; return true;
        case 113006: codeValue = "113006"; codeMeaning = "For Therapy"; return true;
        case 113007: codeValue = "113007"; codeMeaning = "For Patient"; return true;
        case 113008: codeValue = "113008"; codeMeaning = "For Peer Review"; return true;
        case 113009: codeValue = "113009"; codeMeaning = "For Research"; return true;
        case 113010: codeValue = "113010"; codeMeaning = "Quality Issue"; return true;
        case 113013: codeValue = "113013"; codeMeaning = "Best In Set"; return true;
        case 113018: codeValue = "113018"; codeMeaning = "For Printing"; return true;
        case 113020: codeValue = "113020"; codeMeaning = "For Report Attachment"; return true;
        default: return false;
    }
}

static OFCondition HorosModernDCMTKBuildKeyObjectReport(DSRDocument& document,
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
                                                        int imageCount)
{
    if (studyInstanceUID == nullptr || studyInstanceUID[0] == '\0')
        return EC_IllegalParameter;

    const char* codeValue = nullptr;
    const char* codeMeaning = nullptr;
    if (!HorosModernDCMTKKeyObjectTitle(titleCode, codeValue, codeMeaning))
        return EC_IllegalParameter;

    OFCondition status = document.createNewDocument(DSRTypes::DT_KeyObjectSelectionDocument);
    if (status.good())
        status = document.setSpecificCharacterSet("ISO_IR 192");
    if (status.good())
        status = document.createNewSeriesInStudy(studyInstanceUID);
    if (status.bad())
        return status;

    if (status.good() && studyDescription != nullptr && studyDescription[0] != '\0')
        status = document.setStudyDescription(studyDescription);
    if (status.good())
        status = document.setSeriesDescription("OsiriX Key Object Report");
    if (status.good() && patientName != nullptr && patientName[0] != '\0')
        status = document.setPatientName(patientName);
    if (status.good() && patientBirthDate != nullptr && patientBirthDate[0] != '\0')
        status = document.setPatientBirthDate(patientBirthDate);
    if (status.good() && patientSex != nullptr && patientSex[0] != '\0')
        status = document.setPatientSex(patientSex);
    if (status.good() && patientID != nullptr && patientID[0] != '\0')
        status = document.setPatientID(patientID);
    if (status.good() && referringPhysician != nullptr && referringPhysician[0] != '\0')
        status = document.setReferringPhysicianName(referringPhysician);
    if (status.good() && studyID != nullptr && studyID[0] != '\0')
        status = document.setStudyID(studyID);
    if (status.good() && accessionNumber != nullptr && accessionNumber[0] != '\0')
        status = document.setAccessionNumber(accessionNumber);
    if (status.good())
        status = document.setSeriesNumber("5002");
    if (status.good())
        status = document.setManufacturer("OsiriX");
    if (status.bad())
        return status;

    DSRDocumentTree& tree = document.getTree();
    if (tree.addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container) == 0)
        return EC_IllegalCall;

    status = tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue(codeValue, "DCM", codeMeaning));
    if (status.bad())
        return status;

    if (keyDescription != nullptr && keyDescription[0] != '\0')
    {
        if (tree.addContentItem(DSRTypes::RT_hasObsContext, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent) == 0)
            return EC_IllegalCall;
        status = tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("113012", "DCM", "Key Object Description"));
        if (status.bad())
            return status;
        status = tree.getCurrentContentItem().setStringValue(keyDescription);
        if (status.bad())
            return status;
        tree.goUp();
    }

    bool first = true;
    for (int index = 0; index < imageCount; ++index)
    {
        const char* imagePath = (imagePaths != nullptr) ? imagePaths[index] : nullptr;
        const char* imageSeriesUID = (imageSeriesInstanceUIDs != nullptr) ? imageSeriesInstanceUIDs[index] : nullptr;
        const char* imageSOPInstanceUID = (imageSOPInstanceUIDs != nullptr) ? imageSOPInstanceUIDs[index] : nullptr;
        if (imagePath == nullptr || imagePath[0] == '\0' ||
            imageSeriesUID == nullptr || imageSeriesUID[0] == '\0' ||
            imageSOPInstanceUID == nullptr || imageSOPInstanceUID[0] == '\0')
            continue;

        DcmFileFormat imageFile;
        if (imageFile.loadFile(imagePath, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).bad())
            continue;

        OFString sopClassUID;
        if (imageFile.getDataset() == nullptr ||
            imageFile.getDataset()->findAndGetOFString(DCM_SOPClassUID, sopClassUID, OFFalse).bad() ||
            sopClassUID.empty())
            continue;

        if (tree.addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, first ? DSRTypes::AM_belowCurrent : DSRTypes::AM_afterCurrent) == 0)
            return EC_IllegalCall;
        first = false;

        status = tree.getCurrentContentItem().setImageReference(DSRImageReferenceValue(sopClassUID, OFString(imageSOPInstanceUID)));
        if (status.bad())
            return status;

        status = document.getCurrentRequestedProcedureEvidence().addItem(OFString(studyInstanceUID),
                                                                         OFString(imageSeriesUID),
                                                                         sopClassUID,
                                                                         OFString(imageSOPInstanceUID));
        if (status.bad())
            return status;
    }

    if (!first)
        tree.goUp();

    return EC_Normal;
}

int HorosModernDCMTKIsDICOMFile(const char* path)
{
    if (path == nullptr || path[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    return fileformat.loadFile(path).good() ? 1 : 0;
}

char* HorosModernDCMTKCopyGeneratedUID(void)
{
    char uid[100];
    return HorosModernDCMTKDuplicateCString(dcmGenerateUniqueIdentifier(uid));
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

int HorosModernDCMTKCopyBufferByTag(const char* path, unsigned short group, unsigned short element, unsigned char** buffer, unsigned long* length)
{
    if (buffer == nullptr || length == nullptr)
        return 0;

    *buffer = nullptr;
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
    if (dataset->findAndGetUint8Array(DcmTagKey(group, element), data, &dataLength, OFFalse).bad() ||
        data == nullptr || dataLength == 0)
        return 0;

    unsigned char* copy = static_cast<unsigned char*>(std::malloc(dataLength));
    if (copy == nullptr)
        return 0;

    std::memcpy(copy, data, dataLength);
    *buffer = copy;
    *length = dataLength;
    return 1;
}


int HorosModernDCMTKCopyFileDataInTransferSyntax(const char* path,
                                                 const char* transferSyntaxUID,
                                                 int quality,
                                                 unsigned char** buffer,
                                                 unsigned long* length)
{
    if (buffer)
        *buffer = nullptr;
    if (length)
        *length = 0;

    if (path == nullptr || path[0] == '\0' || transferSyntaxUID == nullptr || transferSyntaxUID[0] == '\0' || buffer == nullptr || length == nullptr)
        return 0;

    DcmFileFormat fileformat;
    OFCondition status = fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    DcmXfer originalXfer(dataset->getOriginalXfer());
    DcmXfer requestedXfer(transferSyntaxUID);
    if (requestedXfer.getXfer() == EXS_Unknown)
        return 0;

    const E_TransferSyntax originalSyntax = originalXfer.getXfer();
    const E_TransferSyntax requestedSyntax = requestedXfer.getXfer();
    const bool syntaxEquivalent =
        (originalSyntax == requestedSyntax) ||
        (originalSyntax == EXS_JPEG2000 && requestedSyntax == EXS_JPEG2000LosslessOnly) ||
        (originalSyntax == EXS_JPEG2000LosslessOnly && requestedSyntax == EXS_JPEG2000) ||
        (originalSyntax == EXS_JPEGLSLossy && requestedSyntax == EXS_JPEGLSLossless) ||
        (originalSyntax == EXS_JPEGLSLossless && requestedSyntax == EXS_JPEGLSLossy);

    auto copyFileBytes = [&](const char* sourcePath) -> int {
        FILE* fp = std::fopen(sourcePath, "rb");
        if (fp == nullptr)
            return 0;

        if (std::fseek(fp, 0, SEEK_END) != 0)
        {
            std::fclose(fp);
            return 0;
        }

        const long size = std::ftell(fp);
        if (size < 0)
        {
            std::fclose(fp);
            return 0;
        }

        if (std::fseek(fp, 0, SEEK_SET) != 0)
        {
            std::fclose(fp);
            return 0;
        }

        unsigned char* data = static_cast<unsigned char*>(std::malloc(static_cast<size_t>(size)));
        if (data == nullptr && size > 0)
        {
            std::fclose(fp);
            return 0;
        }

        const size_t readLength = (size > 0) ? std::fread(data, 1, static_cast<size_t>(size), fp) : 0;
        std::fclose(fp);
        if (readLength != static_cast<size_t>(size))
        {
            std::free(data);
            return 0;
        }

        *buffer = data;
        *length = static_cast<unsigned long>(readLength);
        return 1;
    };

    if (syntaxEquivalent)
        return copyFileBytes(path);

    HorosModernDCMTKEnsureCodecRegistration();

    DcmRepresentationParameter* params = nullptr;
    DJ_RPLossy lossyParams(90);
    DJ_RPLossy jpeg2000Params(quality);
    DJ_RPLossy jpeg2000LosslessParams(quality);
#if HOROS_HAS_DCMRLE
    DcmRLERepresentationParameter rleParams;
#endif
    DJ_RPLossless losslessParams(6, 0);

    if (requestedSyntax == EXS_JPEGProcess14SV1)
        params = &losslessParams;
    else if (requestedSyntax == EXS_JPEGProcess2_4)
        params = &lossyParams;
    else if (requestedSyntax == EXS_RLELossless)
#if HOROS_HAS_DCMRLE
        params = &rleParams;
#else
        return 0;
#endif
    else if (requestedSyntax == EXS_JPEG2000LosslessOnly)
        params = &jpeg2000LosslessParams;
    else if (requestedSyntax == EXS_JPEG2000)
        params = &jpeg2000Params;
    else if (requestedSyntax == EXS_JPEGLSLossless)
        params = &jpeg2000LosslessParams;
    else if (requestedSyntax == EXS_JPEGLSLossy)
        params = &jpeg2000Params;

    dataset->chooseRepresentation(requestedSyntax, params);
    if (!dataset->canWriteXfer(requestedSyntax))
        return 0;

    char tempPath[256];
    std::snprintf(tempPath, sizeof(tempPath), "/tmp/horos-modern-bridge-%u.dcm", static_cast<unsigned>(std::rand()));
    status = fileformat.saveFile(tempPath, requestedSyntax);
    if (status.bad())
        return 0;

    const int copied = copyFileBytes(tempPath);
    std::remove(tempPath);
    return copied;
}


int HorosModernDCMTKWriteFileInTransferSyntax(const char* inputPath,
                                              const char* outputPath,
                                              const char* transferSyntaxUID,
                                              int quality)
{
    if (inputPath == nullptr || inputPath[0] == '\0' || outputPath == nullptr || outputPath[0] == '\0' ||
        transferSyntaxUID == nullptr || transferSyntaxUID[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    OFCondition status = fileformat.loadFile(inputPath, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect);
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    DcmXfer originalXfer(dataset->getOriginalXfer());
    DcmXfer requestedXfer(transferSyntaxUID);
    if (requestedXfer.getXfer() == EXS_Unknown)
        return 0;

    const E_TransferSyntax originalSyntax = originalXfer.getXfer();
    const E_TransferSyntax requestedSyntax = requestedXfer.getXfer();
    const bool syntaxEquivalent =
        (originalSyntax == requestedSyntax) ||
        (originalSyntax == EXS_JPEG2000 && requestedSyntax == EXS_JPEG2000LosslessOnly) ||
        (originalSyntax == EXS_JPEG2000LosslessOnly && requestedSyntax == EXS_JPEG2000) ||
        (originalSyntax == EXS_JPEGLSLossy && requestedSyntax == EXS_JPEGLSLossless) ||
        (originalSyntax == EXS_JPEGLSLossless && requestedSyntax == EXS_JPEGLSLossy);

    if (!syntaxEquivalent)
    {
        HorosModernDCMTKEnsureCodecRegistration();

        DcmRepresentationParameter* params = nullptr;
        DJ_RPLossy lossyParams(90);
        DJ_RPLossy jpeg2000Params(quality);
        DJ_RPLossy jpeg2000LosslessParams(quality);
#if HOROS_HAS_DCMRLE
        DcmRLERepresentationParameter rleParams;
#endif
        DJ_RPLossless losslessParams(6, 0);

        if (requestedSyntax == EXS_JPEGProcess14SV1)
            params = &losslessParams;
        else if (requestedSyntax == EXS_JPEGProcess2_4)
            params = &lossyParams;
        else if (requestedSyntax == EXS_RLELossless)
#if HOROS_HAS_DCMRLE
            params = &rleParams;
#else
            return 0;
#endif
        else if (requestedSyntax == EXS_JPEG2000LosslessOnly)
            params = &jpeg2000LosslessParams;
        else if (requestedSyntax == EXS_JPEG2000)
            params = &jpeg2000Params;
        else if (requestedSyntax == EXS_JPEGLSLossless)
            params = &jpeg2000LosslessParams;
        else if (requestedSyntax == EXS_JPEGLSLossy)
            params = &jpeg2000Params;

        dataset->chooseRepresentation(requestedSyntax, params);
        if (!dataset->canWriteXfer(requestedSyntax))
            return 0;
    }

    fileformat.loadAllDataIntoMemory();
    status = fileformat.saveFile(outputPath, requestedSyntax);
    return status.good() ? 1 : 0;
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
    const DcmTagKey cardiacTriggerSequenceTag(0x0018, 0x9118);
    const DcmTagKey triggerDelayTimeTag(0x0020, 0x9153);

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
            if (perFrameItem->findAndGetSequenceItem(cardiacTriggerSequenceTag, eitem, x).good())
            {
                Float64 trigger = 0;
                if (eitem->findAndGetFloat64(triggerDelayTimeTag, trigger, 0, OFFalse).good())
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

int HorosModernDCMTKWriteBufferByTag(const char* path, unsigned short group, unsigned short element, const unsigned char* buffer, unsigned long length)
{
    if (path == nullptr || path[0] == '\0' || buffer == nullptr || length == 0)
        return 0;

    DcmFileFormat fileformat;
    if (!fileformat.loadFile(path, EXS_Unknown, EGL_noChange, DCM_MaxReadLength, ERM_autoDetect).good())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    if (dataset == nullptr)
        return 0;

    const DcmTagKey key(group, element);
    if (dataset->putAndInsertUint8Array(key, buffer, length, OFTrue).bad())
        return 0;

    const E_TransferSyntax originalXfer = fileformat.getDataset()->getOriginalXfer();
    OFCondition status = fileformat.saveFile(path, originalXfer, EET_UndefinedLength, EGL_recalcGL, EPD_withoutPadding);
    return status.good() ? 1 : 0;
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
        DSRTypes::sopClassUIDToDocumentType(sopClassUID) == DSRTypes::DT_invalid) {
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

char* HorosModernDCMTKCopyStructuredReportXML(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    std::ostringstream output;
    const size_t writeFlags = 0;
    if (document.writeXML(output, writeFlags).bad())
        return nullptr;

    const std::string xml = output.str();
    return HorosModernDCMTKDuplicateCString(xml.c_str());
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
        DSRTypes::sopClassUIDToDocumentType(sopClassUID) == DSRTypes::DT_invalid)
        return false;

    const size_t readFlags =
        DSRTypes::RF_acceptUnknownRelationshipType |
        DSRTypes::RF_ignoreRelationshipConstraints |
        DSRTypes::RF_ignoreContentItemErrors |
        DSRTypes::RF_skipInvalidContentItems;

    return document.read(*fileformat.getDataset(), readFlags).good();
}

static bool HorosModernDCMTKStructuredReportItemMatchesCode(DSRContentItem& item,
                                                            const char* codeValue,
                                                            const char* codingSchemeDesignator,
                                                            const char* codeMeaning)
{
    const DSRCodedEntryValue conceptName = item.getConceptName();
    if (conceptName.isEmpty())
        return false;

    if (codeValue != nullptr && codeValue[0] != '\0' && conceptName.getCodeValue() != codeValue)
        return false;

    if (codingSchemeDesignator != nullptr &&
        codingSchemeDesignator[0] != '\0' &&
        conceptName.getCodingSchemeDesignator() != codingSchemeDesignator)
        return false;

    if (codeMeaning != nullptr && codeMeaning[0] != '\0' && conceptName.getCodeMeaning() != codeMeaning)
        return false;

    return true;
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

char* HorosModernDCMTKCopyStructuredReportRootCodeMeaning(const char* path)
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
        DSRContentItem& item = tree.getCurrentContentItem();
        if (item.getValueType() == DSRTypes::VT_Image)
        {
            OFString sopInstance = item.getImageReference().getSOPInstanceUID();
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

char* HorosModernDCMTKCopyStructuredReportPrimaryReference(const char* path)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    int instanceNumber = 0;
    OFString rawInstanceNumber;
    if (document.getInstanceNumber(rawInstanceNumber).good() && !rawInstanceNumber.empty())
        instanceNumber = std::atoi(rawInstanceNumber.c_str());

    DSRDocumentTree& tree = document.getTree();
    tree.gotoRoot();
    do
    {
        DSRContentItem& item = tree.getCurrentContentItem();
        if (item.getValueType() == DSRTypes::VT_Image)
        {
            OFString sopInstance = item.getImageReference().getSOPInstanceUID();
            if (sopInstance.empty())
                continue;

            std::string value = sopInstance.c_str();
            if (instanceNumber > 0)
            {
                value += "-";
                value += std::to_string(instanceNumber);
            }
            return HorosModernDCMTKDuplicateCString(value.c_str());
        }
    } while (tree.iterate());

    return nullptr;
}

char* HorosModernDCMTKCopyStructuredReportNamedTextValue(const char* path,
                                                         const char* codeValue,
                                                         const char* codingSchemeDesignator,
                                                         const char* codeMeaning)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    DSRDocumentTree& tree = document.getTree();
    tree.gotoRoot();
    do
    {
        DSRContentItem& item = tree.getCurrentContentItem();
        if (!HorosModernDCMTKStructuredReportItemMatchesCode(item, codeValue, codingSchemeDesignator, codeMeaning))
            continue;

        const OFString value = item.getStringValue();
        if (!value.empty())
            return HorosModernDCMTKDuplicateCString(value.c_str());
    } while (tree.iterate());

    return nullptr;
}

char* HorosModernDCMTKCopyStructuredReportNamedTextValues(const char* path,
                                                          const char* codeValue,
                                                          const char* codingSchemeDesignator,
                                                          const char* codeMeaning)
{
    DcmFileFormat fileformat;
    DSRDocument document;
    if (!HorosModernDCMTKLoadStructuredReport(path, fileformat, document))
        return nullptr;

    std::vector<OFString> values;
    DSRDocumentTree& tree = document.getTree();
    tree.gotoRoot();
    do
    {
        DSRContentItem& item = tree.getCurrentContentItem();
        if (!HorosModernDCMTKStructuredReportItemMatchesCode(item, codeValue, codingSchemeDesignator, codeMeaning))
            continue;

        const OFString value = item.getStringValue();
        if (!value.empty())
            values.push_back(value);
    } while (tree.iterate());

    if (values.empty())
        return nullptr;

    OFString joined;
    for (size_t index = 0; index < values.size(); ++index)
    {
        if (index > 0)
            joined += "\\";
        joined += values[index];
    }

    return HorosModernDCMTKDuplicateCString(joined.c_str());
}

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
                                                          unsigned long roiArchiveLength)
{
    if (path == nullptr || path[0] == '\0' ||
        studyInstanceUID == nullptr || studyInstanceUID[0] == '\0' ||
        seriesInstanceUID == nullptr || seriesInstanceUID[0] == '\0' ||
        sopInstanceUID == nullptr || sopInstanceUID[0] == '\0')
        return 0;

    DcmFileFormat fileformat;
    DcmDataset* dataset = fileformat.getDataset();
    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (dataset == nullptr)
        return 0;

    const char* sopClassUID = UID_BasicTextSRStorage;

    dataset->putAndInsertString(DCM_SOPClassUID, sopClassUID, OFTrue);
    dataset->putAndInsertString(DCM_SOPInstanceUID, sopInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_StudyInstanceUID, studyInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_SeriesInstanceUID, seriesInstanceUID, OFTrue);
    dataset->putAndInsertString(DCM_Modality, "SR", OFTrue);
    dataset->putAndInsertString(DCM_ConversionType, "WSD", OFTrue);

    if (studyDescription != nullptr && studyDescription[0] != '\0')
        dataset->putAndInsertString(DCM_StudyDescription, studyDescription, OFTrue);
    if (patientName != nullptr && patientName[0] != '\0')
        dataset->putAndInsertString(DCM_PatientName, patientName, OFTrue);
    if (patientBirthDate != nullptr && patientBirthDate[0] != '\0')
        dataset->putAndInsertString(DCM_PatientBirthDate, patientBirthDate, OFTrue);
    if (patientSex != nullptr && patientSex[0] != '\0')
        dataset->putAndInsertString(DCM_PatientSex, patientSex, OFTrue);
    if (patientID != nullptr && patientID[0] != '\0')
        dataset->putAndInsertString(DCM_PatientID, patientID, OFTrue);
    if (referringPhysician != nullptr && referringPhysician[0] != '\0')
        dataset->putAndInsertString(DCM_ReferringPhysicianName, referringPhysician, OFTrue);
    if (studyID != nullptr && studyID[0] != '\0')
        dataset->putAndInsertString(DCM_StudyID, studyID, OFTrue);
    if (accessionNumber != nullptr && accessionNumber[0] != '\0')
        dataset->putAndInsertString(DCM_AccessionNumber, accessionNumber, OFTrue);
    if (seriesDescription != nullptr && seriesDescription[0] != '\0')
        dataset->putAndInsertString(DCM_SeriesDescription, seriesDescription, OFTrue);
    if (seriesNumber != nullptr && seriesNumber[0] != '\0')
        dataset->putAndInsertString(DCM_SeriesNumber, seriesNumber, OFTrue);
    if (manufacturer != nullptr && manufacturer[0] != '\0')
        dataset->putAndInsertString(DCM_Manufacturer, manufacturer, OFTrue);
    if (contentDate != nullptr && contentDate[0] != '\0')
        dataset->putAndInsertString(DCM_ContentDate, contentDate, OFTrue);
    if (contentTime != nullptr && contentTime[0] != '\0')
        dataset->putAndInsertString(DCM_ContentTime, contentTime, OFTrue);
    if (referencedSOPClassUID != nullptr && referencedSOPClassUID[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedSOPClassUID, referencedSOPClassUID, OFTrue);
    if (referencedSOPInstanceUID != nullptr && referencedSOPInstanceUID[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedSOPInstanceUID, referencedSOPInstanceUID, OFTrue);
    if (referencedFrameNumber != nullptr && referencedFrameNumber[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedFrameNumber, referencedFrameNumber, OFTrue);
    if (roiArchiveBytes != nullptr && roiArchiveLength > 0)
    {
        dataset->putAndInsertUint8Array(DCM_EncapsulatedDocument, roiArchiveBytes, roiArchiveLength, OFTrue);
        dataset->putAndInsertUint8Array(DcmTagKey(0x0071, 0x0011), roiArchiveBytes, roiArchiveLength, OFTrue);
    }

    if (metaInfo != nullptr)
    {
        metaInfo->putAndInsertString(DCM_MediaStorageSOPClassUID, sopClassUID, OFTrue);
        metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, sopInstanceUID, OFTrue);
    }

    OFCondition status = fileformat.saveFile(path, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
}

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
                                                       unsigned long encapsulatedLength)
{
    if (path == nullptr || path[0] == '\0' ||
        studyInstanceUID == nullptr || studyInstanceUID[0] == '\0')
        return 0;

    DSRDocument document;
    OFCondition status = document.createNewDocument(DSRTypes::DT_BasicTextSR);
    if (status.good())
        status = document.setSpecificCharacterSet("ISO_IR 192");
    if (status.good())
        status = document.createNewSeriesInStudy(studyInstanceUID);
    if (status.good() && studyDescription != nullptr && studyDescription[0] != '\0')
        status = document.setStudyDescription(studyDescription);
    if (status.good() && seriesDescription != nullptr && seriesDescription[0] != '\0')
        status = document.setSeriesDescription(seriesDescription);
    if (status.good() && patientName != nullptr && patientName[0] != '\0')
        status = document.setPatientName(patientName);
    if (status.good() && patientBirthDate != nullptr && patientBirthDate[0] != '\0')
        status = document.setPatientBirthDate(patientBirthDate);
    if (status.good() && patientSex != nullptr && patientSex[0] != '\0')
        status = document.setPatientSex(patientSex);
    if (status.good() && patientID != nullptr && patientID[0] != '\0')
        status = document.setPatientID(patientID);
    if (status.good() && referringPhysician != nullptr && referringPhysician[0] != '\0')
        status = document.setReferringPhysicianName(referringPhysician);
    if (status.good() && studyID != nullptr && studyID[0] != '\0')
        status = document.setStudyID(studyID);
    if (status.good() && accessionNumber != nullptr && accessionNumber[0] != '\0')
        status = document.setAccessionNumber(accessionNumber);
    if (status.good() && seriesNumber != nullptr && seriesNumber[0] != '\0')
        status = document.setSeriesNumber(seriesNumber);
    if (status.good() && manufacturer != nullptr && manufacturer[0] != '\0')
        status = document.setManufacturer(manufacturer);
    if (status.good() && contentDate != nullptr && contentDate[0] != '\0')
        status = document.setContentDate(contentDate);
    if (status.good() && contentTime != nullptr && contentTime[0] != '\0')
        status = document.setContentTime(contentTime);
    if (status.bad())
        return 0;

    DSRDocumentTree& tree = document.getTree();
    if (tree.addContentItem(DSRTypes::RT_isRoot, DSRTypes::VT_Container) == 0)
        return 0;

    const char* rootMeaning = (rootCodeMeaning != nullptr && rootCodeMeaning[0] != '\0') ? rootCodeMeaning : "Annotations";
    status = tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("1", "99HUG", rootMeaning));
    if (status.bad())
        return 0;

    if (referencedSOPClassUID != nullptr && referencedSOPClassUID[0] != '\0' &&
        referencedSOPInstanceUID != nullptr && referencedSOPInstanceUID[0] != '\0')
    {
        if (tree.addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Image, DSRTypes::AM_belowCurrent) == 0)
            return 0;
        tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("IHE.10", "99HUG", "Image Reference"));
        DSRImageReferenceValue imageRef{OFString(referencedSOPClassUID), OFString(referencedSOPInstanceUID)};
        if (referencedFrameNumber != nullptr && referencedFrameNumber[0] != '\0')
            imageRef.getFrameList().putString(referencedFrameNumber);
        status = tree.getCurrentContentItem().setImageReference(imageRef);
        if (status.bad())
            return 0;
        tree.goUp();
    }

    if (childTextValue != nullptr && childTextValue[0] != '\0')
    {
        if (tree.addContentItem(DSRTypes::RT_contains, DSRTypes::VT_Text, DSRTypes::AM_belowCurrent) == 0)
            return 0;
        status = tree.getCurrentContentItem().setConceptName(DSRCodedEntryValue("CODE_01", OFFIS_CODING_SCHEME_DESIGNATOR, "Description"));
        if (status.bad())
            return 0;
        status = tree.getCurrentContentItem().setStringValue(childTextValue);
        if (status.bad())
            return 0;
        tree.goUp();
    }

    DcmFileFormat fileformat;
    status = document.write(*fileformat.getDataset());
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (dataset == nullptr)
        return 0;

    if (seriesInstanceUID != nullptr && seriesInstanceUID[0] != '\0')
        dataset->putAndInsertString(DCM_SeriesInstanceUID, seriesInstanceUID, OFTrue);
    if (sopInstanceUID != nullptr && sopInstanceUID[0] != '\0')
    {
        dataset->putAndInsertString(DCM_SOPInstanceUID, sopInstanceUID, OFTrue);
        if (metaInfo != nullptr)
            metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, sopInstanceUID, OFTrue);
    }
    if (referencedSOPClassUID != nullptr && referencedSOPClassUID[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedSOPClassUID, referencedSOPClassUID, OFTrue);
    if (referencedSOPInstanceUID != nullptr && referencedSOPInstanceUID[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedSOPInstanceUID, referencedSOPInstanceUID, OFTrue);
    if (referencedFrameNumber != nullptr && referencedFrameNumber[0] != '\0')
        dataset->putAndInsertString(DCM_ReferencedFrameNumber, referencedFrameNumber, OFTrue);
    if (encapsulatedBytes != nullptr && encapsulatedLength > 0)
        dataset->putAndInsertUint8Array(DCM_EncapsulatedDocument, encapsulatedBytes, encapsulatedLength, OFTrue);

    status = fileformat.saveFile(path, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
}

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
                                         int imageCount)
{
    if (path == nullptr || path[0] == '\0')
        return 0;

    DSRDocument document;
    OFCondition status = HorosModernDCMTKBuildKeyObjectReport(document,
                                                              sopInstanceUID,
                                                              seriesInstanceUID,
                                                              studyInstanceUID,
                                                              studyDescription,
                                                              patientName,
                                                              patientBirthDate,
                                                              patientSex,
                                                              patientID,
                                                              referringPhysician,
                                                              studyID,
                                                              accessionNumber,
                                                              titleCode,
                                                              keyDescription,
                                                              imagePaths,
                                                              imageSeriesInstanceUIDs,
                                                              imageSOPInstanceUIDs,
                                                              imageCount);
    if (status.bad())
        return 0;

    DcmFileFormat fileformat;
    status = document.write(*fileformat.getDataset());
    if (status.bad())
        return 0;

    DcmDataset* dataset = fileformat.getDataset();
    DcmMetaInfo* metaInfo = HorosModernDCMTKMetaInfo(fileformat);
    if (dataset == nullptr)
        return 0;

    if (seriesInstanceUID != nullptr && seriesInstanceUID[0] != '\0')
        dataset->putAndInsertString(DCM_SeriesInstanceUID, seriesInstanceUID, OFTrue);
    if (sopInstanceUID != nullptr && sopInstanceUID[0] != '\0')
    {
        dataset->putAndInsertString(DCM_SOPInstanceUID, sopInstanceUID, OFTrue);
        if (metaInfo != nullptr)
            metaInfo->putAndInsertString(DCM_MediaStorageSOPInstanceUID, sopInstanceUID, OFTrue);
    }

    status = fileformat.saveFile(path, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
}

int HorosModernDCMTKWriteStructuredReportFromXML(const char* xmlPath, const char* dicomPath)
{
    if (xmlPath == nullptr || xmlPath[0] == '\0' || dicomPath == nullptr || dicomPath[0] == '\0')
        return 0;

    DSRDocument document;
    if (document.readXML(xmlPath, 0).bad())
        return 0;

    DcmFileFormat fileformat;
    OFCondition status = document.write(*fileformat.getDataset());
    if (status.bad())
        return 0;

    status = fileformat.saveFile(dicomPath, EXS_LittleEndianExplicit);
    return status.good() ? 1 : 0;
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
