#import "HorosDCMTKBridgeLoader.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>

static void *HorosDCMTKBridgeHandle(void)
{
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = NSBundle.mainBundle;
        NSArray<NSString *> *basePaths = @[
            bundle.resourcePath ?: @"",
            bundle.privateFrameworksPath ?: @"",
            bundle.sharedFrameworksPath ?: @"",
            bundle.builtInPlugInsPath ?: @""
        ];
        NSArray<NSString *> *relativePaths = @[
            @"libHorosModernDCMTKBridge.dylib",
            @"DCMTK/libHorosModernDCMTKBridge.dylib"
        ];

        for (NSString *basePath in basePaths)
        {
            if (basePath.length == 0)
                continue;
            for (NSString *relativePath in relativePaths)
            {
                NSString *candidate = [basePath stringByAppendingPathComponent:relativePath];
                if (![NSFileManager.defaultManager fileExistsAtPath:candidate])
                    continue;

                handle = dlopen(candidate.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
                if (handle == NULL)
                    NSLog(@"DCMTK bridge failed to load at %@: %s", candidate, dlerror());
                return;
            }
        }

        // Retain the existing dyld lookup for command-line and test hosts.
        handle = dlopen("libHorosModernDCMTKBridge.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (handle == NULL)
            NSLog(@"DCMTK bridge unavailable: %s", dlerror());
    });
    return handle;
}

void *HorosDCMTKBridgeSymbol(const char *name)
{
    if (name == NULL || name[0] == '\0')
        return NULL;
    void *handle = HorosDCMTKBridgeHandle();
    return handle != NULL ? dlsym(handle, name) : NULL;
}
