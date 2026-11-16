/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 WineTouchBridge contributors
 * See LICENSE for the full license text.
 */

/* Standalone, automatically activated XDR touch bridge for Wine.
 * Forwards single-finger input through AppKit's supported touch gesture path
 * and Wine's existing mouse handler. No global event tap, event posting,
 * pointer warp or method swizzle.
 * This is not a WM_TOUCH / WM_POINTER implementation.
 */
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <stdatomic.h>
#import "../include/WineTouchBridge.h"

static FILE *bridgeLog;
static atomic_bool startRequested = false;
static atomic_bool bridgeActive = false;
static char recognizerKey;
static id bridge;
static dispatch_source_t scanTimer;

static void writeLog(NSString *format, ...) {
    if (!bridgeLog) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(bridgeLog, "%.3f pid=%d %s\n", NSProcessInfo.processInfo.systemUptime,
            getpid(), message.UTF8String);
    fflush(bridgeLog);
}

/* A mouse NSEvent with an explicit Wine window and a Quartz event carrying
 * the touch coordinates. Wine reads both -window and CGEventGetLocation().
 * Forward other NSEvent methods, including Wine's NSEvent category methods.
 */
@interface WTDMouseEvent : NSProxy {
    NSEvent *_event;
    NSWindow *_window;
    CGEventRef _cgEvent;
}
+ (instancetype)eventForWindow:(NSWindow *)window location:(NSPoint)location
                         type:(NSEventType)type;
@end

/* Cache complete packets: AppKit can coalesce target/action delivery between
 * two state transitions. Even a very short tap must deliver both down and up.
 * Touch callbacks only track state; mouse delivery occurs in the action.
 */
@interface WTDRecognizer : NSGestureRecognizer
@property(strong) id primaryIdentity;
@property NSPoint trackedPoint;
@property(strong) NSMutableArray<NSDictionary *> *packets;
- (void)cancelTracking;
@end

@interface WTDTouchBridge : NSObject <NSGestureRecognizerDelegate>
@property(strong) WTDRecognizer *activeRecognizer;
@property(strong) NSWindow *pressedWindow;
@property(strong) id controller;
@property NSPoint lastPoint;
@property BOOL pressed;
@property(strong) NSHashTable<WTDRecognizer *> *recognizers;
- (void)scanWindows;
- (void)changed:(WTDRecognizer *)recognizer;
- (void)releasePressed:(NSString *)reason;
- (void)cancelRecognizer:(WTDRecognizer *)recognizer reason:(NSString *)reason;
@end

