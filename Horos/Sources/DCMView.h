/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/

#ifndef DCMVIEW_H_INCLUDED
#define DCMVIEW_H_INCLUDED

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

#import "HorosToolMode.h"

#include "options.h"

#define STAT_UPDATE					0.6f
#define IMAGE_COUNT					1
#define IMAGE_DEPTH					32

extern NSString * const HorosPasteboardType;

extern int CLUTBARS, ANNOTATIONS, SOFTWAREINTERPOLATION_MAX, DISPLAYCROSSREFERENCELINES;

enum { annotNone = 0, annotGraphics, annotBase, annotFull };
enum { barHide = 0, barOrigin, barFused, barBoth };
enum { syncroOFF = 0, syncroABS = 1, syncroREL = 2, syncroLOC = 3, syncroRatio = 4};

@class DCMPix;
@class DCMView;
@class ROI;
@class DICOMExport;
@class DicomImage, DicomSeries, DicomStudy;
@class DCMObject;

@interface DCMExportPlugin: NSObject
- (void) finalize:(DCMObject*) dcmDst withSourceObject:(DCMObject*) dcmObject;
- (NSString*) seriesName;
@end

/** \brief Image/Frame View for ViewerController */

@interface DCMView: NSView
{
	NSInteger		_imageRows;
	NSInteger		_imageColumns;
	NSInteger		_tag;

	BOOL			flippedData;
    BOOL            whiteBackground;
	
	NSString		*yearOld;
	
	ROI				*curROI;
	int				volumicData;
	BOOL			drawingROI, noScale, volumicSeries, mouseDraggedForROIUndo;
	DCMView			*blendingView;
	float			blendingFactor, blendingFactorStart;
	BOOL			eraserFlag; // use by the PaletteController to switch between the Brush and the Eraser
	BOOL			colorTransfer;
	unsigned char   *colorBuf, *blendingColorBuf;
	unsigned char   alphaTable[256], opaqueTable[256], redTable[256], greenTable[256], blueTable[256];
	float			redFactor, greenFactor, blueFactor;
	long			blendingMode;
	
	float			sliceFromTo[ 2][ 3], sliceFromToS[ 2][ 3], sliceFromToE[ 2][ 3], sliceFromTo2[ 2][ 3], sliceFromToThickness;
	
	float			sliceVector[ 3];
	float			slicePoint3D[ 3];
	float			syncRelativeDiff;
	long			syncSeriesIndex;
	
	float			mprVector[ 3], mprPoint[ 3];
    
    NSTimeInterval  timeIntervalForDrag;
	
	short			thickSlabMode, thickSlabStacks;
	
	NSMutableArray	*rectArray;
	
    NSMutableArray  *dcmPixList;
    NSArray			*dcmFilesList;
	NSMutableArray  *dcmRoiList, *curRoiList;
    DCMPix			*_curDCM;
	DCMExportPlugin	*dcmExportPlugin;
	
    char            listType;
    
    short           curImage, startImage;
    
    ToolMode        currentTool, currentToolRight, currentMouseEventTool;
    
	BOOL			mouseDragging;
	BOOL			suppress_labels; // keep from drawing the labels when command+shift is pressed

    NSPoint         start, originStart, previous;
	
    float			startWW, curWW, startMin, startMax;
    float			startWL, curWL;

    float			bdstartWW, bdcurWW, bdstartMin, bdstartMax;
    float			bdstartWL, bdcurWL;
	
	BOOL			curWLWWSUVConverted;
	float			curWLWWSUVFactor;
	
    NSSize          scaleStart, scaleInit;
    
	double			resizeTotal;
    float           scaleValue, startScaleValue;
    float           rotation, rotationStart;
    NSPoint			origin;
	short			crossMove;
    
    NSMatrix        *matrix;
    
    long            count;
	
    BOOL            xFlipped, yFlipped;

	NSSize			stringSize;
	NSFont			*labelFont;
	NSColor			*fontColor;
	float			fontRasterY;
		
    NSPoint         mesureA, mesureB;
    NSRect          roiRect;
	NSString		*stringID;
	NSSize			previousViewSize;

	float			contextualMenuInWindowPosX;
	float			contextualMenuInWindowPosY;	

	
	float			mouseXPos, mouseYPos;
	float			pixelMouseValue;
	long			pixelMouseValueR, pixelMouseValueG, pixelMouseValueB;
    
