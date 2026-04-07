# Mouse Driver (Simone Riminucci)

INT 33h compatible mouse driver for the Olivetti PC1, featuring hardware cursor rendering via the V6335D sprite engine.

## Overview

This is Simone Riminucci's PC1 mouse driver, translated to English and modified to skip physical hardware detection, allowing it to load without a connected mouse.

**Original:** v0.97 (2016-2017)  
**Modified:** 2026 (detection bypass, documentation)

## Features

- **INT 33h API** - Microsoft-compatible mouse driver interface
- **Hardware sprite cursor** - V6335D chip renders the pointer (no software blitting)
- **Button tracking** - Left and right mouse button state, press/release counts, positions
- **Motion tracking** - Reads Mickey counters from CRTC registers
- **Keyboard integration** - Buttons delivered as special keyboard scancodes (77h, 78h, 79h)
- **Text & graphics mode** - Works in any video mode
- **Tiny footprint** - ~2 KB resident memory

## Files

- `Mouse.asm` - Driver source code (NEC V40 CPU, 186+ instructions)
- `constant.inc` - Bit definitions (BIT0-BIT7, NULL)
- `mouse.com` - Compiled executable

## Building

### Requirements
- NASM (Netwide Assembler)
- DOS 2.1+

### Compile
```bash
nasm -f bin -o mouse.com Mouse.asm
```

## Running

```bash
mouse.com [/flags]
```

### Flags

- `/I` - Skip PC1 hardware detection (allows loading without mouse)
- `/M` - Show cursor immediately in DOS
- `/F` - Force installation over existing driver
- `/E` - Force EGA/VGA patch installation

**Example (no mouse, show cursor):**
```bash
mouse.com /I /M
```

## INT 33h API Reference

Supported functions:

| Function | Description |
|----------|-------------|
| **00h** | Reset/Query driver presence (returns AX=0xFFFF) |
| **01h** | Show pointer |
| **02h** | Hide pointer |
| **03h** | Query position & button status |
| **04h** | Move pointer to X, Y |
| **05h** | Query button press count (LB=0, RB=1) |
| **06h** | Query button release count |
| **07h** | Set horizontal range (CX=min, DX=max) |
| **08h** | Set vertical range (CX=min, DX=max) |
| **09h** | Set graphic pointer shape (ES:DX=mask, BX/CX=hotspot) |
| **0Ah** | Set text pointer color attribute (BL=0xFF, CL=attribute) |
| **0Bh** | Query last motion distance |
| **0Ch** | Set event handler |
| **0Fh** | Set pointer speed (CX=H ratio, DX=V ratio) |
| **11h** | Get number of buttons (returns AX=0x33, BX=2) - PC1 specific |
| **13h** | Set max speed doubling threshold |
| **14h** | Exchange event handler |

### Example: Show Cursor

```asm
mov ax, 01h    ; Function 01h
int 33h        ; Call driver
```

### Example: Move Pointer

```asm
mov ax, 04h    ; Function 04h
mov cx, 320    ; X position
mov dx, 100    ; Y position
int 33h
```

## Sprite Details

The driver uses the V6335D sprite engine:
- **Size**: 16×16 pixels
- **Coordinates**: 640×200 virtual space
- **Masking**: AND/XOR monochrome with color attribute (register 64h)
- **Ports**: 3DDh (control), 3DEh (data), 0DDh/0DEh (shape upload)

## Mouse Port Compatibility

The PC1's DE-9 mouse port uses a unique pinout that is **not compatible** with Amstrad or Atari ST mice without a passive adapter cable:

| PC1 Pin | PC1 expects  | Amstrad mouse sends | Atari ST mouse sends | Atari joystick sends |
|---------|-------------|--------------------|--------------------|---------------------|
| 1       | Right button | XA                 | XB                 | Up (switch)         |
| 2       | Left button  | XB                 | XA                 | Down (switch)       |
| 3       | XA           | YA                 | YA                 | Left (switch)       |
| 4       | YB           | YB ✓               | YB ✓               | Right (switch)      |
| 6       | YA           | Left button        | Left button        | Fire (switch)       |
| 7       | XB           | +5V                | +5V                | +5V                 |
| 9       | ENA (low)    | Right button       | Right button       | n/c (floats high)   |

Neither the Amstrad nor Atari ST mouse will work directly — quadrature signals land on button pins and vice versa, and pin 9 (ENA) receives a button signal instead of ground. A passive rewiring adapter is the simplest solution.

When pin 9 floats (joystick connected), the 8042 keyboard controller reads the switch states and generates arrow key and Space scan codes.

## Hardware Detection (Bypassed)

The original driver checks:
1. BIOS ROM at 0F000h:FFFDh for PC1 signatures
2. V6335D chip response at port 0D1h
3. 8042 keyboard controller configuration for mouse button scancodes

**Current version** skips the keyboard controller test, allowing the driver to install without hardware.

## Modifications Made

**Changes from original:**
- `call set_mouse_keyb` commented out in `cont0:` section
- Forced `mov al, 01h` to bypass hardware verification
- English translations in error messages and string labels
- Added header comment documenting modifications

**Preserved:**
- All original INT 33h functions
- Sprite rendering logic
- Motion/button handling
- Event handler system

## References

- Simone Riminucci's original source code and documentation
- Z-180 PC1 Manual (6355 LCDC section)
- Yamaha V6335D Video Controller datasheet

## License

Original driver by Simone Riminucci (2016-2017).  
Modifications and documentation by RetroErik (2026).

See [../../../LICENSE](../../../LICENSE) for details.

---

## YouTube

For more retro computing content, visit my YouTube channel **Retro Hardware and Software**:
[https://www.youtube.com/@RetroErik](https://www.youtube.com/@RetroErik)
