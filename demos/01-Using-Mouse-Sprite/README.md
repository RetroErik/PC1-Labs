# Bouncing Ball Demos (Using Mouse Driver)

Learning-focused demos showing how to use the V6335D hardware sprite via Simone Riminucci's INT 33h mouse driver.

## Files in This Folder

| Version | File | Features | Balls |
|---------|------|----------|-------|
| 0.1 | BBall.asm | Single ball, basic concept | 1 |
| 0.2 | BBalls1.asm | Frame-based multiplexing, 3 balls | 3 |
| 0.3 | BBalls2.asm | Direct V6335D hardware access (no mouse driver) | 3 |
| 0.4 | BBalls3.asm | Vsync-synchronized, one ball per frame cycling | 3 |

> **Next Step**: See `../02-sprite-multiplexing/` for true raster-sync multiplexing (2 balls in ONE frame, no flicker!)

## Version Details

### BBall.asm (v0.1) - Foundation Demo
The starting point. Single bouncing ball using the mouse driver INT 33h interface. Demonstrates:
- Sprite loading and positioning
- BIOS timer synchronization (~18 FPS)
- Boundary collision detection

### BBalls1.asm (v0.2) - Basic Multiplexing
First attempt at multiple objects. Repositions the sprite 3 times per frame (once for each ball) with small delays between repositioning to create persistence of vision. Still uses mouse driver.

### BBalls2.asm (v0.3) - Direct Hardware Access
Removes mouse driver dependency and directly controls the V6335D hardware sprite. Includes proper virtual-to-hardware coordinate transformation (X/2 + 15, Y + 8). Still animates 3 bouncing balls with frame-based multiplexing.

### BBalls3.asm (v0.4) - Vsync-Synchronized
Synchronizes ball updates to screen refresh (vsync). Cycles through updating one ball per frame, creating smoother animation. Still uses 3 balls but distributes computation across frames.

## Features

- Hardware sprite rendering via mouse driver INT 33h (BBall, BBalls1)
- Direct V6355D hardware access (BBalls2, BBalls3)
- BIOS timer synchronization for consistent animation
- Collision detection with screen bounds
- Velocity reversal on bounce
- ESC key to exit
- **Foundation for advanced techniques** (see ../02-sprite-multiplexing/)

## Building

```bash
nasm -f bin BBall.asm -o BBall.com
nasm -f bin BBalls1.asm -o BBalls1.com
nasm -f bin BBalls2.asm -o BBalls2.com
nasm -f bin BBalls3.asm -o BBalls3.com
```

## Running

### BBall and BBalls1 (require mouse driver)
```bash
mouse.com /I
BBall.com
```

### BBalls2 and BBalls3 (standalone)
```bash
BBalls2.com
BBalls3.com
```

Press **ESC** to exit any demo.

## How It Works

### INT 33h Mouse Driver Sprite Control (BBall, BBalls1)

BBall.asm uses Simone Riminucci's enhanced INT 33h driver to control the V6335D hardware sprite:

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

**This folder** establishes:
- ✓ Basic sprite loading and positioning
- ✓ BIOS timer synchronization  
- ✓ Boundary collision detection
- ✓ Frame-based animation
- ✓ Frame-based multiplexing (multiple balls, but with flicker)
- ✓ Direct hardware access

**Next step** → [../02-sprite-multiplexing/](../02-sprite-multiplexing/) shows:
- ✓ True raster-synchronized multiplexing (2 balls in ONE frame!)
- ✓ **No flicker** - both balls visible simultaneously
- ✓ Rainbow colors and blend mode switching
- ✓ Shape animation (spinning lines)

## Architecture

- **Driver interface**: 
  - BBall/BBalls1: Simone Riminucci's INT 33h mouse driver (no-hardware mode with `/I` flag)
  - BBalls2/BBalls3: Direct V6355D hardware registers (port 60h-6Fh)
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

- **Mouse driver required for BBall/BBalls1**: Uses Simone Riminucci's enhanced INT 33h mouse driver. Load with `mouse.com /I` (no-hardware mode) before running.
- **BBalls2/BBalls3 are standalone**: No mouse driver needed - direct hardware access.
- **Works in any video mode**: Text or graphics modes both work since the demos control the V6355D sprite hardware directly.
- **Single sprite hardware**: All demos share the same hardware sprite. See [../02-sprite-multiplexing/](../02-sprite-multiplexing/) for true flicker-free multiplexing.
- **Frame rate**: ~18 FPS (BIOS timer ticks at ~18Hz). Frame-based multiplexing can cause visible flicker.

## Future Enhancements

See the **[02-sprite-multiplexing](../02-sprite-multiplexing/)** folder for the next evolution:

- **BBalls4**: True raster-sync multiplexing (the breakthrough!)
- **BBalls5**: Rainbow colors + XOR/solid blend modes
- **BBalls6**: Spinning line animation + all effects combined
