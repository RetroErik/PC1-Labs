# Scanline Palette Demos - Olivetti PC1

Educational demonstrations of per-scanline **Palette RAM manipulation** on the Olivetti PC1 with Yamaha V6355D video controller.

The plan is to test 4 method. We have tested method 1 and 2
  1. PORT_COLOR (0x3D9): 1 OUT per scanline, 16 palette indices (fast, limited). Tested in 03-port-color-rasters. Works on standard CGA.
  2. Palette RAM (0x3DD/0x3DE): 3 OUTs per scanline, RGB333 (512 colors). - Tested in 05-palette-ram-rasters. V6355D-only.
 **  3. PIT interrupt raster (8088MPH/Area5150): timer IRQs schedule mid-scanline updates. Works on standard CGA as a timing method.
 **  4. CGA palette flip (0x3D8): toggle between the two CGA palettes mid-scanline. Works on standard CGA.

## Hardware Target
- **Machine:** Olivetti Prodest PC1
- **CPU:** NEC V40 (80186 compatible) @ 8 MHz
- **Video Controller:** Yamaha V6355D
- **Video Mode:** CGA 160x200x16 (Hidden graphics mode)
- **Compatibility note:** If you change the demo resolution from 160x200 to a standard CGA mode (for example 320x200 mode 0x04) and avoid palette RAM writes, the code will run on any IBM PC with CGA.

## Overview

This folder contains demonstrations of a powerful technique: **changing the video palette during the horizontal blanking interval** to achieve more colors than the hardware normally allows.

The key insight: Instead of being limited to 16 simultaneous colors (standard CGA), the V6355D allows you to change the RGB values of any palette entry 16 times per frame (once per scanline). This means you can display **up to 512 different colors on screen simultaneously** by changing what each palette index "looks like" on every line.

### How It Works

1. Fill the entire screen with palette index 0 (all pixels the same color)
2. During the horizontal blanking interval of each scanline:
   - Write new RGB values to palette entry 0
   - The next scanline draws with this new color
3. Result: 200 unique colors (one per scanline)

**Similar to:**
- Amiga Copper (temporal palette manipulation)
- Amiga HAM mode (breaking color limitations)
- C64 FLI mode (per-scanline effects)

## Files

### `palram1.asm` - Basic Implementation
**Purpose:** Learn the core technique with minimal code
- **Complexity:** Simple and clean (~417 lines)
- **Features:**
  - Single static color gradient (rainbow)
  - Optional animation (SPACE bar to toggle)
  - Demonstrates the fundamental per-scanline palette write pattern
- **Learning focus:** Understand the basic hardware interaction
- **Good for:** Getting started, understanding the timing constraints

**Controls:**
- `SPACE` - Toggle animation on/off
- `ESC` - Exit to DOS

### `palram2.asm` - Multiple Palette Modes
**Purpose:** Explore different gradient effects and patterns
- **Complexity:** Intermediate (~622 lines)
- **Features:**
  - 6 selectable palette modes (press 1-6):
    1. Rainbow + Grayscale
    2. RGB Cube Snake (uses all 200 unique colors from 512)
    3. Warm Sunset Gradient
    4. Cool Ocean Gradient
    5. Fire Gradient
    6. Grayscale (black to white to black)
  - Keyboard selection between modes
- **Learning focus:** Explore different color spaces and gradient techniques
- **Good for:** Understanding color gradients, seeing variations on the technique

**Controls:**
- `1-6` - Select palette mode
- `ESC` - Exit to DOS

