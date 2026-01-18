# Fix memory leaks when tabs/windows are closed

## Summary

Fix multiple memory leaks that can cause significant RAM accumulation over extended use.

## Motivation

A user reported memory issues after extended use (39.6GB RAM after 47 hours), with evidence of:
- 69,523 leaked allocations of 592KB each (VM_ALLOCATE regions)
- Orphaned child processes from closed tabs

The 592KB size matches `std_size` in `src/terminal/PageList.zig` - the terminal page buffer.

## Root Causes Found

### 1. Missing NotificationCenter cleanup in TerminalViewContainer (CRITICAL)
**File:** `TerminalViewContainer.swift`

The class adds a NotificationCenter observer but had **no deinit** to remove it. NotificationCenter holds strong references to observers, preventing the entire view hierarchy from being deallocated.

### 2. Missing timer invalidation in SurfaceView
**File:** `SurfaceView_AppKit.swift`

`titleChangeTimer` was not invalidated in deinit (only `progressReportTimer` was). Timers hold strong references to their targets.

### 3. No explicit surface cleanup when undo expires
**Files:** `BaseTerminalController.swift`, `TerminalController.swift`

When tabs/windows are closed, surfaces are captured in undo closures. If undo expires without being executed, there was no explicit cleanup - it relied solely on ARC/deinit which may not trigger if other references exist.

### 4. Combine cancellables not cleared on window close
**Files:** `BaseTerminalController.swift`, `TerminalController.swift`

`focusedSurfaceCancellables` and `surfaceAppearanceCancellables` weren't explicitly cleared in `windowWillClose`, potentially holding references to surfaces.

## The Fixes

### 1. Add deinit to TerminalViewContainer
```swift
deinit {
    NotificationCenter.default.removeObserver(self)
}
```

### 2. Add titleChangeTimer invalidation to SurfaceView deinit
```swift
// Cancel timers
progressReportTimer?.invalidate()
titleChangeTimer?.invalidate()  // NEW
```

### 3. Add explicit `close()` method to `Ghostty.Surface`
Provides immediate cleanup that doesn't rely on deinit:
```swift
func close() {
    closeIfNeeded()  // calls ghostty_surface_free synchronously
}
```

### 4. Add `onExpire` callback to `ExpiringUndoManager`
```swift
func registerUndo<TargetType: AnyObject>(
    withTarget target: TargetType,
    expiresAfter duration: Duration,
    onExpire: (() -> Void)?,  // NEW - called when undo expires without execution
    handler: @escaping (TargetType) -> Void
)
```

### 5. Update all undo registrations that capture surfaces
Added `onExpire` callbacks to:
- `BaseTerminalController.replaceSurfaceTree()` - for split operations
- `TerminalController.closeTabImmediately()` - for tab close
- `TerminalController.registerUndoForCloseWindow()` - for window close

### 6. Clear Combine cancellables on window close
```swift
func windowWillClose(_ notification: Notification) {
    focusedSurfaceCancellables.removeAll()  // NEW
    surfaceAppearanceCancellables.removeAll()  // NEW
    // ...
}
```

## Testing Results

**Stress test: 30 rapid create/close cycles**

| Metric | Result |
|--------|--------|
| Orphaned processes | +0 |
| Memory growth | ~40MB |
| VM region growth | +5 |

Note: Tests require `confirm-close-surface = false` in config.

## Files Changed

- `macos/Sources/Ghostty/Ghostty.Surface.swift` - Add `close()` method
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` - Add `close()` delegation, fix timer cleanup
- `macos/Sources/Helpers/ExpiringUndoManager.swift` - Add `onExpire` callback
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` - Use `onExpire`, clear cancellables
- `macos/Sources/Features/Terminal/TerminalController.swift` - Use `onExpire`, clear cancellables
- `macos/Sources/Features/Terminal/TerminalViewContainer.swift` - Add deinit for NotificationCenter cleanup

## Why These Fixes Are Correct

1. **Explicit > Implicit** - Doesn't rely on ARC/deinit timing
2. **Guaranteed cleanup** - `onExpire` is always called when undo expires
3. **Idempotent** - `close()` can be called multiple times safely
4. **Thread-safe** - Uses `OSAllocatedUnfairLock` for `isClosed` state
5. **Backwards compatible** - `deinit` still calls cleanup as fallback
6. **Complete coverage** - Fixes NotificationCenter, timers, Combine, and undo system

## Testing

```bash
# Build
zig build

# Automated stress test (requires confirm-close-surface = false)
./stress-test-cleanup.sh /path/to/Ghostty.app 30

# Manual test
1. Open Ghostty
2. Create splits (Cmd+D, Cmd+Shift+D)
3. Close tab (Cmd+Option+W)
4. Wait 5+ seconds (undo timeout)
5. Verify with: pgrep -P $(pgrep -x ghostty)
   - Should show only processes for remaining tabs
```
