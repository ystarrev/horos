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

#endif