@implementation WTDRecognizer
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        _packets = [NSMutableArray new];
    }
    return self;
}
- (void)queue:(NSEventType)type touch:(NSTouch *)touch {
    if (touch) {
        NSPoint local = [touch locationInView:self.view];
        self.trackedPoint = [self.view convertPoint:local toView:nil];
    }
    [self.packets addObject:@{@"type": @(type), @"point": [NSValue valueWithPoint:self.trackedPoint]}];
}
- (NSTouch *)primaryInEvent:(NSEvent *)event {
    for (NSTouch *touch in [event touchesMatchingPhase:NSTouchPhaseAny inView:self.view]) {
        if ([touch.identity isEqual:self.primaryIdentity]) return touch;
    }
    return nil;
}
- (void)touchesBeganWithEvent:(NSEvent *)event {
    [super touchesBeganWithEvent:event];
    NSSet *touches = [event touchesMatchingPhase:NSTouchPhaseTouching inView:self.view];
    if (self.primaryIdentity || touches.count != 1) {
        if (self.state == NSGestureRecognizerStatePossible) {
            self.state = NSGestureRecognizerStateFailed;
            return;
        }
        [self cancelTracking];
        return;
    }
    NSTouch *touch = touches.anyObject;
    if (touch.type != NSTouchTypeDirect) { self.state = NSGestureRecognizerStateFailed; return; }
    self.primaryIdentity = touch.identity;
    [self queue:NSEventTypeLeftMouseDown touch:touch];
    self.state = NSGestureRecognizerStateBegan;
}
- (void)touchesMovedWithEvent:(NSEvent *)event {
    [super touchesMovedWithEvent:event];
    NSTouch *touch = [self primaryInEvent:event];
    if (!touch || !self.primaryIdentity) return;
    [self queue:NSEventTypeLeftMouseDragged touch:touch];
    self.state = NSGestureRecognizerStateChanged;
}
- (void)touchesEndedWithEvent:(NSEvent *)event {
    [super touchesEndedWithEvent:event];
    NSTouch *touch = [self primaryInEvent:event];
    if (!touch || touch.phase != NSTouchPhaseEnded || !self.primaryIdentity) return;
    [self queue:NSEventTypeLeftMouseUp touch:touch];
    self.primaryIdentity = nil;
    self.state = NSGestureRecognizerStateEnded;
}
- (void)touchesCancelledWithEvent:(NSEvent *)event {
    [super touchesCancelledWithEvent:event];
    [self cancelTracking];
}
- (void)cancelTracking {
    if (self.state == NSGestureRecognizerStateBegan || self.state == NSGestureRecognizerStateChanged) {
        [self queue:NSEventTypeLeftMouseUp touch:nil];
        self.primaryIdentity = nil;
        self.state = NSGestureRecognizerStateCancelled;
    } else if ((self.primaryIdentity || self.packets.count) && self.state == NSGestureRecognizerStatePossible) {
        self.state = NSGestureRecognizerStateFailed;
    }
}
- (void)reset {
    /* Also drain pending terminal packets when AppKit resets before the next
     * ordinary target/action dispatch. The action consumes each packet once. */
    if (self.packets.count) [(WTDTouchBridge *)self.target changed:self];
    WTDTouchBridge *owner = (WTDTouchBridge *)self.target;
    if (owner.activeRecognizer == self) [owner releasePressed:@"recognizer-reset"];
    [super reset];
    self.primaryIdentity = nil;
    self.trackedPoint = NSZeroPoint;
    [self.packets removeAllObjects];
}
- (NSPoint)locationInView:(NSView *)view {
    return view ? [view convertPoint:self.trackedPoint fromView:nil] : self.trackedPoint;
}
@end

