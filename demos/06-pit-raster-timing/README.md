# PIT Interrupt Raster Timing - Olivetti PC1

Demonstrations of **PIT (Programmable Interval Timer) based scanline timing** on the Olivetti PC1 with Yamaha V6355D video controller.

## What This Folder Provides

This folder tests using **PIT interrupts** instead of **HSYNC polling** for per-scanline palette updates. The PIT method provides smoother, more consistent timing.

**Measurement tool:** `pitclk.asm` (now in [PC1-Labs/Tools/](../../Tools/)) — proved CPU, PIT, and pixel clocks are all phase-locked from the same 14.31818 MHz crystal. See [PC1-CLOCK-DISCOVERY.md](PC1-CLOCK-DISCOVERY.md) for full analysis.

| Demo | Technique | Status |
|------|-----------|--------|
| pitras1a | PIT interrupt, per-frame re-sync (naive) | ✅ WORKS (flickery) |
| pitras1b | PIT interrupt, phase-locked free-running | ✅ **CONFIRMED 99%+ STABLE** |
| pitras1c | pitras1b synced to active display edge | ✅ WORKS (more jitter, proves mid-display writes OK) |
| pitras1d | Half-scanline PIT (count=38), two colors/scanline | ❌ CRASHES |
| pitras2 | Animated rainbow scroll (pitras1b + scrolling offset) | 📋 PLANNED |
| pitras3 | Sinusoidal color gradient (sine table + animation) | 📋 PLANNED — needs sine table research |
| pitras4 | Copper bars / rainbow serpents (bouncing color bands) | 📋 PLANNED — needs gradient stamping research |

**Key Finding:** PIT and scanlines are **phase-locked** from the same 14.31818 MHz crystal — zero drift, ever. PIT count 76 and frame total 314 are both confirmed exact on real hardware. pitras1b achieves 99%+ stable raster bars with a one-time PIT setup that free-runs forever.

**Mid-scanline conclusion:** Changing palette TWICE per scanline remains unsolved. pitras3 does not work. pitras1d (half-scanline PIT at count=38) crashes. Reading PORT_STATUS between palette writes causes V6355D blinking. NOP-only delays inherit ISR entry jitter. Future work focuses on **maximizing the proven one-change-per-scanline** approach.

## Related Work

- **05-palette-ram-rasters/palram1-6** - Per-scanline palette changes using polling
- **05-palette-ram-rasters/palram5** - Mid-scanline color changes (multiple writes per scanline)

For mid-scanline experiments (changing color WITHIN the visible scanline), see **palram5.asm** which documents that technique with findings about 4-8 pixel jitter.

## Hardware Target

- **Machine:** Olivetti Prodest PC1
- **CPU:** NEC V40 @ 7.159 MHz (14.31818 / 2)
- **Video Controller:** Yamaha V6355D
- **Timer:** Intel 8253/8254 PIT (Programmable Interval Timer)

## Why PIT Instead of Polling?

### The Polling Problem

```asm
.wait_hsync:
    in al, dx           ; Read status port
    test al, 0x01       ; Test HSYNC bit
    jz .wait_hsync      ; Loop until HIGH
```

**Problem:** This polling loop introduces **4-8 pixels of horizontal jitter** because we might catch the HSYNC transition at any point in the loop.

### The PIT Solution

By programming PIT Channel 0 to fire IRQ0 every scanline (~76 ticks), we get consistent timing without polling:

```asm
; Program PIT for scanline timing
mov al, 0x34        ; Channel 0, lobyte/hibyte, mode 2
out 0x43, al
mov ax, 76          ; 76 ticks ≈ 63.5 µs = 1 scanline
out 0x40, al
mov al, ah
out 0x40, al
```

## Timing Constants

| Constant | Value | Notes |
|----------|-------|-------|
| PIT Clock | 1,193,182 Hz | 14.31818 MHz ÷ 12 |
| PIT Tick | ~0.838 µs | 1 / 1,193,182 |
| Scanline Duration | ~63.5 µs | CGA horizontal timing |
| **PIT Count/Scanline** | **76 ticks** | 912 / 12 = 76.0 EXACTLY (confirmed) |
| **Lines/Frame** | **314** | 200 visible + 114 VBLANK (confirmed) |
| **Frame Rate** | ~50 Hz | 14,318,180 / 912 / 314 ≈ 50.0 Hz |

## Files

### `pitras1a.asm` - PIT-Timed Palette Updates (Naive Version) ✅

**Purpose:** First attempt at PIT-driven raster — replace HSYNC polling with timer-driven interrupts for per-scanline palette updates. Works but flickers visibly due to per-frame re-sync. See pitras1b for the improved version.

**How it works:**
1. Save original IRQ0 vector (INT 08h)
2. Wait for VBLANK to synchronize with frame start
3. Install custom IRQ0 handler that writes palette entry 0
4. Program PIT for 76-tick intervals (mode 2, rate generator)
5. ISR fires 200 times per frame, each time writing new color
6. After 200 scanlines, set frame_done flag
7. Restore original PIT and IRQ0 vector

