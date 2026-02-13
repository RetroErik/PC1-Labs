; ============================================================================
; CGAFLIP1.ASM - CGA Palette Flip (Method 4)
; ============================================================================
;
; EDUCATIONAL DEMONSTRATION: Per-Scanline CGA Palette Switching
;
; This method writes to the CGA Mode Control register (0x3D8) during HBLANK to
; flip between the two CGA palettes and intensity states per scanline. It is
; a single OUT per line and works on standard CGA hardware.
;
; NOTE: This file is a starter template. Update the render path to write the
; per-line 0x3D8 values that drive the palette flips as the implementation
; evolves.
;
; Written for NASM assembler
; Target: Olivetti Prodest PC1 with Yamaha V6355D video controller
; CPU: NEC V40 (80186 compatible) @ 8 MHz
;
; By Retro Erik - 2026

; ** The plan is to test 4 method. We have tested method 1 and 2
;   1. PORT_COLOR (0x3D9): 1 OUT per scanline, 16 palette indices (fast, limited). Tested in 03-port-color-rasters
;   2. Palette RAM (0x3DD/0x3DE): 3 OUTs per scanline, RGB333 (512 colors). Tested in 05-palette-ram-rasters
;   3. PIT interrupt raster (8088MPH/Area5150): timer IRQs schedule mid-scanline updates.
; **  4. CGA palette flip (0x3D8): toggle between the two CGA palettes mid-scanline.
;
; DISTINGUISHES THIS VERSION:
;   - Single OUT to 0x3D8 per scanline (palette/intensity flip)
;   - Standard CGA-compatible technique
;
; ============================================================================
; HARDWARE BACKGROUND
; ============================================================================
;
; The Yamaha V6355D is an unusual CGA-compatible video controller that has
; a hidden 16-color mode at 160x200 resolution. Unlike standard CGA which
; has fixed palettes, this chip has programmable RGB palette entries.
;
; PALETTE FORMAT: RGB333 (3 bits per channel = 512 possible colors)
;   - First byte:  R (bits 2-0 = red intensity 0-7)
;   - Second byte: G<<4 | B (high nibble = green, low nibble = blue)
;
; The trick: CRT monitors draw the screen line-by-line, left to right.
; Between each line there's a brief "horizontal blanking" period when the
; electron beam returns to the left side. If we change the palette during
; this blanking period, each scanline can have a different color!
;
; ============================================================================
; THE TECHNIQUE
; ============================================================================
;
; Palette updates are synchronized to the HSYNC edge each scanline.
;
; 1. Fill entire screen with color index 0 (appears black initially)
; 2. Wait for VBLANK (start of frame) to synchronize
; 3. For each of the 200 scanlines:
;    a. Wait for HSYNC (horizontal blanking period)
;    b. Quickly write new RGB values to palette entry 0
;    c. The scanline draws with this new color
; 4. Result: 200 different colors on screen simultaneously!
;
; TIMING IS CRITICAL: We have only ~10 microseconds during HBLANK to write
; 3 bytes to the palette. On the 8 MHz V40, that's about 80 cycles.
; Our 3 OUT instructions take ~30 cycles - just enough time!
;
; NOTE: A full scanline is ~63.5 µs (~509 cycles), but only HBLANK (~80 cycles)
; is safe for palette writes. Writing during the visible portion causes tearing.
; For glitch-free results: max ~6-8 OUTs per scanline (during HBLANK only).

[BITS 16]
[ORG 0x100]

