# Bitmap Demos - Olivetti PC1

Educational demonstrations exploring BMP image loading, raster bars over images, scrolling, and hardware register tricks on the Olivetti PC1 with Yamaha V6355D video controller.

## Hardware Target
- **Machine:** Olivetti PC1
- **CPU:** NEC V40 (80186 compatible) @ 8 MHz
- **Video Controller:** Yamaha V6355D
- **Video Mode:** CGA 160×200×16 (Hidden graphics mode)
- **VRAM:** 16KB at segment B000h, CGA-interlaced (even rows at 0x0000, odd rows at 0x2000)

## Overview

This folder traces the evolution from "display a BMP with raster bars" all the way to "scroll a tall image efficiently using hardware tricks." The demos progress through increasingly sophisticated techniques:

1. **Raster bars over images** (demo1–demo4) — Can we overlay animated bars on a BMP?
2. **Full-screen scrolling** (demo5a–demo5c) — Scroll an image around with sine-wave motion
3. **Partial-screen panning** (demo6) — Only update part of the screen for speed
4. **Hardware scrolling** (demo7a) — Use CRTC R12/R13 to scroll without copying pixels
5. **Software viewport scrolling** (demo7b) — Scroll tall images (>200 rows) via RAM→VRAM copy
6. **Circular buffer scrolling** (demo8a–demo8c) — Copy only 160 bytes/frame instead of 16KB
7. **R12/R13 effects** (demo9) — Screen shake, wave, bounce, marquee via Start Address

## Files

### Raster Bars over BMP Images

#### `demo1.asm` — PORT_COLOR Raster Bars (Flickery)
**Technique:** PORT_COLOR per-scanline color changes over a loaded BMP
- Loads BMP, then overlays two sine-wave raster bars via PORT_COLOR (port 0xD9)
- Bars swap depth order when crossing for 3D "dancing" illusion
- **Key finding:** PORT_COLOR only affects blank scanlines — on lines with non-zero pixels, the override is blocked by the V6355D
- Uses 8-bit port aliases (0xD9/0xDA) for faster OUT timing
- **901 lines** | Any key = exit

#### `Demo2.asm` — VRAM Strip Bars with Palette Cycling
**Technique:** Draw bar strips into VRAM using reserved palette entries 14/15, animate via palette cycling
- Bars are solid VRAM strips (0xEE/0xFF pixels), not PORT_COLOR
- Color animation by rewriting palette entries 14/15 during VBlank — no VRAM writes needed for color changes
- Backs up original VRAM scanlines before drawing bars, restores when bar passes
- **Problem:** VRAM→VRAM backup is slow on the V6355D
- **1296 lines** | Any key = exit

#### `demo3.asm` — VRAM Strip Bars with RAM Buffer (Broken)
**Technique:** Same as Demo2, but restores bars from a RAM buffer copy instead of VRAM backup
- BMP decoded into 16KB linear RAM buffer first, then copied to VRAM
- Bar restoration reads from RAM instead of slow VRAM
- **Problem:** Palette cycling is broken in this version
- Superseded by demo4
- **1400 lines** | Any key = exit

#### `demo4.asm` — VRAM Strip Bars (Complete Working Version)
**Technique:** RAM buffer + palette cycling + gradient bars — the polished version
- Everything from demo3, but with working palette cycling
- Extensive header documentation of alternative techniques:
  - Multi-color gradient bars (3–4 palette entries per bar)
  - HSync palette switching (Amiga copper-bar style)
- Smooth gradient color breathing/pulsing animation
- **1520 lines** | Any key = exit

---

### Full-Screen Image Scrolling

#### `demo5a.asm` — Lissajous Scroller (Interlaced RAM, Final)
**Technique:** Scroll a 160×200 BMP around the screen using sine-wave Lissajous motion
- Interlaced RAM buffer mirrors VRAM layout → fast REP MOVSW bank-to-bank copies
- 2-pixel Y movement steps preserve bank alignment
- Uses 80186 instructions (PUSHA/POPA, immediate shifts)
- Copies full 16KB viewport to VRAM each frame
- **1160 lines** | Any key = exit

