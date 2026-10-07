#ifndef HOROS_DCMTK_BRIDGE_LOADER_H
#define HOROS_DCMTK_BRIDGE_LOADER_H

#include "ModernDCMTKBridge.h"

#ifdef __cplusplus
extern "C" {
#endif

// The bundled library is retained for the process lifetime. Missing symbols
// return NULL so callers can keep their existing operation-specific errors.
void *HorosDCMTKBridgeSymbol(const char *name);

#ifdef __cplusplus
}
#endif

// Derive the pointer type from the shared C API without linking the symbol.
#define HorosDCMTKFunction(function) \
    ((__typeof__(&(function)))HorosDCMTKBridgeSymbol(#function))

// Typed accessors allow Swift clients to use the dynamically loaded SR API.
static inline __typeof__(&HorosModernDCMTKWriteCompatibilityStructuredReport) HorosSRWriter(void) {
    return HorosDCMTKFunction(HorosModernDCMTKWriteCompatibilityStructuredReport);
}
static inline __typeof__(&HorosModernDCMTKCopyStructuredReportNamedTextValue) HorosSRTextReader(void) {
    return HorosDCMTKFunction(HorosModernDCMTKCopyStructuredReportNamedTextValue);
}
static inline __typeof__(&HorosModernDCMTKFreeString) HorosSRFreeString(void) {
    return HorosDCMTKFunction(HorosModernDCMTKFreeString);
}
static inline __typeof__(&HorosModernDCMTKReplaceTagValue) HorosDICOMTagWriter(void) {
    return HorosDCMTKFunction(HorosModernDCMTKReplaceTagValue);
}

#endif
