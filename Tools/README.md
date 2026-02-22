# PC1-Labs — Tools

Utility programs for testing, measuring, and debugging V6355D video chip behavior on the Olivetti PC1.

## Tools

### hpos.asm — Horizontal Position Tester

An interactive utility for testing V6355D Register 0x67 (Configuration Mode Register) which controls horizontal display position.

**Files:** `hpos.asm` / `hpos.com`

**Usage:**
```
hpos.com
```
- **LEFT/RIGHT arrows** — Adjust horizontal position value
- **Q or ESC** — Quit

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

---

### timing.asm — HSYNC / VBLANK Timing Measurement

Measures scanline timing and VBLANK duration on the Olivetti PC1. Originally developed alongside the raster bar demos (03-port-color-rasters) to understand the timing constraints for per-scanline effects.

**Files:** `timing.asm` / `timing.com` (393 lines)

**Usage:**
```
timing.com
```
Runs three automated tests, then displays results on screen.

**What It Measures:**
| Test | Method | Result on PC1 |
|------|--------|----------------|
| Scanline timing | Tight loop counting iterations while HSYNC=1 | **~2 iterations** (HSYNC pulse is very brief) |
| VBLANK duration | Tight loop counting iterations while VBLANK=1 | **~133 iterations** |
| Scanlines per frame | Count HSYNC edges between VBLANKs | **4096 (timeout)** — HSYNC counting unreliable |

**Key Findings:**
- The HSYNC pulse (STATUS bit 0 = 1) is extremely brief — only ~2 loop iterations
- VBLANK (STATUS bit 3) is reliable for frame synchronization
- Raster bar code must detect the HSYNC *edge* (0→1 transition), not poll for duration
- PAL 50 Hz expected: ~512 CPU cycles/scanline, ~312 scanlines/frame, ~112 VBLANK lines

**Why This Matters:**
These measurements directly informed the raster bar timing strategy used in demos 03 through 05. The discovery that HSYNC is too brief to poll reliably led to the edge-detection approach used in all the raster demos.

---

### cga_scroll_test.asm — CGA CRTC R12/R13 Hardware Scroll Test

Tests whether standard CGA CRTC Start Address registers (R12/R13) control hardware scrolling on the V6355D. The V6355D datasheet mentions "6845 restricted mode for IBM-PC compatibility" — this tool verifies that hardware scrolling works.

**Files:** `cga_scroll_test.asm` / `cga_scroll_test.com` (333 lines)

**Usage:**
```
cga_scroll_test.com
```

**Controls:**
| Key | Action |
|-----|--------|
| `,` (comma) | Scroll up (decrease start address) |
| `.` (period) | Scroll down (increase start address) |
| **R** | Reset start address to 0 |
| **ESC / Q** | Exit |

**Diagnostics (border color feedback):**
- Red = comma key detected
- Green = period key detected
- Blue = R key detected
- White flash = CRTC register write attempt

**Key Finding:** CGA CRTC R12/R13 **do work** on the V6355D for hardware scrolling with unlimited range. This discovery enabled the tall-image viewport scrollers in demo7a–demo7c and the circular buffer technique in demo8.

---

### V6355D_scroll_test.asm — Register 0x64 Vertical Adjust Test

Tests V6355D-specific Register 0x64 (bits 3-5) for vertical display adjustment. This is a V6355D-native register, not a CGA-compatible one.

**Files:** `V6355D_scroll_test.asm` / `V6355D_scroll_test.com` (300 lines)

**Usage:**
```
V6355D_scroll_test.com
```

**Test Results (February 2, 2026):**
- Register 0x64 **does** control vertical scrolling
- Limited range: **±8 lines** (3 bits = 8 values: 0-7)
- Write operations do not crash (register is valid)
- Screen visibly shifts by 0-7 rows based on bits 3-5 value
- Side effect: colors may shift during register writes

**Recommendation:**
- Small adjustments (±4 lines): Use Register 0x64 (simpler)
- Full-screen tall image scrolling: Use CGA CRTC R12/R13 (unlimited range) — see `cga_scroll_test.asm`

---

### make_test_bmp.ps1 — Test Image Generator

