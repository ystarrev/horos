#import "DCMPixelDataAttributeJPEG16.h"
#import "DCMPixelDataAttribute.h"

@implementation DCMPixelDataAttribute (DCMPixelDataAttributeJPEG16)

- (NSData *)convertJPEG16ToHost:(NSData *)jpegData
{
    return [self convertEncapsulatedJPEGToHost:jpegData];
}

@end