	float			blendingMouseXPos, blendingMouseYPos;
	float			blendingPixelMouseValue;
	long			blendingPixelMouseValueR, blendingPixelMouseValueG, blendingPixelMouseValueB;
	
    long			textureX, blendingTextureX;
    long			textureY, blendingTextureY;
    long			textureWidth, blendingTextureWidth;
    long			textureHeight, blendingTextureHeight;
    
	BOOL			f_ext_texture_rectangle; // is texture rectangle extension supported
	BOOL			f_arb_texture_rectangle; // is texture rectangle extension supported
	BOOL			f_ext_client_storage; // is client storage extension supported
	BOOL			f_ext_packed_pixel; // is packed pixel extension supported
	BOOL			f_ext_texture_edge_clamp; // is SGI texture edge clamp extension supported
	unsigned long	edgeClampParam; // the param that is passed to the texturing parmeteres
	long			maxTextureSize; // the minimum max texture size across all GPUs
	long			maxNOPTDTextureSize; // the minimum max texture size across all GPUs that support non-power of two texture dimensions
	long			TEXTRECTMODE;
	
	BOOL			isKeyView; //needed for Image View subclass
	NSCursor		*cursor;
	
	BOOL			cursorSet;
	NSTrackingArea	*cursorTracking;
	
	NSPoint			display2DPoint;
    int             display2DPointIndex;
	
	NSMutableDictionary	*stringTextureCache;
	
	BOOL           _dragInProgress; // Are we drag and dropping
	NSTimer			*_mouseDownTimer; //Timer to check if mouseDown is Persisiting;
	NSTimer			*_rightMouseDownTimer; //Checking For Right hold
	NSImage			*destinationImage; //image will be dropping
	
	BOOL			_hasChanged, needToLoadTexture, showDescriptionInLarge;
	
	BOOL			scaleToFitNoReentry;
	
    float           previousScalingFactor;
	
	BOOL			drawing;
	
	int				repulsorRadius;
	NSPoint			repulsorPosition;
	NSTimer			*repulsorColorTimer;
	float			repulsorAlpha, repulsorAlphaSign;
	BOOL			repulsorROIEdition;
	long            scrollMode;
	
	NSPoint			ROISelectorStartPoint, ROISelectorEndPoint;
	BOOL			selectorROIEdition;
	NSMutableArray	*ROISelectorSelectedROIList;
	
	BOOL			syncOnLocationImpossible, updateNotificationRunning;
	
	char			*resampledBaseAddr, *blendingResampledBaseAddr;
	BOOL			zoomIsSoftwareInterpolated, firstTimeDisplay;
	
	int				resampledBaseAddrSize, blendingResampledBaseAddrSize;
		
	// iChat
//	float			iChatWidth, iChatHeight;
//	unsigned char*	iChatCursorTextureBuffer;
//	NSSize			iChatCursorImageSize;
//	NSPoint			iChatCursorHotSpot;
//	BOOL			iChatDrawing;
//	NSMutableDictionary	*iChatStringTextureCache;
//	NSSize			iChatStringSize;
	NSRect			drawingFrameRect, screenCaptureRect;
	
	BOOL			exceptionDisplayed;
	BOOL			COPYSETTINGSINSERIES;
	BOOL			is2DViewerCached, is2DViewerValue;
	
	int avoidRecursiveSync;
	BOOL avoidMouseMovedRecursive;
	BOOL avoidChangeWLWWRecursive;
	BOOL TextureComputed32bitPipeline;
    
//    BOOL iChatRunning;
	
	float studyColorR, studyColorG, studyColorB;
    NSUInteger studyDateIndex;
    
    int annotationType;
    
    NSArray *cleanedOutDcmPixArray;
}

