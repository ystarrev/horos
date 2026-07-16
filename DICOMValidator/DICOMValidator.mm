#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>

typedef int (*HorosValidateDICOMFileFunction)(const char*, char**);
typedef int (*HorosValidateDICOMDIRFunction)(const char*, char**);
typedef void (*HorosFreeStringFunction)(char*);

static void* LoadModernDCMTKBridge(const char* executablePath)
{
    NSString* executable = [NSString stringWithUTF8String:executablePath != nullptr ? executablePath : ""];
    NSString* executableDirectory = executable.stringByStandardizingPath.stringByDeletingLastPathComponent;
    NSArray<NSString*>* candidates = @[
        [executableDirectory stringByAppendingPathComponent:@"libHorosModernDCMTKBridge.dylib"],
        [executableDirectory stringByAppendingPathComponent:@"DCMTK/libHorosModernDCMTKBridge.dylib"],
        [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"libHorosModernDCMTKBridge.dylib"]
    ];

    for (NSString* candidate in candidates)
    {
        if (![[NSFileManager defaultManager] fileExistsAtPath:candidate])
            continue;

        void* handle = dlopen(candidate.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (handle != nullptr)
            return handle;

        fprintf(stderr, "DICOMValidator: failed to load %s: %s\n",
                candidate.fileSystemRepresentation,
                dlerror());
    }

    return nullptr;
}

static int ValidateFiles(int argc,
                         const char* argv[],
                         HorosValidateDICOMFileFunction validate,
                         HorosFreeStringFunction freeString)
{
    int result = EXIT_SUCCESS;
    for (int index = 2; index < argc; ++index)
    {
        char* failureReason = nullptr;
        if (!validate(argv[index], &failureReason))
        {
            fprintf(stderr, "DICOMValidator: %s: %s\n",
                    argv[index],
                    failureReason != nullptr ? failureReason : "validation failed");
            result = EXIT_FAILURE;
        }
        if (failureReason != nullptr && freeString != nullptr)
            freeString(failureReason);
    }
    return result;
}

int main(int argc, const char* argv[])
{
    @autoreleasepool
    {
        if (argc < 3)
        {
            fprintf(stderr, "Usage: DICOMValidator --files <path> [...] | --dicomdir <path>\n");
            return EXIT_FAILURE;
        }

        void* bridge = LoadModernDCMTKBridge(argv[0]);
        if (bridge == nullptr)
        {
            fprintf(stderr, "DICOMValidator: modern DCMTK bridge was not found\n");
            return EXIT_FAILURE;
        }

        HorosFreeStringFunction freeString =
            reinterpret_cast<HorosFreeStringFunction>(dlsym(bridge, "HorosModernDCMTKFreeString"));

        int result = EXIT_FAILURE;
        if (std::strcmp(argv[1], "--files") == 0)
        {
            HorosValidateDICOMFileFunction validate =
                reinterpret_cast<HorosValidateDICOMFileFunction>(dlsym(bridge, "HorosModernDCMTKValidateDICOMFile"));
            if (validate != nullptr)
                result = ValidateFiles(argc, argv, validate, freeString);
            else
                fprintf(stderr, "DICOMValidator: file-validation API is unavailable\n");
        }
        else if (std::strcmp(argv[1], "--dicomdir") == 0 && argc == 3)
        {
            HorosValidateDICOMDIRFunction validate =
                reinterpret_cast<HorosValidateDICOMDIRFunction>(dlsym(bridge, "HorosModernDCMTKValidateDICOMDIR"));
            if (validate != nullptr)
            {
                char* failureReason = nullptr;
                if (validate(argv[2], &failureReason))
                    result = EXIT_SUCCESS;
                else
                    fprintf(stderr, "DICOMValidator: %s: %s\n",
                            argv[2],
                            failureReason != nullptr ? failureReason : "validation failed");
                if (failureReason != nullptr && freeString != nullptr)
                    freeString(failureReason);
            }
            else
                fprintf(stderr, "DICOMValidator: DICOMDIR-validation API is unavailable\n");
        }
        else
            fprintf(stderr, "DICOMValidator: invalid arguments\n");

        dlclose(bridge);
        return result;
    }
}
