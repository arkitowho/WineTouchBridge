/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 WineTouchBridge contributors
 * See LICENSE for the full license text.
 */

/* Standalone bridge tests use the production bridge source and real AppKit
 * coordinate transforms. Wine, touch input and the gesture state scheduler are
 * test doubles. These tests do not simulate hardware touch arbitration or
 * validate a particular Wine binary's private Objective-C ABI. */
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>
#import "../src/WineTouchBridge.m"

static NSMutableArray<NSDictionary *> *received;
static unsigned checks;
static void check(BOOL value, const char *description)
{
    checks++;
    if (!value) { fprintf(stderr, "FAIL: %s\n", description); exit(1); }
}

@interface MockWineController : NSObject
@end
@implementation MockWineController
- (void)record:(id)event {
    check([event window] != nil, "proxy carries its Wine window");
    check([event CGEvent] != NULL, "proxy carries a Quartz event");
    CGPoint point = CGEventGetLocation([event CGEvent]);
    [received addObject:@{@"type": @([(NSEvent *)event type]),
                         @"point": [NSValue valueWithPoint:[event locationInWindow]],
                         @"quartz": [NSValue valueWithPoint:NSPointFromCGPoint(point)]}];
}
- (void)handleMouseButton:(id)event { [self record:event]; }
- (void)handleMouseMove:(id)event { [self record:event]; }
@end

@interface WineApplication : NSApplication
@property(strong) MockWineController *wineController;
@end
@implementation WineApplication
- (BOOL)isActive { return YES; }
@end

@interface WineWindow : NSWindow
@end
@implementation WineWindow
- (BOOL)isVisible { return YES; }
@end

@interface TestTouch : NSObject
@property(strong) id identity;
@property NSTouchPhase phase;
@property NSTouchType type;
@property NSPoint point;
@end
@implementation TestTouch
- (NSPoint)locationInView:(NSView *)view { return self.point; }
@end

@interface TestTouchEvent : NSEvent
@property(strong) NSArray<TestTouch *> *contacts;
@property NSTimeInterval clock;
@end
@implementation TestTouchEvent
- (NSEventType)type { return NSEventTypeDirectTouch; }
- (NSTimeInterval)timestamp { return self.clock; }
- (NSSet *)touchesMatchingPhase:(NSTouchPhase)phase inView:(NSView *)view {
    NSMutableSet *result = [NSMutableSet set];
    for (TestTouch *touch in self.contacts) if (touch.phase & phase) [result addObject:touch];
    return result;
}
@end

@interface FlippedTestView : NSView
@end
@implementation FlippedTestView
- (BOOL)isFlipped { return YES; }
@end

/* AppKit normally changes state only for a real event-arena touch sequence.
 * Substitute only its scheduler for direct invocation of production methods. */
@interface ExercisedRecognizer : WTDRecognizer
@property NSGestureRecognizerState testState;
@end
@implementation ExercisedRecognizer
- (NSGestureRecognizerState)state { return self.testState; }
- (void)setState:(NSGestureRecognizerState)state { self.testState = state; }
- (void)reset { [super reset]; self.testState = NSGestureRecognizerStatePossible; }
@end

static TestTouch *touch(NSString *identity, NSTouchPhase phase, NSPoint point)
{
    TestTouch *result = [TestTouch new];
    result.identity = identity; result.phase = phase; result.type = NSTouchTypeDirect; result.point = point;
    return result;
}
static TestTouchEvent *event(NSArray *contacts)
{
    TestTouchEvent *result = [TestTouchEvent new];
    result.contacts = contacts; result.clock = NSProcessInfo.processInfo.systemUptime; return result;
}
static WTDRecognizer *recognizer(NSView *view, WTDTouchBridge *owner)
{
    [received removeAllObjects];
    for (NSGestureRecognizer *old in view.gestureRecognizers.copy) [view removeGestureRecognizer:old];
    ExercisedRecognizer *result = [[ExercisedRecognizer alloc] initWithTarget:owner action:@selector(changed:)];
    [view addGestureRecognizer:result];
    if (!owner.recognizers) owner.recognizers = [NSHashTable weakObjectsHashTable];
    [owner.recognizers addObject:result];
    return result;
}
static void types(NSArray *expected, const char *description)
{
    check([[received valueForKey:@"type"] isEqualToArray:expected], description);
}

