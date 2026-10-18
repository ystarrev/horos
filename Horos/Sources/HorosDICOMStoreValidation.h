#ifndef HOROS_DICOM_STORE_VALIDATION_H
#define HOROS_DICOM_STORE_VALIDATION_H

#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmnet/diutil.h>
#include <cstring>
#include <initializer_list>

inline DIC_US HorosValidateReceivedStore(const char* path, const T_DIMSE_C_StoreRQ& request,
                                       E_TransferSyntax syntax, OFBool correctUIDPadding)
{
    DcmFileFormat header;
    // Both SOP identifiers precede this tag. Do not read image, document or SR payloads.
    OFCondition result = header.loadFileUntilTag(path, syntax, EGL_noChange,
        DIC_UI_LEN, ERM_autoDetect, DcmTagKey(0x0008, 0x0019));
    if (result.bad()) return STATUS_STORE_Error_CannotUnderstand;

    DcmDataset* dataset = header.getDataset();
    for (const DcmTagKey& tag : {DCM_SOPClassUID, DCM_SOPInstanceUID})
    {
        DcmElement* element = NULL;
        if (dataset->findAndGetElement(tag, element).bad() || !element ||
            element->getLength() == 0 || element->getLength() > DIC_UI_LEN)
            return STATUS_STORE_Error_CannotUnderstand;
    }

    DIC_UI sopClass = {}, sopInstance = {};
    if (!DU_findSOPClassAndInstanceInDataSet(dataset, sopClass, sizeof(sopClass),
        sopInstance, sizeof(sopInstance), correctUIDPadding))
        return STATUS_STORE_Error_CannotUnderstand;
    if (strcmp(sopClass, request.AffectedSOPClassUID) != 0 ||
        strcmp(sopInstance, request.AffectedSOPInstanceUID) != 0)
        return STATUS_STORE_Error_DataSetDoesNotMatchSOPClass;
    return STATUS_Success;
}

#endif
