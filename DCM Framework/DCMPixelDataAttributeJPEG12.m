#import "DCMPixelDataAttributeJPEG12.h"
#import "DCMPixelDataAttribute.h"

@implementation DCMPixelDataAttribute (DCMPixelDataAttributeJPEG12)

- (NSData *)convertJPEG12ToHost:(NSData *)jpegData
{
    return [self convertEncapsulatedJPEGToHost:jpegData];
}

@end
