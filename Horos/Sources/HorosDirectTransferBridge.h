#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

FOUNDATION_EXPORT BOOL HorosRetrieveDICOMQueryItems(
    NSArray<NSDictionary<NSString *, NSString *> *> *items,
    NSString *host,
    NSInteger dicomPort,
    NSString *calledAET
);

#ifdef __cplusplus
}
#endif
