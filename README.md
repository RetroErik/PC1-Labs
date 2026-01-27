# PC1 Sprite Demo

V6335D sprite programming examples for the Olivetti PC1—hardware-accelerated animation demos in x86 assembly.

## Overview

This repository contains a collection of assembly language programs demonstrating the capabilities of the Yamaha V6335D video chip's built-in hardware sprite engine on the Olivetti PC1 computer. The sprite can be positioned independently of VRAM, enabling smooth animations without blitting overhead.

## Hardware Features

The V6335D sprite engine provides:
- **16×16 monochrome sprite** with AND/XOR masking
- **Hardware positioning** via dedicated CPU ports (3DDh, 3DEh)
- **Works in any video mode** (text or graphics) using a virtual 640×200 coordinate space
- **Color control** via attribute register (64h) for transparency, inversion, and effects
- **No CPU cycles** needed for blitting—the chip handles composition during raster scan

## Projects

### 01-Bouncing-Ball
A simple bouncing ball demo using the sprite engine with BIOS timer synchronization (~18 Hz).

**Files:**
- `BB.asm` - Bouncing ball source code
- `BB.com` - Compiled executable

**Requirements:**
- `mouse.com` (Simone's INT 33h driver) loaded first

**Usage:**
```
mouse.com /I
BB.com
```
Press ESC to exit.

## Drivers

### Mouse Driver (Simone Riminucci)
The INT 33h mouse driver by Simone Riminucci, modified to skip hardware detection.

**Files:**
- `Mouse.asm` - Driver source (modified version, hardware detection bypassed)
- `constant.inc` - Bit definitions and constants
- `mouse.com` - Compiled executable

**Features:**
- INT 33h compatibility (Microsoft mouse driver API)
- Hardware cursor via V6335D sprite engine
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

See [docs/V6335D-Hardware-Sprite.md](docs/V6335D-Hardware-Sprite.md) for:
- V6335D register reference
- Sprite positioning and masking
- Color/attribute register details
- Advanced techniques (multiplexing, plasma effects, etc.)

## References

- [Z-180 PC1 Manual - 6355 LCDC](docs/)
- [Yamaha V6335D Datasheet](docs/)
- Simone Riminucci's PC1 documentation and forums

## Future Demos

Planned additions:
- Sprite multiplexing (multiple objects per frame)
- Plasma ball effect (color cycling)
- Sprite shape animation
- Starfield effect
- More complex physics demos

## Author

Original bouncing ball demo and project structure by RetroErik, 2026.

Mouse driver by Simone Riminucci, modified for hardware-free testing.

## License

See [LICENSE](LICENSE) file.

## Contributing

Pull requests welcome! Please follow the existing assembly style (NASM 186 CPU target).