**Controls:**
- `P` - Toggle PIT mode vs HSYNC polling mode (compare!)
- `.` - Increase PIT count (bars drift down)
- `,` - Decrease PIT count (bars drift up)
- `V` - Toggle VSYNC waiting
- `ESC` - Exit

---

### `pitras1b.asm` - Phase-Locked PIT Raster (Zero-Drift) ✅ **CONFIRMED**

**Purpose:** Exploit the phase-locked clock tree (CPU, PIT, and pixel clock all derive from the same 14.31818 MHz crystal) to achieve near-perfect raster stability with zero drift.

**Key improvements over pitras1a:**
1. ONE-TIME setup: sync PIT to HBLANK edge, install ISR, done forever
2. PIT runs at 76 ticks/scanline — never reprogrammed
3. ISR uses CS-relative data only (no DS reload = ~12 cycles saved)
4. Scanline counter wraps at 314 (full PAL frame)
5. Main loop uses HLT — CPU sleeps between interrupts

**Confirmed Findings:**
- **76 PIT ticks = 1 scanline** — mathematically exact (912/12), confirmed by testing 75 and 77 (both cause drift)
- **314 lines per frame** — confirmed by testing 313 (caused upward scroll)
- **99%+ stable raster bars** — near-zero horizontal jitter or drift
- Remaining ~1% edge flicker = V40 interrupt latency variance (can't break mid-instruction)
- **Phase-lock theory: PROVEN** on real hardware

**Controls:**
- `S` - Toggle HLT sleep vs busy-wait (jitter comparison)
- `.` / `,` - Fine-tune PIT count (shouldn't be needed — 76 is exact)
- `ESC` - Exit

---

### `pitras1c.asm` - Active Display Phase Sync ✅

**Purpose:** Exact copy of pitras1b with only HBLANK sync polarity flipped (2-byte binary difference). Syncs PIT to FALLING edge of HBLANK instead of RISING.

**Key Finding:** Proves V6355D tolerates palette writes during active display. More visible jitter than pitras1b (expected — jitter occurs during visible scanline instead of blanking).

---

### `pitras1d.asm` - Half-Scanline PIT Mid-Scanline Split ❌ CRASHES

**Purpose:** Two colors per scanline via half-scanline PIT (count=38, two interrupts per scanline). Phase-toggle ISR: phase 0 writes rainbow during HBLANK, phase 1 writes blue mid-scanline.

**Result:** Crashes on real hardware. Multiple approaches tried (6 iterations):
- NOP delays between writes: diagonal jitter
- PORT_STATUS poll between palette writes: V6355D blinking
- PORT_STATUS poll before writes: reduced but still jittery
- Half-scanline PIT (count=38) with phase toggle: crash

**Key Discoveries:**
- Reading PORT_STATUS (0xDA) BETWEEN two palette writes causes V6355D blinking
- 31,400 IRQs/sec may overwhelm V40 or interact badly with V6355D bus timing
- Mid-scanline color changes remain an unsolved problem on the PC1

---

## Key Findings Summary

| Finding | Detail |
|---------|--------|
| PIT per-scanline timing | ✅ Works reliably at 76 ticks/scanline |
| **76 PIT ticks = exact scanline** | ✅ **CONFIRMED** — 75 drifts one way, 77 the other |
| **314 lines per frame** | ✅ **CONFIRMED** — 313 caused upward scroll |
| **Phase-locked clocks** | ✅ **PROVEN** — PIT free-runs forever, zero drift |
| Per-scanline stability (pitras1b) | ✅ **99%+ stable** — near-zero jitter |
| Multiple palette entries/scanline (pitras2) | ❌ Does not work |
| Mid-scanline color split (pitras3) | ❌ Does not work |
| Half-scanline PIT (count=38) | ❌ Crashes — pitras1d, 6 iterations all failed |
| PORT_STATUS between palette writes | ❌ Causes V6355D blinking — must not interleave status reads with palette I/O |
| DRAM refresh trick (8088MPH) | ❌ Not applicable — V40 has internal refresh, not PIT CH1-driven |
| V6355D HSYNC status bit | ❌ Not available — no readable horizontal sync reference |

**Conclusion:** PIT-driven raster effects on the PC1 are excellent for **per-scanline** color changes. pitras1b proves the phase-lock theory — PIT count 76 and frame total 314 are mathematically exact, and the raster is 99%+ stable with a one-time setup. Mid-scanline splits (two colors per scanline) do not work — pitras3 fails and pitras1d crashes. Future work focuses on maximizing the proven one-change-per-scanline approach to create Amiga copper-style visual effects.

---

## PIT Programming Reference

### PIT Ports

| Port | Name | Purpose |
|------|------|---------|
| 0x40 | PIT_CH0_DATA | Channel 0 data (IRQ0 timer) |
| 0x41 | PIT_CH1_DATA | Channel 1 data (DRAM refresh) |
| 0x42 | PIT_CH2_DATA | Channel 2 data (PC speaker) |
| 0x43 | PIT_COMMAND | Command/mode register |

### PIT Command Byte (port 0x43)

```
Bits 7-6: Channel select (00=CH0, 01=CH1, 10=CH2)
Bits 5-4: Access mode (01=LSB, 10=MSB, 11=LSB then MSB)
Bits 3-1: Operating mode (010=Mode 2 rate generator)
Bit 0:    Counting mode (0=binary)
```

### Example: Program PIT for Scanline Timing

```asm
; Command: Channel 0, lobyte/hibyte, mode 2, binary = 0x34
mov al, 0x34
out 0x43, al

; Count: 76 ticks = ~63.5 µs = 1 scanline
mov ax, 76
out 0x40, al        ; Low byte
mov al, ah
out 0x40, al        ; High byte
```

### Restoring BIOS Timer

```asm
; Command: Channel 0, lobyte/hibyte, mode 3, binary = 0x36
mov al, 0x36
out 0x43, al

; Count: 0 = 65536 = ~18.2 Hz (BIOS default)
xor al, al
out 0x40, al        ; Low byte
out 0x40, al        ; High byte
```

## Test Results

**Tested on real Olivetti Prodest PC1**

| Aspect | Polling Mode | PIT Mode |
|--------|--------------|----------|
| Left border jitter | Less jitter | Slightly more |
| Center/right jitter | More jitter | **Much less** |
| Overall smoothness | Visible jitter | **Smoother** |

**Conclusion:** PIT interrupt timing provides visibly smoother raster effects compared to HSYNC polling, especially in the center and right portions of the screen.

---

## Roadmap: Future PIT Demos

All future work builds on **pitras1b** — the proven one-change-per-scanline approach (99%+ stable, phase-locked to crystal). **No mid-scanline splits needed** — all effects below use ONE palette write per scanline.

### pitras2 — Animated Rainbow Scroll

**Visual:** Rainbow color bars scrolling smoothly down (or up) the screen.

**How:** Same pitras1b ISR, but shift the `color_table` read offset by 1-2 entries each frame during VBLANK. The rainbow pattern appears to flow vertically.

**Difficulty:** Trivial — pitras1b + a single ADD to the starting index per frame.

**Requires:** pitras1b only (one palette write per scanline).

**Research needed:** None — straightforward modification.

---

### pitras3 — Sinusoidal Color Gradient

**Visual:** Smooth pulsing color waves flowing down the screen, like looking through tinted water.

**How:** Pre-compute a 64-entry sine table. Each frame, recalculate `color_table[scanline] = sin(scanline + frame_offset)` mapped to R/G/B palette values. Frame offset advances each VBLANK.

**Difficulty:** Easy — sine lookup + per-frame table rewrite during VBLANK.

**Requires:** pitras1b only (one palette write per scanline).

**Research needed:**
- Sine table generation for 8086 ASM (integer approximation, 64 or 128 entries)
- RGB mapping: how to map sine values (0-255) to the V6355D 3-bit R, 3-bit G, 3-bit B palette format
- VBLANK budget: how many cycles available during VBLANK to rewrite 200 color_table entries (114 blank lines × 456 cycles = ~52,000 cycles — should be plenty)

---

### pitras4 — Copper Bars / Rainbow Serpents

**Visual:** Multiple colored bands (8-16 scanlines each) with smooth dark→bright→dark gradients, bouncing up and down at different speeds. Classic Amiga "copper bar" effect.

**How:** Each frame during VBLANK: fill `color_table` with background color, then "stamp" each bar's gradient at its current Y position. Multiple bars moving independently = rainbow serpents.

**Difficulty:** Medium — multiple bar positions + gradient stamping + bounce logic.

**Requires:** pitras1b only (one palette write per scanline).

**Research needed:**
- Bar gradient shape: pre-computed lookup table for dark→bright→dark intensity curve (triangular or gaussian)
- Bar overlap: what happens when two bars overlap? Options: additive blending (clamp to max), priority (front bar wins), or XOR
- Bounce physics: simple y_pos += y_speed; if y_pos > 200 or y_pos < 0: y_speed = -y_speed
- Performance: stamping 3-5 bars × 16 scanlines × 2 bytes = 160-320 bytes of writes per VBLANK — trivially fast

---

### Priority Order

| # | Demo | Effect | Prerequisite |
|---|------|--------|--------------|
| 2 | Animated scroll | Flowing rainbow | pitras1b (trivial mod) |
| 3 | Sine gradient | Pulsing color waves | pitras2 + sine table |
| 4 | Copper bars | Bouncing color bands | pitras3 + multi-bar |

Each demo builds incrementally on the previous. pitras2 is essentially pitras1b with one extra instruction.

---

## References

- Intel 8253/8254 PIT datasheet
- [8088 MPH: We Break All Your Emulators](https://trixter.oldskool.org/2015/04/07/8088-mph-we-break-all-your-emulators/) - Trixter
- [More 8088 MPH how it's done](http://www.reenigne.org/blog/more-8088-mph-how-its-done/) - reenigne

## Compilation

```powershell
nasm -f bin -o pitras1a.com pitras1a.asm
nasm -f bin -o pitras1b.com pitras1b.asm
copy pitras*.com a:
```

## Author
Retro Erik - 2026
