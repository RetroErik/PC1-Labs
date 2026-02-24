# PC1 CPU Clock Discovery

## The Question

Is the Olivetti Prodest PC1's CPU clock derived from the same 14.31818 MHz crystal as the V6355D video controller, or does it use a separate oscillator?

This matters enormously for demo effects: if both clocks come from the same crystal, the CPU and pixel output are **phase-locked**, meaning cycle-counted code can target exact pixel positions on screen.

## Background

The Yamaha V6355D video controller receives a 14.31818 MHz master clock from an external crystal. Its datasheet describes a **DCK** (Divided Clock) output pin:

> **DCK** | O | Outputs external clock dividing signal of 14.31818 MHz. Usable for CPU clock by dividing.

This mirror the IBM PC/XT architecture where the 8284A clock generator divides the same 14.31818 MHz crystal by 3 to produce the 4.77 MHz CPU clock. That shared crystal is what makes 8088 MPH's pixel-exact beam racing possible on the IBM PC.

The PC1's Turbo mode was assumed to run at "8 MHz" based on marketing materials, but 14.31818 / N cannot produce 8.0 MHz for any integer N.

## The Measurement Tool: PITCLK

We built `PITCLK.COM`, a measurement tool that uses the PIT (Programmable Interval Timer) as a reference clock. The PIT runs at exactly 14.31818 MHz ÷ 12 = 1,193,182 Hz — derived from the same master crystal.

### Method

1. Program PIT channel 0 as a free-running counter (Mode 2, count 65536)
2. Run a calibrated CPU loop of known iteration count during VBLANK
3. Latch and read PIT before and after the loop
4. The PIT tick delta reveals the CPU/PIT clock ratio

If CPU = DCK / 2, then CPU/PIT = (14.31818/2) / (14.31818/12) = 12/2 = **6.0 exactly**  
If CPU = DCK / 3, then CPU/PIT = (14.31818/3) / (14.31818/12) = 12/3 = **4.0 exactly**  
If CPU = 8.0 MHz (independent), then CPU/PIT = 8.0 / 1.193 = **6.706...**

### Why VBLANK Matters

The V6355D steals bus cycles during active display to fetch VRAM data. Running the calibration loop during VBLANK avoids this contention. The tool also runs the same loop during active display to measure the bus stealing impact.

## Results

### Turbo Mode (how the PC1 boots by default)

| Measurement | Value |
|---|---|
| Frame period | 23,862 ticks (50 Hz PAL) |
| 100 scanlines | 7,602 ticks |
| Avg ticks/scanline | 76.02 |
| Scanlines/frame | 313 |
| **VBLANK loop (100 iter)** | **513 PIT ticks** |
| Display loop (100 iter) | 514 PIT ticks |
| Bus contention | 100% (no difference!) |
| **Best match** | **~7.16 MHz = DCK / 2 = PIXEL CLOCK** |

### Normal Mode (after TURBO /N)

| Measurement | Value |
|---|---|
| VBLANK loop (100 iter) | 905 PIT ticks |
| Display loop (100 iter) | 905 PIT ticks |
| Bus contention | 100% |
| **Best match** | **~4.77 MHz = DCK / 3** |

### CheckIt Benchmark (independent verification)

CheckIt's CPU Speed test reported: **V20, 7.03 MHz** in Turbo mode.

This is within CheckIt's measurement margin (it's calibrated against 8088 timings, not V40). 7.03 MHz is much closer to 7.159 MHz (DCK/2) than to 8.0 MHz.

## Conclusions

### 1. Both CPU Speeds Derive from the 14.31818 MHz Crystal

- **Normal mode: 14.31818 / 3 = 4.773 MHz** (matches IBM PC/XT exactly)
- **Turbo mode: 14.31818 / 2 = 7.159 MHz** (the pixel clock itself!)
- The "8 MHz" marketing claim is rounded up from 7.16 MHz

The Turbo switch (ports 0xFFF5, 0xFFF6, 0xFFF2) likely controls the DCK divider ratio on the motherboard, switching between ÷3 and ÷2.

### 2. In Turbo Mode: 1 CPU Cycle = 1 Pixel

