/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, version 3 of the License.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. See the
 GNU Lesser General Public License for more details.
 ============================================================================*/

#import <Cocoa/Cocoa.h>

@class CIALayoutView;
@class RWTokenField;

@interface OSICustomImageAnnotationsContentView : NSView

@property(readonly) NSPopUpButton *modalitiesPopUpButton;
@property(readonly) NSButton *sameAsDefaultButton;
@property(readonly) NSButton *resetDefaultButton;
@property(readonly) NSButton *orientationWidgetButton;
@property(readonly) NSButton *addAnnotationButton;
@property(readonly) NSButton *removeAnnotationButton;
@property(readonly) NSSegmentedControl *loadsaveButton;
@property(readonly) CIALayoutView *layoutView;
@property(readonly) NSTextField *titleLabelTextField;
@property(readonly) NSTextField *titleTextField;
@property(readonly) NSTextField *contentLabeltextField;
@property(readonly) RWTokenField *contentTokenField;
@property(readonly) NSTextField *dicomGroupTextField;
@property(readonly) NSTextField *dicomElementTextField;
@property(readonly) NSTextField *dicomNameTokenField;
@property(readonly) NSTextField *groupLabel;
@property(readonly) NSTextField *elementLabel;
@property(readonly) NSTextField *nameLabel;
@property(readonly) NSButton *addCustomDICOMFieldButton;
@property(readonly) NSButton *addDICOMFieldButton;
@property(readonly) NSButton *addDatabaseFieldButton;
@property(readonly) NSButton *addSpecialFieldButton;
@property(readonly) NSPopUpButton *DICOMFieldsPopUpButton;
@property(readonly) NSPopUpButton *databaseFieldsPopUpButton;
@property(readonly) NSPopUpButton *specialFieldsPopUpButton;
@property(readonly) NSBox *contentBox;

- (id)initWithFrame:(NSRect)frame target:(id)target;

@end
