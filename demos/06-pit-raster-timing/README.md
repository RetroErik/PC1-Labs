# PIT Interrupt Raster Timing - Olivetti PC1

Demonstrations of **PIT (Programmable Interval Timer) based scanline timing** on the Olivetti PC1 with Yamaha V6355D video controller.

## What This Folder Provides

This folder tests using **PIT interrupts** instead of **HSYNC polling** for per-scanline palette updates. The PIT method provides smoother, more consistent timing.

| Demo | Technique | Status |
|------|-----------|--------|
| pitras1 | PIT interrupt, 1 color/scanline | ✅ WORKS |
| pitras2 | PIT interrupt, multi-entry/scanline | ✅ WORKS |
| pitras3 | PIT interrupt, mid-scanline color split | ✅ WORKS (with jitter) |
| pitras4 | Cycle-counted loop, no ISR (8088MPH style) | 🧪 EXPERIMENT |
| pitras5 | HSYNC-synced cycle-counted + deferred palette | 🧪 EXPERIMENT |

**Key Finding:** PIT interrupts provide smoother raster effects than HSYNC polling, especially in the center and right portions of the screen. Mid-scanline palette changes are possible but jitter ~4-8 pixels due to V6355D bus contention.

**Goal of pitras4/5:** Achieve **pixel-precise** mid-scanline color changes by eliminating ISR overhead jitter. Inspired by reenigne's 8088 MPH cycle-counting techniques.

## Related Work

- **05-palette-ram-rasters/palram1-6** - Per-scanline palette changes using polling
- **05-palette-ram-rasters/palram5** - Mid-scanline color changes (multiple writes per scanline)

For mid-scanline experiments (changing color WITHIN the visible scanline), see **palram5.asm** which documents that technique with findings about 4-8 pixel jitter.

## Hardware Target

- **Machine:** Olivetti Prodest PC1
- **CPU:** NEC V40 (80186 compatible) @ 8 MHz
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
| **PIT Count/Scanline** | **76 ticks** | 63.5 / 0.838 ≈ 76 |

## Files

### `pitras1.asm` - PIT-Timed Palette Updates ✅

**Purpose:** Replace HSYNC polling with timer-driven interrupts for per-scanline palette updates.

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

### `pitras2.asm` - Multiple Palette Entries per Scanline ✅

**Purpose:** Test updating multiple palette entries during each PIT ISR.

**Status:** Successfully updates up to 8 palette entries per scanline.

**Controls:**
- `1-8` - Select number of palette entries to update per scanline
- `ESC` - Exit

---

### `pitras3.asm` - Mid-Scanline Color Split ✅ (with jitter)

**Purpose:** Prove that PIT interrupts can produce **two different colors on a single scanline** by changing palette entry 0 mid-scanline.

**How it works:**
1. PIT Channel 0 fires IRQ0 once per scanline (~76 ticks)
2. ISR writes BLUE (R=0,G=0,B=7) to palette entry 0
3. Variable NOP+LOOP delay burns CPU cycles while the CRT beam scans right
4. ISR writes RED (R=7,G=0,B=0) to palette entry 0
5. Left portion of scanline renders blue, right portion renders red

**Result:** Two colors clearly visible on same scanlines. The split point is controllable via the NOP delay. However, the boundary jitters ~4-8 pixels per frame.

**Why the jitter?**
- The Yamaha V6355D steals bus cycles unpredictably to fetch VRAM, causing the NOP delay to vary by a few cycles per scanline
- No hardware HSYNC status bit is available on the V6355D for precise synchronization
- The 8088MPH DRAM refresh trick (PIT CH1: 18→19 ticks) does **not** apply — the NEC V40 has integrated refresh logic, not PIT-driven refresh
- Pixel-stable splits would require reverse-engineering the V6355D bus access pattern

**Controls:**
- `Left/Right` - NOP delay ±1 (fine tune split position)
- `+/-` - NOP delay ±10 (coarse adjustment)
- `.` / `,` - PIT count ±1 (tune scanline interval)
- `ESC` - Exit

