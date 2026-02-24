# PC1-Labs

Demo scene effects and hardware experiments for the **Olivetti Prodest PC1** — x86 assembly programs exploring the Yamaha V6355D video chip and NEC V40 CPU.

## Overview

A collection of educational assembly demos that push the Olivetti PC1 beyond its standard CGA capabilities. Topics include hardware sprite multiplexing, per-scanline palette manipulation, PIT-timed raster effects, CGA palette flipping, bitmap scrolling, Kefrens bars, and real-time 3D vector graphics — all running on the V6355D's hidden 160×200×16 graphics mode.

## Hardware Target

- **Machine:** Olivetti Prodest PC1
- **CPU:** NEC V40 (80186-compatible) @ 8 MHz
- **Video:** Yamaha V6355D (CGA-compatible + extended modes)
- **Video Mode:** 160×200×16 (hidden graphics mode), plus standard CGA modes
- **VRAM:** 16 KB at segment B000h, CGA-interlaced layout

## Demos

### 01-Using-Mouse-Sprite
Bouncing ball demos using the V6355D hardware sprite via Simone Riminucci's INT 33h mouse driver. Progresses from a single ball to frame-based multiplexing and direct hardware access.

- `BBall.asm` — Single bouncing ball (mouse driver)
- `BBalls1.asm` — 3 balls, frame-based multiplexing (mouse driver)
- `BBalls2.asm` — 3 balls, direct V6355D hardware access (no mouse driver)
- `BBalls3.asm` — Vsync-synchronized, one ball per frame cycling

Also includes [V6335D-Hardware-Sprite.md](demos/01-Using-Mouse-Sprite/V6335D-Hardware-Sprite.md) — hardware sprite documentation.

### 02-sprite-multiplexing
True raster-synchronized sprite multiplexing — 2 balls displayed simultaneously in one frame by chasing the CRT beam. No flicker.

- `BBalls4.asm` — Raster-sync multiplexing (2 balls, one frame)
- `BBalls5.asm` — Rainbow colors + XOR/solid blend modes
- `BBalls6.asm` — Spinning line animation (8 frames) + rainbow colors

### 03-port-color-rasters
Raster bar effects using PORT_COLOR (0x3D9) and palette RAM per-scanline color changes.

- `rbars1.asm` — Fast gradient via PORT_COLOR (with tearing)
- `rbars2.asm` — Pre-computed pattern (no tearing)
- `rbars3.asm` through `rbars7.asm` — Progressive techniques including CGA-compatible variants
- `rbars4_CGA.asm` — CGA-compatible version (runs on any IBM PC with CGA)

### 04-Bitmap-stuff
BMP image loading, raster bars over images, software and hardware scrolling techniques.

- `demo1.asm` through `demo4.asm` — Raster bars over BMP images
- `demo5a.asm` — Full-screen scrolling with sine-wave motion
- `demo5b - linear ram.asm` — Linear RAM scrolling
- `demo5c - fast interlaced RAM.asm` — Fast interlaced RAM scrolling
- `demo6.asm` — Partial-screen panning
- `demo7a.asm` / `demo7b.asm` — Hardware (CRTC R12/R13) and software viewport scrolling
- `demo8a.asm` through `demo8c.asm` — Circular buffer scrolling (160 bytes/frame)
- `demo9.asm` / `demo9b.asm` — R12/R13 effects (screen shake, wave, bounce, marquee)

### 05-palette-ram-rasters
Per-scanline palette RAM manipulation — changing RGB values during horizontal blanking to display up to 512 colors on screen simultaneously.

- `palram1.asm` — Basic static rainbow gradient
- `palram2.asm` through `palram6.asm` — Increasingly advanced palette techniques
- `colorbars.asm` — Color bar test pattern

### 06-pit-raster-timing
PIT (Programmable Interval Timer) based scanline timing for smoother raster effects than HSYNC polling.

- `pitclk.asm` — Clock speed measurement and discovery tool
- `pitras1.asm` through `pitras3.asm` — PIT interrupt raster effects (working)
- `pitras4.asm` / `pitras5.asm` — Cycle-counted experiments (8088MPH-style)

