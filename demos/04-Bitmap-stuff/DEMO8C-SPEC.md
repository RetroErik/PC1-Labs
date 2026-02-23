# DEMO8C — Improved Hardware Scroll with Register 0x65

## Starting Point

Based on `demo8b.asm` (circular buffer scroller, 1095 lines).

## Critical Bug in demo8b (Root Cause of Stuttering/Flickering)

**demo8b's entire strategy is built on a broken assumption.**

It tries to reduce the display to 196 rows by writing CRTC R6 (Vertical Displayed) = 98:

```asm
; In enable_graphics_mode:
mov dx, PORT_CRTC_ADDR
mov al, 6               ; R6 = Vertical Displayed
out dx, al
mov dx, PORT_CRTC_DATA
mov al, ROWS_PER_BANK   ; 98 rows
out dx, al
```

**But R6 is a DUMMY register on the V6355D!** This was confirmed by hardware testing with `crtc_restarts_test.asm` (February 2026). The write silently does nothing.

This means:
- demo8b thinks it has **352 bytes** of headroom (8192 - 7840 = 352)
- It actually has only **192 bytes** of headroom (8192 - 8000 = 192)
- `GAP_BOUNDARY` is set to 320 (4 rows past middle position 160), but the real gap starts at just 192 bytes from the start
- The middle-position strategy (starting at offset 160) means on the VERY FIRST scroll down, `crtc_start_addr` goes to 240 — already past the real gap boundary!
- **Result: garbage pixels on nearly every scroll step**, causing the flickering and visual corruption

## The Fix — Register 0x65 (Hardware Confirmed)

Register 0x65 bits 0-1 actually DO control vertical line count (confirmed by `reg65_test.asm`, February 23, 2026):
- `0x08` = 192 lines (96 per bank × 80 = 7680 bytes per bank)
- `0x09` = 200 lines (default)
- `0x0A` = 204 lines

**Using 192-line mode gives real headroom:** 8192 - 7680 = **512 bytes** = 6.4 rows per bank.

## Demo8c Design

### Core Improvements

1. **Use register 0x65 for 192-line mode** instead of the broken R6 approach
   - Write `0x08` to register 0x65 via port 0x3DD/0x3DE
   - Must close palette session (write 0x80 to 0x3DD) after the register write
   - Must write register 0x65 BEFORE palette setup (per proven code pattern)
   - Gives 512 bytes real headroom = 6 fast scroll steps

2. **Fix the headroom math**
   - `DISPLAY_ROWS` = 192 (not 196)
   - `ROWS_PER_BANK` = 96 (not 98)
   - `BANK_USED` = 7680 (not 7840)
   - `BANK_HEADROOM` = 512 (not 352)
   - `GAP_BOUNDARY` recalculated for 6 fast scrolls

3. **Remove the broken R6 write** from `enable_graphics_mode`

4. **Optimize the periodic reload**
   - Currently reloads entire viewport (15,360 bytes for 192 rows) every N scrolls
   - Ratio: 6 fast scrolls (160 bytes each = 960) + 1 reload (15,360) = ~2,280 bytes avg
   - This is already better than demo8b's theoretical 3,200 bytes/scroll

5. **Use word-wide CRTC writes** for R12/R13 (confirmed working on V6355D)
   - Instead of 4 separate `out` instructions, use `out dx, ax` for atomic update
   - Reduces CRTC update from ~16 cycles to ~4 cycles
   - Less chance of tearing between R12 and R13

6. **Better vsync synchronization**
   - demo8b waits for vsync inside the fast scroll but not consistently
   - Ensure ALL CRTC updates happen during vblank
   - Consider double-buffering the CRTC write: pre-calculate, then write atomically in vblank

7. **Smooth reload transition**
   - The periodic reload causes a visible stutter (15KB copy takes multiple frames)
   - Option A: Split the reload across 2-3 frames (copy even bank one frame, odd bank next)
   - Option B: Accept the stutter but make it less frequent (6 fast + 1 slow vs 4 fast + 1 slow)
   - Option C: During reload, do the copy during the visible area (top-down) so it's partially hidden

### Constants Update