@property NSRect drawingFrameRect;
@property(readonly) NSMutableArray *rectArray, *curRoiList;
@property BOOL COPYSETTINGSINSERIES, flippedData, showDescriptionInLarge;
@property(nonatomic) BOOL whiteBackground;
@property(readonly) NSMutableArray *dcmPixList,  *dcmRoiList;
@property(readonly) NSArray *dcmFilesList;
@property long syncSeriesIndex;
@property(nonatomic)float syncRelativeDiff, studyColorR, studyColorG, studyColorB;
@property(nonatomic) long blendingMode;
@property(nonatomic) NSUInteger studyDateIndex;
@property(retain,setter=setBlending:) DCMView *blendingView;
@property(readonly) float blendingFactor;
@property(nonatomic) BOOL xFlipped, yFlipped;
@property(retain) NSString *stringID;
@property(nonatomic) ToolMode currentTool;
@property(nonatomic, setter=setRightTool:) ToolMode currentToolRight;
@property(readonly) short curImage;
@property(retain) NSMatrix *theMatrix;
@property(readonly) BOOL suppressLabels;
@property(nonatomic) float scaleValue, rotation;
@property(nonatomic) NSPoint origin;
@property(readonly) double pixelSpacing, pixelSpacingX, pixelSpacingY;
@property(readonly, strong) DCMPix *curDCM;
@property(retain) DCMExportPlugin *dcmExportPlugin;
@property(readonly) float mouseXPos, mouseYPos;
@property(readonly) float contextualMenuInWindowPosX, contextualMenuInWindowPosY;
@property NSInteger tag;
@property(readonly) float curWW, curWL;
@property NSInteger rows, columns;
@property(readonly) NSCursor *cursor;
@property BOOL eraserFlag;
@property BOOL drawing;
@property BOOL volumicSeries;
@property (nonatomic) NSTimeInterval timeIntervalForDrag;
@property(readonly) BOOL isKeyView, mouseDragging;
@property int annotationType;

@end

/// Declarations retained only while non-rendering legacy source files are
/// disentangled from the retired 2D viewer. New code must use the Metal viewer.
@interface DCMView (LegacyCompatibilitySurface)

+ (void) setDontListenToSyncMessage: (BOOL) v;
+ (BOOL) noPropagateSettingsInSeriesForModality: (NSString*) m;
+ (void) purgeStringTextureCache;
+ (void) setDefaults;
+ (void) setCLUTBARS:(int) c ANNOTATIONS:(int) a;
+ (void)setPluginOverridesMouse: (BOOL)override DEPRECATED_ATTRIBUTE;
+ (void) computePETBlendingCLUT;
+ (NSString*) findWLWWPreset: (float) wl :(float) ww :(DCMPix*) pix;
+ (NSSize)sizeOfString:(NSString *)string forFont:(NSFont *)font;
+ (long) lengthOfString:( char *) cstr forFont:(long *)fontSizeArray;
+ (BOOL) intersectionBetweenTwoLinesA1:(NSPoint) a1 A2:(NSPoint) a2 B1:(NSPoint) b1 B2:(NSPoint) b2 result:(NSPoint*) r;
+ (float) Magnitude:( NSPoint) Point1 :(NSPoint) Point2;
+ (float) angleBetweenVector: (float*) v1 andVector: (float*) v2;
+ (double) angleBetweenVectorD: (double*) v1 andVectorD: (double*) v2;
+ (int) DistancePointLine: (NSPoint) Point :(NSPoint) startPoint :(NSPoint) endPoint :(float*) Distance;
+ (float) pbase_Plane: (float*) point :(float*) planeOrigin :(float*) planeVector :(float*) pointProjection;
+ (short)syncro;
+ (void)setSyncro:(short) s;
- (BOOL) softwareInterpolation;
- (void) applyImageTransformation;
- (void) gClickCountSetReset;
- (int) findPlaneAndPoint:(float*) pt :(float*) location;
- (int) findPlaneForPoint:(float*) pt localPoint:(float*) location distanceWithPlane: (float*) distanceResult;
- (int) findPlaneForPoint:(float*) pt preferParallelTo:(float*)parto localPoint:(float*) location distanceWithPlane: (float*) distanceResult;
- (void) blendingPropagate;
- (void) subtract:(DCMView*) bV;
- (void) subtract:(DCMView*) bV absolute:(BOOL) abs;
- (void) multiply:(DCMView*) bV;
- (short)syncro;
- (void)setSyncro:(short) s;

