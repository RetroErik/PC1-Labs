# Bouncing Ball Demo

A simple proof-of-concept demo showing a 16×16 circular ball bouncing around the screen using the V6335D hardware sprite engine.

## Features

- Hardware sprite rendering (no VRAM blitting)
- BIOS timer synchronization for consistent ~18 FPS animation
- Collision detection with screen bounds
- Velocity reversal on bounce
- ESC key to exit

## Building

```bash
nasm -f bin -o BB.com BB.asm
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

## Controls

- **ESC** - Exit to DOS

## How It Works

1. **Load sprite shape** - Calls INT 33h function 09h to upload a 16×16 circular AND/XOR mask to the V6335D sprite RAM
2. **Show sprite** - INT 33h function 01h makes it visible
3. **Main loop:**
   - Update X/Y position based on velocity
   - Check screen boundaries (0-639, 0-199)
   - Reverse velocity on collision
   - Move sprite via INT 33h function 04h
   - Wait for next BIOS timer tick (~55ms)
4. **Exit** - ESC key hides sprite and returns to DOS

## Architecture

- **Sprite data**: 32 words total
  - 16 words screen mask (AND mask)
  - 16 words cursor mask (XOR mask)
- **Position**: Stored in `pos_x`, `pos_y` (word variables)
- **Velocity**: `vel_x`, `vel_y` (can be adjusted for speed)
- **Timing**: BIOS INT 1Ah for frame synchronization

## Customization

Edit these in the source:

```nasm
mov word [pos_x], 320   ; Initial X position
mov word [pos_y], 100   ; Initial Y position
mov word [vel_x], 3     ; Pixels per frame (X)
mov word [vel_y], 2     ; Pixels per frame (Y)
```

To modify the sprite shape, replace the `sprite_mask` data table with your own 16×16 monochrome AND/XOR pattern.

## Notes

- Requires Simone Riminucci's INT 33h mouse driver (with `/I` flag for no-hardware mode)
- Works in both text and graphics modes
- Sprite pixels inherit the screen's aspect ratio (not square on 640×200)
- Single sprite only (no multiplexing in this basic version)

## Future Enhancements

- Sprite multiplexing for multiple objects
- Color cycling via register 64h
- Shape animation (swapping masks)
- Acceleration/gravity physics