#### `demo5b - linear ram.asm` — Scroller (Linear RAM Buffer)
**Technique:** Same scroller as demo5a, but with LINEAR RAM layout
- RAM buffer stores rows sequentially (row N at offset N×80)
- Requires per-row bank calculation when copying to VRAM
- Raster bars disabled to isolate the RAM layout comparison
- Paired with demo5c for benchmarking linear vs interlaced RAM layout
- **1747 lines** | Any key = exit

#### `demo5c - fast interlaced RAM.asm` — Scroller (Interlaced RAM Buffer)
**Technique:** Same scroller as demo5b, but with INTERLACED RAM layout matching VRAM
- RAM buffer mirrors CGA interlacing → bulk bank-to-bank REP MOVSW
- Faster than linear layout (no per-row bank math)
- Raster bars disabled to isolate the RAM layout comparison
- Paired with demo5b for benchmarking
- **1809 lines** | Any key = exit

---

### Partial-Screen Panning

#### `demo6.asm` — Partial Image Panning with Delta Clearing + FPS Counter
**Technique:** Only update a configurable number of rows (default 50) — not the full screen
- **Delta clearing:** Only clears exposed rows that won't be overwritten (no full-screen flash)
  - Moving down? Clear only top exposed rows. Moving up? Clear only bottom exposed rows
- C64-style Lissajous wobble motion
- FPS counter shows actual performance (updates once per second)
- 50 rows = 50 FPS with VSync, 72 FPS free-running (44% headroom)
- **1942 lines** | V = toggle VSync, any other key = exit

---

### Hardware Scrolling (R12/R13 Start Address)

#### `demo7a.asm` — R12/R13 Hardware Scroll (Has Bank Gap Bug)
**Technique:** True hardware scrolling via CRTC Start Address registers — no pixel copying
- Writes to R12/R13 to shift which VRAM address the display starts reading from
- Zero CPU cost per scroll (just 2 register writes)
- **Known bug:** 192-byte gap at end of each 8KB bank causes ~96px horizontal shift when scrolling past one screenful
- Kept as educational artifact showing why pure R12/R13 fails for CGA interlaced scrolling
- **547 lines** | UP/DOWN or <,> = scroll, ESC/Q = exit

#### `demo7b.asm` — Software Viewport Scroller for Tall Images
**Technique:** Loads tall BMP (up to 800 rows) into DOS-allocated RAM, copies 200-row viewport to VRAM
- Pure software scrolling — no R12/R13 used
- Interlaced RAM buffer for fast REP MOVSW copies
- 2 bulk block copies per frame (one per bank) instead of 200 row-by-row calls
- Auto-scroll mode (SPACE) bounces viewport up and down
- VSync toggle for smooth vs benchmark mode
- **842 lines** | UP/DOWN/<,> = scroll, SPACE = auto-scroll, V = VSync, ESC/Q = exit

---

### Circular Buffer Scrolling (The "100x Faster" Attempt)

#### `demo8a.asm` — Circular Buffer Concept Demo (384-Byte Gap Bug)
**Technique:** Treat VRAM as a ring buffer — only copy 2 new rows (160 bytes) per scroll instead of 16KB
- Overwrite the rows that scrolled off-screen with new rows from RAM
- Shift R12/R13 to move the display start address forward
- CRTC wraps at bank boundary for seamless circular reading
- **Fatal flaw:** Each 8KB bank has 192 bytes of unused gap (8192-8000). When R12/R13 offset is non-zero, the CRTC reads into the gap → garbage pixels at screen bottom
- Kept as reference for the circular buffer concept
- **968 lines** | UP/DOWN/<,> = scroll, SPACE = auto, V = VSync, R = reset, ESC/Q = exit

