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
