# Raster Bars Demos - Olivetti PC1

Educational demonstrations of raster bar techniques on the Olivetti PC1 with Yamaha V6355D video controller.

## Hardware Target
- **Machine:** Olivetti PC1
- **CPU:** NEC V40 (80186 compatible) @ 8 MHz
- **Video Controller:** Yamaha V6355D
- **Video Mode:** CGA 160x200x16 (Hidden graphics mode) and ordinary CGA modes - because changing color per scanline.
- **Compatibility note:** If you change the demo resolution from 160x200 to a standard CGA mode (for example 320x200 mode 0x04) and avoid palette RAM writes, the code will run on any IBM PC with CGA.

## Overview

Raster bars are a classic demo scene effect where different colors appear on different horizontal scanlines, creating the illusion of bars scrolling or changing colors smoothly. This requires **per-scanline color changes timed to the video display**.

The V6355D provides two main mechanisms:

### 1. **PORT_COLOR (0x3D9)** - Fast but limited
- 1 OUT instruction per scanline
- Pick from 16 palette colors
- Only affects background/overscan, not drawn graphics
- Fast: limited by CPU time, not I/O

### 2. **Palette RAM (0x3DD/0x3DE)** - Slower but powerful
- 3 OUT instructions per scanline (select + R + G|B)
- Direct RGB control: 512 colors (8×8×8 RGB)
- Affects all graphics using that palette index
- Can change multiple palette entries per scanline

## Files

### `rbars1.asm` - Fast Gradient (PORT_COLOR, with tearing)
**Technique:** PORT_COLOR with direct color calculation
- **Speed:** Very fast - only 1 OUT per scanline
- **Colors:** 16 palette colors
- **Feature:** Uses fast AND-based math instead of slow DIV
  - `BAR_SPACING = 64` (power of 2) → `color = (scanline AND 0xC0) >> 6` = 0-3
- **Issue:** Visible tearing because color calculation happens AFTER HSYNC edge
  - Workaround: Pre-compute colors (see rbars2)
- **Learning point:** Demonstrates timing constraints and tearing artifacts

### `rbars2.asm` - Pre-computed Pattern (PORT_COLOR, no tearing)
**Technique:** Pre-computed color lookup table, scrolls the pattern
- **Speed:** Fast - 1 OUT per scanline
- **Colors:** 16 palette colors
- **Advantage:** No tearing - all calculations pre-computed during VBLANK
- **Method:** Compute color pattern once, then use modulo arithmetic to scroll it
- **Learning point:** How to avoid tearing by pre-computing during vertical retrace

### `rbars3.asm - rbars7.asm` - Various Techniques
Different variations and optimizations of PORT_COLOR approach.

### `rbars4.asm` - PC1 Hidden Mode (160x200x16)
**Technique:** PORT_COLOR in the PC1's hidden 160x200x16 mode
- **Mode:** Hidden graphics mode 0x4A (Olivetti PC1 specific)
- **Colors:** 16 palette colors via V6355D
- **Feature:** Uses PC1-specific register unlocking (0x40 to PORT_REG_ADDR)
- **Learning point:** PC1's hidden mode and V6355D-specific setup

### `rbars4_CGA.asm` - Standard CGA Mode (320x200)
**Technique:** PORT_COLOR in standard CGA mode 0x04
- **Mode:** Standard CGA 320x200 graphics (works on any CGA system!)
- **Colors:** 16 CGA color indices
- **Key Finding:** Proves PORT_COLOR per-scanline changes work in standard CGA modes
- **Portability:** This technique is universal to all CGA-compatible hardware
- **Learning point:** Raster bars are not PC1-specific — they work on standard CGA

### Palette RAM Demos - MOVED
**Palette RAM demonstrations have been moved to `05-palette-ram-rasters/` folder**

These demos demonstrate per-scanline Palette RAM manipulation to display 512 colors:
- `palram1.asm` - Basic version (417 lines, single gradient)
- `palram2.asm` - Intermediate (622 lines, 6 palette modes)
- `palram3.asm` - Advanced/Reference (925 lines, H/V SYNC controls)

**See [../05-palette-ram-rasters/README.md](../05-palette-ram-rasters/README.md) for details.**

## Compilation & Testing