#### `demo8b.asm` — Circular Buffer with Reduced Display (196 Row Workaround) — SUPERSEDED
**Technique:** Reduce display to 196 rows to create more gap headroom, then periodic full reload
- 196 rows = 98 per bank × 80 = 7840 bytes → 352 bytes headroom (vs 192)
- 4 fast scrolls (160 bytes each) before gap is reached → 1 full 15,680-byte reload
- Average: ~3,200 bytes/scroll — about 5× faster than demo7b's 16KB/frame
- **Three bugs cause stuttering:** R6 is dummy, wrong write destination, 15KB reload stutter
- **Superseded by demo8c** which fixes all three issues
- **1095 lines** | UP/DOWN/<,> = scroll, SPACE = auto, V = VSync, R = reset, ESC/Q = exit

#### `demo8c.asm` — True Circular Buffer with Register 0x65 (192 Lines) — **FINAL**
**Technique:** Register 0x65 = 0x08 for genuine 192-line mode + true circular buffer with CRTC MA wrapping
- 192 lines = 96 rows/bank × 80 = 7680 bytes → **512 bytes gap** per bank
- CRTC MA counter wraps naturally at 8K bank boundary (standard 6845/CGA behavior)
- Every scroll writes exactly 160 bytes — no reloads, no exceptions, no stuttering
- New rows written at (crtc_start + 7680) & 0x1FFF with 8K boundary split copy
- Word-wide CRTC writes (`out dx, ax`) for atomic R12/R13 updates during VBlank
- Palette session close (0x80 → 0x3DD) after register 0x65 write to prevent DAC corruption
- **Hardware confirmed: perfectly smooth scrolling on real PC1**
- **~96× faster than demo7b** (160 bytes vs 15,360 bytes per scroll)
- **1077 lines** | UP/DOWN/<,> = scroll, SPACE = auto, V = VSync, R = reset, ESC/Q = exit

---

### R12/R13 Effects Showcase

#### `demo9.asm` — CRTC Start Address Effects Demo (SUPERSEDED by demo9b)
**Technique:** All visual effects via R12/R13 register manipulation only — no pixel copying at all
- **Screen shake** — Random R12/R13 offsets for earthquake/explosion effect (intensity 1–9)
- **Horizontal wave** — Sinusoidal horizontal wobble
- **Slide-in transition** — Image slides in from left
- **Bounce** — Horizontal bounce animation
- **Marquee** — Ping-pong horizontal scroll
- All effects are essentially free (single register write per frame)
- Limited to small offsets (~5 rows) before the 384-byte gap causes artifacts
- **Three bugs:** (1) missing CRTC word addressing (`shr ax,1`), (2) non-row-aligned offsets cause mid-scanline seam, (3) gap artifacts at 200 lines
- **Superseded by demo9b** which fixes all three bugs
- **1089 lines** | S/H/T/B/M = effects, 1–9 = shake intensity, V = VSync, R = reset, ESC = exit

#### `demo9b.asm` — Vertical R12/R13 Effects with Tall Image Support — **FINAL**
**Technique:** All effects converted to row-aligned vertical movement + 192-line mode + gap patching + RAM buffer for tall images
- All five effects rewritten as **vertical** (row-aligned) — eliminates the CGA mid-scanline seam
- **CRTC word addressing fix:** divides byte offset by 2 (`shr ax,1`) before writing R12/R13 (MC6845 counts in words, not bytes)
- **192-line mode** (register 0x65 = 0x08) gives 512-byte gap per bank — 6 rows of headroom for effects
- **Gap patching:** copies first 512 bytes of each bank into its gap area for seamless circular wrap during effects
- **Tall image support (up to 160×800):** shrinks PSP, allocates RAM buffer via DOS, decodes full BMP to interlaced RAM, copies 192-row viewport to VRAM
- **Navigation keys:** UP/DOWN (2-row steps), PgUp/PgDn (96-row half-screen), Home/End (top/bottom)
- Effects operate on current VRAM viewport; viewport changes stop effects and do full refresh
- Word-wide CRTC writes (`out dx, ax`) for atomic R12/R13 updates
- Uses `[CPU 186]` for `pusha`/`popa` and immediate-count shifts (NEC V40 is 80186-compatible)
- **Hardware confirmed: all effects clean on real PC1, no seam, no gap artifacts**
- **~1380 lines** | S/H/T/B/M = effects, 1–6 = shake intensity, UP/DOWN/PgUp/PgDn/Home/End = navigate, V = VSync, R = reset, ESC = exit