In 320-pixel-wide CGA modes (including the hidden 160×200×16 mode):
- Pixel clock = 14.31818 / 2 = 7.159 MHz
- CPU clock = 14.31818 / 2 = 7.159 MHz
- **1 pixel = exactly 1 CPU cycle**
- **912 master clocks per scanline** (14.318 MHz)
- **456 CPU cycles per scanline** (7.159 MHz = master ÷ 2)
- **320 visible pixels + 136 blanking pixel-clocks = 456 total**

### 3. No V6355D Bus Contention on System RAM

The VBLANK vs active display tests show **identical timings** (100% ratio). This means:
- V6355D bus stealing affects only VRAM (segment B000h) access
- Code executing from system RAM runs at full speed regardless of beam position
- NOP delay loops in cycle-counted raster code are **deterministic**

### 4. PAL Timing: 312-313 Scanlines Per Frame

- 50 Hz vertical refresh (PAL standard)
- ~76 PIT ticks per scanline = 63.7 µs (standard CGA horizontal timing)
- 200 visible lines + ~112 blank lines = 312 total
- VBLANK duration: ~112 scanlines × 63.7 µs ≈ 7.1 ms

## Implications for Beam Racing

### What's Now Possible

With CPU and pixels phase-locked at 7.159 MHz:

1. **Cycle-counted delay = pixel-precise positioning**: A NOP takes 3 CPU cycles = moves the beam exactly 3 pixels. `DEC CX` = 2 pixels. `JNZ` = 4 pixels (taken).

2. **Deterministic raster effects**: Since system RAM execution has no bus contention, unrolled cycle-counted loops produce perfectly stable horizontal split positions.

3. **Exact scanline budgets**: Each scanline is exactly 456 CPU cycles. The scanline loop must total exactly 456 cycles for drift-free operation.

### Remaining Challenges

1. **Palette I/O port timing**: The `OUT` instructions to ports 0xDD/0xDE interact with the V6355D. These may have variable latency depending on V6355D internal state (palette write window).

2. **Initial sync precision**: The HSYNC polling loop that establishes the starting reference point still has ~4-13 cycle jitter (1 poll loop iteration). Once synced, cycle counting maintains alignment.

3. **V40 8-bit bus wait states**: At 7.16 MHz, DRAM access may insert wait states (bus cycle ~140 ns vs DRAM ~150 ns). This affects instruction fetch timing but is deterministic for a given instruction sequence.

## How This Relates to 8088 MPH

Reenigne's 8088 MPH on the IBM PC/XT also relies on CPU/pixel phase-locking:
- IBM PC: 14.31818 / 3 = 4.77 MHz CPU, same crystal as CGA → phase-locked
- PC1 Turbo: 14.31818 / 2 = 7.16 MHz CPU, same crystal as V6355D → phase-locked

The key difference: on the IBM PC, DRAM refresh (via PIT channel 1 and DMA) steals bus cycles at semi-deterministic intervals, which reenigne solved by reprogramming PIT CH1 to exactly 76 ticks (1 scanline). On the PC1, the NEC V40 handles DRAM refresh internally — and our measurements show it does NOT cause timing variation for system RAM instruction execution.

**The PC1 may actually be EASIER to beam-race than the IBM PC** because we don't need the DRAM refresh trick at all.

## Reference: Clock Tree

```
14.31818 MHz Crystal
    │
    ├── V6355D Master Clock Input
    │   ├── ÷ 2 → 7.159 MHz pixel clock (320-wide modes)
    │   ├── ÷ 1 → 14.318 MHz pixel clock (640-wide modes)
    │   └── DCK output pin → motherboard clock MUX
    │
    ├── DCK ÷ 2 → 7.159 MHz CPU clock (Turbo mode)
    │
    ├── DCK ÷ 3 → 4.773 MHz CPU clock (Normal mode)
    │
    └── ÷ 12 → 1.193 MHz PIT clock
```

## Files

| File | Description |
|---|---|
| `pitclk.asm` | CPU frequency measurement tool (v3). Runs calibrated loops during VBLANK and active display, measures PIT tick deltas, determines CPU/pixel clock relationship. |
| `pitclk.com` | Compiled binary — run on real PC1 hardware |
