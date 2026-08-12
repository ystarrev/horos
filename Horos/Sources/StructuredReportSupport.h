#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface StructuredReportSupport : NSObject

+ (nullable NSString *)htmlStringForPath:(NSString *)path;
+ (NSString *)surgicalProcedureSeriesDescription;
+ (nullable NSString *)surgicalProcedureRecordJSONForPath:(NSString *)path;
+ (BOOL)writeSurgicalProcedureRecordJSON:(NSString *)recordJSON
                                  toPath:(NSString *)path
                           sopInstanceUID:(NSString *)sopInstanceUID
                        seriesInstanceUID:(NSString *)seriesInstanceUID
                         studyInstanceUID:(NSString *)studyInstanceUID
                              patientName:(NSString *)patientName
                         patientBirthDate:(nullable NSString *)patientBirthDate
                                patientID:(NSString *)patientID
                              contentDate:(NSString *)contentDate
                              contentTime:(NSString *)contentTime
                                    error:(NSError * _Nullable * _Nullable)error;
+ (NSArray<NSDictionary<NSString *, id> *> *)surgicalProcedureRecordDescriptorsForDatabaseBasePath:(NSString *)basePath
    NS_SWIFT_NAME(surgicalProcedureRecordDescriptors(databaseBasePath:));
+ (NSArray<NSDictionary<NSString *, id> *> *)surgicalProcedureRecordDescriptorsForStudies:(NSArray *)studies
    NS_SWIFT_NAME(surgicalProcedureRecordDescriptors(studies:));
+ (NSDictionary<NSString *, id> *)storeSurgicalProcedureRecordPayloads:(NSArray<NSDictionary<NSString *, id> *> *)payloads
                                                       databaseBasePath:(NSString *)basePath
    NS_SWIFT_NAME(storeSurgicalProcedureRecordPayloads(_:databaseBasePath:));
+ (BOOL)writePDFForDICOMAtPath:(NSString *)dicomPath
                        toPath:(NSString *)pdfPath
                         error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