## BMP Files

| File | Purpose |
|------|---------|
| `bands.bmp` | Horizontal color bands test pattern |
| `vstripe.bmp` | Vertical stripe test pattern |

Most demos expect 160×200 or 320×200, 4-bit (16 color) BMP files as input.
demo9b also supports tall images up to 160×800 or 320×800.

## Compilation

```powershell
nasm -f bin -o demo1.com demo1.asm
nasm -f bin -o Demo2.com Demo2.asm
nasm -f bin -o demo3.com demo3.asm
nasm -f bin -o demo4.com demo4.asm
nasm -f bin -o demo5a.com demo5a.asm
nasm -f bin -o "demo5b - linear ram.com" "demo5b - linear ram.asm"
nasm -f bin -o "demo5c - fast interlaced RAM.com" "demo5c - fast interlaced RAM.asm"
nasm -f bin -o demo6.com demo6.asm
nasm -f bin -o demo7a.com demo7a.asm
nasm -f bin -o demo7b.com demo7b.asm
nasm -f bin -o demo8a.com demo8a.asm
nasm -f bin -o demo8b.com demo8b.asm
nasm -f bin -o demo8c.com demo8c.asm
nasm -f bin -o demo9.com demo9.asm
nasm -f bin -o DEMO9B.COM demo9b.asm
```

## Running

Copy .COM files and a BMP to floppy, then on the PC1:
```
A:\PERITEL.COM
A:\demo1.com bands.bmp
```

All demos that load images take the BMP filename as a command-line argument.

## The 384-Byte Gap Problem (Solved in demo8c)

A recurring theme in demo7a, demo8a, and demo8b. CGA interlaced mode uses two 8KB banks:
- Each bank: 8192 bytes physical, but only 8000 bytes used (100 rows × 80 bytes)
- **192-byte gap** at the end of each bank (offsets 0x1F40–0x1FFF and 0x3F40–0x3FFF)
- Total waste: 384 bytes across both banks

This gap is invisible during normal display but breaks any technique that shifts R12/R13 away from zero, because the CRTC reads linearly through the gap as if it were valid image data.

**Demo8c's solution:** Use register 0x65 = 0x08 for genuine 192-line mode (96 rows/bank = 7680 bytes). This increases the gap to **512 bytes** per bank — enough for the CRTC MA counter to wrap naturally at 8K without ever reading uninitialized gap data. New rows are always written into the gap area ahead of the display, and crtc_start advances by 80 with `& 0x1FFF` wrapping. On the rare case where an 80-byte row straddles the 8K boundary (~1 in 102 scrolls), the copy is split into two parts. Result: zero reloads, zero stuttering, constant 160-byte cost per scroll.

See **V6355D-Technical-Reference.md, Section 17f** for the full investigation.

## Learning Progression

1. **demo1 → demo4** — Raster bars over images: PORT_COLOR limitations, VRAM strips, palette cycling
2. **demo5a–5c** — Full-screen scrolling: RAM buffer strategies (linear vs interlaced)
3. **demo6** — Partial updates: delta clearing, FPS measurement
4. **demo7a** — Hardware scrolling: R12/R13 concept and the bank gap problem
5. **demo7b** — Software scrolling: brute-force 16KB/frame for tall images
6. **demo8a → demo8c** — Circular buffer: the elegant 160-byte solution, the gap problem, and the final fix via register 0x65 (192-line mode + true CRTC wrapping)
7. **demo9 → demo9b** — Creative effects: what you CAN do with R12/R13 (vertical offsets, 192-line gap patching, tall image RAM buffer)

## References

- V6355D Technical Reference (in Documentation folder)
- CGA memory layout and interlacing
- CRTC 6845 register documentation

## Author
Retro Erik - 2026

---

**Note:** These demos trace a real engineering journey — from "how do I even display a BMP?" to "can I scroll at 100× less memory bandwidth?" — complete with dead ends (demo3), fundamental hardware limitations (the gap), and creative workarounds (demo8b) leading to the final solution (demo8c). The progression mirrors how demo scene coders historically pushed hardware beyond its intended limits.
