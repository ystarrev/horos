#import <Foundation/Foundation.h>

// Adapt DCMTK XML to the metadata outline's existing tag/item/value hierarchy.
FOUNDATION_EXPORT NSXMLDocument *HorosDICOMMetadataDocument(NSString *xml, NSError **error);
FOUNDATION_EXPORT NSXMLElement *HorosDICOMMetadataAttribute(NSString *tag, NSString *name,
                                                         NSString *vr, NSArray<NSString *> *values);
FOUNDATION_EXPORT NSString *HorosDICOMMetadataText(NSXMLDocument *document);
// Short scalar preview for tag menus; never returns binary placeholders or sequence content.
FOUNDATION_EXPORT NSString *HorosDICOMMetadataShortValue(NSXMLElement *attribute);

// Direct children only: never substitute a similarly named tag from a nested item.
// Missing/unreadable scalars return nil; present empty scalars return an empty array/string.
FOUNDATION_EXPORT NSArray<NSString *> *HorosDICOMMetadataValues(NSXMLElement *item, NSString *tag);
FOUNDATION_EXPORT NSString *HorosDICOMMetadataString(NSXMLElement *item, NSString *tag);
FOUNDATION_EXPORT NSArray<NSXMLElement *> *HorosDICOMMetadataItems(NSXMLElement *item, NSString *tag);
FOUNDATION_EXPORT NSArray<NSNumber *> *HorosDICOMMetadataNumbers(NSXMLElement *item, NSString *tag);
