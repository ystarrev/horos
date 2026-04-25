/* Compatibility aliases for legacy Horos/DCMTK tag macro names. */
#ifndef DCMTKTagCompatibility_h
#define DCMTKTagCompatibility_h

#include <dcmtk/dcmdata/dcdeftag.h>

#ifndef DCM_PatientsName
#define DCM_PatientsName DCM_PatientName
#endif
#ifndef DCM_PatientsSex
#define DCM_PatientsSex DCM_PatientSex
#endif
#ifndef DCM_PatientsBirthDate
#define DCM_PatientsBirthDate DCM_PatientBirthDate
#endif
#ifndef DCM_PatientsBirthTime
#define DCM_PatientsBirthTime DCM_PatientBirthTime
#endif
#ifndef DCM_ReferringPhysiciansName
#define DCM_ReferringPhysiciansName DCM_ReferringPhysicianName
#endif
#ifndef DCM_PerformingPhysiciansName
#define DCM_PerformingPhysiciansName DCM_PerformingPhysicianName
#endif
#ifndef DCM_StudyComments
#define DCM_StudyComments DCM_RETIRED_StudyComments
#endif
#ifndef DCM_InterpretationStatusID
#define DCM_InterpretationStatusID DCM_RETIRED_InterpretationStatusID
#endif
#ifndef DCM_AcquisitionDatetime
#define DCM_AcquisitionDatetime DCM_AcquisitionDateTime
#endif
#ifndef DCM_ManufacturersModelName
#define DCM_ManufacturersModelName DCM_ManufacturerModelName
#endif

#endif /* DCMTKTagCompatibility_h */
