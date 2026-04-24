# Vendored xterm.dart — local patches

Forked from upstream `xterm` **4.0.0** (pub.dev, published 2024).

This is a local vendor copy so we can patch bugs and extend behaviour we
hit in andssh. Every local change MUST be recorded here; otherwise a
future upstream-rebase will silently clobber it.

When rebasing onto a newer upstream release:

1. Download the new upstream tarball into a scratch dir.
2. Apply each entry below (reading the diff against the pristine 4.0.0
   tree, not against this directory).
3. Update the "Forked from" line at the top of this file.
4. Run `flutter analyze && flutter build apk --debug` at the repo root.

## Patches

### P12 — `RenderTerminal.autoResize` is a runtime toggle, not just an initial flag (`lib/src/ui/render.dart`)

Added a public `autoResize` getter and made the existing setter flush a pending resize on flip-to-true: while `autoResize` is false, `_resizeTerminalIfNeeded` short-circuits so `terminal.resize` — and therefore `Buffer.resize`'s reflow, which detaches every cell anchor — cannot run. When it flips back to true we call `_resizeTerminalIfNeeded` once to apply whatever viewport size the paused layouts computed.

Why: the P8/P11 freeze holds SSH stdout, but a layout change in the host app (soft-keyboard animation settling, rotation, split-screen resize) still runs `RenderTerminal.performLayout`, which still calls `_updateViewportSize` → `_resizeTerminalIfNeeded` → `terminal.resize` — which reflows the buffer and detaches the anchors `selectWord` just created. The visible symptom was a long-press succeeding, the selection appearing for a frame, then vanishing as the keyboard animation crossed a cell boundary. andssh's `ActiveSession.freeze` / `unfreeze` now flip this gate so a selection is safe across layout changes.

### P11 — Fix aliasing bug in `IndexAwareCircularBuffer._adoptChild` (`lib/src/utils/circular_buffer.dart`)

`Buffer.scrollDown` and `scrollUp` move lines within the buffer by assigning `this.lines[i] = this.lines[i - n]`. That reassignment goes through `_adoptChild`, which detaches whatever was at `[i]` and stores the source line there — but it *doesn't* clear the source slot `[i - n]`. The same `BufferLine` instance is now referenced from two array positions. A later iteration of the caller's loop then assigns something new to `[i - n]`, and `_adoptChild` there calls `_detach()` on the shared line — which nulls its `_owner` while it is still referenced at `[i]`.

From then on, `lines[i]` returns a line object whose `attached` getter is `false`. Any anchor created with `lines[i].createAnchor(x)` is born detached, and `TerminalController.selection` returns `null` because its getter requires `base.attached && extent.attached`. Visible symptom in andssh: long-press in tmux (alt-buffer) after the keyboard has been toggled silently fails to produce a selection, because tmux's `SIGWINCH`-triggered redraw after the resize runs scroll operations that leave the buffer full of zombie lines.

Fixed `_adoptChild` to detect when the incoming `child` is already attached to this same buffer at a different index, and null out that stale slot before attaching the child at the destination — preventing the double-reference that the later `_detach` relies on.

### P10 — `suppressNextTapMouseEvent` + always fire tap-up callback (`lib/src/ui/controller.dart`, `lib/src/ui/gesture/gesture_handler.dart`)

Two small changes to fix two tmux-specific bugs that surfaced after P9:

1. **Dismiss-tap poked tmux with a click.** When the user taps to dismiss our frozen selection overlay, the same tap-up still ran `_tapUp`'s paired mouse-down+up — which in mouse-reporting mode reaches tmux as a real click, often moving the cursor or entering tmux's own copy mode and leaving the next long-press operating against stale state. Added a one-shot `TerminalController.suppressNextTapMouseEvent` flag that `_tapUp` consumes before emitting the mouse event. andssh sets it in `_dismissSelection`.

2. **Tap could not reopen the soft keyboard in mouse-reporting mode.** Upstream's `_tapUp` gated the callback on `!handled`, and `handled=true` whenever mouse-reporting consumed the click — so `_onSingleTapUp`'s `requestKeyboard()` never ran in tmux. Once the user closed the keyboard it couldn't be reopened by tapping the terminal. `_tapUp` now always invokes the callback; `requestKeyboard()` is idempotent, so taps that simply maintain focus are harmless.

### P9 — Defer mouse-button-down to tap-up (`lib/src/ui/gesture/gesture_handler.dart`)

Upstream's `_tapDown` sent an SGR mouse button-press to the remote program immediately on every pointer-down — including at the start of a gesture that would become a long-press. In mouse-aware apps (tmux with mouse mode, less, vim) that's a real click: they start scrolling, entering copy mode, or repositioning the cursor. By the time the long-press fires and `selectWord` runs, the buffer has already been modified, so the word the user targeted is gone (or has moved rows).

Moved the mouse-button event emission to `_tapUp`, where we now send a paired down+up sequence so the remote still sees a complete click on a real tap. Long-presses send no mouse events at all — tmux's buffer stays static until P8's `session.freeze()` takes over.

### P8 — `onLongPressStart` callback for freeze-before-select (`lib/src/ui/gesture/gesture_handler.dart`, `lib/src/terminal_view.dart`)

