#ifndef HorosDirectTransferDICOM_h
#define HorosDirectTransferDICOM_h

#include <dcmtk/dcmdata/dctagkey.h>

// Keep this separate from the 0x7777 group used by Metal ROI SEG objects.
static const DcmTagKey HorosDirectPrivateCreatorTag(0x7779, 0x0010);
static const DcmTagKey HorosDirectVersionTag(0x7779, 0x1001);
static const DcmTagKey HorosDirectPortTag(0x7779, 0x1002);
static const DcmTagKey HorosDirectTokenTag(0x7779, 0x1003);
static const char HorosDirectPrivateCreator[] = "HOROS DIRECT TRANSFER";

#endif
