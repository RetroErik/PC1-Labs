# Sprite Multiplexing Demo - Bouncing Balls

True raster-synchronized sprite multiplexing demos showing how to display multiple sprites from a single hardware sprite by chasing the CRT beam.

## Files in This Folder

| Version | File | Features | Balls |
|---------|------|----------|---------|
| 0.5 | BBalls4.asm | True raster-sync multiplexing (2 balls in one frame) | 2 |
| 0.6 | BBalls5.asm | Raster-sync + random rainbow colors + XOR/solid modes | 2 |
| 0.7 | BBalls6.asm | Raster-sync + spinning line animation (8 frames) + rainbow colors | 2 |

> **Note**: BBalls1-3 (earlier learning versions) are in the `01-Using-Mouse-Sprite` folder.

## Version Details

### BBalls4.asm (v0.5) - True Raster-Sync Multiplexing (THE BREAKTHROUGH)
Introduces true raster-synchronized multiplexing with **2 balls displayed simultaneously in a single frame**. Splits the screen into two vertical zones (top half and bottom half) and repositions the sprite mid-frame to "chase" the CRT beam. No flicker, both balls visible at the same time. Pure white, no embellishment - focuses on the core technique.

### BBalls5.asm (v0.6) - Raster-Sync + Rainbow Colors
Extends BBalls4 with dynamic features:
- Random rainbow color selection on every bounce (never repeats consecutively)
- Different blend modes: top ball XOR transparent (see-through!), bottom ball solid
- Color and mode changes mid-frame via hardware registers

### BBalls6.asm (v0.7) - Raster-Sync + Spinning Animation
Advanced version with frame-based sprite shape animation:
- 8-frame spinning line animation (line rotates 45° per frame)
- Random rainbow colors on every bounce
- Top ball XOR transparent, bottom ball solid
- Sprite shape updates mid-frame along with color changes

## How Raster-Sync Multiplexing Works

**The Challenge**: The V6355D only has ONE hardware sprite. How do we show 2 balls without flicker?

**The Solution**: Chase the CRT beam!

```
1. Wait for vsync (beam returns to top of screen)
2. Position sprite at Ball 1 (top half of screen)
3. Wait for beam to pass Ball 1's Y position + 16 pixels
4. Reposition sprite to Ball 2 (bottom half of screen)
5. Result: Both balls drawn in ONE frame = no flicker!
```

The key insight is that once the CRT beam has drawn a scanline, it won't return to that line until the next frame. So we can safely reposition the sprite after the beam passes.

## Technical Details

### Screen Zones
- **Ball 1 (top)**: Y = 8 to 84 (sprite bottom at scanline 100)
- **Ball 2 (bottom)**: Y = 100 to 184

### Physics
Each ball maintains:
- Position: `ballN_x`, `ballN_y`
- Velocity: `ballN_vx`, `ballN_vy`
- Bounds: 0-639 (H), 0-199 (V) with margins

### Raster-Sync Code Pattern

```asm
; 1. Wait for vsync
call wait_vsync

; 2. Position sprite for Ball 1 (top zone)
mov bx, [ball1_x]
mov dx, [ball1_y]
call set_sprite_pos

; 3. Wait for beam to pass Ball 1's position
mov ax, [ball1_y]
add ax, 24           ; sprite height + margin
call wait_for_line

; 4. Reposition sprite for Ball 2 (bottom zone)
mov bx, [ball2_x]
mov dx, [ball2_y]
call set_sprite_pos

; Result: Both balls visible simultaneously!
```

### Why This Works

- The CRT beam scans top-to-bottom, left-to-right
- Once a scanline is drawn, it won't be drawn again until next frame
- By timing our sprite repositioning, we can show multiple objects
- **No delays, no flickering** - just precise synchronization with the display

## Building

```bash
nasm -f bin BBalls4.asm -o BBalls4.com
nasm -f bin BBalls5.asm -o BBalls5.com
nasm -f bin BBalls6.asm -o BBalls6.com
```

All versions are self-contained .com files that directly access V6355D hardware.

## Running

```bash
BBalls4.com
BBalls5.com
BBalls6.com
```

Press ESC to exit any demo. Press ? for help screen.

## Customization

### Learning Path
Start with **BBalls1-3** in the `01-Using-Mouse-Sprite` folder to understand basic concepts, then progress to these demos:
- **BBalls4**: The breakthrough - true raster-sync multiplexing (2 balls in ONE frame, no flicker!)
- **BBalls5**: Adding rainbow colors and blend mode switching
- **BBalls6**: Frame-based sprite animation with all the visual effects

### Add More Balls

For raster-sync multiplexing, adding more balls is constrained by screen zones:
- 2 balls: Screen divided into top/bottom halves (current approach)
- 3 balls: Would need 3 zones (~66 pixels each)
- More zones = less vertical movement range per ball

The tradeoff is vertical space vs number of sprites.

### Adjust Ball Speeds

Edit initial velocities:
```asm
mov word [ball1_vx], 2      ; Pixels per frame
mov word [ball1_vy], 3
```

### Modify Animation (for BBalls6)

Change the spinning line animation by editing the sprite shape data. The demo uses 8 frames with different line angles:
```asm
frame_0: db 0x00, 0x00, 0x00, 0x08, 0x08, 0x08, 0x00, 0x00  ; Vertical line
frame_1: db 0x00, 0x00, 0x04, 0x08, 0x08, 0x04, 0x00, 0x00  ; Diagonal
; ... more frames
```

Increase for faster movement, decrease for slower.

## Notes

- Requires Olivetti PC1 (or compatible with V6355D graphics chip)
- Uses CGA 640x200 mode (Mode 6)
- All demos are standalone - no mouse driver or other dependencies
- Visual effect depends on correct raster timing

## Future Enhancements

- 3+ ball multiplexing with smaller vertical zones
- Collision detection between balls
- Variable ball speeds and sizes (via shape swapping)
- Horizontal sprite multiplexing (for side-scrollers)
