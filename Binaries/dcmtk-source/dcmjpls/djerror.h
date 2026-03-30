/*
 *
 *  Copyright (C) 1997-2010, OFFIS e.V.
 *  All rights reserved.  See COPYRIGHT file for details.
 *
 *  This software and supporting documentation were developed by
 *
 *    OFFIS e.V.
 *    R&D Division Health
 *    Escherweg 2
 *    D-26121 Oldenburg, Germany
 *
 *
 *  Module:  dcmjpls
 *
 *  Author:  Uli Schlachter
 *
 *  Purpose: Helper function than converts between CharLS and dcmjpgls errors
 *
 *  Last Update:      $Author: joergr $
 *  Update Date:      $Date: 2010-10-14 13:20:24 $
 *  CVS/RCS Revision: $Revision: 1.5 $
 *  Status:           $State: Exp $
 *
 *  CVS/RCS Log at end of file
 *
 */

#ifndef DJERROR_H
#define DJERROR_H

#include "osconfig.h"
#include "djlsutil.h" /* For the OFCondition codes */
#include <CharLS/charls.h>

/** Helper class for converting between dcmjpls and CharLS error codes
 */
class DJLSError
{
private:
  /// private undefined constructor
  DJLSError();

public:

  /** This method converts a CharLS error code into a dcmjpls OFCondition
   *  @param error The CharLS error code
   *  @return The OFCondition
   */
  static const OFCondition& convert(charls::ApiResult error)
  {
    switch (error)
    {
      case charls::ApiResult::success:
        return EC_Normal;
      case charls::ApiResult::destination_buffer_too_small:
        return EC_JLSUncompressedBufferTooSmall;
      case charls::ApiResult::source_buffer_too_small:
        return EC_JLSCompressedBufferTooSmall;
      case charls::ApiResult::encoding_not_supported:
        return EC_JLSCodecUnsupportedImageType;
      case charls::ApiResult::invalid_argument:
        return EC_JLSCodecInvalidParameters;
      case charls::ApiResult::parameter_value_not_supported:
        return EC_JLSCodecUnsupportedValue;
      case charls::ApiResult::invalid_encoded_data:
        return EC_JLSInvalidCompressedData;
      case charls::ApiResult::bit_depth_for_transform_not_supported:
        return EC_JLSUnsupportedBitDepthForTransform;
      case charls::ApiResult::color_transform_not_supported:
        return EC_JLSUnsupportedColorTransform;
      case charls::ApiResult::too_much_encoded_data:
        return EC_JLSTooMuchCompressedData;
      default:
        return EC_IllegalParameter;
    }
  }
};

#endif

/*
 * CVS/RCS Log:
 * $Log: djerror.h,v $
 * Revision 1.5  2010-10-14 13:20:24  joergr
 * Updated copyright header. Added reference to COPYRIGHT file.
 *
 * Revision 1.4  2010-02-25 08:50:38  uli
 * Updated to latest CharLS version.
 *
 * Revision 1.3  2010-01-19 15:19:06  uli
 * Made file names fit into 8.3 format.
 *
 * Revision 1.2  2009-10-07 13:16:47  uli
 * Switched to logging mechanism provided by the "new" oflog module.
 *
 * Revision 1.1  2009-07-31 09:05:43  meichel
 * Added more detailed error messages, minor code clean-up
 *
 *
 */