Includes [PC1-CLOCK-DISCOVERY.md](demos/06-pit-raster-timing/PC1-CLOCK-DISCOVERY.md) — clock speed findings.

### 07-cga-palette-flip
Per-scanline CGA palette switching — toggling between two CGA palettes every scanline to produce up to 512 colors per frame. Inspired by Simone's Monkey Island technique on the PC1.

- `cgaflip2.asm` through `cgaflip9.asm` — Progressive development from 8 colors to full 512-color streaming
- `cgaflip-diag.asm` through `cgaflip-diag4.asm` — Diagnostic/timing analysis tools

### 08-kefrens-bars
Kefrens bars effect — a classic demo scene technique.

- `KEFRENS.asm` through `KEFRENS4.asm` — Progressive Kefrens bar implementations

### 09-vector-gfx
Real-time 3D flat-shaded rotating pyramid with backface culling, painter's algorithm depth sorting, and zero-flicker scanline compositing.

- `PYRAMID.asm` — Flat-shaded rotating pyramid (~3.3 KB .COM file)

## Drivers

### Mouse Driver (Simone Riminucci)

INT 33h compatible mouse driver featuring hardware cursor via the V6355D sprite engine.

**Location:** `drivers/mouse/`

- `Mouse.asm` — Driver source (translated to English, hardware detection bypassed)
- `constant.inc` — Bit definitions and constants
- `mouse.com` — Compiled executable

**Building:**
```
nasm -f bin -o mouse.com Mouse.asm
```

**Running:**
```
mouse.com /I    (Skip hardware detection)
mouse.com /M    (Show cursor immediately)
```

See [drivers/mouse/README.md](drivers/mouse/README.md) for full documentation.

## Tools

Utility programs for testing and debugging V6355D behavior.

**Location:** `Tools/`

- `hpos.asm` / `hpos.com` — Horizontal position tester (Register 0x67)
- `timing.asm` / `timing.com` — HSYNC/VBLANK timing measurement
- `cga_scroll_test.asm` / `cga_scroll_test.com` — CGA CRTC R12/R13 hardware scroll test
- `V6355D_scroll_test.asm` / `V6355D_scroll_test.com` — Register 0x64 vertical adjust test
- `test_r12r13.asm` / `test_r12r13.com` — CRTC start address register test
- `reg65_test.asm` / `reg65_test.com` — Register 0x65 experiment
- `crtc_restarts_test.asm` / `crtc_restarts_test.com` — CRTC restart behavior test
- `flip-hidden-test.asm` / `fliptest.com` — Hidden mode flip test
- `test-ansi.asm` / `test-ansi.com` — ANSI escape code test
- `make_test_bmp.ps1` — PowerShell script to generate test BMP images
- `test_bands.bmp` / `test_vstripe.bmp` — Test images

See [Tools/README.md](Tools/README.md) for detailed documentation.

## Building

### Requirements
- [NASM](https://www.nasm.us/) (Netwide Assembler)
- Target: Olivetti Prodest PC1 with NEC V40 CPU
- DOS 2.1+

### Compile Example
```bash
cd demos/01-Using-Mouse-Sprite
nasm -f bin -o BBall.com BBall.asm
```

### Run on PC1
1. Load the mouse driver (if needed by the demo): `mouse.com /I`
2. Run the demo: `BBall.com`
3. Press ESC to exit

## Technical References

- [V6335D Hardware Sprite Documentation](demos/01-Using-Mouse-Sprite/V6335D-Hardware-Sprite.md)
- [PIT Clock Discovery](demos/06-pit-raster-timing/PC1-CLOCK-DISCOVERY.md)
- Each demo folder contains its own README with detailed technical notes
- Simone Riminucci's PC1 documentation and forums

## Author

Demos and project structure by RetroErik, 2026.

Mouse driver by Simone Riminucci, modified for hardware-free testing.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Pull requests welcome! Please follow the existing assembly style (NASM, 186 CPU target).
