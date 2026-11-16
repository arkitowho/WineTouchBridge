/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 WineTouchBridge contributors
 * See LICENSE for the full license text.
 */

/* Tests the compiled dylib's real constructor, not an included source copy.
 * Wine classes are minimal test doubles. This verifies automatic loading and
 * compatibility detection, not hardware touch or a real Wine driver's ABI. */
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
static void check(BOOL value, const char *description)
{
    checks++;
    if (!value) { fprintf(stderr, "FAIL: %s\n", description); exit(1); }
}
@interface LoadTestController : NSObject
@end
@implementation LoadTestController
- (void)handleMouseButton:(id)event { (void)event; }
- (void)handleMouseMove:(id)event { (void)event; }
@end
@interface WineApplication : NSApplication
@property(strong) LoadTestController *wineController;
@end
@implementation WineApplication
@end
@interface WineWindow : NSWindow
@end
@implementation WineWindow
- (BOOL)isVisible { return YES; }
@end

int main(int argc, const char **argv)
{
    @autoreleasepool {
        check(argc == 2, "compiled dylib path provided");
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) fprintf(stderr, "dlopen: %s\n", dlerror());
        check(library != NULL, "compiled dylib loads through dlopen");
        void (*start)(void) = (void (*)(void))dlsym(library, "WineTouchBridgeStart");
        bool (*active)(void) = (bool (*)(void))dlsym(library, "WineTouchBridgeIsActive");
        const char *(*version)(void) = (const char *(*)(void))dlsym(library, "WineTouchBridgeVersion");
        check(start && active && version, "public C functions exported");
        check(strlen(version()) > 0, "loaded library reports version");
        check(!active(), "library does not claim Wine readiness before NSApp exists");
        [WineApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        ((WineApplication *)NSApp).wineController = [LoadTestController new];
        WineWindow *window = [[WineWindow alloc] initWithContentRect:NSMakeRect(10,10,400,300)
                              styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0,0,400,300)];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.2];
        while ((!active() || window.contentView.gestureRecognizers.count == 0) && deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        check(active(), "constructor activates on compatible Wine without calling Start");
        check(window.contentView.gestureRecognizers.count == 1, "constructor attaches exactly one touch recognizer");
        check(window.contentView.gestureRecognizers.firstObject.allowedTouchTypes == NSTouchTypeMaskDirect,
              "loaded library requests direct touches only");
        start(); start(); start();
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        check(window.contentView.gestureRecognizers.count == 1, "optional Start does not duplicate recognizers");
        /* Keep the library loaded: live recognizers/timers execute its code. */
        printf("PASS: %u compiled-dylib loading assertions; automatic activation with %s logging; mocked Wine interfaces\n",
               checks, getenv("WINE_TOUCH_BRIDGE_LOG") ? "unwritable" : "unset");
    }
    return 0;
}
