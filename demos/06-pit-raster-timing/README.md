# PIT Interrupt Raster Timing - Olivetti PC1

Experimental demonstrations of **PIT (Programmable Interval Timer) based scanline timing** on the Olivetti PC1 with Yamaha V6355D video controller.

This is **Method 3** from our raster timing experiments:

1. PORT_COLOR (0x3D9): 1 OUT per scanline, 16 palette indices. ✓ Tested in 03-port-color-rasters
2. Palette RAM (0x3DD/0x3DE): 3 OUTs per scanline, RGB333 (512 colors). ✓ Tested in 05-palette-ram-rasters
3. **PIT interrupt raster (this folder)**: Timer IRQs schedule scanline updates
4. CGA palette flip (0x3D8): Toggle between CGA palettes mid-scanline. (Not yet tested)

## Hardware Target
- **Machine:** Olivetti Prodest PC1
- **CPU:** NEC V40 (80186 compatible) @ 8 MHz
- **Video Controller:** Yamaha V6355D
- **Timer:** Intel 8253/8254 PIT (Programmable Interval Timer)

## The Problem with Polling

In our previous demos (palram1-6), we used **HSYNC polling** to synchronize palette writes:

```asm
.wait_low:
    in al, dx           ; Read status port
    test al, 0x01       ; Test HSYNC bit
    jnz .wait_low       ; Loop while HIGH

.wait_high:
    in al, dx           ; Read status port  
    test al, 0x01       ; Test HSYNC bit
    jz .wait_high       ; Loop while LOW
```

**Problem:** This polling loop introduces **4-8 pixels of horizontal jitter** because we might catch the HSYNC transition at any point in the loop. This is unavoidable with polling.

## The PIT Solution

The Intel 8253/8254 PIT can generate interrupts at precise intervals. By programming it to fire **once per scanline**, we get jitter-free palette updates:

### PIT Timing Theory

| Constant | Value | Notes |
|----------|-------|-------|
| PIT Clock | 1,193,182 Hz | 14.31818 MHz ÷ 12 |
| PIT Tick | ~0.838 µs | 1 / 1,193,182 |
| Scanline Duration | ~63.5 µs | CGA horizontal timing |
| **PIT Count/Scanline** | **76 ticks** | 63.5 / 0.838 ≈ 76 |

By programming PIT Channel 0 with count=76, we get IRQ0 every scanline!

### How pitras1.asm Works

1. **Save original IRQ0 vector** (INT 08h) at startup
2. **Wait for VBLANK** to synchronize with frame start
3. **Install custom IRQ0 handler** that writes palette entry 0
4. **Program PIT** for 76-tick intervals (mode 2, rate generator)
5. **ISR fires 200 times** (once per scanline), each time:
   - Writes new color to palette entry 0
   - Increments scanline counter
   - Sends EOI to PIC
6. **After 200 scanlines**: Set frame_done flag
7. **Restore original PIT** (mode 3, count 65536 = ~18.2 Hz BIOS timer)
8. **Restore original IRQ0** vector

## Files

### `pitras1.asm` - PIT-Timed Palette Updates
**Purpose:** Replace HSYNC polling with timer-driven interrupts
- **Complexity:** Advanced (~620 lines)
- **Features:**
  - Custom IRQ0 handler for per-scanline palette writes
  - Toggle between PIT mode and polling mode (for comparison)
  - Adjustable PIT count (use +/- keys to tune timing)
  - Full rainbow gradient (200 colors)
- **Learning focus:** PIT programming, interrupt handling, jitter-free timing

**Controls:**
- `P` - Toggle PIT mode vs HSYNC polling mode
- `+` / `=` - Increase PIT count (bars drift down)
- `-` - Decrease PIT count (bars drift up)
- `V` - Toggle VSYNC waiting
- `ESC` - Exit to DOS

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
Bits 7-6: Channel select
  00 = Channel 0 (IRQ0, system timer)
  01 = Channel 1 (DRAM refresh)
  10 = Channel 2 (PC speaker)
  11 = Read-back command (8254 only)

Bits 5-4: Access mode
  00 = Latch count value
  01 = Low byte only
  10 = High byte only
  11 = Low byte, then high byte

Bits 3-1: Operating mode
  000 = Mode 0 (interrupt on terminal count)
  001 = Mode 1 (hardware retriggerable one-shot)
  010 = Mode 2 (rate generator) ← Use this for scanline timing
  011 = Mode 3 (square wave generator) ← BIOS default
  100 = Mode 4 (software triggered strobe)
  101 = Mode 5 (hardware triggered strobe)

Bit 0: Counting mode
  0 = Binary (16-bit)
  1 = BCD (4-digit)
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

## I/O Port Speed Optimization

**Short port addresses (≤ 255) are faster** because they use smaller instruction encoding:

### Short vs Long Address Encoding

| Port | Instruction | Bytes | Cycles | Example |
|------|-------------|-------|--------|---------|
| ≤ 255 | `out 0xDD, al` | 2 | ~8 | Palette ports (0xDD, 0xDE) |
| > 255 | `mov dx, 0x3DD` + `out dx, al` | 4 | ~12 | Standard CGA form |

**Savings:** ~4 cycles per OUT instruction

### When It Matters

| Scenario | OUTs/frame | Savings | Worth it? |
|----------|------------|---------|-----------|
| This demo (pitras1) | 600+ | ~2400 cycles | **YES** |
| Bitmap scroller | ~5 | ~20 cycles | No |

### PC1 Port Aliases

| Long Address | Short Alias | Purpose |
|--------------|-------------|---------|
| 0x3D8 | 0xD8 | Mode control |
| 0x3D9 | 0xD9 | Color select |
| 0x3DA | 0xDA | Status register |
| 0x3DD | 0xDD | Palette address |
| 0x3DE | 0xDE | Palette data |

**pitras1.asm uses short addresses** (0xD8, 0xDD, 0xDE) for the palette ports that are written inside the ISR.

## Comparison: Polling vs PIT

| Aspect | HSYNC Polling | PIT Interrupts |
|--------|---------------|----------------|
| Horizontal jitter | 4-8 pixels | **0 pixels** (if tuned) |
| CPU usage | 100% (busy-wait) | ~20% (wait + ISR) |
| Complexity | Simple | More complex |
| Tuning required | No | Yes (PIT count) |
| Works on CGA | Yes | Yes |
| Works on V6355D | Yes | Unknown (testing!) |

## Compilation & Testing

### Compile:
```powershell
nasm -f bin -o pitras1.com pitras1.asm
```

### Copy to floppy:
```powershell
copy pitras1.com a:
```

### Run on PC1:
```
A:\pitras1.com
```

### Tuning the PIT Count

If the raster bars drift up or down on your hardware:
- Press `+` to increase count (bars drift down, then stabilize)
- Press `-` to decrease count (bars drift up, then stabilize)

The theoretical value is 76, but your specific hardware may need 75-77 due to clock drift between PIT and video controller.

## Research Status

This is an **experimental demo**. We're investigating whether PIT-based timing works better than polling on the Yamaha V6355D. Results will be documented here after testing on real hardware.

## References

- Intel 8253/8254 PIT datasheet
- 8088MPH demo (Hornet + CRTC + Trixter) - pioneered PIT raster timing on CGA
- Area 5150 demo - advanced CGA raster effects
- Kefrens bars effect - classic Amiga technique adapted for PC

## Author
Retro Erik - 2026

---

**Note:** PIT-based raster timing is an advanced technique that requires careful coordination between timer interrupts and video hardware. This demo explores whether it's practical on the Yamaha V6355D.