### Compile all demos:
```powershell
nasm -f bin -o rbars1.com rbars1.asm
nasm -f bin -o rbars2.com rbars2.asm
nasm -f bin -o rbars4.com rbars4.asm
nasm -f bin -o rbars4_CGA.com rbars4_CGA.asm
nasm -f bin -o rbarsram.com rbarsram.asm
# ... etc for rbars3-7
```

### Run on PC1:
Copy .COM files to floppy and boot PC1, or:
```
A:\rbars1.com
A:\rbars2.com
A:\rbarsram.com
```

## Controls (all demos)

| Key | Action |
|-----|--------|
| **H** | Toggle HSYNC wait on/off (free-running vs synchronized) |
| **ESC** | Exit to DOS |

## Mode Compatibility

The per-scanline color change technique works in **multiple CGA graphics modes** on the PC1:

| Mode | Resolution | Colors | PORT_COLOR | Notes |
|------|-----------|--------|-----------|-------|
| **160×200×16** | 160×200 | 16 palette colors | ✅ Yes | PC1 hidden mode (0x4A) - rbars4.asm |
| **320×200×4** | 320×200 | 4 colors (2 palettes) | ✅ Yes | Standard CGA mode (0x04) - rbars4_CGA.asm |
| **640×200×2** | 640×200 | 2 colors (monochrome) | ✅ Likely | Standard CGA/EGA mode (0x06) - untested but should work |
| **320×200×16** | 320×200 | 16 palette colors | ✅ Likely | Tandy/PC1 hidden mode - compatible timing with 320×200×4 |

**Key insight:** The horizontal sync pulse timing is consistent across CGA modes. Per-scanline color changes via PORT_COLOR (or palette switching) should work in any CGA-compatible mode, as they depend on I/O port timing, not the video mode specifics.

**Timing remains the same:** All CGA modes use the same display clock (14.31818 MHz pixel clock / 2), so the ~509 cycles per scanline figure holds for all modes.

---

## Technical Details

### Video Ports (Yamaha V6355D)

The V6355D responds to both standard CGA 0x3D* ports and the 0xD* aliases. This README uses 0x3D* for CGA compatibility; 0xD* is equivalent on the PC1.

| Port | Name | Purpose |
|------|------|---------|
| 0x3D8 | MODE | Video mode control (0x4A = 160×200×16 graphics) |
| 0x3D9 | COLOR | Set overscan/background color (bits 0-3 = palette entry) |
| 0x3DA | STATUS | Bit 0 = HSYNC (1=in retrace), Bit 3 = VBLANK |
| 0x3DD | PAL_ADDR | Palette address (0x40-0x4F = palette entries 0-15) |
| 0x3DE | PAL_DATA | Palette data (write R, then G\|B) |

### Timing Constraints

At 8 MHz (NEC V40), per scanline:
- **Total cycles:** ~509 cycles per scanline
- **Active display:** ~320 cycles
- **Horizontal retrace:** ~189 cycles

**Critical timing issue:** ~15 instructions of delay between HSYNC edge and when color output takes effect. This is why rbars1 shows tearing (calculates color after HSYNC) while rbars2 (pre-computed) doesn't.

## Learning Progression

1. **Start with rbars1** - Understand the basic PORT_COLOR technique and why tearing happens
2. **Try rbars2** - See how pre-computing eliminates tearing
3. **Explore rbars3-7** - Various optimizations and variations
4. **Advanced:** See `05-palette-ram-rasters/` folder for Palette RAM technique demos

## Educational Notes

### Why Raster Bars?
- Requires precise timing synchronization with display hardware
- Demonstrates I/O port programming and real-time constraints
- Shows optimization trade-offs (speed vs quality, calculation vs pre-computation)
- Classic effect that teaches hardware interaction

### Key Insights
- **Timing matters:** Hardware-level effects require cycle-accurate timing
- **Tearing is real:** Color changes must happen during retrace, not active display
- **Trade-offs:** PORT_COLOR is fast but limited; see `05-palette-ram-rasters/` for more powerful techniques
- **Creativity:** Limited hardware sparked incredible creative effects in the demo scene

## References

- V6355D Technical Reference (in Documentation folder)
- Demo scene raster bar techniques
- Amiga graphics programming concepts

## Author
Retro Erik - 2026

---

**Note:** These demos are educational. They demonstrate fundamental concepts in real-time graphics programming and hardware interaction on retro systems. The V6355D is a fascinating piece of hardware that enabled creative visual effects with limited resources.