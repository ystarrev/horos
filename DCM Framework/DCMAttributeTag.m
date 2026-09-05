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


#import "DCMAttributeTag.h"
#import "DCMTagDictionary.h"
#import "DCMTagForNameDictionary.h"

static BOOL DCMParseTagComponent(NSString *text, unsigned int *value)
{
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text hasPrefix:@"0x"] || [text hasPrefix:@"0X"])
        text = [text substringFromIndex:2];
    if (text.length == 0 || text.length > 4)
        return NO;
    unsigned int result = 0;
    for (NSUInteger i = 0; i < text.length; ++i)
    {
        unichar c = [text characterAtIndex:i];
        unsigned int digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return NO;
        result = (result << 4) | digit;
    }
    *value = result;
    return YES;
}

static BOOL DCMParseTagString(NSString *text, unsigned int *group, unsigned int *element)
{
    if (![text isKindOfClass:[NSString class]])
        return NO;
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text hasPrefix:@"("] && [text hasSuffix:@")"])
        text = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    NSArray *parts = [text componentsSeparatedByString:@","];
    return parts.count == 2 && DCMParseTagComponent(parts[0], group)
        && DCMParseTagComponent(parts[1], element);
}

@implementation DCMAttributeTag

@synthesize group = _group, element = _element, name = _name, vr = _vr;

+ (id) tagWithGroup:(int)group element:(int)element{
	return [[[DCMAttributeTag alloc] initWithGroup:group element:element] autorelease];
}

+ (id) tagWithTag:(DCMAttributeTag *)tag{
	return [[[DCMAttributeTag alloc] initWithTag:(DCMAttributeTag *)tag] autorelease];
}

+ (id) tagWithTagString:(NSString *)tagString{
	return [[[DCMAttributeTag alloc] initWithTagString:tagString] autorelease];
}

+ (id) tagWithName:(NSString *)name{
	return [[[DCMAttributeTag alloc] initWithName:name] autorelease];
}

- (id) initWithGroup:(int)group element:(int)element{
	if (group < 0 || group > 0xffff || element < 0 || element > 0xffff) {
        [self release];
        return nil;
    }
	if ((self = [super init])) {
		_group = group;
		_element = element;
		NSDictionary *info = [DCMTagDictionary infoForGroup:group element:element];
        _name = [(info[@"Description"] ?: @"Unknown") retain];
        _vr = [(info[@"VR"] ?: @"UN") retain];
	}
	return self;
}

- (id) initWithTag:(DCMAttributeTag *)tag{
    if (!tag) {
        [self release];
        return nil;
    }
    if ((self = [self initWithGroup:tag.group element:tag.element]))
        self.vr = tag.vr;
    return self;
}

- (id) initWithTagString:(NSString *)tagString{
    unsigned int group, element;
    if (!DCMParseTagString(tagString, &group, &element)) {
        [self release];
        return nil;
    }
    return [self initWithGroup:(int)group element:(int)element];
}
- (id) initWithName:(NSString *)name
{
    NSString *tagString = [name isKindOfClass:[NSString class]]
        ? [[DCMTagForNameDictionary sharedTagForNameDictionary] objectForKey:name] : nil;
    return [self initWithTagString:tagString];
}


- (id)copyWithZone:(NSZone *)zone{
	return [[DCMAttributeTag allocWithZone:zone] initWithTag:self];
}

- (void) dealloc{
	[_name release];
	[_vr release];
	[_stringValue release];
	[super dealloc];
}

- (BOOL)isPrivate{
	if ((_group%2) == 0)
		return NO;		
	return YES;
}

- (NSString *)stringValue {
	if (!_stringValue)
		_stringValue = [[NSString alloc] initWithFormat:@"%04X,%04X", _group, _element];
	return _stringValue;
}

- (NSString *)description {
	return [NSString stringWithFormat:@"%@\t%@\t%@", self.stringValue, _name, _vr];
}

- (NSString *)readableDescription {
    
    if( _name.length > 0)
        return _name;
    else
        return self.stringValue;
}

- (long)longValue {
    return (long)(((unsigned long)_group << 16) | (unsigned long)_element);
}

- (NSComparisonResult)compare:(DCMAttributeTag *)tag {
	return [[self stringValue] compare: tag.stringValue];
}

- (BOOL)isEquaToTag:(DCMAttributeTag *)tag {
    return [tag isKindOfClass:[DCMAttributeTag class]] && _group == tag.group && _element == tag.element;
}

-(BOOL)isEqual:(id)object {
	return [object isKindOfClass:[DCMAttributeTag class]] && [self isEquaToTag:object];
}

- (NSUInteger)hash {
    return (NSUInteger)self.longValue;
}

@end
