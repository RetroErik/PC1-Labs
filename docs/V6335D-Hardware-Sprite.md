# V6335D Hardware Sprite Engine

Technical reference for the Yamaha V6335D video controller's sprite capabilities on the Olivetti PC1.

## Overview

The V6335D integrates a **single hardware sprite** capable of:
- Rendering a 16×16 monochrome masked cursor/pointer/object
- Operating on a fixed 640×200 virtual coordinate space (regardless of actual video mode)
- Applying AND/XOR logic to composite with background pixels
- No CPU blitting overhead—the chip composites during raster scan

## Coordinate System

The sprite uses a fixed **640×200 virtual address space**:

- **Horizontal**: 0–639 (640 pixels per scanline)
- **Vertical**: 0–199 (200 scanlines)

This mapping applies **regardless of the actual video mode**:
- **Text mode (80×25)**: Each character = 8×8 raster pixels; sprite positions across the underlying 640×200 grid
- **Graphics mode (160×200×16)**: Each graphics pixel = 4 raster pixels wide; sprite can position at subpixel (4×) precision
- **CGA/EGA modes**: Similarly mapped to 640×200 virtual space

## Register Interface

### Sprite Position & Control (Port 3DDh/3DEh)

Register 60h – Sprite Control and X/Y Position:

```
OUT 3DDh, 60h+80h       ; Select register 60h, enable sprite
OUT 3DEh, al            ; X low byte
OUT 3DEh, ah            ; X high byte
OUT 3DEh, dl            ; Y low byte
OUT 3DEh, dh            ; Y high byte
```

**Example:** Position sprite at (320, 100)
```asm
mov dx, 3DDh
mov al, 60h+80h
out dx, al
inc dx
mov ax, 320             ; X position
xchg al, ah
out dx, al
xchg al, ah
out dx, al
mov ax, 100             ; Y position
xchg al, ah
out dx, al
xchg al, ah
out dx, al
```

### Sprite Shape (Port 0DDh/0DEh)

Register 00h – Sprite Shape Upload:

```
OUT 0DDh, 00h           ; Select shape memory (index 0)
OUT 0DEh, [32 words]    ; Load 32 words: screen mask (16) + cursor mask (16)
```

**Format:**
- **Words 0–15**: Screen mask (AND mask) – 0 = transparent, 1 = background preserved
- **Words 16–31**: Cursor mask (XOR mask) – 1 = draw/invert, 0 = transparent

**Example:** Load circular sprite
```asm
mov al, 00h
out 0DDh, al
mov si, offset sprite_data  ; 32-word array
mov cx, 32
loop_load:
    lodsw
    xchg ah, al
    out 0DEh, al
    xchg ah, al
    out 0DEh, al
    loop loop_load
```

### Sprite Color Attribute (Port 0DDh/0DEh)

Register 64h – AND/XOR Attribute for Sprite Masking:

```
OUT 0DDh, 64h+80h       ; Select register 64h
OUT 0DEh, attribute     ; AL = color byte
```

**Attribute byte format:**
```
Bit 7-4: AND mask (0-15)
Bit 3-0: XOR mask (0-15)
```

**Common values:**
- `0xF0` (default) - AND=15 (preserve all), XOR=0 → opaque white/foreground
- `0x0F` - AND=0 (black), XOR=15 → full inversion
- `0xFF` - AND=15, XOR=15 → total inversion
- `0x00` - AND=0, XOR=0 → black silhouette
- `0x77`, `0x88` - Partial masking for dim/glow effects

**Example:** Set glowing white sprite
```asm
mov al, 64h+80h
out 0DDh, al
mov al, 0F0h            ; Opaque white
out 0DEh, al
```

## Sprite Visibility

### Show/Hide via Register 60h Enable Bit

```asm
mov al, 60h+80h         ; 60h + 80h = enable sprite
out 3DDh, al
; (follow with X, Y position writes)

mov al, 60h             ; 60h (no 80h) = disable sprite
out 3DDh, al
```

