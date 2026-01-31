# Sprite Multiplexing Demo - Bouncing Balls

Advanced sprite demo series showing how to use a single hardware sprite to animate multiple objects via rapid repositioning and raster-synchronized multiplexing.

## BBalls Versions

| Version | File | Features | Balls |
|---------|------|----------|-------|
| 0.2 | BBalls1.asm | Basic multiplexing using mouse driver | 3 |
| 0.3 | BBalls2.asm | Direct V6335D hardware access, no mouse driver | 3 |
| 0.4 | BBalls3.asm | Vsync-synchronized, one ball per frame cycling | 3 |
| 0.5 | BBalls4.asm | True raster-sync multiplexing (2 balls in one frame) | 2 |
| 0.6 | BBalls5.asm | Raster-sync + random rainbow colors + XOR mode | 2 |
| 0.7 | BBalls6.asm | Raster-sync + spinning line animation (8 frames) + rainbow colors | 2 |

## Version Details

### BBalls1.asm (v0.2) - Basic Multiplexing
Uses the mouse driver to animate 3 bouncing balls. Repositions the sprite 3 times per frame (once for each ball) with small delays between repositioning to create persistence of vision.

### BBalls2.asm (v0.3) - Direct Hardware Access
Removes mouse driver dependency and directly controls the V6335D hardware sprite. Includes proper virtual-to-hardware coordinate transformation (X/2 + 15, Y + 8). Still animates 3 bouncing balls with frame-based multiplexing.

### BBalls3.asm (v0.4) - Vsync-Synchronized
Synchronizes ball updates to screen refresh (vsync). Cycles through updating one ball per frame, creating a smoother animation. Still uses 3 balls but distributes computation across frames.

### BBalls4.asm (v0.5) - True Raster-Sync Multiplexing
Introduces true raster-synchronized multiplexing with **2 balls displayed simultaneously in a single frame**. Splits the screen into two vertical zones (top half and bottom half) and reposition the sprite mid-frame to "chase" the CRT beam. No flicker, both balls visible at the same time.

### BBalls5.asm (v0.6) - Raster-Sync + Rainbow Colors
Extends BBalls4 with dynamic features:
- Random rainbow color selection on every bounce (never repeats consecutively)
- Separate color modes: top ball in solid mode, bottom ball in XOR transparent mode
- Color and mode changes mid-frame via hardware registers

### BBalls6.asm (v0.7) - Raster-Sync + Spinning Animation
Advanced version with frame-based sprite shape animation:
- 8-frame spinning line animation (line rotates 45° per frame)
- Random rainbow colors on every bounce
- Both balls use XOR transparent mode
- Sprite shape updates mid-frame along with color changes

## How It Works

**The Challenge**: The V6335D only has ONE hardware sprite. To show multiple balls, we:

1. **Update physics** for all 3 balls independently
2. **Reposition the sprite** 3 times per frame:
   - Draw ball 1 (position sprite, small delay for persistence)
   - Draw ball 2 (reposition, small delay)
   - Draw ball 3 (reposition, small delay)
3. **Wait for next timer tick** (~55ms total frame time)

The human eye + display refresh persistence create the illusion of 3 simultaneous bouncing balls.

## Technical Details

### Physics
Each ball maintains:
- Position: `ballN_x`, `ballN_y`
- Velocity: `ballN_vx`, `ballN_vy`
- Bounds: 0-639 (H), 0-199 (V) with 8-pixel margin

### Sprite Multiplexing Technique

```asm
; Update positions for all 3 balls
call update_ball1
call update_ball2
call update_ball3

; Rapidly reposition sprite at each ball's location
mov ax, 04h         ; Function 04h: Move pointer
mov cx, [ball1_x]
mov dx, [ball1_y]
int 33h             ; Show ball 1

mov cx, 0x3FFFh     ; Brief delay for visual persistence
call delay_short

mov cx, [ball2_x]   ; Reposition to ball 2
mov dx, [ball2_y]
int 33h

mov cx, 0x3FFFh
call delay_short

mov cx, [ball3_x]   ; Reposition to ball 3
mov dx, [ball3_y]
int 33h

; Wait for next frame
```

### Why This Works

- Each repositioning + delay (~16ms loop) creates **persistence of vision**
- Humans can't distinguish the rapid repositioning if the delay is short enough
- Total frame time still syncs to BIOS timer (~55ms), keeping animation smooth
- No flickering because we're not clearing/redrawing—just repositioning

## Building

```bash
nasm -f bin BBalls1.asm -o BBalls1.com
nasm -f bin BBalls2.asm -o BBalls2.com
nasm -f bin BBalls3.asm -o BBalls3.com
nasm -f bin BBalls4.asm -o BBalls4.com
nasm -f bin BBalls5.asm -o BBalls5.com
nasm -f bin BBalls6.asm -o BBalls6.com
```

All versions are self-contained .com files (except BBalls1 which requires the mouse driver).

## Running

### BBalls1 (with mouse driver)
```bash
mouse.com /I
BBalls1.com
```

### BBalls2-6 (standalone)
```bash
BBalls2.com
BBalls3.com
BBalls4.com
BBalls5.com
BBalls6.com
```

Press ESC to exit any demo.

## Customization

### Learning Path
Start with **BBalls1** to understand basic multiplexing concepts. Progress through the versions to see how techniques evolve:
- BBalls1-3: Frame-based multiplexing (simple, but multiple balls require multiple frame cycles)
- BBalls4: The breakthrough - true raster-sync multiplexing (multiple balls in ONE frame)
- BBalls5-6: Adding visual effects while maintaining raster-sync

### Add More Balls (for earlier versions)

1. Copy `ball1_x/y/vx/vy` to `ball4_x/y/vx/vy` (add data)
2. Add `update_ball4` routine (copy and rename `update_ball1`)
3. Add draw/reposition in main loop
4. Note: More balls = slower frame rate due to repositioning overhead

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

### Change Sprite Mask

Replace the `sprite_mask` data with your own 16×16 AND/XOR pattern.

## Performance Notes

- **3 balls**: ~60ms frame time (just fits in ~55ms tick, slight slowdown)
- **4 balls**: ~80ms frame time (noticeably slower)
- **Optimization**: Remove delay loops, sync directly to raster (requires scanline register access)

## Advanced: Raster-Synced Multiplexing

For true hardware multiplexing (sprite drawn at different Y positions on the same scanline), you would:

1. Hook timer interrupt or read V6335D scanline register
2. Sync repositioning to specific screen rows
3. Position sprite at ball1's Y on scanline 50, ball2's Y on scanline 100, etc.

This demo uses the simpler **frame-based** approach (all 3 balls per frame cycle).

## Notes

- Requires Simone Riminucci's INT 33h mouse driver
- Works in text and graphics modes
- Visual effect depends on monitor refresh rate and human persistence of vision
- Flicker may occur on very slow systems or if delays are too short

## Future Enhancements

- Scanline-based multiplexing (true raster effect)
- Color cycling while multiplexing (plasma effect with 3 balls)
- Collision detection between balls
- Variable ball speeds and sizes (via shape swapping)
