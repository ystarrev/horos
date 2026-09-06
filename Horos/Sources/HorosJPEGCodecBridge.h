#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decodes one encapsulated JPEG frame. This is a codec-only boundary: the
/// caller owns DICOM parsing, fragment selection, and pixel normalization.
FOUNDATION_EXPORT NSData * _Nullable HorosDecodeJPEGFrame(NSData *jpegData,
                                                        NSString *transferSyntaxUID,
                                                        NSString *photometricInterpretation,
                                                        int rows,
                                                        int columns,
                                                        int samplesPerPixel,
                                                        int bitsAllocated,
                                                        int bitsStored,
                                                        BOOL isSigned,
                                                        int planarConfiguration);

NS_ASSUME_NONNULL_END
