#import <Foundation/Foundation.h>

// Adapt DCMTK XML to the metadata outline's existing tag/item/value hierarchy.
FOUNDATION_EXPORT NSXMLDocument *HorosDICOMMetadataDocument(NSString *xml, NSError **error);
FOUNDATION_EXPORT NSXMLElement *HorosDICOMMetadataAttribute(NSString *tag, NSString *name,
                                                         NSString *vr, NSArray<NSString *> *values);
FOUNDATION_EXPORT NSString *HorosDICOMMetadataText(NSXMLDocument *document);
