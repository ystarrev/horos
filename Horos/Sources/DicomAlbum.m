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

#import "DicomAlbum.h"
#import "DicomSeries.h"
#import "DicomStudy.h"
#import "NSManagedObject+N2.h"

static NSString * const HorosSeriesCollectionPrefixV1 = @"horos:series-collection:v1:";
static NSString * const HorosSeriesCollectionPrefix = @"horos:series-collection:v2:";

static NSString *HorosSeriesCollectionKey(DicomSeries *series)
{
    NSString *studyUID = series.study.studyInstanceUID;
    // Horos may split one DICOM series into multiple records; use its distinct series identity.
    NSString *seriesUID = series.seriesInstanceUID.length ? series.seriesInstanceUID : series.seriesDICOMUID;
    if (studyUID.length && seriesUID.length)
        return [NSString stringWithFormat:@"uid:%@|%@", studyUID, seriesUID];
    NSString *xid = [series XID];
    return xid.length ? [@"xid:" stringByAppendingString:xid] : nil;
}

@implementation DicomAlbum

@dynamic index;
@dynamic name;
@dynamic predicateString;
@dynamic smartAlbum;
@dynamic studies;
@synthesize numberOfStudies;

+ (NSString *)seriesCollectionKeyForSeries:(DicomSeries *)series
{
    return HorosSeriesCollectionKey(series);
}

- (BOOL)isSeriesCollection
{
    return !self.smartAlbum.boolValue &&
        ([self.predicateString hasPrefix:HorosSeriesCollectionPrefix] ||
         [self.predicateString hasPrefix:HorosSeriesCollectionPrefixV1]);
}

- (NSDictionary *)seriesCollectionPayload
{
    if (![self isSeriesCollection]) return @{};
    NSUInteger prefixLength = [self.predicateString hasPrefix:HorosSeriesCollectionPrefix] ?
        HorosSeriesCollectionPrefix.length : HorosSeriesCollectionPrefixV1.length;
    NSString *json = [self.predicateString substringFromIndex:prefixLength];
    id values = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                               options:0 error:NULL];
    if ([values isKindOfClass:[NSArray class]]) return @{ @"series": values };
    return [values isKindOfClass:[NSDictionary class]] ? values : @{};
}

- (NSArray<NSString *> *)seriesCollectionStringArrayForKey:(NSString *)field
{
    id values = [[self seriesCollectionPayload] objectForKey:field];
    if (![values isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *keys = [NSMutableArray array];
    for (id value in values)
        if ([value isKindOfClass:[NSString class]] && [value length])
            [keys addObject:value];
    return keys;
}

- (NSArray<NSString *> *)seriesCollectionKeys
{
    return [self seriesCollectionStringArrayForKey:@"series"];
}

- (NSDictionary *)seriesCollectionCriteria
{
    id criteria = [[self seriesCollectionPayload] objectForKey:@"criteria"];
    return [criteria isKindOfClass:[NSDictionary class]] ? criteria : @{};
}

- (NSArray<NSString *> *)seriesCollectionExcludedKeys
{
    return [self seriesCollectionStringArrayForKey:@"excluded"];
}

- (void)setSeriesCollectionPayloadField:(id)value forKey:(NSString *)field
{
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:[self seriesCollectionPayload]];
    [payload setObject:value forKey:field];
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (data)
        self.predicateString = [HorosSeriesCollectionPrefix stringByAppendingString:
            [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]];
}

- (void)setSeriesCollectionKeys:(NSArray<NSString *> *)keys
{
    NSMutableOrderedSet *uniqueKeys = [NSMutableOrderedSet orderedSet];
    for (id key in keys)
        if ([key isKindOfClass:[NSString class]] && [key length])
            [uniqueKeys addObject:key];
    [self setSeriesCollectionPayloadField:uniqueKeys.array forKey:@"series"];
}

- (void)setSeriesCollectionCriteria:(NSDictionary *)criteria
{
    if ([criteria isKindOfClass:[NSDictionary class]])
        [self setSeriesCollectionPayloadField:criteria forKey:@"criteria"];
}

- (void)setSeriesCollectionExcludedKeys:(NSArray<NSString *> *)keys
{
    NSMutableOrderedSet *uniqueKeys = [NSMutableOrderedSet orderedSet];
    for (id key in keys)
        if ([key isKindOfClass:[NSString class]] && [key length])
            [uniqueKeys addObject:key];
    [self setSeriesCollectionPayloadField:uniqueKeys.array forKey:@"excluded"];
}

- (BOOL)containsSeriesInCollection:(DicomSeries *)series
{
    NSString *key = HorosSeriesCollectionKey(series);
    return key.length && [[self seriesCollectionKeys] containsObject:key];
}

- (void)addSeriesToCollection:(DicomSeries *)series
{
    if (![self isSeriesCollection] || !series.study) return;
    NSString *key = HorosSeriesCollectionKey(series);
    if (!key.length) return;
    NSMutableArray *keys = [NSMutableArray arrayWithArray:[self seriesCollectionKeys]];
    if (![keys containsObject:key])
        [keys addObject:key];
    [self setSeriesCollectionKeys:keys];
    NSMutableArray *excluded = [NSMutableArray arrayWithArray:[self seriesCollectionExcludedKeys]];
    [excluded removeObject:key];
    if (excluded.count != [self seriesCollectionExcludedKeys].count)
        [self setSeriesCollectionExcludedKeys:excluded];
    [self addStudiesObject:series.study];
}

- (void)removeSeriesFromCollection:(DicomSeries *)series
{
    if (![self isSeriesCollection]) return;
    NSString *key = HorosSeriesCollectionKey(series);
    if (!key.length) return;
    NSMutableArray *keys = [NSMutableArray arrayWithArray:[self seriesCollectionKeys]];
    [keys removeObject:key];
    [self setSeriesCollectionKeys:keys];
    NSMutableArray *excluded = [NSMutableArray arrayWithArray:[self seriesCollectionExcludedKeys]];
    if (![excluded containsObject:key]) {
        [excluded addObject:key];
        [self setSeriesCollectionExcludedKeys:excluded];
    }
    BOOL hasRemainingSeries = NO;
    for (DicomSeries *candidate in series.study.series)
        if ([self containsSeriesInCollection:candidate]) {
            hasRemainingSeries = YES;
            break;
        }
    if (!hasRemainingSeries)
        [self removeStudiesObject:series.study];
}

@end
