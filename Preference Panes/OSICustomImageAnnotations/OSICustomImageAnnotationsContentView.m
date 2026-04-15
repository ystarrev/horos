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

#import "OSICustomImageAnnotationsContentView.h"

#import "CIALayoutView.h"
#import "RWTokenField.h"

@interface OSICustomImageAnnotationsContentView ()
{
    NSPopUpButton *_modalitiesPopUpButton;
    NSButton *_sameAsDefaultButton;
    NSButton *_resetDefaultButton;
    NSButton *_orientationWidgetButton;
    NSButton *_addAnnotationButton;
    NSButton *_removeAnnotationButton;
    NSSegmentedControl *_loadsaveButton;
    CIALayoutView *_layoutView;
    NSTextField *_titleLabelTextField;
    NSTextField *_titleTextField;
    NSTextField *_contentLabeltextField;
    RWTokenField *_contentTokenField;
    NSTextField *_dicomGroupTextField;
    NSTextField *_dicomElementTextField;
    NSTextField *_dicomNameTokenField;
    NSTextField *_groupLabel;
    NSTextField *_elementLabel;
    NSTextField *_nameLabel;
    NSButton *_addCustomDICOMFieldButton;
    NSButton *_addDICOMFieldButton;
    NSButton *_addDatabaseFieldButton;
    NSButton *_addSpecialFieldButton;
    NSPopUpButton *_DICOMFieldsPopUpButton;
    NSPopUpButton *_databaseFieldsPopUpButton;
    NSPopUpButton *_specialFieldsPopUpButton;
    NSBox *_contentBox;
}
@end

@implementation OSICustomImageAnnotationsContentView

@synthesize modalitiesPopUpButton = _modalitiesPopUpButton;
@synthesize sameAsDefaultButton = _sameAsDefaultButton;
@synthesize resetDefaultButton = _resetDefaultButton;
@synthesize orientationWidgetButton = _orientationWidgetButton;
@synthesize addAnnotationButton = _addAnnotationButton;
@synthesize removeAnnotationButton = _removeAnnotationButton;
@synthesize loadsaveButton = _loadsaveButton;
@synthesize layoutView = _layoutView;
@synthesize titleLabelTextField = _titleLabelTextField;
@synthesize titleTextField = _titleTextField;
@synthesize contentLabeltextField = _contentLabeltextField;
@synthesize contentTokenField = _contentTokenField;
@synthesize dicomGroupTextField = _dicomGroupTextField;
@synthesize dicomElementTextField = _dicomElementTextField;
@synthesize dicomNameTokenField = _dicomNameTokenField;
@synthesize groupLabel = _groupLabel;
@synthesize elementLabel = _elementLabel;
@synthesize nameLabel = _nameLabel;
@synthesize addCustomDICOMFieldButton = _addCustomDICOMFieldButton;
@synthesize addDICOMFieldButton = _addDICOMFieldButton;
@synthesize addDatabaseFieldButton = _addDatabaseFieldButton;
@synthesize addSpecialFieldButton = _addSpecialFieldButton;
@synthesize DICOMFieldsPopUpButton = _DICOMFieldsPopUpButton;
@synthesize databaseFieldsPopUpButton = _databaseFieldsPopUpButton;
@synthesize specialFieldsPopUpButton = _specialFieldsPopUpButton;
@synthesize contentBox = _contentBox;

static NSTextField *OCIAMakeLabel(NSRect frame, NSString *title, NSTextAlignment alignment)
{
    NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [label setEditable:NO];
    [label setBordered:NO];
    [label setDrawsBackground:NO];
    [label setSelectable:NO];
    [[label cell] setLineBreakMode:NSLineBreakByClipping];
    [label setAlignment:alignment];
    [label setStringValue:title ?: @""];
    return label;
}

static NSButton *OCIAMakeSmallSquareButton(NSRect frame, NSString *title, id target, SEL action)
{
    NSButton *button = [[[NSButton alloc] initWithFrame:frame] autorelease];
    [button setButtonType:NSMomentaryPushInButton];
    [button setBezelStyle:NSSmallSquareBezelStyle];
    [button setControlSize:NSControlSizeSmall];
    [button setTitle:title];
    [button setTarget:target];
    [button setAction:action];
    return button;
}

