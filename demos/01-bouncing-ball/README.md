# Bouncing Ball Demo (BB.asm)

A simple proof-of-concept demo showing a 16×16 circular ball bouncing around the screen using the V6335D hardware sprite engine.

**BB.asm** is the foundational demo in this sprite series. It demonstrates core concepts used by all subsequent demos in the `/demos` folder.

## Features

- Hardware sprite rendering via mouse driver INT 33h
- BIOS timer synchronization for consistent ~18 FPS animation
- Collision detection with screen bounds
- Velocity reversal on bounce
- ESC key to exit
- **Foundation for advanced techniques** (see ../02-sprite-multiplexing/)

## Building

```bash
nasm -f bin BB.asm -o BB.com
```

## Running

First, load the mouse driver:
```bash
mouse.com /I
```

Then run the demo:
```bash
BB.com
```

A white circular ball will bounce around the screen. Press **ESC** to exit.

## How It Works

### INT 33h Mouse Driver Sprite Control

BB.asm uses Simone Riminucci's enhanced INT 33h driver to control the V6335D hardware sprite:

1. **Check driver presence** (Function 00h)
   ```asm
   xor ax, ax
   int 33h             ; Returns AX = 0xFFFF if driver loaded
   ```

2. **Upload sprite shape** (Function 09h)
   - Uploads a 16×16 circular AND/XOR mask pair to sprite RAM
   - AND mask (screen mask): 0 = transparent, 1 = preserve background
   - XOR mask (cursor mask): 1 = draw white, 0 = no change
   ```asm
   mov ax, 09h         ; Set graphic pointer shape
   mov dx, sprite_mask ; Pointer to 32-word mask
   int 33h
   ```

3. **Show sprite** (Function 01h)
   ```asm
   mov ax, 01h
   int 33h
   ```

4. **Main animation loop:**
   - Update X/Y position based on velocity
   - Check screen boundaries (0-639 pixels × 0-199 pixels)
   - Reverse velocity on collision
   - Move sprite to new position (Function 04h)
   ```asm
   mov ax, 04h         ; Move pointer
   mov cx, [pos_x]
   mov dx, [pos_y]
   int 33h
   ```
   - Wait for next BIOS timer tick (~55ms per tick)

5. **Hide sprite and exit** (Function 02h on ESC key)
   ```asm
   mov ax, 02h         ; Hide pointer
   int 33h
   ```

### Key Data Structures

```asm
pos_x        dw 320      ; Current X position
pos_y        dw 100      ; Current Y position
vel_x        dw 3        ; Velocity X (pixels/frame)
vel_y        dw 2        ; Velocity Y (pixels/frame)
timer_target dw 0        ; Target for frame sync

sprite_mask:
    ; 16 words: Screen mask (AND)
    ; 16 words: Cursor mask (XOR)
```

## Progression to Advanced Techniques

**BB.asm** establishes:
- ✓ Basic sprite loading and positioning
- ✓ BIOS timer synchronization  
- ✓ Boundary collision detection
- ✓ Frame-based animation

**Next step** → [../02-sprite-multiplexing/](../02-sprite-multiplexing/) shows how to:
- ✗ Eliminate mouse driver dependency (direct hardware access)
- ✗ Display **multiple objects** with a single sprite
- ✗ Use raster-synchronized multiplexing for flicker-free multi-sprite animation
- ✗ Add colors and shape animation

## Architecture

- **Driver interface**: Simone Riminucci's INT 33h mouse driver (no-hardware mode with `/I` flag)
- **Sprite data**: 32 words total
  - 16 words screen mask (AND - which pixels are transparent)
  - 16 words cursor mask (XOR - which pixels draw white)
  - Circular 16×16 pixel sprite
- **Position**: Stored in `pos_x`, `pos_y` (word variables, range 0-639 × 0-199)
- **Velocity**: `vel_x`, `vel_y` (can be positive/negative for direction, adjust magnitude for speed)
- **Timing**: BIOS INT 1Ah for frame synchronization (~18 FPS target)

## Customization

### Adjust Initial Position and Velocity

Edit the initialization code in BB.asm:

```nasm
mov word [pos_x], 320   ; Initial X position (0-639)
mov word [pos_y], 100   ; Initial Y position (0-199)
mov word [vel_x], 3     ; Pixels per frame (X direction)
mov word [vel_y], 2     ; Pixels per frame (Y direction)
```

Higher velocity values = faster bouncing. Negative values reverse direction.

### Create Custom Sprite Shape

Replace the `sprite_mask` data table with your own 16×16 monochrome pattern:

```nasm
sprite_mask:
    ; Screen mask (16 words) - AND operation
    dw 1111111111111111b    ; Row 0: 0=transparent, 1=keep background
    dw 1111110000111111b    ; Row 1
    ; ... 14 more rows
    
    ; Cursor mask (16 words) - XOR operation  
    dw 0000000000000000b    ; Row 0: 1=draw white, 0=no change
    dw 0000001111000000b    ; Row 1
    ; ... 14 more rows
```

Use online tools or image editors to create patterns, then convert to binary masks.

## Notes

- **Requires mouse driver**: Uses Simone Riminucci's enhanced INT 33h mouse driver. Load with `mouse.com /I` (no-hardware mode) before running.
- **Works in any video mode**: Text or graphics modes both work since the driver controls the V6335D sprite hardware directly.
- **Single sprite only**: BB.asm animates one ball. See [../02-sprite-multiplexing/](../02-sprite-multiplexing/) for multiple objects.
- **Aspect ratio**: Sprite pixels inherit the screen's aspect ratio (not perfectly square in 640×200 mode).
- **Frame rate**: ~18 FPS (BIOS timer ticks at ~18Hz). More complex demos reduce this further.

## Future Enhancements

See the **[02-sprite-multiplexing](../02-sprite-multiplexing/)** folder for advanced versions that build on BB.asm:

- Direct hardware access (no mouse driver needed)
- Sprite multiplexing for multiple objects
- Raster-synchronized animation (no flicker with multiple sprites)
- Color cycling via hardware register 64h
- Shape animation (swapping sprite masks per frame)