Added `onLongPressStart` callback (with `CellOffset`) to `TerminalGestureHandler` and `TerminalView`. It fires at the moment a long-press is recognised, before P3's `onLongPressMoveUpdate` calls `selectWord`. andssh calls `session.freeze()` here to pause SSH stdout/stderr; the terminal buffer is therefore static when xterm builds its `CellAnchor` selection objects, preventing tmux redraws from detaching them mid-gesture.

### P7 — Open the IME on tap-up, not tap-down (`lib/src/terminal_view.dart`)

Upstream's `_onTapDown` called `CustomTextEdit.requestKeyboard()`
immediately on every pointer-down. That made the soft keyboard flash
into view at the start of every long-press gesture (it opens, then the
long-press wins the arena and the consumer tears the view down →
keyboard closes again — visible flicker to the user).

Moved the keyboard-request logic to a new `_onSingleTapUp` method and
wired it through `TerminalGestureHandler.onSingleTapUp`. Only real tap
gestures now open the IME; long-press and drag leave it alone.

### P6 — `suppressInternalSelectionGestures` flag (`lib/src/ui/gesture/gesture_handler.dart`, `lib/src/terminal_view.dart`)

When `TerminalView` is wrapped in Flutter's `SelectionArea`, both
xterm's own `TerminalGestureDetector` and the framework's
`SelectableRegion` register competing long-press / drag / double-tap
recognizers. xterm's win the arena, call `renderTerminal.selectWord`
directly, and the framework never sees the event — so its draggable
handles and adaptive toolbar never appear.

Added `suppressInternalSelectionGestures` (default false) to
`TerminalView` and `TerminalGestureHandler`. When true, xterm's
long-press / drag / double-tap paths no longer call selectWord /
selectCharacters, freeing the framework to drive selection via
`SelectionContainerDelegate.dispatchSelectionEvent`. Other terminal
gestures (tap to focus, mouse reporting) still work.

### P5 — Push selection-handle `LeaderLayer`s (`lib/src/ui/render.dart`)

`SelectionContainerDelegate.pushHandleLayers` hands two `LayerLink`s,
one per teardrop handle. The framework's handle widgets use
`CompositedTransformFollower` to follow those links — they only render
if somebody has actually installed a `LeaderLayer` with the same link
during paint.

Added `startHandleLayerLink` and `endHandleLayerLink` setters on
`RenderTerminal`. Paint now pushes a zero-size `LeaderLayer` at each
selection endpoint (bottom of the cell, so the teardrop points up into
the selection), letting Flutter's adaptive handles track the terminal's
own selection state.

### P4 — Opt-out of alt-buffer `InfiniteScrollView` (`lib/src/ui/scroll_handler.dart`, `lib/src/terminal_view.dart`)

Upstream unconditionally wraps the terminal in an `InfiniteScrollView`
(a Flutter `Scrollable`) whenever the program switches to alt-screen
mode, so that touch drag can be translated to mouse-wheel events. That
Scrollable has its own vertical-drag gesture recognizer which wins the
gesture arena from the `LongPressGestureRecognizer`, so long-press-drag
text selection silently never fires inside tmux / vim / less.

New boolean `handleAltBufferTouchScroll` (default true for backward
compat) on `TerminalScrollGestureHandler` and `TerminalView`. When
false, the alt-buffer wrap is skipped entirely. andssh passes false
because we emit wheel events from touch in our own outer `Listener`.

### P3 — "Bare long-press" callback (`lib/src/ui/gesture/gesture_handler.dart`, `lib/src/terminal_view.dart`)

Upstream's `TerminalGestureHandler.onLongPressStart` immediately calls
`selectWord` — so a user who long-presses to open a paste menu ends up
with a selected word instead. We changed the flow to:

- `onLongPressStart`: record position but do **not** select.
- `onLongPressMoveUpdate`: first move triggers `selectWord(start,
  current)`; subsequent moves extend the selection as before.
- `onLongPressUp`: if no drag movement occurred, fire the new
  `TerminalView.onLongPressTap` callback with the start details + cell
  offset. The caller can show a Paste / context menu.

This keeps long-press-drag selection working and adds a clean hook for
the "user long-pressed on blank space" case that Android text fields
handle.

### P2 — Export `RenderTerminal` (`lib/ui.dart`)

Added `export 'src/ui/render.dart' show RenderTerminal;` so we can
compute pixel offsets of cell coordinates from outside the package
(used for positioning the native text-selection toolbar at the top of
the current selection).

### P1 — Correct SGR wheel button IDs (`lib/src/core/mouse/button.dart`)

Upstream defines:

```dart
wheelUp(id: 64 + 4, isWheel: true),   // 68 — wrong
wheelDown(id: 64 + 5, isWheel: true), // 69 — wrong
```

Per the xterm ctlseqs spec, wheel events use button codes **64 and 65**
in the SGR encoding — not 68/69. Upstream's `64 + 4` conflates "button
number 4 = wheel-up" with the "+64 wheel flag". Tmux, less, vim and
htop all ignore the 68/69 codes, so wheel scrolling is broken for every
real terminal program. Fixed to `64` and `65`.
