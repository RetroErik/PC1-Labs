# PC1 Sprite Demo

V6355D sprite programming examples for the Olivetti PC1—hardware-accelerated animation demos in x86 assembly.

## Overview

This repository contains a collection of assembly language programs demonstrating the capabilities of the Yamaha V6355D video chip's built-in hardware sprite engine on the Olivetti PC1 computer. The sprite can be positioned independently of VRAM, enabling smooth animations without blitting overhead.

## Hardware Features

The V6355D sprite engine provides:
- **16×16 monochrome sprite** with AND/XOR masking
- **Hardware positioning** via dedicated CPU ports (3DDh, 3DEh)
- **Works in any video mode** (text or graphics) using a virtual 640×200 coordinate space
- **Color control** via attribute register (64h) for transparency, inversion, and effects
- **No CPU cycles** needed for blitting—the chip handles composition during raster scan

## Projects

### 01-Bouncing-Ball
A simple bouncing ball demo using the sprite engine with BIOS timer synchronization (~18 Hz).

**Files:**
- `demos/01-bouncing-ball/BB.asm` - Bouncing ball source code

**Requirements:**
- `mouse.com` (Simone's INT 33h driver) loaded first

**Usage:**
```
mouse.com /I
BB.com
```
Press ESC to exit.

### 02-Sprite-Multiplexing
Multiple bouncing balls using sprite multiplexing techniques.

**Files:**
- `demos/02-sprite-multiplexing/BBalls1.asm` through `BBalls6.asm` - Progressive multiplexing demos

### 03-Raster-Bars
Raster bar effects using palette manipulation and border color changes.

**Files:**
- `demos/03-raster-bars/rbars1.asm` through `rbars4.asm` - Raster bar demos
- `demos/03-raster-bars/rbars-border.asm` - Border-only raster bars
- `demos/03-raster-bars/rbars-full.asm` - Full-screen raster bars
- `demos/03-raster-bars/timing.asm` - Timing test utility

### 04-Demos
General graphics demos showcasing the hidden 160×200×16 mode.

**Files:**
- `demos/04-Demos/demo1.asm` through `demo6.asm` - Various graphics demos
- `demos/04-Demos/demo5 - linear ram.asm` - Linear RAM access demo
- `demos/04-Demos/demo5 - non linear ram.asm` - Non-linear RAM demo

## Drivers

### Mouse Driver (Simone Riminucci)
The INT 33h mouse driver by Simone Riminucci, modified to skip hardware detection.

**Location:** `drivers/mouse/`

**Files:**
- `Mouse.asm` - Driver source (modified version, hardware detection bypassed)
- `constant.inc` - Bit definitions and constants

**Features:**
- INT 33h compatibility (Microsoft mouse driver API)
- Hardware cursor via V6355D sprite engine
- Button input via 8042 keyboard controller
- ~2 KB resident memory footprint

**Building:**
```
nasm -f bin -o mouse.com Mouse.asm
```

**Running:**
```
mouse.com /I    (Skip hardware detection)
mouse.com /M    (Show cursor immediately)
```

## Tools

Utility programs for testing and development.

**Location:** `Tools/`

**Files:**
- `hpos.asm` / `hpos.com` - Horizontal position test utility
- `make_test_bmp.ps1` - PowerShell script to generate test BMP images
- `test_bands.bmp`, `test_vstripe.bmp` - Test images

## Building

### Requirements
- NASM (Netwide Assembler)
- Target: Olivetti PC1 with NEC V40 CPU
- DOS 2.1+

### Compile
```bash
cd demos/01-bouncing-ball
nasm -f bin -o BB.com BB.asm
```

### Run on PC1
1. Load the mouse driver first
2. Run the demo

## Technical Details

See [docs/V6335D-Hardware-Sprite.md](docs/V6335D-Hardware-Sprite.md) for sprite-specific documentation.

For comprehensive V6355D chip documentation, see [V6355D-Technical-Reference.md](../V6355D-Technical-Reference.md).

## References

- [Yamaha V6355D Datasheet](docs/)
- Simone Riminucci's PC1 documentation and forums

## Author

Original demos and project structure by RetroErik, 2026.

Mouse driver by Simone Riminucci, modified for hardware-free testing.

## License

See [LICENSE](LICENSE) file.

## Contributing

Pull requests welcome! Please follow the existing assembly style (NASM 186 CPU target).
