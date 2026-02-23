# 09 - Vector Graphics: Flat-Shaded Rotating Pyramid

Real-time 3D flat-shaded rotating pyramid running on the Olivetti Prodest PC1's hidden 160x200x16 graphics mode.

**Status: Working on real hardware.** Smooth rotation, zero flicker, clean exit to DOS.

## Screenshot

A 4-sided pyramid rotates continuously around the Y axis with a fixed 31-degree X tilt, showing red, green, blue, and cyan faces with correct backface culling and painter's algorithm depth sorting.

## Hardware

- **CPU:** NEC V40 @ 8 MHz (80186-compatible, IMUL/IDIV instructions)
- **Video:** Yamaha V6355D, hidden 160x200x16 mode at segment B000h
- **VRAM:** 16 KB, CGA-interlaced (even rows at +0000h, odd rows at +2000h)
- **Palette:** 16 colors from 512 (RGB333), programmed via V6355D registers
- **Timing:** PAL/50Hz, ~160,000 CPU cycles per frame

## Build

Requires [NASM](https://www.nasm.us/):

```
nasm PYRAMID.asm -f bin -o PYRAMID.com
```

Output is a standalone DOS .COM file (~3.3 KB).

## Controls

- **ESC** - Exit to DOS

## Technical Details

### 3D Pipeline

1. **Transform:** Y-axis rotation + fixed X-axis tilt using 8.8 fixed-point IMUL math, with perspective projection (focal length 256, Z offset 300)
2. **Backface culling:** 2D cross product in screen space (CCW winding, Y-down coordinate system)
3. **Depth sort:** Painter's algorithm - bubble sort visible faces by average Z (back-to-front)
4. **Render:** Scanline compositor (see below)

### Scanline Compositor (Zero-Flicker Rendering)

The key innovation for flicker-free rendering on a single-buffer 16 KB VRAM system:

1. For each Y row in the bounding box:
   - Clear an 80-byte RAM scanline buffer to black
   - Composite all visible face spans onto the buffer (painter's order)
   - Blast the completed buffer to VRAM via `rep movsw` (40 words)

Each VRAM row is written **exactly once** with the final composited pixel values. There is never an intermediate black state visible to the CRT beam, eliminating all flicker.

### Fixed-Point Math

- **3D rotation:** 8.8 fixed-point (256-entry sine table, range -256 to +256)
- **Edge tracking:** 10.6 fixed-point (integer range -512 to +511, safe for 160px width)
- **Slope calculation:** Unsigned MUL/DIV with manual sign tracking and overflow clamping to prevent INT 0 divide faults on nearly-horizontal edges

### Performance

- **Estimated CPU usage:** ~45% of frame time
  - Transform + backface cull: ~2,400 cycles
  - Edge precomputation: ~750 cycles
  - Scanline compositor: ~69,000 cycles (~130 rows)
  - Total active: ~72,000 out of 160,000 cycles per frame
- **Frame rate:** Locked to 50 Hz (PAL VBlank sync)

### Data Tables

- **Sine table:** 256 entries x 2 bytes = 512 bytes
- **yTable:** 200 entries x 2 bytes = 400 bytes (CGA-interlaced row offsets)
- **Vertices:** 5 vertices (apex + 4 base corners), signed 16-bit X/Y/Z
- **Faces:** 4 triangular faces with CCW winding and color index

## Development History

Iterative development with testing on real PC1 hardware:

1. Initial implementation with 8.8 fixed-point edge tracking caused horizontal spikes (overflow at X > 127). Fixed by switching to 10.6 fixed-point.
2. Full-screen clear caused heavy flicker (32K cycles of VRAM writes during active display). Several approaches attempted:
   - Bounding-box clear: reduced but didn't eliminate flicker
   - Erase-then-redraw: still visible flicker from two VRAM write passes
   - **Scanline compositor: zero flicker** (final solution)
3. Exit palette restoration added - INT 10h mode 3 does not reprogram V6355D palette registers, so default CGA colors must be explicitly restored.

## Author

By Retro Erik - 2026
