#import "StructuredReportSupport.h"

#import <WebKit/WebKit.h>
#include <dlfcn.h>

static NSString * const StructuredReportSupportErrorDomain = @"org.horosproject.StructuredReportSupport";

typedef char* (*HorosCopyStructuredReportHTMLFunction)(const char*);
typedef void (*HorosFreeStringFunction)(char*);

static void* StructuredReportBridgeHandle(void)
{
    static void* handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        NSArray<NSString *> *basePaths = @[
            bundle.resourcePath ?: @"",
            bundle.privateFrameworksPath ?: @"",
            bundle.sharedFrameworksPath ?: @""
        ];
        NSArray<NSString *> *relativePaths = @[
            @"libHorosModernDCMTKBridge.dylib",
            @"DCMTK/libHorosModernDCMTKBridge.dylib"
        ];

        for (NSString *basePath in basePaths)
        {
            for (NSString *relativePath in relativePaths)
            {
                NSString *candidate = [basePath stringByAppendingPathComponent:relativePath];
                if (![[NSFileManager defaultManager] fileExistsAtPath:candidate])
                    continue;

                handle = dlopen(candidate.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
                if (handle == NULL)
                    NSLog(@"Modern DCMTK bridge failed to load at %@: %s", candidate, dlerror());
                return;
            }
        }
    });
    return handle;
}

static void* StructuredReportBridgeSymbol(const char* name)
{
    void* handle = StructuredReportBridgeHandle();
    return handle != NULL ? dlsym(handle, name) : NULL;
}

static NSError *StructuredReportError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:StructuredReportSupportErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

@interface StructuredReportPDFLoadSession : NSObject <WKNavigationDelegate>
@property(nonatomic) BOOL finished;
@property(nonatomic, strong, nullable) NSError *error;
@end

@implementation StructuredReportPDFLoadSession

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    self.finished = YES;
}

- (void)webView:(WKWebView *)webView
didFailNavigation:(WKNavigation *)navigation
      withError:(NSError *)error
{
    self.error = error;
    self.finished = YES;
}

- (void)webView:(WKWebView *)webView
didFailProvisionalNavigation:(WKNavigation *)navigation
      withError:(NSError *)error
{
    self.error = error;
    self.finished = YES;
}

@end

@implementation StructuredReportSupport

+ (NSString *)htmlStringForPath:(NSString *)path
{
    if (path.length == 0)
        return nil;

    HorosCopyStructuredReportHTMLFunction render =
        (HorosCopyStructuredReportHTMLFunction)StructuredReportBridgeSymbol("HorosModernDCMTKCopyStructuredReportHTML");
    HorosFreeStringFunction freeString =
        (HorosFreeStringFunction)StructuredReportBridgeSymbol("HorosModernDCMTKFreeString");
    if (render == NULL)
        return nil;

    char *html = render(path.fileSystemRepresentation);
    if (html == NULL)
        return nil;

    NSString *result = [NSString stringWithUTF8String:html];
    if (freeString != NULL)
        freeString(html);
    return result;
}

+ (BOOL)writePDFForDICOMAtPath:(NSString *)dicomPath
                        toPath:(NSString *)pdfPath
                         error:(NSError **)error
{
    NSString *html = [self htmlStringForPath:dicomPath];
    if (html.length == 0)
    {
        if (error != NULL)
            *error = StructuredReportError(1, @"The structured report could not be rendered as HTML.");
        return NO;
    }

    __block BOOL succeeded = NO;
    __block NSError *conversionError = nil;
    void (^renderPDF)(void) = ^{
        StructuredReportPDFLoadSession *session = [[StructuredReportPDFLoadSession alloc] init];
        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];

        WKWebView *webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 612, 792)
                                               configuration:configuration];
        webView.navigationDelegate = session;

        NSWindow *window = [[NSWindow alloc] initWithContentRect:webView.frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        window.contentView = webView;

        NSURL *baseURL = [NSURL fileURLWithPath:dicomPath.stringByDeletingLastPathComponent
                                   isDirectory:YES];
        [webView loadHTMLString:html baseURL:baseURL];

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
        while (!session.finished && deadline.timeIntervalSinceNow > 0.0)
        {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }

        if (!session.finished)
            conversionError = StructuredReportError(2, @"Timed out while loading the structured report.");
        else if (session.error != nil)
            conversionError = session.error;
        else
        {
            [[NSFileManager defaultManager] removeItemAtPath:pdfPath error:nil];
            NSMutableDictionary *printDictionary =
                [NSMutableDictionary dictionaryWithDictionary:[NSPrintInfo sharedPrintInfo].dictionary];
            printDictionary[NSPrintJobDisposition] = NSPrintSaveJob;
            printDictionary[NSPrintJobSavingURL] = [NSURL fileURLWithPath:pdfPath];

            NSPrintInfo *printInfo = [[NSPrintInfo alloc] initWithDictionary:printDictionary];
            printInfo.bottomMargin = 30.0;
            printInfo.topMargin = 30.0;
            printInfo.leftMargin = 24.0;
            printInfo.rightMargin = 24.0;
            printInfo.horizontalPagination = NSPrintingPaginationModeAutomatic;
            printInfo.verticalPagination = NSPrintingPaginationModeAutomatic;
            printInfo.verticallyCentered = NO;

            NSPrintOperation *operation = [webView printOperationWithPrintInfo:printInfo];
            operation.showsPrintPanel = NO;
            operation.showsProgressPanel = NO;
            succeeded = [operation runOperation] &&
                        [[NSFileManager defaultManager] fileExistsAtPath:pdfPath];
            if (!succeeded)
                conversionError = StructuredReportError(3, @"The structured report PDF could not be written.");
        }

        webView.navigationDelegate = nil;
        window.contentView = nil;
    };

    if ([NSThread isMainThread])
        renderPDF();
    else
        dispatch_sync(dispatch_get_main_queue(), renderPDF);

    if (!succeeded && error != NULL)
        *error = conversionError;
    return succeeded;
}

@end
