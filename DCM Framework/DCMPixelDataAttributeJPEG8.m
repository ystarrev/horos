#import "DCMPixelDataAttributeJPEG8.h"
#import "DCMPixelDataAttribute.h"
#import "DCMTransferSyntax.h"

@implementation DCMPixelDataAttribute (DCMPixelDataAttributeJPEG8)

- (NSMutableData *)convertJPEG8LosslessToHost:(NSData *)jpegData
{
    NSData *decodedData = [self convertEncapsulatedJPEGToHost:jpegData];
    return decodedData ? [NSMutableData dataWithData:decodedData] : nil;
}

- (NSMutableData *)compressJPEG8:(NSMutableData *)data compressionSyntax:(DCMTransferSyntax *)compressionSyntax quality:(float)quality
{
    return nil;
}

@end