```
DISPLAY_ROWS    equ 192         ; 192 visible rows (register 0x65 = 0x08)
ROWS_PER_BANK   equ 96          ; 96 rows × 80 = 7680 bytes per bank
BANK_USED       equ 7680        ; 96 rows × 80 bytes
BANK_HEADROOM   equ 512         ; 8192 - 7680 = 512 bytes (6.4 rows)
GAP_BOUNDARY    equ 480         ; 6 rows × 80 (safe fast-scroll range)
VRAM_SIZE       equ 15360       ; 192 rows × 80 bytes
```

### Register 0x65 Write Sequence

Must follow the proven pattern from colorbar.asm/PC1-BMP.asm, with palette protection:

```asm
; Write register 0x65 BEFORE palette setup
mov dx, PORT_REG_ADDR       ; 0x3DD
mov al, 0x65
out dx, al
mov dx, PORT_REG_DATA       ; 0x3DE
mov al, 0x08                ; 192 lines, PAL, CRT
out dx, al
; Close palette session
mov dx, PORT_REG_ADDR
mov al, 0x80
out dx, al
; ... then set up palette ...
```

### Word-Wide CRTC Write

```asm
; Atomic R12/R13 update (confirmed working on V6355D)
; AX = byte offset, convert to word offset
shr ax, 1                  ; byte → word offset
xchg ah, al                ; AH=low byte, AL=high byte → AL=R12 value, AH=R13 value
mov dx, PORT_CRTC_ADDR
mov al, CRTC_START_HIGH     ; R12
out dx, ax                  ; Write R12 index + R12 data
mov al, CRTC_START_LOW      ; R13
out dx, ax                  ; Write R13 index + R13 data
```

Wait — word-wide `out dx, ax` writes AL to port DX and AH to port DX+1. So:
```asm
; First write: AL=12 (R12 index), AH=start_high → port 0x3D4=12, port 0x3D5=high_byte
; Second write: AL=13 (R13 index), AH=start_low → port 0x3D4=13, port 0x3D5=low_byte
mov ax, word_offset
mov bx, ax
mov ah, bh              ; R12 data (high byte of word offset)
mov al, 12              ; R12 index
mov dx, PORT_CRTC_ADDR
out dx, ax              ; Writes index 12 to 0x3D4, high byte to 0x3D5
mov ah, bl              ; R13 data (low byte of word offset)
mov al, 13              ; R13 index
out dx, ax              ; Writes index 13 to 0x3D4, low byte to 0x3D5
```

### Scrolling Strategy

**Circular buffer with middle-start position:**

```
VRAM bank layout (7680 bytes used, 512 bytes free):

Offset:  0              240       7680    7920     8192
         |-- 3 rows --|-- 96 rows display --|-- 3 rows --|gap|
                       ^
                  start position (offset 240)
```

- Start `crtc_start_addr` at 240 (3 rows into bank) — centered in headroom
- Can scroll DOWN 3 rows (240 bytes) before hitting end of used area at 7920
- Can scroll UP 3 rows (240 bytes) before hitting offset 0
- Total: 6 fast scrolls in either direction before reload
- On reload: copy viewport, reset `crtc_start_addr` to 240

### File Naming

- Source: `demo8c.asm`
- Binary: `DEMO8C.COM`

### Minimum Image Height

- Changed from 196 to 192 rows minimum
- Usage message updated accordingly

### Testing

- Use the same test BMPs as demo8b (any 160×192+ tall 4-bit BMP)
- Compare scrolling smoothness: demo8b vs demo8c
- Verify no garbage pixels at any scroll position
- Verify palette is correct (no corruption from register 0x65 write)
- Test both manual (arrow keys) and auto-scroll (SPACE)

## Summary of Changes from demo8b → demo8c

| Area | demo8b (broken) | demo8c (fixed) |
|------|-----------------|----------------|
| Line reduction method | CRTC R6 (DUMMY — does nothing!) | Register 0x65 (hardware confirmed) |
| Display rows | 196 (intended) / 200 (actual) | 192 (actual) |
| Real headroom | 192 bytes (2.4 rows) | 512 bytes (6.4 rows) |
| Fast scrolls before reload | ~2 (buggy) | 6 (clean) |
| CRTC write method | 4× separate `out` | 2× word-wide `out dx, ax` |
| Average bytes/scroll | ~8,000 (frequent reloads due to bug) | ~2,280 (proper 6:1 ratio) |
| Palette safety | Not addressed | 0x80 session close after reg 0x65 |
