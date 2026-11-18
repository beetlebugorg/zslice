# The print view: G-code on a printer screen

A printer host (for example printdeck, in Go on a Raspberry Pi 5) can show the print as the zslice 3D view: the same beads, light, and colors as a slice, in a reduced view with no tools. The host gives the file position of the printer, and the view draws the print up to it. The calls are in `include/zslice-app.h`, in the part "a print view".

## Build

```sh
zig build lib -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu   # the Pi
zig build lib -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu    # a simulator on a PC
```

Link `zig-out/lib/libzslice.a` with `-lc -lm -lpthread -ldl`. The library loads Vulkan (`libvulkan.so.1`) when it makes a view, so the program does not link it. The Pi 5 has Vulkan in Mesa (v3dv). A PC with no GPU can use Mesa lavapipe.

## The flow

1. Read the file: `zs_gcode_open(path, &g)`. To stream it (an upload), use `zs_gcode_new`, then `zs_gcode_feed` for each piece, then `zs_gcode_finish`. The reader takes G-code of zslice, Cura, PrusaSlicer, OrcaSlicer, and Bambu Studio.
2. Make the view: `zs_view_offscreen(800, 480, ZS_VIEW_REDUCED | ZS_VIEW_BGRA, &v)`. The view needs no window system and no display.
3. Show the file: `zs_view_load_gcode(v, g, bed_x, bed_y)`. Keep `g` while the view shows it.
4. On each change, set the state, then draw and read the pixels:
   - `zs_view_set_position(v, offset)`: the file position that Klipper reports (`virtual_sdcard.file_position`).
   - `zs_view_set_layer(v, layer)`: the scrubber. It shows whole layers up to `layer`. The next `zs_view_set_position` follows the print again.
   - `zs_view_touch(v, id, action, x, y)`: the fingers. `zs_view_reset(v)` goes back to the start view.
   - `zs_view_gcode_colors(v, by_feature, 0xRRGGBB)`, `zs_view_set_dark(v, on)`, `zs_view_print_look(v, nozzle, lit)`.
   - `zs_view_draw(v)`, then `zs_view_read(v, buf, len, stride)`.
5. Free: `zs_view_free(v)`, then `zs_gcode_free(g)`.

## Byte offsets

An offset counts the bytes that the printer has read. At offset `p`, the printer has read each line that ends at or before `p`. `zs_gcode_get_layer` gives the bytes of a layer as `start` to `end`, and `zs_gcode_layer_at(g, p)` is the layer of byte `p - 1`. `zs_gcode_state_at(g, p, &s)` gives the layer, the feature of the last bead, the speed, and the position of the last move.

## Example

```c
#include <zslice-app.h>

int show(const char *path, uint64_t file_position, uint8_t *fb, size_t fb_len, size_t stride) {
    zs_gcode *g = NULL;
    zs_view *v = NULL;
    int rc = zs_gcode_open(path, &g);
    if (rc != ZS_OK) return rc;
    rc = zs_view_offscreen(800, 480, ZS_VIEW_REDUCED | ZS_VIEW_BGRA, &v);
    if (rc == ZS_OK) rc = zs_view_load_gcode(v, g, 280, 280);
    if (rc == ZS_OK) {
        zs_view_set_position(v, file_position);
        rc = zs_view_draw(v);
    }
    if (rc == ZS_OK) rc = zs_view_read(v, fb, fb_len, stride);
    zs_view_free(v);
    zs_gcode_free(g);
    return rc;
}
```

A host keeps `g` and `v` for the whole print, and calls only the set, draw, and read calls on each update.

## Go (cgo)

```go
/*
#cgo CFLAGS: -I${SRCDIR}/zslice/include
#cgo LDFLAGS: ${SRCDIR}/zslice/lib/libzslice.a -lc -lm -lpthread -ldl
#include <zslice-app.h>
*/
import "C"
```

- Give the path as a `C.CString`, and free it after `zs_gcode_open`.
- Give the pixels as `(*C.uint8_t)(unsafe.Pointer(&buf[0]))`. The view does not keep the pointer.
- Call each handle from one goroutine at a time (for example a goroutine that owns the view). Use `runtime.LockOSThread` in that goroutine: the Vulkan driver can keep state on the thread.

## Speed and memory

- The reader takes about 0.4 s for 85 MB of G-code on a desktop CPU (x86-64). The Pi 5 is slower: plan for a few seconds.
- The reader keeps 24 bytes for each move: 70 MB for an 85 MB file with 3 million moves. It never holds the whole file.
- The view puts 32 bytes for each bead in one GPU buffer, once. A position or a layer only changes how many beads draw.
- An offscreen print view keeps the finished layers in a cached image. When the camera and the colors stay the same, a frame draws only the new beads and the top layer. A touch that moves the camera draws all the beads once.
- The reduced view uses the coarse bead mesh (36 triangles for each bead in place of 100).
- `zs_view_draw`, `zs_view_read`, and the set and touch calls do not allocate memory.

## Thumbnails

`zs_gcode_thumbnail_png(g, w, h, by_feature, rgb, &png, &len)` draws the beads on the CPU (no GPU) in the view of the thumbnails of a slice, and gives a PNG with a clear background. Free it with `zs_buffer_free`.
