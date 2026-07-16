#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface StructuredReportSupport : NSObject

+ (nullable NSString *)htmlStringForPath:(NSString *)path;
+ (BOOL)writePDFForDICOMAtPath:(NSString *)dicomPath
                        toPath:(NSString *)pdfPath
                         error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
