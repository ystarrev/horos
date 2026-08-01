/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 =========================================================================*/

#ifndef HOROS_TOOL_MODE_H
#define HOROS_TOOL_MODE_H

#import <Foundation/Foundation.h>

/*
 * Stable tool identifiers used by archived Horos ROI objects.
 *
 * These numeric values are part of the on-disk ROI format. Keep them
 * independent from any viewer implementation so old Horos databases and
 * structured reports remain interoperable.
 */
typedef NS_ENUM(short, ToolMode)
{
    tWL = 0,
    tTranslate,
    tZoom,
    tRotate,
    tNext,
    tMesure,
    tROI,
    t3DRotate,
    tCross,
    tOval,
    tOPolygon,
    tCPolygon,
    tAngle,
    tText,
    tArrow,
    tPencil,
    t3Dpoint,
    t3DCut,
    tCamera3D,
    t2DPoint,
    tPlain,
    tBonesRemoval,
    tWLBlended,
    tRepulsor,
    tLayerROI,
    tROISelector,
    tAxis,
    tDynAngle,
    tCurvedROI,
    tTAGT
};

/* Stable annotation levels shared by the database preview and Metal viewer. */
typedef NS_ENUM(NSInteger, HorosAnnotationLevel)
{
    HorosAnnotationLevelNone = 0,
    HorosAnnotationLevelGraphics,
    HorosAnnotationLevelBase,
    HorosAnnotationLevelFull
};

#endif
