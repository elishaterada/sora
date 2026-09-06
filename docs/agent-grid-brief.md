# Shape brief: Agent thread in the terminal grid

## Resolved decisions (2026-09-05)

1. **Ghostty cannot inject non-PTY text into the grid.** `ghostty_surface_text`
   pastes into the shell; there is no scrollback-write API. True in-grid
   transcript injection is blocked without new libghostty APIs.
2. **Ship a hybrid overlay.** The Metal surface stays visible (dimmed); Agent
   is a translucent SwiftUI panel on top. Escape does not stop the stream and
   does not hide/destroy the surface.
3. **Approval controls stay in the overlay** as labeled cards (not glyph-only).
4. **Setup stays out-of-band** in the Agent panel / Settings — not in the grid.
5. **Resume slot is permanently reserved** (36pt) above the sticky bar so the
   PTY row count never changes when a thread becomes resumable.

## Job and audience

A developer mid-shell-task who typed a sentence at a ready prompt and got
`↵ agent`. They need continuity with the terminal they already trust while an
agent answers.

## Outcome

Success today: Escape never kills work, never resizes the PTY, and never swaps
away the Metal surface. The grid remains visible under the agent overlay.

Future stretch: cell-aligned multi-line overlay (generalize `GhostTextView`)
that paints turns on the grid metrics without joining Ghostty scrollback.

## Status

Vertical slice shipped as hybrid overlay + reserved resume slot. Cell-aligned
transcript painting remains a follow-up if product still wants turns to read
as terminal glyphs.
