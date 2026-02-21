# 07 - CGA Palette Flip

Per-scanline CGA palette switching experiments on the **Olivetti Prodest PC1** (Yamaha V6355D, NEC V40 @ 8 MHz) in 320×200×4 CGA mode.

Inspired by **Simone's** technique used in Monkey Island on the PC1 — alternate between the two CGA palettes every scanline and reprogram the V6355D palette RAM on the fly, producing far more than 4 colors per frame.

## The Technique

In CGA 320×200×4 mode, each pixel value (0–3) maps to a palette entry:

| Pixel Value | Palette 0 (even lines) | Palette 1 (odd lines) |
|:-----------:|:----------------------:|:---------------------:|
| 0           | entry 0 (bg/border)    | entry 0 (bg/border)   |
| 1           | entry 2                | entry 3               |
| 2           | entry 4                | entry 5               |
| 3           | entry 6                | entry 7               |

Entry 1 is unused (no pixel value maps to it when bg = entry 0).

By flipping **port 0xD9 bit 5** every scanline during HBLANK, even lines display entries {0, 2, 4, 6} and odd lines display entries {1, 3, 5, 7} — giving **7 visible foreground colors** plus black background.

## Demo Progression

The demos build on each other in sequence, each discovering or proving something new:

```
cgaflip2 → cgaflip3 → cgaflip4 (fail) → cgaflip5 (proof) → cgaflip6 → cgaflip7 → cgaflip8 → cgaflip9
                                                                         ↑
                                                          cgaflip-diag + cgaflip-diag2 (diagnostics)
```

| Step | File | Colors | Technique |
|:----:|------|:------:|-----------|
| 1/8 | cgaflip2 | 8 | Palette flip + entry 0 gradient. Border flickers. |
| 2/8 | cgaflip3 | 8 | Entry 2 gradient. Black border fixed. 9 OUTs/HBLANK. |
| 3/8 | cgaflip4 | — | Visible-area streaming. **FAILS** (blinking). |
| 4/8 | cgaflip5 | 7 | Flip-only stability proof. Zero flicker. |
| 5/8 | cgaflip6 | 7+ | Row-dithered VRAM → "virtual colors". No streaming. |
| 6/8 | cgaflip7 | 85 | 3 columns × E2 via VRAM rotation. Deferred open/close. |
| 7/8 | cgaflip8 | 85+ | E2+E3 dual gradient. Smoother blending. |
| 8/8 | cgaflip9 | **512** | Full E2-E7 passthrough. 3 × 200 lines. **Final.** |

## Files — Assembly Demos

| File | Description |
|------|-------------|
| `cgaflip2.asm` | **Part 1/8: Palette flip + entry 0 gradient.** First working palette flip via 0xD9 bit 5. Reprograms entry 0 per scanline for a rainbow gradient. 5 OUTs per HBLANK. Border flickers because even/odd bg indices differ (entry 0 vs entry 1). |
| `cgaflip3.asm` | **Part 2/8: Entry 2 gradient (fixed border).** Moves gradient to entry 2, giving a solid black border on all lines. 9 OUTs per HBLANK (streams through entries 0-1 to reach entry 2). Foundation for all subsequent HBLANK palette updates. |
| `cgaflip4.asm` | **Part 3/8: Visible-area streaming experiment.** Only 1 OUT during HBLANK (palette flip). All 8 entries streamed during the visible area. **CAUSES BLINKING** — the V6355D palette write protocol (open/stream/close) disrupts video output during the visible area, regardless of which entries are written. |
| `cgaflip5.asm` | **Part 4/8: Flip-only stability proof.** Split-screen test: top = palette 0, bottom = palette 1. **6 colors + black, zero flicker.** Proves the palette flip via 0xD9 is perfectly stable; the blinking in cgaflip4 was caused by the palette write protocol, not the flip. |
| `cgaflip6.asm` | **Part 5/8: "Sunset Gradient" showcase.** Row-dithered VRAM + palette flip = 7+ perceived "virtual colors" from 4 CGA pixel values. No per-scanline palette streaming — all entries set once during VBLANK. Demonstrates temporal color blending. |
| `cgaflip7.asm` | **Part 6/8: Three-column gradients via VRAM rotation.** Per-scanline E2 update with deferred open/close (3 OUTs per even HBLANK). VRAM pixel pattern rotates every 2 rows so each column gets E2 every 6 lines. ~33 gradient steps per column. Two modes: Sunset/Rainbow/Cubehelix and Red/Green/Blue. Up to 85 unique colors on screen. |
| `cgaflip8.asm` | **Part 7/8: E2+E3 dual gradient.** Streams 4 bytes (E2 R, E2 GB, E3 R, E3 GB) per even HBLANK. E3 fills the odd-line gap for smoother blending. 5 OUTs even, 3 OUTs odd. Built on cgaflip-diag's finding that inactive-entry writes are safe. |
| `cgaflip9.asm` | **Part 8/8: Full E2-E7 passthrough (final).** Writes all 6 entries per even HBLANK via OUTSB×12 (13 OUTs, ~119 cycles). Active entries receive the same value ("passthrough"), inactive entries get next line's colors. No VRAM rotation needed. 3 columns × 200 lines. 4 modes: 34-step Sunset/Rainbow/Cubehelix, RGB, all 512 RGB333, and 200-step smooth gradients. |

## Files — Diagnostics