The upper bit (80h) toggles the sprite on/off without affecting position.

## INT 33h Driver API

The Simone Riminucci mouse driver wraps the hardware sprite behind INT 33h calls:

```asm
; Show sprite
mov ax, 01h
int 33h

; Hide sprite
mov ax, 02h
int 33h

; Move sprite
mov ax, 04h
mov cx, [x_pos]
mov dx, [y_pos]
int 33h

; Set shape & hotspot
mov ax, 09h
mov bx, [hotspot_x]     ; -16 to +16
mov cx, [hotspot_y]
mov es:dx, [sprite_mask] ; 32-word array
int 33h

; Set color attribute
mov ax, 0Ah
mov bl, 0FFh            ; Special marker
mov cl, [color_attr]    ; Color byte
int 33h
```

## Advanced Techniques

### Sprite Multiplexing

Reposition the sprite multiple times per frame (requires scanline timing):

1. Use V6335D interrupt or timer to sync to specific scanline
2. Write new X/Y to register 60h
3. Repeat for each desired sprite position

**Challenge**: No built-in V6335D raster interrupt exposed by BIOS; would need custom timer interrupt monitoring.

### Color Animation (Plasma Effect)

Rapidly cycle the attribute register (64h) to create pulsing/glowing:

```asm
color_table: db 0F0h, 0F7h, 0FFh, 0F7h, ... ; Color sequence

; In main loop:
mov al, 64h+80h
out 0DDh, al
mov al, [color_table + si]
out 0DEh, al
inc si
and si, 0Fh             ; Wrap around
```

### Shape Animation

Store multiple 16×16 masks and swap them each frame:

```asm
shapes:
    ; Shape 0: 32 words
    ; Shape 1: 32 words
    ; Shape 2: 32 words
    ; ...

; In main loop:
mov al, 00h             ; Select sprite memory
out 0DDh, al
mov dx, offset shapes[si]  ; Current shape offset
mov cx, 32
loop_upload:
    lodsw
    xchg ah, al
    out 0DEh, al
    xchg ah, al
    out 0DEh, al
    loop loop_upload
add si, 64              ; Move to next shape (32 words * 2 bytes)
```

### Subpixel Motion

In 160×200×16 graphics mode, each graphics pixel = 4 raster pixels. Move the sprite ±1 or ±2 units per frame for 4× finer motion than chunky pixels:

```asm
mov ax, [sprite_x]
add ax, [fine_velocity]  ; Fine velocity in raster units
mov [sprite_x], ax
; Use modulo 4 for subpixel phase
```

## Masking & Compositing

The sprite uses a two-layer mask:

1. **Screen mask (AND)** - Which background pixels to preserve
2. **Cursor mask (XOR)** - Which pixels to toggle/invert

**Compositing logic:**
```
output = (background AND mask_and) XOR mask_xor
```

**Examples:**
- Mask: AND=1111b, XOR=0000b → Output = Background (opaque, no change)
- Mask: AND=1111b, XOR=1111b → Output = ~Background (full inversion)
- Mask: AND=0000b, XOR=0000b → Output = 0000b (black hole)
- Mask: AND=0000b, XOR=1111b → Output = 1111b (white square)

**Gradient masking:** Design the 16×16 mask with varying AND/XOR patterns to create soft edges, halos, or glows when composed over different backgrounds.

## Performance

- **Zero CPU cost** for sprite rendering (chip does it during scan)
- **Minimal INT 33h overhead** for positioning (single port write sequence)
- **16×16 fixed size** (no scaling, rotation in hardware)
- **Single sprite** (no multiplexing without custom interrupt code)

## Limits

- Only **one sprite** at a time
- **16×16 fixed resolution** (no resizing)
- **Monochrome masking** (AND/XOR only, not true multicolor like C64)
- **No rotation** (masks are always axis-aligned)
- **No scaling** (must create separate masks for different sizes)

## References

- Yamaha V6335D Datasheet
- Z-180 PC1 Manual (6355 LCDC section)
- Simone Riminucci's Mouse Driver source code