@implementation WTDTouchBridge
- (void)scanWindows {
    if (self.pressed && (!self.pressedWindow.visible || !self.activeRecognizer.view.window)) {
        [self cancelRecognizer:self.activeRecognizer reason:@"window-unavailable"];
    }
    Class wineWindow = NSClassFromString(@"WineWindow");
    SEL selector = NSSelectorFromString(@"wineController");
    if (!wineWindow || !NSApp || ![NSApp respondsToSelector:selector]) return;
    id controller = ((id (*)(id, SEL))objc_msgSend)(NSApp, selector);
    if (![controller respondsToSelector:NSSelectorFromString(@"handleMouseButton:")] ||
        ![controller respondsToSelector:NSSelectorFromString(@"handleMouseMove:")]) return;
    atomic_store(&bridgeActive, true);
    if (!self.recognizers) self.recognizers = [NSHashTable weakObjectsHashTable];
    for (NSWindow *window in NSApp.windows) {
        if (![window isKindOfClass:wineWindow] || !window.visible) continue;
        NSView *view = window.contentView;
        if (!view || objc_getAssociatedObject(view, &recognizerKey)) continue;
        WTDRecognizer *recognizer = [[WTDRecognizer alloc] initWithTarget:self action:@selector(changed:)];
        recognizer.allowedTouchTypes = NSTouchTypeMaskDirect;
        recognizer.delegate = self;
        recognizer.delaysPrimaryMouseButtonEvents = NO;
        recognizer.delaysSecondaryMouseButtonEvents = NO;
        recognizer.delaysOtherMouseButtonEvents = NO;
        [view addGestureRecognizer:recognizer];
        [self.recognizers addObject:recognizer];
        objc_setAssociatedObject(view, &recognizerKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        writeLog(@"attached window=%ld view=%@ bounds=%@", (long)window.windowNumber,
                 NSStringFromClass(view.class), NSStringFromRect(view.bounds));
    }
}
- (void)windowChanged:(NSNotification *)note {
    (void)note;
    [self scanWindows];
}
- (void)cancelRecognizer:(WTDRecognizer *)recognizer reason:(NSString *)reason {
    if (!recognizer) return;
    /* Includes a Began contact whose down action has not run yet. */
    [recognizer.packets removeAllObjects];
    [recognizer cancelTracking];
    [recognizer.packets removeAllObjects];
    if (self.activeRecognizer == recognizer) [self releasePressed:reason];
}
- (void)windowUnavailable:(NSNotification *)note {
    for (WTDRecognizer *recognizer in self.recognizers.allObjects) {
        if (note.object == NSApp || note.object == recognizer.view.window)
            [self cancelRecognizer:recognizer reason:@"window-or-app-deactivated"];
    }
}
- (BOOL)gestureRecognizer:(NSGestureRecognizer *)recognizer shouldReceiveTouch:(NSTouch *)touch {
    writeLog(@"touch-received window=%ld type=%ld phase=%lu", (long)recognizer.view.window.windowNumber,
             (long)touch.type, (unsigned long)touch.phase);
    return touch.type == NSTouchTypeDirect && !(NSEvent.pressedMouseButtons & 1);
}
- (BOOL)gestureRecognizer:(NSGestureRecognizer *)recognizer
         shouldAttemptToRecognizeWithEvent:(NSEvent *)event {
    (void)recognizer; (void)event;
    return NO; /* Ordinary mouse/trackpad events retain the existing Wine path. */
}
- (BOOL)sendType:(NSEventType)type point:(NSPoint)point {
    @try {
        WTDMouseEvent *event = [WTDMouseEvent eventForWindow:self.pressedWindow location:point type:type];
        if (!event) { writeLog(@"event-construction-failed type=%lu", (unsigned long)type); return NO; }
        SEL selector = NSSelectorFromString(type == NSEventTypeLeftMouseDragged ? @"handleMouseMove:" : @"handleMouseButton:");
        ((void (*)(id, SEL, id))objc_msgSend)(self.controller, selector, event);
        self.lastPoint = point;
        writeLog(@"mouse-%@ window=%ld local=(%.1f,%.1f)",
                 type == NSEventTypeLeftMouseDown ? @"down" : type == NSEventTypeLeftMouseUp ? @"up" : @"drag",
                 (long)self.pressedWindow.windowNumber, point.x, point.y);
        return YES;
    } @catch (NSException *exception) {
        writeLog(@"mouse-dispatch-exception: %@", exception);
        return NO;
    }
}
- (void)releasePressed:(NSString *)reason {
    if (self.pressed) {
        [self sendType:NSEventTypeLeftMouseUp point:self.lastPoint];
        writeLog(@"session-release reason=%@", reason);
    }
    self.pressed = NO;
    self.pressedWindow = nil;
    self.controller = nil;
    self.activeRecognizer = nil;
}
- (void)changed:(WTDRecognizer *)recognizer {
    NSArray *packets = recognizer.packets.copy;
    [recognizer.packets removeAllObjects];
    for (NSDictionary *packet in packets) {
        NSEventType type = [packet[@"type"] unsignedIntegerValue];
        NSPoint point = [packet[@"point"] pointValue];
        if (type == NSEventTypeLeftMouseDown) {
            if (self.pressed) [self releasePressed:@"new-session"];
            NSWindow *window = recognizer.view.window;
            SEL controllerSelector = NSSelectorFromString(@"wineController");
            if (!window.visible || !NSApp.active || (NSEvent.pressedMouseButtons & 1) ||
                ![NSApp respondsToSelector:controllerSelector]) continue;
            id controller = ((id (*)(id, SEL))objc_msgSend)(NSApp, controllerSelector);
            if (![controller respondsToSelector:NSSelectorFromString(@"handleMouseButton:")] ||
                ![controller respondsToSelector:NSSelectorFromString(@"handleMouseMove:")]) {
                writeLog(@"Wine mouse handlers unavailable");
                continue;
            }
            self.activeRecognizer = recognizer;
            self.pressedWindow = window;
            self.controller = controller;
            self.pressed = YES;
            if (![self sendType:type point:point]) [self releasePressed:@"down-failed"];
        } else if (self.pressed && self.activeRecognizer == recognizer) {
            if (type == NSEventTypeLeftMouseUp) {
                self.lastPoint = point;
                [self releasePressed:@"touch-ended-or-cancelled"];
            } else if (![self sendType:type point:point]) {
                [self releasePressed:@"move-failed"];
            }
        }
    }
}
@end

const char *WineTouchBridgeVersion(void) { return "0.1.0"; }
bool WineTouchBridgeIsActive(void) { return atomic_load(&bridgeActive); }

void WineTouchBridgeStart(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&startRequested, &expected, true)) return;
    /* Logging is optional. An unset variable or an unwritable log file must
     * never prevent the bridge from activating when Wine loads this library. */
    const char *path = getenv("WINE_TOUCH_BRIDGE_LOG");
    if (path && *path) bridgeLog = fopen(path, "a");
    fprintf(stderr, "WineTouchBridge %s loaded; automatic activation scheduled\n", WineTouchBridgeVersion());
    dispatch_async(dispatch_get_main_queue(), ^{
        bridge = [WTDTouchBridge new];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification]) {
            [center addObserver:bridge selector:@selector(windowChanged:) name:name object:nil];
        }
        for (NSString *name in @[NSWindowWillCloseNotification, NSWindowDidResignKeyNotification,
                                 NSApplicationWillResignActiveNotification]) {
            [center addObserver:bridge selector:@selector(windowUnavailable:) name:name object:nil];
        }
        [bridge scanWindows];
        scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(scanTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(scanTimer, ^{ [bridge scanWindows]; });
        dispatch_resume(scanTimer);
    });
}

