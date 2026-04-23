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