A PowerShell script that creates test BMP files for V6355D raster bar testing. Generates 160×200 4-bit BMP images.

**Generated Files:**
- `test_bands.bmp` — Horizontal bands (alternating black/colored rows)
- `test_vstripe.bmp` — Vertical split (left half black, right half colored)

**Usage:**
```powershell
.\make_test_bmp.ps1
```

**Test Theory:**
These images help determine how the V6355D handles transparency and raster effects:
- If raster bars show through **black bands only** → per-scanline detection
- If bars show through **left half only** → per-pixel transparency
- If bars only appear in **border** → blocked by any non-zero pixel

---

### test-ansi.asm — ANSI Terminal Test

**Files:** `test-ansi.asm` / `test-ansi.com`

---

### test_r12r13.asm — R12/R13 Hardware Scroll Diagnostic

Loads a 320×200 BMP directly to VRAM and tests CGA CRTC R12/R13 hardware scrolling. Uses border color changes at each stage (RED→GREEN→CYAN→MAGENTA→BLACK) for diagnostic feedback. Originally `demo7_simple.asm`.

**Files:** `test_r12r13.asm` / `test_r12r13.com` (441 lines)

**Usage:**
```
test_r12r13.com filename.bmp
```

**Controls:**
| Key | Action |
|-----|--------|
| `,` (comma) | Scroll up |
| `.` (period) | Scroll down |
| **ESC** | Exit |

**Diagnostic border colors:**
- Red = startup
- Green = file opened
- Cyan = graphics mode enabled
- Magenta = loading image
- Black = ready for scrolling

**Note:** Has the same 192-byte bank gap bug as demo7a — scrolling past one screenful shifts the image ~96 pixels right. This is expected for a pure R12/R13 test; see demo7b for the software viewport solution.

---

### flip-hidden-test.asm — Port 0xD9 Bit 5 Palette Flip Test (Hidden Mode)

Tests whether the CGA palette select bit (port `0xD9` bit 5) has any effect in the hidden 160×200×16 graphics mode. In CGA mode 4, this bit selects between two subsets of palette entries (the "Simone flip" used in PC1-BMP2). This tool checks if the same mechanism works in hidden mode.

**Files:** `flip-hidden-test.asm` / `fliptest.com`

**Usage:**
```
fliptest.com
```

**Controls:**
| Key | Action |
|-----|--------|
| **SPACE** | Toggle port 0xD9 bit 5 (white border flash confirms) |
| **ESC** | Exit |

**Test Pattern:**
- 16 vertical color bars, each 10 pixels wide
- Bars 0–7: warm colors (black, dark red, red, orange, yellow, light yellow, pink, magenta)
- Bars 8–15: cool colors (dark blue, blue, dark cyan, cyan, dark green, green, light green, white)

**Confirmed Result (February 22, 2026 — real PC1 hardware):**
- **Outcome A: Bit 5 is completely ignored in hidden 160×200×16 mode.**
- Toggling bit 5 produced zero change to the 16 color bars.
- Only the intentional white border flash (keypress confirmation) was visible.
- The CGA palette select MUX has no effect when the pixel path is 4 bits wide — all 16 palette entries are always active.

**Implication for per-scanline palette:**
The "Simone flip" double-buffer technique from CGA mode 4 cannot be used in hidden mode. Per-scanline palette updates must write directly to live/visible entries during HBLANK (~76 cycles, enough for 2 entries with zero flicker).

---

## Building

```bash
nasm -f bin hpos.asm -o hpos.com
nasm -f bin timing.asm -o timing.com
nasm -f bin cga_scroll_test.asm -o cga_scroll_test.com
nasm -f bin V6355D_scroll_test.asm -o V6355D_scroll_test.com
nasm -f bin flip-hidden-test.asm -o fliptest.com
```

## Requirements

- **NASM** (Netwide Assembler) for building .asm files
- **PowerShell** for running .ps1 scripts
- **Target:** Olivetti PC1 with V6355D video chip

## Related Documentation

See the main project [README](../README.md) and [V6355D Hardware Sprite documentation](../docs/V6335D-Hardware-Sprite.md) for more details on the video chip registers and capabilities.