// checks to see if tool is for ROIs.  maybe better name - (BOOL)isToolforROIs:(long)tool
- (BOOL) roiTool:(ToolMode) tool;
- (void) prepareToRelease;
- (void) orientationCorrectedToView:(float*) correctedOrientation;
- (NSPoint) ConvertFromNSView2GL:(NSPoint) a;
- (NSPoint) ConvertFromView2GL:(NSPoint) a;
- (NSPoint) ConvertFromUpLeftView2GL:(NSPoint) a;
- (NSPoint) ConvertFromGL2View:(NSPoint) a;
- (NSPoint) ConvertFromGL2NSView:(NSPoint) a;
- (NSPoint) ConvertFromGL2Screen:(NSPoint) a;
- (NSPoint) ConvertFromGL2GL:(NSPoint) a toView:(DCMView*) otherView;
- (NSRect) smartCrop;
- (void) setWLWW:(float) wl :(float) ww;
- (void)discretelySetWLWW:(float)wl :(float)ww;
- (void) getWLWW:(float*) wl :(float*) ww;
- (void) getThickSlabThickness:(float*) thickness location:(float*) location;
- (void) setCLUT:( unsigned char*) r :(unsigned char*) g :(unsigned char*) b;
- (NSImage*) nsimage;
- (NSImage*) nsimage:(BOOL) originalSize;
- (NSImage*) nsimage:(BOOL) originalSize allViewers:(BOOL) allViewers;
- (NSDictionary*) exportDCMCurrentImage: (DICOMExport*) exportDCM size:(int) size;
- (NSDictionary*) exportDCMCurrentImage: (DICOMExport*) exportDCM size:(int) size  views: (NSArray*) views viewsRect: (NSArray*) viewsRect;
- (NSDictionary*) exportDCMCurrentImage: (DICOMExport*) exportDCM size:(int) size  views: (NSArray*) views viewsRect: (NSArray*) viewsRect exportSpacingAndOrigin: (BOOL) exportSpacingAndOrigin;
- (NSImage*) exportNSImageCurrentImageWithSize:(int) size;
- (void) setIndex:(short) index;
- (void) setIndexWithReset:(short) index :(BOOL)sizeToFit;
- (void) setDCM:(NSMutableArray*) c :(NSArray*)d :(NSMutableArray*)e :(short) firstImage :(char) type :(BOOL) reset;
- (void) setPixels: (NSMutableArray*) pixels files: (NSArray*) files rois: (NSMutableArray*) rois firstImage: (short) firstImage level: (char) level reset: (BOOL) reset;
- (void) sendSyncMessage:(short) inc;
- (void) loadTextures;
- (void)loadTexturesCompute;
- (IBAction) flipVertical:(id) sender;
- (IBAction) flipHorizontal:(id) sender;
- (void) setFusion:(short) mode :(short) stacks;
- (NSPoint) rotatePoint:(NSPoint) a;
- (void) setOrigin:(NSPoint) x;
- (void) setOriginX:(float) x Y:(float) y;
- (void) scaleToFit;
- (float) scaleToFitForDCMPix: (DCMPix*) d;
- (BOOL) isScaledFit;
- (void) setBlendingFactor:(float) f;
- (void) sliderAction:(id) sender;
- (void) roiSet;
- (void) sync3DPosition;
- (void) roiSet:(ROI*) aRoi;
- (void) colorTables:(unsigned char **) a :(unsigned char **) r :(unsigned char **)g :(unsigned char **) b;
- (void) blendingColorTables:(unsigned char **) a :(unsigned char **) r :(unsigned char **)g :(unsigned char **) b;
- (void )changeFont:(id)sender;
- (IBAction) sliderRGBFactor:(id) sender;
- (IBAction) alwaysSyncMenu:(id) sender;
- (void) getCLUT:( unsigned char**) r : (unsigned char**) g : (unsigned char**) b;
- (void) sync:(NSNotification*)note;
- (id)initWithFrame:(NSRect)frame imageRows:(int)rows  imageColumns:(int)columns;
- (float)getSUV;
- (IBAction) roiLoadFromXMLFiles: (NSArray*) filenames;
- (BOOL)checkHasChanged;
- (void) drawTextualData:(NSRect) size :(long) annotations;
- (void) drawTextualData:(NSRect) size annotationsLevel:(long) annotations fullText: (BOOL) fullText onlyOrientation: (BOOL) onlyOrientation;
- (void) draw2DPointMarker;
- (void) drawImage:(NSImage *)image inBounds:(NSRect)rect;
- (void) setScaleValueCentered:(float) x;
- (void) updateCurrentImage: (NSNotification*) note;
- (void) setImageParamatersFromView:(DCMView *)aView;
- (void) setRows:(int)rows columns:(int)columns;
- (void) updateTilingViews;
- (void) becomeMainWindow;
- (void) checkCursor;
- (DicomImage *)imageObj;
- (DicomSeries *)seriesObj;
- (DicomStudy *)studyObj;
- (void) updatePresentationStateFromSeries;
- (void) updatePresentationStateFromSeriesOnlyImageLevel: (BOOL) onlyImage;
- (void) updatePresentationStateFromSeriesOnlyImageLevel: (BOOL) onlyImage scale: (BOOL) scale offset: (BOOL) offset;
- (void) setCursorForView: (ToolMode) tool;
- (ToolMode) getTool: (NSEvent*) event;
- (void)resizeWindowToScale:(float)resizeScale;
- (float) getBlendedSUV;
- (void) roiChange:(NSNotification*)note;
- (void) roiSelected:(NSNotification*) note;
- (void) magnifyWithEvent:(NSEvent *)anEvent;
- (void) rotateWithEvent:(NSEvent *)anEvent;
- (void) setStartWLWW;
- (void) stopROIEditing;
- (void) deleteInvalidROIs;
- (void) stopROIEditingForce:(BOOL) force;
- (void) subDrawRect: (NSRect)aRect;     // Subclassable, default does nothing.
- (void) drawRectAnyway:(NSRect)aRect;   // Subclassable, default does nothing.
- (void) updateImage;
- (BOOL) shouldPropagate;
//- (NSPoint) convertFromView2iChat: (NSPoint) a;
//- (NSPoint) convertFromNSView2iChat: (NSPoint) a;
- (void) annotMenu:(id) sender;
- (ROI*) clickInROI: (NSPoint) tempPt;
- (void) switchShowDescriptionInLarge;
- (void)getOrientationText:(char *) orientation : (float *) vector :(BOOL) inv;
- (NSMutableArray*) selectedROIs;
- (void) computeSliceIntersection: (DCMPix*) oPix sliceFromTo: (float[2][3]) sft vector: (float*) vectorB origin: (float*) originB;
+ (unsigned char*) PETredTable;
+ (unsigned char*) PETgreenTable;
+ (unsigned char*) PETblueTable;
- (void) startDrag:(NSTimer*)theTimer;
- (void)deleteMouseDownTimer;
- (DicomImage *)dicomImage;
- (void) roiLoadFromFilesArray: (NSArray*) filenames;
- (id)windowController;
- (BOOL)is2DViewer;
- (NSPoint) positionWithoutRotation: (NSPoint) tPt;
- (IBAction)realSize:(id)sender;
- (IBAction)scaleToFit:(id)sender;
- (IBAction)actualSize:(id)sender;
- (void) drawOrientation:(NSRect) size;
- (void) setCOPYSETTINGSINSERIESdirectly: (BOOL) b;
-(BOOL)actionForHotKey:(NSString *)hotKey;
+(NSDictionary*) hotKeyDictionary;
+(NSDictionary*) hotKeyModifiersDictionary;