### `palram3.asm` - Advanced Reference Implementation
**Purpose:** Comprehensive demo with advanced controls and detailed documentation
- **Complexity:** Advanced (~925 lines)
- **Features:**
  - 7 palette modes (includes "Full Rainbow" in addition to palram2's 6)
  - **H** key - Toggle HSYNC synchronization (see what happens without it!)
  - **V** key - Toggle VSYNC synchronization (causes scrolling effect when disabled)
  - Extensive hardware documentation and timing analysis
  - Detailed comments explaining the "why" behind the technique
- **Learning focus:** Understand timing constraints, experimentation tools
- **Good for:** Understanding hardware synchronization, debugging, reference material

**Controls:**
- `1-7` - Select palette mode
- `H` - Toggle HSYNC wait (on/off)
- `V` - Toggle VSYNC wait (on/off)
- `ESC` - Exit to DOS

### `palram4.asm` - Optimized Single Palette
**Purpose:** Production-ready version with minimal code
- **Complexity:** Simple (~556 lines - optimized from 932)
- **Features:**
  - Single rainbow palette (full spectrum)
  - Clean, commented code for reuse in projects
  - Toggle HSYNC/VSYNC for experimentation
  - Minimal overhead
- **Learning focus:** How to implement the technique efficiently
- **Good for:** Template for your own projects, performance reference

**Controls:**
- `H` - Toggle HSYNC wait
- `V` - Toggle VSYNC wait
- `ESC` - Exit to DOS

### `palram5.asm` - **NEW!** Multiple Writes Per Scanline Experiment
**Purpose:** RESEARCH DEMO - How many color changes per scanline are possible?
- **Complexity:** Experimental (~410 lines)
- **Features:**
  - Writes palette entry 0 **multiple times** during EACH scanline
  - Creates horizontal color stripes (not vertical gradients)
  - Live control: increase/decrease writes per scanline
  - Demonstrates timing limits and polling jitter
  - Extensively documented with research findings
- **Learning focus:** Understand horizontal timing, CPU cycle budgets, polling vs interrupts
- **Good for:** Understanding the technical limits of the V6355D, advanced timing experiments

**Research Findings Documented:**
- Polling introduces 4-8 pixel horizontal jitter (normal and unavoidable)
- Maximum ~15-20 palette writes fit in one scanline period
- Excessive delays cause scanline skipping (200 lines → 68 lines visible)
- Explains why timer-based techniques (8088mph, Area 5150) use PIT interrupts instead

**Controls:**
- `.` (period) - Increase writes per scanline
- `,` (comma) - Decrease writes per scanline
- `H` - Toggle HSYNC wait (compare synchronized vs unsynchronized)
- `V` - Toggle VSYNC wait
- `ESC` - Exit to DOS

### `palram6.asm` - **NEW!** Multi-Color Raster Bar Experiment
**Purpose:** RESEARCH DEMO - Can we change multiple palette entries per HBLANK?
- **Complexity:** Experimental (~600 lines)
- **Features:**
  - Displays 16 vertical color bars (colors 0-15)
  - Attempts to change palette entry 0 each scanline during HBLANK
  - Tests whether multiple entries can be changed per scanline
  - Extensively documented with hardware behavior findings
- **Learning focus:** Understanding V6355D palette pipeline limitations
- **Good for:** Understanding why multi-color rasters are limited on V6355D

**Critical Findings Documented:**
- **Maximum 1 palette entry per HBLANK** - Only entry 0 can be cleanly changed
- **Writing 2 entries causes corruption** - Entry 1 shows visible artifacts
- **"Bleed" effect discovered** - Adjacent palette entries are affected during writes
- **Delays make it WORSE** - Adding delays before 0x80 close increases bleed
- **Immediate close is best** - Close palette mode immediately after last data byte
- **No direct entry selection** - V6355D streams from entry 0, cannot select arbitrary entries

**Optimizations That Helped:**
- Move `mov dx, PORT_STATUS` outside loop (saves ~800 cycles)
- Remove delay after 0x40 address select (saves ~3000 cycles)
- Close palette immediately (no delay before 0x80)

**Controls:**
- Any key - Exit to DOS

### `palram7.asm` - **NEW!** BMP Image with Palette RAM Raster Bars
**Purpose:** Combine BMP image loading with palette RAM raster bars
- **Complexity:** Intermediate (~1000 lines)
- **Features:**
  - Loads a 4-bit BMP image and displays it
  - Two animated raster bars using **palette RAM** instead of PORT_COLOR
  - Bars bounce with sine-wave motion and swap depth when crossing (3D effect)
  - Raster bars "shine through" wherever the image has color 0 (background) pixels
  - Colors 1-15 from the BMP palette remain unaffected
  - RGB333 gradient colors (red bar + cyan bar)
  - **Skip-if-same optimization:** only writes palette on scanlines where color changes (~30 of 200)
  - **OUTSB burst writes:** 186-mode OUTSB for ~60 cycle HBLANK critical path
  - C64-style border color cycling during image loading
- **Learning focus:** Combining bitmap display with per-scanline palette manipulation
- **Good for:** Understanding how palette RAM rasters interact with actual image data

**Key Differences from PORT_COLOR raster bars (demo1.asm in 04-Bitmap-stuff):**
- PORT_COLOR only affects the border/overscan area — palette RAM changes what color 0 actually looks like
- Palette RAM bars affect all color 0 pixels in the active display area
- 4 OUTs per scanline (open + R + G|B + close) instead of 1, but fits in HBLANK
- RGB333 gives 512 possible colors vs 16 palette indices

**vs demo1b.asm (04-Bitmap-stuff):** Both use palette RAM + skip-if-same + OUTSB. The difference is the scanline table format: demo1b stores a 1-byte palette index per scanline and does a runtime LUT lookup to get the RGB pair, while palram7 stores the 2-byte R,G|B pair directly — no lookup needed at render time, at the cost of 200 extra bytes of RAM.

**Controls:**
- Any key - Exit to DOS

**Usage:**
```
PALRAM7 image.bmp
```

## Why Palette RAM Instead of PORT_COLOR?

The V6355D offers two raster bar techniques:

| Feature | PORT_COLOR (0x3D9) | Palette RAM (0x3DD/0x3DE) |
|---------|------------------|------------------------|
| Speed | 1 OUT per scanline | 3 OUTs per scanline |
| Colors | 16 palette colors | 512 RGB colors |
| Affects | Background only | All graphics (sprites, text, etc.) |
| Flexibility | Pick from 16 | Direct RGB control |
| Entries per HBLANK | N/A (index only) | **1 entry only** (see palram6 findings) |

**Palette RAM is more powerful** - you get direct RGB control and affect drawn graphics, not just background. The trade-off is 3 I/O operations instead of 1.

**Important limitation:** While theoretically you could change multiple palette entries per HBLANK (~80 cycles = ~11 OUTs), the V6355D palette pipeline causes adjacent entry corruption. Testing in palram6 confirmed only **1 palette entry can be cleanly changed per HBLANK**.

## Palette RAM Technical Details

### Write Sequence (3 OUTs)
```
1. OUT 0x3DD, 0x40       ; Select palette entry 0 (0x40-0x4F for entries 0-15)
2. OUT 0x3DE, R          ; Red intensity (bits 0-2 = 0-7)
3. OUT 0x3DE, G|B        ; Green (bits 4-6) | Blue (bits 0-2)
```

### RGB333 Format
Each palette entry is 2 bytes:
- **Byte 1 (Red):** bits 0-2 = intensity (0-7)
- **Byte 2 (Green|Blue):** bits 4-6 = green (0-7), bits 0-2 = blue (0-7)

Example: Bright red = `0x07, 0x00` (R=7, G=0, B=0)

### Timing Constraints
At 8 MHz (NEC V40), per scanline:
- **Total:** ~509 cycles per scanline
- **Safe window (HBLANK):** ~80 cycles
- **3 OUT instructions:** ~30 cycles ✓ (fits comfortably)
- **7 OUTs (2 entries):** ~49 cycles (fits timing, but corrupts entry 1!)
- **48 OUTs (all 16):** Too slow, causes artifacts

**Important:** Timing is NOT the only constraint. The V6355D palette pipeline limits you to **1 entry per HBLANK** regardless of available cycles. Writing 2+ entries causes visible corruption on adjacent entries (see palram6 findings).

## Compilation & Testing

### Compile all demos:
```powershell
nasm -f bin -o palram1.com palram1.asm
nasm -f bin -o palram2.com palram2.asm
nasm -f bin -o palram3.com palram3.asm
nasm -f bin -o palram4.com palram4.asm
nasm -f bin -o palram5.com palram5.asm
nasm -f bin -o palram6.com palram6.asm
nasm -f bin -o palram7.com palram7.asm
```

### Copy to floppy:
```powershell
copy palram*.com a:
```

### Run on PC1:
```
A:\palram1.com
A:\palram2.com
A:\palram3.com
A:\palram4.com
A:\palram5.com
A:\palram6.com
A:\palram7 image.bmp
```

## Learning Progression

1. **Start with `palram1.asm`** - Understand the basic per-scanline write pattern
2. **Try `palram2.asm`** - Explore different gradient techniques
3. **Study `palram3.asm`** - Learn about timing constraints and synchronization
4. **Use `palram4.asm`** - See clean, optimized implementation for your projects
5. **Experiment with `palram5.asm`** - Explore horizontal timing limits and advanced techniques
6. **Study `palram6.asm`** - Understand why multi-color rasters are limited to 1 entry per HBLANK
7. **Try `palram7.asm`** - See palette RAM rasters combined with BMP image display

## Educational Insights

### Why This Technique?
- Demonstrates **temporal** graphics programming (changes over time, not space)
- Requires understanding of video synchronization (HSYNC/VSYNC)
- Shows creative hardware exploitation to overcome limitations
- Teaches real-time constraints and tight timing windows

### Key Learnings
1. **Timing is critical** - You have only ~80 cycles during horizontal blanking (vertical changes) or ~400 cycles per full scanline (horizontal changes)
2. **Synchronization matters** - You must wait for HBLANK, or visual tearing occurs
3. **Direct hardware access** - I/O ports give you low-level control
4. **Creative limitations breed innovation** - 16 colors → 512 through clever timing
5. **Polling vs Interrupts** - V6355D requires polling HSYNC, introducing unavoidable jitter. Timer interrupt methods (8088mph, Area 5150, Kefrens) use PIT to achieve zero-jitter scanline sync on CGA.
6. **Palette pipeline limits multi-color rasters** - V6355D can only cleanly change 1 palette entry per HBLANK. Writing 2+ entries causes visible corruption on adjacent entries due to internal palette pipeline behavior.

### Advanced Timing Techniques
**Polling Method (used in these demos):**
- Read status port (0x3DA) to detect HSYNC transitions
- Simple to implement, works on V6355D
- 4-8 pixel horizontal jitter due to polling loop latency
- Good enough for most effects

**Timer Interrupt Method (8088mph, Area 5150, Kefrens):**
- Program PIT (8253 chip, ports 0x40-0x43) to generate IRQ0 at scanline frequency
- Example: `writePIT16 0, 2, 76*262` = ~59.923Hz with 262 scanlines
- ISR (Interrupt Service Routine) writes palette with zero jitter
- Requires precise timer calibration to match CRT timing
- Not verified to work on V6355D (may have different timing than CGA)

### Comparison: Retro Color-Breaking Techniques
- **PC1 Palette RAM:** Per-scanline temporal manipulation (clean gradients, 512 colors)
- **Amiga Copper:** Per-scanline spatial manipulation (hardware blitter instructions)
- **Amiga HAM:** Per-pixel color selection (4096 colors with artifacts)
- **C64 FLI:** Per-scanline trickery (tricks character mode)
- **Apple II Hi-Res:** Clever bit placement (monochrome to colors)

Each system had different constraints, so each developed unique techniques!

## Video Ports Reference

The V6355D responds to both standard CGA 0x3D* ports and the 0xD* aliases. This README uses 0x3D* for CGA compatibility; 0xD* is equivalent on the PC1.

| Port | Name | Purpose |
|------|------|---------|
| 0x3D8 | MODE | Video mode control (0x4A = 160×200×16 graphics) |
| 0x3D9 | COLOR | Set background color (bits 0-3 = palette entry) |
| 0x3DA | STATUS | Bit 0 = HSYNC (1=in retrace), Bit 3 = VBLANK |
| 0x3DD | PAL_ADDR | Palette address (0x40-0x4F for entries 0-15) |
| 0x3DE | PAL_DATA | Palette data (write R, then G\|B) |

## I/O Port Speed Optimization (Short vs Long Addresses)

On 8088/8086/V40 CPUs, **using port addresses ≤ 255 is faster** because of smaller instruction encoding:

### Why Short Port Addresses Are Faster

**Port ≤ 255 (e.g., 0xDD):**
```asm
out 0xDD, al    ; 2 bytes: E6 DD (immediate byte)
                ; ~8 cycles on 8088/V40
```

**Port > 255 (e.g., 0x3DD):**
```asm
mov dx, 0x3DD   ; 3 bytes: BA DD 03 (~4 cycles)
out dx, al      ; 1 byte: EE (~8 cycles)
                ; Total: 4 bytes, ~12+ cycles
```

**Savings per OUT:** ~4 cycles

### When Does It Matter?

| Scenario | OUTs/frame | Savings | Worth it? |
|----------|------------|---------|-----------|
| Raster effects (palram1-6) | 600+ (200 × 3 OUTs) | ~2400 cycles | **YES** |
| Bitmap scroller (demo8) | ~5 (one-time setup) | ~20 cycles | No |
| Sound playback loops | Thousands | Significant | **YES** |

**Rule of thumb:** Use short addresses (0xD8, 0xD9, 0xDD, 0xDE) in tight loops that run every scanline or frame. For one-time setup code, it doesn't matter.

### PC1 Port Aliases

On the Olivetti PC1, the Yamaha V6355D responds to both address ranges:

| Long Address | Short Alias | Purpose |
|--------------|-------------|---------|
| 0x3D8 | 0xD8 | Mode control |
| 0x3D9 | 0xD9 | Color select |
| 0x3DA | 0xDA | Status register |
| 0x3DD | 0xDD | Palette address |
| 0x3DE | 0xDE | Palette data |

**Important:** 0x3DA (status port) is often kept at 0x3DA for CGA compatibility with other demos, but in tight timing-critical loops, 0xDA works identically and saves cycles.

### Optimizations Applied in palram6.asm

1. **Use short port addresses** (0xDD, 0xDE instead of 0x3DD, 0x3DE)
2. **Move `mov dx, PORT_STATUS` outside loop** — saves ~800 cycles/frame
3. **Remove unnecessary delays** — saves ~3000 cycles/frame
4. **Total savings: ~3800 cycles/frame**

## References

- V6355D Technical Reference (in Documentation folder)
- Retro Erik's analysis of Yamaha V6355D capabilities
- Demo scene techniques (raster effects, color manipulation)
- Classic retro graphics programming

## Author
Retro Erik - 2026

---

**Note:** These demos are educational tools for learning about real-time graphics programming, hardware synchronization, and creative exploitation of limited hardware constraints. The Yamaha V6355D is a fascinating video controller that enables sophisticated visual effects through clever timing!
