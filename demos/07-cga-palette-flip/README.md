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

By flipping **port 0xD9 bit 5** every scanline during HBLANK, even lines display entries {0, 2, 4, 6} and odd lines display entries {1, 3, 5, 7} — giving **7 visible foreground colors** plus black background. Combined with per-scanline palette RAM reprogramming via ports 0xDD/0xDE, the full 512-color RGB333 space is available on every line.

## Key Hardware Findings

All findings verified on real PC1 hardware (February 2026):

1. **Port 0xD9 bit 5** controls palette select on V6355D (VERIFIED WORKING).
   Port 0xD8 bit 5 does NOT work for palette select — despite what some documentation claims.

2. **Pixel value 0 and border share the same source:** 0xD9 bits 3–0 select the V6355D palette entry used for both. This is a hardwired CGA rule — cannot be separated.

3. **Both PAL_EVEN and PAL_ODD must point to the same bg/border entry** (here entry 0 = black). If they differ, the border flickers between two colors every scanline.

4. **V6355D palette writes stream sequentially from entry 0.** Command 0x40 always opens at entry 0. No random access — to change entry N, you must stream through entries 0 to N−1 first.

5. **HBLANK budget:** ~80 cycles (~10 short-form OUTs max). Using short port aliases (0xD9 not 0x3D9) saves ~4 cycles per OUT on the V40.

6. **Visible-area palette writes work** on the V6355D. Writing to palette RAM during the active display area produces only minor horizontal glitches — the palette entries update fast enough to be usable.

## Files

| File | Description | Status |
|------|-------------|--------|
| `cgaflip1.asm` | Starter template / planning file. Uses 0xD8 for palette select (standard CGA approach). Not fully implemented. | Template |
| `cgaflip2.asm` | First working palette flip demo. Static 8-color display with 2 OUTs per scanline (0xD8 + 0xD9). Early version — comments reference 0xD8 for palette select, which was later found to not work on V6355D. | Early version |
| `cgaflip3.asm` | **Palette flip + HBLANK gradient.** Flips palette via 0xD9 and reprograms entry 2 to a rainbow gradient every scanline — all 9 OUTs fit within HBLANK. Solid black border. Includes detailed "Lessons Learned" section. | **Verified working** |
| `cgaflip4.asm` | **Visible-area reprogramming experiment.** Only 1 OUT during HBLANK (the palette flip). All 8 palette entries streamed from a gradient table during the visible area (~160 cycles in a 424-cycle budget). Smooth rainbow gradients on 3 bands. | **Verified working** |
| `*.com` | Assembled COM executables for each version. | Binary |
| `*.lst` | NASM listing files. | Listing |
| `*.jpg` | Photos from real PC1 hardware showing the output. | Hardware photos |

## Build

Requires [NASM](https://www.nasm.us/):

```
nasm cgaflip3.asm -o cgaflip3.com -l cgaflip3.lst
nasm cgaflip4.asm -o cgaflip4.com -l cgaflip4.lst
```

## Controls

| Key | Action |
|-----|--------|
| ESC | Exit to DOS |
| H   | Toggle HSYNC synchronization |
| V   | Toggle VSYNC synchronization |

## Hardware Requirements

- **Olivetti Prodest PC1** (or M24) with Yamaha V6355D video controller
- NEC V40 CPU @ 8 MHz (timing-critical)
- CGA-compatible monitor

## License

See the [PC1-Labs LICENSE](../../LICENSE) file.
