# PC1 Sprite Demo - Tools

Utility programs for testing and debugging V6355D video chip behavior on the Olivetti PC1.

## Tools

### hpos.asm - Horizontal Position Tester

An interactive utility for testing V6355D Register 0x67 (Configuration Mode Register) which controls horizontal display position.

**Files:**
- `hpos.asm` - Assembly source code
- `hpos.com` - Compiled executable

**Usage:**
```
hpos.com
```
- **LEFT/RIGHT arrows** - Adjust horizontal position value
- **Q or ESC** - Quit

**Key Findings:**
- Bits 0-4 control horizontal display position adjustment (-7 to +8 dots) in CRT mode
- Value `0x18` (24) = maximum rightward shift (optimal, used by PERITEL.COM)
- Values above 24 cause the screen to wrap/shift left
- Values below 24 shift the screen left off-screen

**Important Discovery:**
When initializing graphics mode, avoid using BIOS INT 10h as it resets V6355D registers and overwrites PERITEL's horizontal position setting. Instead, write directly to the CGA mode register at port `0x3D8`:

```asm
mov al, 0x4A      ; Bit 6=1 (160x200 mode), Bit 3=1 (enable), Bit 1=1 (graphics)
mov dx, 0x3D8
out dx, al
```

**Building:**
```bash
nasm -f bin hpos.asm -o hpos.com
```

---

### make_test_bmp.ps1 - Test Image Generator

A PowerShell script that creates test BMP files for V6355D raster bar testing. Generates 160×200 4-bit BMP images.

**Generated Files:**
- `test_bands.bmp` - Horizontal bands (alternating black/colored rows)
- `test_vstripe.bmp` - Vertical split (left half black, right half colored)

**Usage:**
```powershell
.\make_test_bmp.ps1
```

**Test Theory:**
These images help determine how the V6355D handles transparency and raster effects:
- If raster bars show through **black bands only** → per-scanline detection
- If bars show through **left half only** → per-pixel transparency
- If bars only appear in **border** → blocked by any non-zero pixel

**Palette:**
Uses the standard CGA/PC1 16-color palette in BGRA format.

---

## Test Images

- `test_bands.bmp` - Horizontal bands pattern for raster timing tests
- `test_vstripe.bmp` - Vertical stripe pattern for transparency tests

## Requirements

- **NASM** (Netwide Assembler) for building .asm files
- **PowerShell** for running .ps1 scripts
- **Target:** Olivetti PC1 with V6355D video chip

## Related Documentation

See the main project [README](../README.md) and [V6355D Hardware Sprite documentation](../docs/V6335D-Hardware-Sprite.md) for more details on the video chip registers and capabilities.