static NSPopUpButton *OCIAMakePopupButton(NSRect frame, id target, SEL action)
{
    NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO] autorelease];
    [popup setTarget:target];
    [popup setAction:action];
    [popup setAutoenablesItems:NO];
    return popup;
}

static NSTextField *OCIAMakeEditableTextField(NSRect frame, id target, SEL action)
{
    NSTextField *field = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [field setTarget:target];
    [field setAction:action];
    return field;
}

- (id)initWithFrame:(NSRect)frame target:(id)target
{
    self = [super initWithFrame:frame];
    if (self)
    {
        [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

        _layoutView = [[CIALayoutView alloc] initWithFrame:NSMakeRect(18.0, 291.0, 651.0, 345.0)];
        [_layoutView setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
        [self addSubview:_layoutView];

        _addAnnotationButton = [OCIAMakeSmallSquareButton(NSMakeRect(310.0, 642.0, 20.0, 20.0), @"+", target, @selector(addAnnotation:)) retain];
        [_addAnnotationButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
        [self addSubview:_addAnnotationButton];

        _removeAnnotationButton = [OCIAMakeSmallSquareButton(NSMakeRect(329.0, 642.0, 20.0, 20.0), @"-", target, @selector(removeAnnotation:)) retain];
        [_removeAnnotationButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
        [self addSubview:_removeAnnotationButton];

        _titleLabelTextField = [OCIAMakeLabel(NSMakeRect(16.0, 244.0, 166.0, 17.0),
                                              NSLocalizedString(@"Selected Annotation Title:", nil),
                                              NSTextAlignmentRight) retain];
        [_titleLabelTextField setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
        [self addSubview:_titleLabelTextField];

        _titleTextField = [OCIAMakeEditableTextField(NSMakeRect(187.0, 242.0, 438.0, 22.0), target, @selector(setTitle:)) retain];
        [_titleTextField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
        [self addSubview:_titleTextField];

        _contentLabeltextField = [OCIAMakeLabel(NSMakeRect(16.0, 219.0, 69.0, 17.0),
                                                NSLocalizedString(@"Content :", nil),
                                                NSTextAlignmentRight) retain];
        [_contentLabeltextField setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
        [self addSubview:_contentLabeltextField];

        _contentTokenField = [[RWTokenField alloc] initWithFrame:NSMakeRect(89.0, 171.0, 580.0, 65.0)];
        [_contentTokenField setTarget:target];
        [_contentTokenField setAction:@selector(validateTokenTextField:)];
        [_contentTokenField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
        [self addSubview:_contentTokenField];

        _contentBox = [[NSBox alloc] initWithFrame:NSMakeRect(1.0, 14.0, 668.0, 158.0)];
        [_contentBox setTitlePosition:NSNoTitle];
        [_contentBox setBorderType:NSNoBorder];
        [_contentBox setBoxType:NSBoxOldStyle];
        [_contentBox setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
        [self addSubview:_contentBox];

        NSView *boxContentView = [_contentBox contentView];

        _elementLabel = [OCIAMakeLabel(NSMakeRect(424.0, 101.0, 55.0, 17.0),
                                       NSLocalizedString(@"Element", nil),
                                       NSTextAlignmentRight) retain];
        [boxContentView addSubview:_elementLabel];

        _DICOMFieldsPopUpButton = [OCIAMakePopupButton(NSMakeRect(260.0, 128.0, 406.0, 26.0), target, @selector(addFieldToken:)) retain];
        [_DICOMFieldsPopUpButton addItemWithTitle:NSLocalizedString(@"DICOM Fields", nil)];
        [boxContentView addSubview:_DICOMFieldsPopUpButton];

        _databaseFieldsPopUpButton = [OCIAMakePopupButton(NSMakeRect(260.0, 36.0, 406.0, 26.0), target, @selector(addFieldToken:)) retain];
        [_databaseFieldsPopUpButton addItemWithTitle:NSLocalizedString(@"Study level", nil)];
        [boxContentView addSubview:_databaseFieldsPopUpButton];

        _specialFieldsPopUpButton = [OCIAMakePopupButton(NSMakeRect(260.0, 6.0, 406.0, 26.0), target, @selector(addFieldToken:)) retain];
        [_specialFieldsPopUpButton addItemWithTitle:NSLocalizedString(@"Other infos", nil)];
        [boxContentView addSubview:_specialFieldsPopUpButton];

        NSTextField *dicomLabel = OCIAMakeLabel(NSMakeRect(71.0, 134.0, 86.0, 17.0),
                                                NSLocalizedString(@"DICOM fields", nil),
                                                NSTextAlignmentLeft);
        [boxContentView addSubview:dicomLabel];

        NSTextField *databaseLabel = OCIAMakeLabel(NSMakeRect(71.0, 42.0, 100.0, 17.0),
                                                   NSLocalizedString(@"Database fields", nil),
                                                   NSTextAlignmentLeft);
        [boxContentView addSubview:databaseLabel];

        NSTextField *specialLabel = OCIAMakeLabel(NSMakeRect(71.0, 9.0, 75.0, 17.0),
                                                  NSLocalizedString(@"Other infos", nil),
                                                  NSTextAlignmentLeft);
        [boxContentView addSubview:specialLabel];

        _groupLabel = [OCIAMakeLabel(NSMakeRect(215.0, 101.0, 43.0, 17.0),
                                     NSLocalizedString(@"Group", nil),
                                     NSTextAlignmentRight) retain];
        [boxContentView addSubview:_groupLabel];

        _nameLabel = [OCIAMakeLabel(NSMakeRect(215.0, 71.0, 41.0, 17.0),
                                    NSLocalizedString(@"Name", nil),
                                    NSTextAlignmentRight) retain];
        [boxContentView addSubview:_nameLabel];

        _dicomGroupTextField = [OCIAMakeEditableTextField(NSMakeRect(265.0, 99.0, 145.0, 22.0), target, NULL) retain];
        [boxContentView addSubview:_dicomGroupTextField];

        _dicomElementTextField = [OCIAMakeEditableTextField(NSMakeRect(484.0, 99.0, 179.0, 22.0), target, NULL) retain];
        [boxContentView addSubview:_dicomElementTextField];

        _addCustomDICOMFieldButton = [OCIAMakeSmallSquareButton(NSMakeRect(51.0, 102.0, 15.0, 16.0), @"+", target, @selector(addFieldToken:)) retain];
        [boxContentView addSubview:_addCustomDICOMFieldButton];

        _addDICOMFieldButton = [OCIAMakeSmallSquareButton(NSMakeRect(51.0, 134.0, 15.0, 16.0), @"+", target, @selector(addFieldToken:)) retain];
        [boxContentView addSubview:_addDICOMFieldButton];

        _addDatabaseFieldButton = [OCIAMakeSmallSquareButton(NSMakeRect(51.0, 42.0, 15.0, 16.0), @"+", target, @selector(addFieldToken:)) retain];
        [boxContentView addSubview:_addDatabaseFieldButton];

        _addSpecialFieldButton = [OCIAMakeSmallSquareButton(NSMakeRect(51.0, 9.0, 15.0, 16.0), @"+", target, @selector(addFieldToken:)) retain];
        [boxContentView addSubview:_addSpecialFieldButton];

        NSTextField *customDICOMLabel = OCIAMakeLabel(NSMakeRect(71.0, 101.0, 132.0, 17.0),
                                                      NSLocalizedString(@"Custom DICOM field", nil),
                                                      NSTextAlignmentLeft);
        [boxContentView addSubview:customDICOMLabel];

        _dicomNameTokenField = [OCIAMakeEditableTextField(NSMakeRect(263.0, 69.0, 400.0, 22.0), target, NULL) retain];
        [boxContentView addSubview:_dicomNameTokenField];

        NSTextField *annotationLabel = OCIAMakeLabel(NSMakeRect(354.0, 643.0, 160.0, 17.0),
                                                     NSLocalizedString(@"Add/Remove Annotation", nil),
                                                     NSTextAlignmentLeft);
        [annotationLabel setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
        [self addSubview:annotationLabel];

        _modalitiesPopUpButton = [OCIAMakePopupButton(NSMakeRect(95.0, 638.0, 98.0, 26.0), target, @selector(switchModality:)) retain];
        [_modalitiesPopUpButton addItemWithTitle:NSLocalizedString(@"Default", nil)];
        [_modalitiesPopUpButton setPreferredEdge:NSMaxYEdge];
        [_modalitiesPopUpButton setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
        [self addSubview:_modalitiesPopUpButton];

        NSTextField *modalityLabel = OCIAMakeLabel(NSMakeRect(14.0, 644.0, 79.0, 17.0),
                                                   NSLocalizedString(@"Modality:", nil),
                                                   NSTextAlignmentRight);
        [modalityLabel setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
        [self addSubview:modalityLabel];

        _sameAsDefaultButton = [[NSButton alloc] initWithFrame:NSMakeRect(196.0, 643.0, 108.0, 18.0)];
        [_sameAsDefaultButton setButtonType:NSSwitchButton];
        [_sameAsDefaultButton setControlSize:NSControlSizeSmall];
        [_sameAsDefaultButton setTitle:NSLocalizedString(@"Same as Default", nil)];
        [_sameAsDefaultButton setTarget:target];
        [_sameAsDefaultButton setAction:@selector(setSameAsDefault:)];
        [_sameAsDefaultButton setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
        [self addSubview:_sameAsDefaultButton];

        _orientationWidgetButton = [[NSButton alloc] initWithFrame:NSMakeRect(577.0, 642.0, 94.0, 18.0)];
        [_orientationWidgetButton setButtonType:NSSwitchButton];
        [_orientationWidgetButton setTitle:NSLocalizedString(@"Orientation", nil)];
        [_orientationWidgetButton setTarget:target];
        [_orientationWidgetButton setAction:@selector(toggleOrientationWidget:)];
        [_orientationWidgetButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
        [self addSubview:_orientationWidgetButton];

        _resetDefaultButton = [[NSButton alloc] initWithFrame:NSMakeRect(198.0, 644.0, 48.0, 16.0)];
        [_resetDefaultButton setBezelStyle:NSRoundedBezelStyle];
        [_resetDefaultButton setControlSize:NSControlSizeMini];
        [_resetDefaultButton setTitle:NSLocalizedString(@"Reset", nil)];
        [_resetDefaultButton setTarget:target];
        [_resetDefaultButton setAction:@selector(reset:)];
        [_resetDefaultButton setAutoresizingMask:NSViewMaxXMargin | NSViewMinYMargin];
        [self addSubview:_resetDefaultButton];

        _loadsaveButton = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(523.0, 272.0, 147.0, 15.0)];
        [_loadsaveButton setSegmentCount:2];
        [_loadsaveButton setLabel:NSLocalizedString(@"Save", nil) forSegment:0];
        [_loadsaveButton setLabel:NSLocalizedString(@"Load", nil) forSegment:1];
        [_loadsaveButton setTarget:target];
        [_loadsaveButton setAction:@selector(loadsave:)];
        [_loadsaveButton setControlSize:NSControlSizeMini];
        [_loadsaveButton setAutoresizingMask:NSViewMinXMargin | NSViewMinYMargin];
        [self addSubview:_loadsaveButton];
    }
    return self;
}

- (void)dealloc
{
    [_modalitiesPopUpButton release];
    [_sameAsDefaultButton release];
    [_resetDefaultButton release];
    [_orientationWidgetButton release];
    [_addAnnotationButton release];
    [_removeAnnotationButton release];
    [_loadsaveButton release];
    [_layoutView release];
    [_titleLabelTextField release];
    [_titleTextField release];
    [_contentLabeltextField release];
    [_contentTokenField release];
    [_dicomGroupTextField release];
    [_dicomElementTextField release];
    [_dicomNameTokenField release];
    [_groupLabel release];
    [_elementLabel release];
    [_nameLabel release];
    [_addCustomDICOMFieldButton release];
    [_addDICOMFieldButton release];
    [_addDatabaseFieldButton release];
    [_addSpecialFieldButton release];
    [_DICOMFieldsPopUpButton release];
    [_databaseFieldsPopUpButton release];
    [_specialFieldsPopUpButton release];
    [_contentBox release];
    [super dealloc];
}

@end
