#pragma once

#import "HorosSwiftInterop.h"
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>

/// Semantic button responses used by the Objective-C call sites while alert
/// construction and presentation live in HorosAlertPresenter.swift.
typedef NS_ENUM(NSInteger, HorosAlertResponse) {
    HorosAlertResponseFirstButton = 1,
    HorosAlertResponseSecondButton = 0,
    HorosAlertResponseThirdButton = -1
};

NS_INLINE NSString *HorosAlertFormattedMessage(NSString *format, va_list arguments)
{
    if (format.length == 0)
        return @"";

    CFStringRef message = CFStringCreateWithFormatAndArguments(
        kCFAllocatorDefault, nil, (__bridge CFStringRef)format, arguments);
    NSString *result = [NSString stringWithString:(__bridge NSString *)message];
    CFRelease(message);
    return result;
}

NS_INLINE HorosAlertResponse HorosAlertResponseFromModalResponse(NSModalResponse response)
{
    if (response == NSAlertSecondButtonReturn)
        return HorosAlertResponseSecondButton;
    if (response == NSAlertThirdButtonReturn)
        return HorosAlertResponseThirdButton;
    return HorosAlertResponseFirstButton;
}

NS_INLINE HorosAlertResponse HorosPresentAlertWithStyle(
    NSAlertStyle style,
    NSString *title,
    NSString *messageFormat,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    va_list arguments)
{
    NSString *message = HorosAlertFormattedMessage(messageFormat, arguments);
    NSModalResponse response = [HorosAlertPresenter
        runWithTitle:title ?: @""
        message:message
        style:style
        firstButton:firstButton.length ? firstButton : NSLocalizedString(@"OK", nil)
        secondButton:secondButton
        thirdButton:thirdButton];
    return HorosAlertResponseFromModalResponse(response);
}

NS_INLINE HorosAlertResponse HorosPresentAlert(
    NSString *title,
    NSString *messageFormat,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    ...) NS_FORMAT_FUNCTION(2, 6);

NS_INLINE HorosAlertResponse HorosPresentAlert(
    NSString *title,
    NSString *messageFormat,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    ...)
{
    va_list arguments;
    va_start(arguments, thirdButton);
    HorosAlertResponse response = HorosPresentAlertWithStyle(
        NSAlertStyleWarning, title, messageFormat, firstButton, secondButton,
        thirdButton, arguments);
    va_end(arguments);
    return response;
}

NS_INLINE HorosAlertResponse HorosPresentCriticalAlert(
    NSString *title,
    NSString *messageFormat,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    ...) NS_FORMAT_FUNCTION(2, 6);

NS_INLINE HorosAlertResponse HorosPresentCriticalAlert(
    NSString *title,
    NSString *messageFormat,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    ...)
{
    va_list arguments;
    va_start(arguments, thirdButton);
    HorosAlertResponse response = HorosPresentAlertWithStyle(
        NSAlertStyleCritical, title, messageFormat, firstButton, secondButton,
        thirdButton, arguments);
    va_end(arguments);
    return response;
}

NS_INLINE HorosAlertResponse HorosPresentInformationalAlert(
    NSString *title,
    NSString *messageFormat,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    ...) NS_FORMAT_FUNCTION(2, 6);

NS_INLINE HorosAlertResponse HorosPresentInformationalAlert(
    NSString *title,
    NSString *messageFormat,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    ...)
{
    va_list arguments;
    va_start(arguments, thirdButton);
    HorosAlertResponse response = HorosPresentAlertWithStyle(
        NSAlertStyleInformational, title, messageFormat, firstButton,
        secondButton, thirdButton, arguments);
    va_end(arguments);
    return response;
}

typedef void (*HorosAlertSheetDelegateIMP)(id, SEL, NSWindow *, NSInteger, void *);

NS_INLINE void HorosInvokeAlertSheetDelegate(
    id delegate,
    SEL selector,
    NSWindow *sheet,
    HorosAlertResponse response,
    void *contextInfo)
{
    if (delegate && selector && [delegate respondsToSelector:selector])
        ((HorosAlertSheetDelegateIMP)objc_msgSend)(delegate, selector, sheet,
                                                   response, contextInfo);
}

NS_INLINE void HorosBeginAlertSheetWithStyle(
    NSAlertStyle style,
    NSString *title,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    NSWindow *window,
    id delegate,
    SEL didEndSelector,
    SEL didDismissSelector,
    void *contextInfo,
    NSString *messageFormat,
    va_list arguments)
{
    NSString *message = HorosAlertFormattedMessage(messageFormat, arguments);
    NSString *resolvedFirstButton = firstButton.length ? firstButton : NSLocalizedString(@"OK", nil);

    if (window == nil) {
        NSModalResponse modalResponse = [HorosAlertPresenter
            runWithTitle:title ?: @""
            message:message
            style:style
            firstButton:resolvedFirstButton
            secondButton:secondButton
            thirdButton:thirdButton];
        HorosAlertResponse response = HorosAlertResponseFromModalResponse(modalResponse);
        HorosInvokeAlertSheetDelegate(delegate, didEndSelector, nil, response, contextInfo);
        HorosInvokeAlertSheetDelegate(delegate, didDismissSelector, nil, response, contextInfo);
        return;
    }

    [HorosAlertPresenter
        beginSheetForWindow:window
        title:title ?: @""
        message:message
        style:style
        firstButton:resolvedFirstButton
        secondButton:secondButton
        thirdButton:thirdButton
        completion:^(NSModalResponse modalResponse) {
            HorosAlertResponse response = HorosAlertResponseFromModalResponse(modalResponse);
            HorosInvokeAlertSheetDelegate(delegate, didEndSelector, nil, response, contextInfo);
            HorosInvokeAlertSheetDelegate(delegate, didDismissSelector, nil, response, contextInfo);
        }];
}

NS_INLINE void HorosBeginAlertSheet(
    NSString *title,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    NSWindow *window,
    id delegate,
    SEL didEndSelector,
    SEL didDismissSelector,
    void *contextInfo,
    NSString *messageFormat,
    ...) NS_FORMAT_FUNCTION(10, 11);

NS_INLINE void HorosBeginAlertSheet(
    NSString *title,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    NSWindow *window,
    id delegate,
    SEL didEndSelector,
    SEL didDismissSelector,
    void *contextInfo,
    NSString *messageFormat,
    ...)
{
    va_list arguments;
    va_start(arguments, messageFormat);
    HorosBeginAlertSheetWithStyle(
        NSAlertStyleWarning, title, firstButton, secondButton, thirdButton,
        window, delegate, didEndSelector, didDismissSelector, contextInfo,
        messageFormat, arguments);
    va_end(arguments);
}

NS_INLINE void HorosBeginInformationalAlertSheet(
    NSString *title,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    NSWindow *window,
    id delegate,
    SEL didEndSelector,
    SEL didDismissSelector,
    void *contextInfo,
    NSString *messageFormat,
    ...) NS_FORMAT_FUNCTION(10, 11);

NS_INLINE void HorosBeginInformationalAlertSheet(
    NSString *title,
    NSString *firstButton,
    NSString *secondButton,
    NSString *thirdButton,
    NSWindow *window,
    id delegate,
    SEL didEndSelector,
    SEL didDismissSelector,
    void *contextInfo,
    NSString *messageFormat,
    ...)
{
    va_list arguments;
    va_start(arguments, messageFormat);
    HorosBeginAlertSheetWithStyle(
        NSAlertStyleInformational, title, firstButton, secondButton,
        thirdButton, window, delegate, didEndSelector, didDismissSelector,
        contextInfo, messageFormat, arguments);
    va_end(arguments);
}