int main(void)
{
    @autoreleasepool {
        check(getenv("WINE_TOUCH_BRIDGE_LOG") == NULL, "optional bridge log env is absent");
        [WineApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        received = [NSMutableArray new];
        ((WineApplication *)NSApp).wineController = [MockWineController new];
        WineWindow *window = [[WineWindow alloc] initWithContentRect:NSMakeRect(10, 10, 400, 300)
                              styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        FlippedTestView *view = [[FlippedTestView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
        window.contentView = view;
        /* The library constructor must auto-start without a CLI flag/log path.
         * Pump once to run its scheduled main-queue initialization and scan. */
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
        while (view.gestureRecognizers.count == 0 && deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        check(view.gestureRecognizers.count == 1, "load automatically attaches with no enable/log environment");
        check([view.gestureRecognizers.firstObject isKindOfClass:[WTDRecognizer class]], "automatic attachment uses production recognizer");
        check(WineTouchBridgeIsActive(), "readiness API reports compatible Wine interfaces");
        check(strlen(WineTouchBridgeVersion()) > 0, "version API provides a nonempty version");
        WineTouchBridgeStart(); WineTouchBridgeStart();
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        check(view.gestureRecognizers.count == 1, "optional Start calls are idempotent");

        WTDTouchBridge *owner = [WTDTouchBridge new];
        WTDRecognizer *r = recognizer(view, owner);
        TestTouch *a = touch(@"a", NSTouchPhaseBegan, NSMakePoint(35, 45));
        check([owner gestureRecognizer:r shouldReceiveTouch:(NSTouch *)a], "direct touch accepted");
        a.type = NSTouchTypeIndirect;
        check(![owner gestureRecognizer:r shouldReceiveTouch:(NSTouch *)a], "indirect trackpad input excluded");
        a.type = NSTouchTypeDirect;
        check(![owner gestureRecognizer:r shouldAttemptToRecognizeWithEvent:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
            location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1]], "ordinary pointer input excluded");
        [r touchesBeganWithEvent:event(@[a])];
        check(r.state == NSGestureRecognizerStateBegan, "one contact begins immediately");
        check(received.count == 0, "event callbacks cache input before action delivery");
        check(NSEqualPoints([r locationInView:nil], NSMakePoint(35, 255)), "flipped view maps to window coordinates");
        check(NSEqualPoints([r locationInView:view], a.point), "recognizer maps back to flipped view");
        a.phase = NSTouchPhaseEnded;
        [r touchesEndedWithEvent:event(@[a])]; [owner changed:r];
        types(@[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)], "coalesced quick tap preserves complete button sequence");
        [r reset]; [r reset];
        types(@[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)], "terminal reset does not duplicate release");

        r = recognizer(view, owner); a.phase = NSTouchPhaseBegan;
        [r touchesBeganWithEvent:event(@[a])]; [owner changed:r];
        a = touch(@"a", NSTouchPhaseMoved, NSMakePoint(80, 90));
        [r touchesMovedWithEvent:event(@[a])]; [owner changed:r];
        a.phase = NSTouchPhaseEnded; [r touchesEndedWithEvent:event(@[a])]; [owner changed:r];
        types(@[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseDragged), @(NSEventTypeLeftMouseUp)], "drag and replacement touch object retain contact identity");
        check(NSEqualPoints([received[1][@"point"] pointValue], [view convertPoint:a.point toView:nil]), "drag forwards latest finger position");
        [r reset];

        r = recognizer(view, owner); a.phase = NSTouchPhaseBegan;
        [r touchesBeganWithEvent:event(@[a])]; [owner changed:r];
        a.phase = NSTouchPhaseCancelled; [r touchesCancelledWithEvent:event(@[a])];
        check(r.state == NSGestureRecognizerStateCancelled, "system cancellation reaches terminal state");
        [owner changed:r]; [r reset];
        types(@[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)], "system cancellation releases once");

        r = recognizer(view, owner); a.phase = NSTouchPhaseBegan;
        [r touchesBeganWithEvent:event(@[a])]; [owner changed:r];
        a.phase = NSTouchPhaseStationary;
        TestTouch *b = touch(@"b", NSTouchPhaseBegan, NSMakePoint(120, 100));
        [r touchesBeganWithEvent:event(@[a,b])]; [owner changed:r]; [r reset];
        types(@[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)], "second contact cancels rather than moving the primary pointer");

        r = recognizer(view, owner); a.phase = NSTouchPhaseBegan;
        [r touchesBeganWithEvent:event(@[a])]; a.phase = NSTouchPhaseEnded;
        [r touchesEndedWithEvent:event(@[a])]; [r reset];
        types(@[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)], "reset drains complete quick tap before deferred action");
        [r reset]; check(received.count == 2, "second reset cannot replay drained packets");

        r = recognizer(view, owner); a.phase = NSTouchPhaseBegan;
        [r touchesBeganWithEvent:event(@[a])]; [owner changed:r];
        TestTouch *foreign = touch(@"foreign", NSTouchPhaseMoved, NSMakePoint(200, 200));
        [r touchesMovedWithEvent:event(@[foreign])]; foreign.phase = NSTouchPhaseEnded;
        [r touchesEndedWithEvent:event(@[foreign])]; [owner changed:r];
        check(received.count == 1, "foreign identity cannot move or release primary contact");
        [r reset];
        types(@[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)], "reset releases unterminated pointer press");

        r = recognizer(view, owner); a.phase = NSTouchPhaseBegan;
        [r touchesBeganWithEvent:event(@[a])];
        [owner windowUnavailable:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:window]];
        [owner changed:r]; [r reset];
        check(received.count == 0, "window loss cancels a press still waiting for action delivery");

        r = recognizer(view, owner); a.phase = NSTouchPhaseBegan;
        [r touchesBeganWithEvent:event(@[a])]; [owner changed:r];
        [owner windowUnavailable:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:window]];
        [owner changed:r]; [r reset];
        types(@[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)], "window loss releases a delivered press once");

        r = recognizer(view, owner); a.phase = NSTouchPhaseBegan;
        [r touchesBeganWithEvent:event(@[a])];
        [owner windowUnavailable:[NSNotification notificationWithName:NSApplicationWillResignActiveNotification object:NSApp]];
        [owner changed:r]; [r reset];
        check(received.count == 0, "application loss cancels pending press without replay on reset");

        /* Explicitly check that constructing the NSEvent/CGEvent proxy preserves
         * the window, type and coordinate conversion without global posting. */
        WTDMouseEvent *proxy = [WTDMouseEvent eventForWindow:window location:NSMakePoint(35,255) type:NSEventTypeLeftMouseDragged];
        check([proxy window] == window, "proxy window identity preserved");
        check([(NSEvent *)proxy type] == NSEventTypeLeftMouseDragged, "proxy forwards event type");
        NSPoint screen = [window convertPointToScreen:NSMakePoint(35,255)];
        CGPoint quartz = CGEventGetLocation(proxy.CGEvent);
        check(quartz.x == screen.x && quartz.y == NSMaxY(NSScreen.screens.firstObject.frame) - screen.y,
              "screen-to-Quartz conversion does not apply duplicate Retina scale");
        printf("PASS: %u assertions; automatic initialization, production recognizer/actions, real AppKit transforms; mocked Wine/input/state scheduler\n", checks);
    }
    return 0;
}
