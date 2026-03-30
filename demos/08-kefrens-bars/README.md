# 08 - Kefrens Bars

Classic Kefrens-style raster bar experiments for the Olivetti Prodest PC1 using the Yamaha V6355D hidden 160x200x16 mode.

By **Retro Erik** — [YouTube: Retro Hardware and Software](https://www.youtube.com/@RetroErik)

![Olivetti Prodest PC1](https://img.shields.io/badge/Platform-Olivetti%20Prodest%20PC1-blue)
![License](https://img.shields.io/badge/License-CC%20BY--NC%204.0-green)

## Overview

This folder explores multiple versions of the Kefrens bars effect, inspired by Amiga/PC demo scene techniques and 8088mph-style motion.

Core ideas used across versions:
- Per-frame drawing of vertical bar columns with persistent trails
- Sine-driven horizontal offsets per scanline for wavy bar shapes
- Copper-like color gradients using the PC1 V6355D palette
- Optional raster background via PORT_COLOR on color 0 background pixels

## Hardware Target

- **Machine:** Olivetti Prodest PC1
- **CPU:** NEC V40 (80186-compatible) @ 8 MHz
- **Video Controller:** Yamaha V6355D
- **Video Mode:** Hidden 160x200x16 graphics mode
- **VRAM:** 16KB at segment B000h, CGA-interlaced layout

## Files

### `KEFRENS.asm` - Base Kefrens Bars
- Original working version
- Draws one vertical column per frame
- Sine-based undulating bars with persistent trail buildup

### `KEFRENS2.asm` - Kefrens + Raster Background
- Adds PORT_COLOR per-scanline raster background behind bars
- Uses 3 summed sine waves for more organic bar motion
- Raster shows through where VRAM pixels remain color 0

### `KEFRENS3.asm` - Refined Combined Version
- Combined Kefrens bars + raster background architecture
- 3-wave morphing motion with synchronized frame flow
- Alternative implementation path for V6355D setup and timing

### `KEFRENS3B.asm` - Variant Build
- Additional iteration of the KEFRENS3 approach
- Kept for comparison/testing

### `KEFRENS4.asm` - Minimal-Delta 3-Wave Upgrade
- Starts from proven `KEFRENS.asm`
- Replaces single-wave X calculation with summed 3-wave positioning
- Keeps most of v1 logic unchanged while improving motion richness

## Screenshot

<p>
<em>Kefrens bars running on real Olivetti Prodest PC1 hardware</em><br>
<img src="kefrens.png" width="60%" alt="Kefrens bars on Olivetti Prodest PC1">
</p>

## Build

Requires [NASM](https://www.nasm.us/):

```powershell
nasm -f bin -o KEFRENS.com KEFRENS.asm
nasm -f bin -o KEFRENS2.com KEFRENS2.asm
nasm -f bin -o KEFRENS3.com KEFRENS3.asm
nasm -f bin -o KEFRENS3B.com KEFRENS3B.asm
nasm -f bin -o KEFRENS4.com KEFRENS4.asm
```

## Run

Copy the COM files to DOS media and run, for example:

```dos
A:\KEFRENS.COM
A:\KEFRENS2.COM
```

## Controls

- **ESC** - Exit to DOS

## License

This project is licensed under **CC BY-NC 4.0**.

Copyright (C) 2026 Retro Erik

---

## YouTube

For more retro computing content, visit my YouTube channel **Retro Hardware and Software**:
[https://www.youtube.com/@RetroErik](https://www.youtube.com/@RetroErik)
