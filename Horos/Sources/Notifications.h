/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#import <Cocoa/Cocoa.h>

extern NSString* const OsirixUpdateWLWWMenuNotification;
extern NSString* const OsirixChangeWLWWNotification;
extern NSString* const OsirixROIChangeNotification;
extern NSString* const OsirixVRViewDidBecomeFirstResponderNotification;
extern NSString* const OsirixUpdateVolumeDataNotification;
extern NSString* const OsirixRevertSeriesNotification;
extern NSString* const OsirixOpacityChangedNotification;
extern NSString* const OsirixDefaultToolModifiedNotification;
extern NSString* const OsirixDefaultRightToolModifiedNotification;
extern NSString* const OsirixUpdateConvolutionMenuNotification;
extern NSString* const OsirixCLUTChangedNotification;
extern NSString* const OsirixUpdateCLUTMenuNotification;
extern NSString* const OsirixUpdateOpacityMenuNotification;
extern NSString* const OsirixRecomputeROINotification;
extern NSString* const OsirixStopPlayingNotification;
extern NSString* const OsirixChatBroadcastNotification;
extern NSString* const OsirixSyncSeriesNotification;
extern NSString* const OsirixStudyAnnotationsChangedNotification;
extern NSString* const OsirixGLFontChangeNotification;
extern NSString* const OsirixAddToDBNotification;
extern NSString* const OsirixAddNewStudiesDBNotification;
extern NSString* const OsirixAddToDBNotificationImagesArray;
extern NSString* const OsirixAddToDBNotificationImagesPerAETDictionary;
extern NSString* const OsirixAddToDBCompleteNotification;
extern NSString* const OsirixAddToDBCompleteNotificationImagesArray __deprecated; // use OsirixAddToDBNotificationImagesArray
extern NSString* const OsirixDicomDatabaseDidChangeContextNotification;
extern NSString* const _O2AddToDBAnywayNotification;
extern NSString* const _O2AddToDBAnywayCompleteNotification;
extern NSString* const O2DatabaseInvalidateAlbumsCacheNotification;
extern NSString* const OsirixDatabaseObjectsMayBecomeUnavailableNotification; // database objects may soon become invalid
extern NSString* const OsirixNewStudySelectedNotification;
extern NSString* const OsirixDidLoadNewObjectNotification;
extern NSString* const OsirixRTStructNotification;
extern NSString* const OsirixAlternateButtonPressedNotification;
extern NSString* const OsirixROISelectedNotification;
extern NSString* const OsirixRemoveROINotification;
extern NSString* const OsirixROIRemovedFromArrayNotification;
extern NSString* const OsirixChangeFocalPointNotification;
extern NSString* const OsirixWindow3dCloseNotification;
extern NSString* const OsirixDisplay3dPointNotification;
extern NSString* const OsirixDragMatrixImageMovedNotification;
extern NSString* const OsirixNotification;
extern NSString* const OsiriXFileReceivedNotification;
extern NSString* const OsirixDCMSendStatusNotification;
extern NSString* const OsirixDCMUpdateCurrentImageNotification;
extern NSString* const OsirixMouseDownNotification;
extern NSString* const OsirixVRCameraDidChangeNotification;
extern NSString* const OsirixSyncNotification;
extern NSString* const OsirixAddROINotification;
extern NSString* const OsirixLabelGLFontChangeNotification;
extern NSString* const OsirixUpdateViewNotification;
extern NSString* const KFSplitViewDidCollapseSubviewNotification;
extern NSString* const KFSplitViewDidExpandSubviewNotification;
extern NSString* const OsiriXLogEvent;

extern NSString* const OsirixActiveLocalDatabaseDidChangeNotification;
