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

#import "DCMTransferSyntax.h"

#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcuid.h>

@implementation DCMTransferSyntax

@synthesize transferSyntax, name;
@synthesize isEncapsulated, isLittleEndian, isExplicit;

+ (id)ExplicitVRLittleEndianTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_LittleEndianExplicitTransferSyntax] autorelease];
}

+ (id)ImplicitVRLittleEndianTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_LittleEndianImplicitTransferSyntax] autorelease];
}

+ (id)ExplicitVRBigEndianTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_BigEndianExplicitTransferSyntax] autorelease];
}

+ (id)JPEG2000LosslessTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_JPEG2000LosslessOnlyTransferSyntax] autorelease];
}

+ (id)JPEG2000LossyTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_JPEG2000TransferSyntax] autorelease];
}

+ (id)JPEGBaselineTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_JPEGProcess1TransferSyntax] autorelease];
}

+ (id)JPEGExtendedTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_JPEGProcess2_4TransferSyntax] autorelease];
}

+ (id)JPEGLosslessTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_JPEGProcess14SV1TransferSyntax] autorelease];
}

+ (id)JPEGLossless14TransferSyntax
{
    return [[[self alloc] initWithTS:@UID_JPEGProcess14TransferSyntax] autorelease];
}

+ (id)JPEGLSLosslessTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_JPEGLSLosslessTransferSyntax] autorelease];
}

+ (id)JPEGLSLossyTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_JPEGLSLossyTransferSyntax] autorelease];
}

+ (id)RLELosslessTransferSyntax
{
    return [[[self alloc] initWithTS:@UID_RLELosslessTransferSyntax] autorelease];
}

+ (id)MPEG2TransferSyntax
{
    return [[[self alloc] initWithTS:@UID_MPEG2MainProfileAtMainLevelTransferSyntax] autorelease];
}

- (id)initWithTS:(NSString *)ts
{
    if (!(self = [super init]))
        return nil;
    if (ts.length == 0)
    {
        [self release];
        return nil;
    }

    DcmXfer syntax(ts.UTF8String);
    transferSyntax = [ts copy];
    if (syntax.getXfer() != EXS_Unknown)
    {
        isEncapsulated = syntax.usesEncapsulatedFormat();
        isLittleEndian = syntax.isLittleEndian();
        isExplicit = syntax.isExplicitVR();
        name = [[NSString alloc] initWithUTF8String:syntax.getXferName()];
    }
    else
    {
        // Preserve the legacy fallback for private transfer syntaxes.
        isEncapsulated = YES;
        isLittleEndian = YES;
        isExplicit = YES;
        name = [@"Unknown Syntax" copy];
    }
    return self;
}

- (id)initWithTS:(NSString *)ts isEncapsulated:(BOOL)encapsulated isLittleEndian:(BOOL)endian isExplicit:(BOOL)explicitValue name:(NSString *)aName
{
    if (!(self = [super init]))
        return nil;
    if (ts.length == 0)
    {
        [self release];
        return nil;
    }
    transferSyntax = [ts copy];
    name = [aName copy];
    isEncapsulated = encapsulated;
    isLittleEndian = endian;
    isExplicit = explicitValue;
    return self;
}

- (id)initWithTransferSyntax:(DCMTransferSyntax *)ts
{
    return [self initWithTS:ts.transferSyntax
            isEncapsulated:ts.isEncapsulated
            isLittleEndian:ts.isLittleEndian
                isExplicit:ts.isExplicit
                      name:ts.name];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[[self class] allocWithZone:zone] initWithTransferSyntax:self];
}

- (void)dealloc
{
    [transferSyntax release];
    [name release];
    [super dealloc];
}

- (BOOL)isEqualToTransferSyntax:(DCMTransferSyntax *)ts
{
    return [ts isKindOfClass:[DCMTransferSyntax class]]
        && [transferSyntax isEqualToString:ts.transferSyntax];
}

- (BOOL)isEqual:(id)object
{
    return [self isEqualToTransferSyntax:object];
}

- (NSUInteger)hash
{
    return transferSyntax.hash;
}

- (NSString *)description
{
    return name;
}

@end