| File | Description |
|------|-------------|
| `cgaflip-diag.asm` | **Inactive-entry write test.** Proves that writing to INACTIVE palette entries during the visible area does NOT disrupt the active entries on the V6355D. This finding enabled cgaflip8 (writing E3 during HBLANK) and paved the way for cgaflip9. Toggle test ON/OFF with SPACE to compare. |
| `cgaflip-diag2.asm` | **Active-entry passthrough test.** Proves that streaming through ACTIVE entries with the SAME value ("passthrough") during the visible area is safe — the V6355D DAC does not glitch. This finding enabled cgaflip9's full E2-E7 streaming without VRAM rotation. |

## Files — Intermediate / Experimental

| File | Description |
|------|-------------|
| `cgaflip7-streaming.asm` | Earlier approach to cgaflip7 using 9 OUTs per HBLANK (streams through entries 0-1 like cgaflip3). Single-column gradient only. Superseded by cgaflip7.asm's deferred open/close technique (3 OUTs). |
| `cgaflip9 first working copy.asm` | Snapshot of cgaflip9 from the first successful hardware test. Kept for reference. |

## Files — HTML Previews

| File | Description |
|------|-------------|
| `cgaflip7-preview.html` | Browser-based preview of cgaflip7's 3-column gradient display. Per-column gradient selector with 10 gradient types. Simulates the VRAM rotation and E2-only update pattern with 6-line interleaving. |
| `cgaflip9-preview.html` | Browser-based preview of cgaflip9's full-palette gradient display. Includes all 4 hardware modes plus extra presets, 200-step parametric gradients (sunset, rainbow, cubehelix, fire, ocean, purple, red, green, blue), cubehelix parameter sweep optimization, 3-column split preset, and unique color counter. |

## Files — Tools & Generators

| File | Description |
|------|-------------|
| `gen_grad200.js` | JScript (cscript) generator for `grad200_tables.inc`. Creates 200-step NASM gradient tables for sunset, rainbow, and cubehelix. Includes cubehelix parameter sweep to find optimal rot/amp/start values maximizing unique RGB333 colors. |
| `gen_grad200_fast.js` | Fast version of `gen_grad200.js` — skips the parameter sweep, uses known-best cubehelix params (rot=37, amp=2.4, start=0.5 → 296 unique RGB333 colors). Runs in seconds instead of minutes. |
| `count_colors.ps1` | PowerShell script to count unique RGB333 colors across the 3-column gradient display for cgaflip7/8. Used to verify color counts during development. |

## Files — Generated Data

| File | Description |
|------|-------------|
| `all512_tables.inc` | NASM include: all 512 RGB333 colors sorted by luminance, interleaved across 3 columns (171 + 171 + 170 = 512), padded to 200 entries each. Used by cgaflip9 Mode 2. |
| `grad200_tables.inc` | NASM include: 200-step gradient tables for sunset, rainbow, and cubehelix (296 unique colors in cubehelix alone). Generated by `gen_grad200_fast.js`. Used by cgaflip9 Mode 3. |

## Files — Binaries & Images

| File | Description |
|------|-------------|
| `*.com` | Assembled COM executables for each demo. |
| `*.png` | Photos/screenshots from real PC1 hardware showing the output of each demo. |

## Key Hardware Findings

All findings verified on real PC1 hardware (February 2026):

1. **Port 0xD9 bit 5** controls palette select on V6355D (VERIFIED WORKING).
2. **Pixel value 0 and border share the same source** — 0xD9 bits 3–0 select the entry for both. Cannot be separated.
3. **V6355D palette writes stream sequentially.** Command 0x40 opens at entry 0. Open-at-offset (0x44) opens at entry 2 — VERIFIED.
4. **HBLANK budget:** ~80 cycles (~10 short-form OUTs max) on NEC V40 @ 8 MHz.
5. **Palette flip (0xD9 only) is perfectly stable** — zero flicker (cgaflip5).
6. **Visible-area palette streaming causes blinking** — the write protocol disrupts V6355D output (cgaflip4, cgaflip5).
7. **Inactive-entry writes during visible area are safe** — no disruption to active entries (cgaflip-diag).
8. **Active-entry passthrough is safe** — writing the same value to active entries causes no glitching (cgaflip-diag2).
9. **Deferred open/close** — opening the palette write session on odd HBLANK lines and consuming it on even lines allows 12+ bytes via OUTSB with only 3 OUTs on the critical even path (cgaflip7).

## Build

Requires [NASM](https://www.nasm.us/):

```
nasm -f bin -o cgaflip2.com cgaflip2.asm
nasm -f bin -o cgaflip3.com cgaflip3.asm
nasm -f bin -o cgaflip4.com cgaflip4.asm
nasm -f bin -o cgaflip5.com cgaflip5.asm
nasm -f bin -o cgaflip6.com cgaflip6.asm
nasm -f bin -o cgaflip7.com cgaflip7.asm
nasm -f bin -o cgaflip8.com cgaflip8.asm
nasm -f bin -o cgaflip9.com cgaflip9.asm
nasm -f bin -o cgaflip-diag.com cgaflip-diag.asm
nasm -f bin -o cgaflip-diag2.com cgaflip-diag2.asm
```

## Controls

| Key | Action |
|-----|--------|
| ESC | Exit to DOS |
| SPACE | Cycle gradient mode (cgaflip7–9) or toggle test (diag/diag2) |

## Hardware Requirements

- **Olivetti Prodest PC1** with Yamaha V6355D video controller
- NEC V40 CPU @ 8 MHz (timing-critical)
- CGA-compatible monitor

## License

See the [PC1-Labs LICENSE](../../LICENSE) file.