---

### `pitras4.asm` - Cycle-Counted Mid-Scanline Split (No ISR) 🧪

**Purpose:** Eliminate ISR overhead jitter by replacing PIT interrupts with a
tight cycle-counted main loop. Inspired by reenigne's 8088 MPH Kefrens bars technique.

**How it works:**
1. Wait for VBLANK (sync to top of frame)
2. CLI — interrupts off for entire frame
3. For each of 200 scanlines:
   - Wait for HSYNC HIGH (sync to scanline start)
   - Write BLUE to palette entry 0 (3 OUTs)
   - Cycle-counted NOP delay → targets specific pixel column
   - Write RED to palette entry 0 (3 OUTs)
   - Pad NOPs to fill rest of scanline (~509 CPU cycles total)
4. STI

**Why this should be better than pitras3:**
- No ISR push/pop/iret overhead (~40 cycles of jitter eliminated)
- HSYNC poll jitter affects vertical position uniformly, not the split point
- Split point is purely determined by cycle count from HSYNC edge

**Controls:**
- `Left/Right` - Split delay ±1 (fine tune pixel position)
- `+/-` - Split delay ±10 (coarse)
- `Up/Down` - Pad ±1 (tune total scanline time)
- `ESC` - Exit

---

### `pitras5.asm` - HSYNC-Synced + Deferred Palette 🧪

**Purpose:** Same cycle-counted approach as pitras4, but adds a **close/open palette
protocol** to minimize V6355D disruption during the visible area.

**How it works:**
Same as pitras4, except Color A is written with a full open-write-close
cycle during HBLANK (safe), then Color B is written mid-scanline with
another open-write-close (may cause brief V6355D glitch).

**Test modes** (press M to cycle):
- **Mode A:** Blue/Red (high contrast for measuring jitter)
- **Mode B:** Black/White (maximum luminance contrast)
- **Mode C:** Gradient (different colors per scanline)

**Controls:**
- `Left/Right` - Split delay ±1
- `+/-` - Split delay ±10
- `Up/Down` - Pad ±1
- `M` - Cycle test modes
- `ESC` - Exit

---

## Key Findings Summary

| Finding | Detail |
|---------|--------|
| PIT per-scanline timing | ✅ Works reliably at 76 ticks/scanline |
| Multiple palette entries/scanline | ✅ Up to 8 entries per ISR (pitras2) |
| Mid-scanline color split | ✅ Proven — two colors visible on same line |
| Pixel-stable mid-scanline (PIT ISR) | ❌ Not achievable — ISR overhead + V6355D bus contention = ~4-8px jitter |
| Cycle-counted loop (no ISR) | 🧪 pitras4/5 — eliminates ISR jitter, V6355D contention remains |
| DRAM refresh trick (8088MPH) | ❌ Not applicable — V40 has internal refresh, not PIT CH1-driven |
| V6355D HSYNC status bit | ❌ Not available — no readable horizontal sync reference |

**Conclusion:** PIT-driven raster effects on the PC1 are excellent for per-scanline color changes (pitras1/2). Mid-scanline splits work visually but cannot achieve pixel-level stability without hardware-level V6355D knowledge. pitras4/5 test whether eliminating ISR overhead via cycle-counting (reenigne's approach) reduces jitter to an acceptable level for pixel-targeted color changes.

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

## References

- Intel 8253/8254 PIT datasheet
- [8088 MPH: We Break All Your Emulators](https://trixter.oldskool.org/2015/04/07/8088-mph-we-break-all-your-emulators/) - Trixter
- [More 8088 MPH how it's done](http://www.reenigne.org/blog/more-8088-mph-how-its-done/) - reenigne

## Compilation

```powershell
nasm -f bin -o pitras1.com pitras1.asm
nasm -f bin -o pitras2.com pitras2.asm
nasm -f bin -o pitras3.com pitras3.asm
copy pitras*.com a:
```

## Author
Retro Erik - 2026