- (BOOL)_checkHasChanged:(BOOL)flag;

// Methods for mouse drag response  Can be modified for subclassing
// This allow the various tools to  have different responses indifferent subclasses.
// Making it easie to modify mouseDragged:
- (NSPoint)currentPointInView:(NSEvent *)event;
- (BOOL)checkROIsForHitAtPoint:(NSPoint)point forEvent:(NSEvent *)event;
- (BOOL)mouseDraggedForROIs:(NSEvent *)event;
- (void)mouseDraggedCrosshair:(NSEvent *)event;
- (void)mouseDragged3DRotate:(NSEvent *)event;
- (void)mouseDraggedZoom:(NSEvent *)event;
- (void)mouseDraggedTranslate:(NSEvent *)event;
- (void)mouseDraggedRotate:(NSEvent *)event;
- (void)mouseDraggedImageScroll:(NSEvent *)event;
- (void)mouseDraggedBlending:(NSEvent *)event;
- (void)mouseDraggedWindowLevel:(NSEvent *)event;
- (void)mouseDraggedRepulsor:(NSEvent *)event;
- (void)mouseDraggedROISelector:(NSEvent *)event;

- (void)deleteROIGroupID:(NSTimeInterval)groupID;
- (void) computeColor;
- (void)setIsLUT12Bit:(BOOL)boo;
- (BOOL)isLUT12Bit;

- (void)flagsChanged;

+ (NSArray*)cleanedOutDcmPixArray:(NSArray*)input; // filters the input array of DCMPix by returning only the pix with the most common ImageType in the input array

+ (NSArray<NSString *> *)PasteboardTypes;
@end
#endif
