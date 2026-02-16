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

**Update (February 2026):** Per-scanline palette RAM reprogramming via ports 0xDD/0xDE during the visible area was tested (cgaflip4, cgaflip5) and **causes visible blinking**. The V6355D palette write protocol (open 0x40 / stream data / close 0x80) disrupts video output regardless of whether active or inactive entries are targeted. The palette flip itself (0xD9 only) is perfectly stable — confirmed with a split-screen test showing 6 distinct colors + black with zero flicker (cgaflip5). Per-scanline color changes are limited to 1 entry per HBLANK (cgaflip3 approach).

## Key Hardware Findings

All findings verified on real PC1 hardware (February 2026):

1. **Port 0xD9 bit 5** controls palette select on V6355D (VERIFIED WORKING).
   Port 0xD8 bit 5 is the blink enable bit (text mode) and has no palette function in graphics mode — on any CGA-compatible hardware.

2. **Pixel value 0 and border share the same source:** 0xD9 bits 3–0 select the V6355D palette entry used for both. This is a hardwired CGA rule — cannot be separated.

3. **Both PAL_EVEN and PAL_ODD must point to the same bg/border entry** (here entry 0 = black). If they differ, the border flickers between two colors every scanline.

4. **V6355D palette writes stream sequentially from entry 0.** Command 0x40 always opens at entry 0. No random access — to change entry N, you must stream through entries 0 to N−1 first.

5. **HBLANK budget:** ~80 cycles (~10 short-form OUTs max). Using short port aliases (0xD9 not 0x3D9) saves ~4 cycles per OUT on the V40.

6. **Palette flip (0xD9 only) is perfectly stable.** Writing ONLY the palette select register (0xD9) during HBLANK produces zero flicker — confirmed with split-screen test showing 6 distinct colors + black (cgaflip5).

7. **Visible-area palette streaming causes blinking.** Opening the palette write protocol (0x40 → 0xDD, stream via 0xDE, close 0x80 → 0xDD) during the visible area causes visible blinking — even when writing only inactive entries with unchanged values (cgaflip4, cgaflip5 streaming variants). The V6355D palette read pipeline is disrupted by the write protocol itself, regardless of data content.

8. **Per-HBLANK palette entry changes:** Only 1 palette entry can be cleanly changed per HBLANK (cgaflip3). Writing 2+ entries during HBLANK causes adjacent entry corruption (see Section 5c in V6355D technical reference).

## Files

| File | Description | Status |
|------|-------------|--------|
| `cgaflip2.asm` | **Palette flip + HBLANK gradient (entry 0).** First working palette flip via 0xD9 bit 5. Reprograms entry 0 per scanline for a rainbow gradient in band 0 (alternating with hot pink on odd lines). 5 OUTs per HBLANK. Border flickers because even/odd bg indices differ (entry 0 vs entry 1). | **Verified working** |
| `cgaflip3.asm` | **Palette flip + HBLANK gradient (entry 2).** Refined version — gradient on entry 2 instead of entry 0, giving a solid black border on all lines. 9 OUTs per HBLANK. Includes detailed "Lessons Learned" section with hardware findings. | **Verified working** |
| `cgaflip4.asm` | **Visible-area reprogramming experiment.** Only 1 OUT during HBLANK (palette flip). All 8 entries streamed from gradient table during the visible area (~160 cycles). **CAUSES FLICKERING** — the palette write protocol (open/stream/close via 0xDD/0xDE) disrupts V6355D output during visible area. See cgaflip5 for conclusions. | **Flickering confirmed** |
| `cgaflip5.asm` | **Palette flip proof-of-concept (split-screen).** Tests palette flip stability WITHOUT any palette streaming. Top half = palette 0 (Red/Green/Blue), bottom half = palette 1 (Yellow/Cyan/Magenta). **6 colors + black, perfectly stable, zero flicker.** Proves that palette flip via 0xD9 is rock solid; the blinking in cgaflip4 was caused by the palette write protocol, not the flip itself. | **Verified stable** |
| `*.com` | Assembled COM executables for each version. | Binary |
| `*.jpg` | Photos from real PC1 hardware showing the output. | Hardware photos |

## Build

Requires [NASM](https://www.nasm.us/):

```
nasm cgaflip2.asm -o cgaflip2.com
nasm cgaflip3.asm -o cgaflip3.com
nasm cgaflip4.asm -o cgaflip4.com
nasm cgaflip5.asm -o cgaflip5.com
```

## Controls

| Key | Action |
|-----|--------|
| ESC | Exit to DOS |
| H   | Toggle HSYNC synchronization |
| V   | Toggle VSYNC synchronization |

## Hardware Requirements

- **Olivetti Prodest PC1** with Yamaha V6355D video controller
- NEC V40 CPU @ 8 MHz (timing-critical)
- CGA-compatible monitor

## License

See the [PC1-Labs LICENSE](../../LICENSE) file.