__attribute__((constructor)) static void startTouchDragBridge(void) {
    WineTouchBridgeStart();
}

@implementation WTDMouseEvent
+ (instancetype)eventForWindow:(NSWindow *)window location:(NSPoint)location
                         type:(NSEventType)type {
    WTDMouseEvent *proxy = [WTDMouseEvent alloc];
    proxy->_window = window;
    NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
    NSEventModifierFlags modifiers = NSEvent.modifierFlags;
    proxy->_event = [NSEvent mouseEventWithType:type
                                     location:location modifierFlags:modifiers timestamp:timestamp
                                 windowNumber:window.windowNumber context:nil eventNumber:0
                                   clickCount:1 pressure:(type == NSEventTypeLeftMouseUp ? 0.0 : 1.0)];
    NSPoint screen = [window convertPointToScreen:location];
    NSScreen *primary = NSScreen.screens.firstObject;
    if (!primary || !proxy->_event) return nil;
    /* Cocoa screen origin is lower left; Quartz is upper left. Wine performs
     * Retina scaling itself, so do not multiply these coordinates by 2. */
    CGPoint point = CGPointMake(screen.x, NSMaxY(primary.frame) - screen.y);
    proxy->_cgEvent = CGEventCreateMouseEvent(NULL,
                         type == NSEventTypeLeftMouseDown ? kCGEventLeftMouseDown :
                         type == NSEventTypeLeftMouseUp ? kCGEventLeftMouseUp : kCGEventLeftMouseDragged,
                         point, kCGMouseButtonLeft);
    if (!proxy->_cgEvent) return nil;
    CGEventSetFlags(proxy->_cgEvent, (CGEventFlags)modifiers);
    CGEventSetTimestamp(proxy->_cgEvent, (CGEventTimestamp)(timestamp * 1e9));
    return proxy;
}
- (void)dealloc {
    if (_cgEvent) CFRelease(_cgEvent);
}
- (BOOL)wine_commandKeyDown { return NO; }
- (NSWindow *)window { return _window; }
- (NSInteger)windowNumber { return _window.windowNumber; }
- (CGEventRef)CGEvent { return _cgEvent; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [_event methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:_event];
}
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [_event respondsToSelector:selector];
}
@end
