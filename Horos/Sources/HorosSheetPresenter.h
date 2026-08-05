#pragma once

#import <AppKit/AppKit.h>
#import <objc/message.h>

typedef void (*HorosSheetDidEndIMP)(id, SEL, NSWindow *, NSInteger, void *);

NS_INLINE void HorosBeginSheet(NSWindow *sheet,
                               NSWindow *parentWindow,
                               id delegate,
                               SEL didEndSelector,
                               void *contextInfo)
{
    if (sheet == nil)
        return;

    void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
        if (delegate && didEndSelector && [delegate respondsToSelector:didEndSelector])
            ((HorosSheetDidEndIMP)objc_msgSend)(delegate, didEndSelector, sheet, response, contextInfo);
    };

    if (parentWindow)
        [parentWindow beginSheet:sheet completionHandler:completion];
    else {
        NSModalResponse response = [NSApp runModalForWindow:sheet];
        [sheet orderOut:nil];
        completion(response);
    }
}

NS_INLINE void HorosEndSheetWithReturnCode(NSWindow *sheet, NSModalResponse returnCode)
{
    if (sheet == nil)
        return;

    NSWindow *parentWindow = sheet.sheetParent;
    if (parentWindow)
        [parentWindow endSheet:sheet returnCode:returnCode];
    else {
        if (NSApp.modalWindow == sheet)
            [NSApp stopModalWithCode:returnCode];
        [sheet orderOut:nil];
    }
}

NS_INLINE void HorosEndSheet(NSWindow *sheet)
{
    HorosEndSheetWithReturnCode(sheet, NSModalResponseStop);
}
