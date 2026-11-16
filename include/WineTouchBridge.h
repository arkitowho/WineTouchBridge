/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 WineTouchBridge contributors
 * See LICENSE for the full license text.
 */

#ifndef WINE_TOUCH_BRIDGE_H
#define WINE_TOUCH_BRIDGE_H
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Forwards XDR touch input exposed through AppKit to Wine mouse handlers.
 * Loading the dylib starts it automatically. Calling Start is optional and
 * idempotent. IsActive becomes true once compatible Wine handlers are ready;
 * it does not indicate hardware touch capability or application acceptance. */
__attribute__((visibility("default"))) void WineTouchBridgeStart(void);
__attribute__((visibility("default"))) bool WineTouchBridgeIsActive(void);
__attribute__((visibility("default"))) const char *WineTouchBridgeVersion(void);

#ifdef __cplusplus
}
#endif
#endif
