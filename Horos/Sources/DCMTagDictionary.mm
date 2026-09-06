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

#import "DCMTagDictionary.h"

#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcdicent.h>
#include <memory>

static NSDictionary *tagDictionary;
static NSDictionary *nameDictionary;
static DcmDataDictionary *toolkitDictionary;
static NSString *dictionaryFailure;

static NSString *DCMTagKeyString(unsigned int group, unsigned int element)
{
    return [NSString stringWithFormat:@"%04X,%04X", group, element];
}

static NSDictionary *DCMTagInfo(const DcmDictEntry *entry)
{
    if (!entry || !entry->getTagName())
        return nil;

    NSString *vr = @(entry->getVR().getVRName());
    // Translate DCMTK's context-dependent VRs to the existing reader contract.
    switch (entry->getEVR())
    {
        case EVR_px: vr = @"ox"; break;
        case EVR_xs: vr = @"US/SS"; break;
        case EVR_lt: vr = @"US/SS/OW"; break;
        case EVR_up: vr = @"UL"; break;
        default: break;
    }
    int minimum = entry->getVMMin(), maximum = entry->getVMMax();
    NSString *vm = minimum == maximum ? [NSString stringWithFormat:@"%d", minimum]
        : maximum == DcmVariableVM ? [NSString stringWithFormat:@"%d-n", minimum]
        : [NSString stringWithFormat:@"%d-%d", minimum, maximum];
    return @{@"Description": @(entry->getTagName()), @"VR": vr, @"VM": vm};
}

static void DCMAddDictionaryEntry(const DcmDictEntry *entry, NSMutableDictionary *tags,
                                 NSMutableDictionary *names)
{
    // A private creator is needed to identify a vendor attribute unambiguously.
    if (entry->getPrivateCreator())
        return;
    NSDictionary *info = DCMTagInfo(entry);
    if (!info)
        return;
    NSString *key = DCMTagKeyString(entry->getGroup(), entry->getElement());
    if (!tags[key])
        tags[key] = info;
    names[@(entry->getTagName())] = key;
}

static void DCMPrepareTagDictionaries(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle bundleForClass:[DCMTagDictionary class]];
        NSString *dictionaryPath = [bundle pathForResource:@"dicom" ofType:@"dic"]
            ?: [[NSBundle mainBundle] pathForResource:@"dicom" ofType:@"dic"];
        NSString *compatibilityPath = [bundle pathForResource:@"DCMTagDictionaryCompatibility" ofType:@"json"];
        NSData *data = compatibilityPath ? [NSData dataWithContentsOfFile:compatibilityPath] : nil;
        NSError *error = nil;
        NSDictionary *compatibility = data
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if (![compatibility isKindOfClass:[NSDictionary class]]
            || ![compatibility[@"Tags"] isKindOfClass:[NSDictionary class]]
            || ![compatibility[@"Aliases"] isKindOfClass:[NSDictionary class]])
        {
            dictionaryFailure = [[NSString alloc] initWithFormat:
                @"Cannot load the DICOM tag compatibility resource: %@", error.localizedDescription ?: @"missing resource"];
            return;
        }

        std::unique_ptr<DcmDataDictionary> dictionary(new DcmDataDictionary(OFTrue, OFFalse));
        if (dictionaryPath && !dictionary->loadDictionary(dictionaryPath.fileSystemRepresentation))
        {
            dictionaryFailure = [@"Cannot read the bundled DCMTK DICOM dictionary." copy];
            return;
        }
        if (!dictionary->isDictionaryLoaded())
        {
            dictionaryFailure = [@"The bundled DCMTK DICOM dictionary is missing." copy];
            return;
        }

        NSMutableDictionary *tags = [NSMutableDictionary dictionary];
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        for (DcmHashDictIterator it = dictionary->normalBegin(); it != dictionary->normalEnd(); ++it)
            DCMAddDictionaryEntry(*it, tags, names);
        for (DcmDictEntryListIterator it = dictionary->repeatingBegin(); it != dictionary->repeatingEnd(); ++it)
            DCMAddDictionaryEntry(*it, tags, names);

        NSDictionary *overrides = compatibility[@"Tags"];
        for (NSString *key in overrides)
        {
            NSMutableDictionary *info = tags[key]
                ? [[tags[key] mutableCopy] autorelease] : [NSMutableDictionary dictionary];
            [info addEntriesFromDictionary:overrides[key]];
            tags[key] = [[info copy] autorelease];
        }
        // Keep canonical DCMTK keywords as well as names already saved by Horos.
        for (NSString *key in [[tags allKeys] sortedArrayUsingSelector:@selector(compare:)])
            names[tags[key][@"Description"]] = key;
        [names addEntriesFromDictionary:compatibility[@"Aliases"]];

        tagDictionary = [tags copy];
        nameDictionary = [names copy];
        // Process-lifetime, immutable dictionary: lookups never load a DICOM file.
        toolkitDictionary = dictionary.release();
    });

    if (dictionaryFailure)
        [NSException raise:NSInternalInconsistencyException format:@"%@", dictionaryFailure];
}

@implementation DCMTagDictionary

+ (id)sharedTagDictionary
{
    DCMPrepareTagDictionaries();
    return tagDictionary;
}

+ (NSDictionary *)sharedNameDictionary
{
    DCMPrepareTagDictionaries();
    return nameDictionary;
}

+ (NSDictionary *)infoForGroup:(int)group element:(int)element
{
    if (group < 0 || group > 0xffff || element < 0 || element > 0xffff)
        return nil;
    DCMPrepareTagDictionaries();
    NSDictionary *info = tagDictionary[DCMTagKeyString(group, element)];
    if (info)
        return info;
    // Resolve repeating groups such as (6002,3000) without expanding ranges
    // into millions of menu entries or guessing a private creator.
    return DCMTagInfo(toolkitDictionary->findEntry(DcmTagKey(group, element), nullptr));
}

@end
