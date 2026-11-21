/* Draws a G-code file with the Direct3D 12 backend and checks the pixels.
 *
 * With no arguments the test makes a square tower. It checks that the frame
 * shows the model, also after a resize.
 *
 * Usage: view_offscreen [file.gcode [out.bmp]]
 * ZSLICE_WARP=1 draws with the software rasterizer.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zslice.h"
#include "zslice-app.h"

enum { WIDTH = 960, HEIGHT = 640, SMALL_W = 320, SMALL_H = 200, LAYERS = 60 };

static int fail(const char *what, int status) {
    fprintf(stderr, "FAIL: %s: %s\n", what, zs_status_string(status));
    return 1;
}

/* A hollow square tower, 30 mm wide and 12 mm tall, in the middle of a
 * 220 mm bed. */
static int feed_tower(zs_gcode *g) {
    static const double corners[5][2] = {{95, 95}, {125, 95}, {125, 125}, {95, 125}, {95, 95}};
    char line[128];
    int n = snprintf(line, sizeof line, "G21\nG90\nM83\n");
    int status = zs_gcode_feed(g, (const uint8_t *)line, (size_t)n);
    for (int l = 1; status == ZS_OK && l <= LAYERS; l++) {
        n = snprintf(line, sizeof line, "G1 Z%.2f F600\nG1 X95 Y95 F3000\n", l * 0.2);
        status = zs_gcode_feed(g, (const uint8_t *)line, (size_t)n);
        for (int k = 1; status == ZS_OK && k < 5; k++) {
            n = snprintf(line, sizeof line, "G1 X%.1f Y%.1f E1.2 F1200\n", corners[k][0], corners[k][1]);
            status = zs_gcode_feed(g, (const uint8_t *)line, (size_t)n);
        }
    }
    return status;
}

static int load(const char *path, zs_gcode **out) {
    int status;
    if (path) return zs_gcode_open(path, out);
    status = zs_gcode_new(out);
    if (status != ZS_OK) return status;
    status = feed_tower(*out);
    if (status == ZS_OK) status = zs_gcode_finish(*out);
    if (status != ZS_OK) {
        zs_gcode_free(*out);
        *out = NULL;
    }
    return status;
}

/* The pixels that differ from the corner of the picture, and the mean row
 * of them. */
static size_t count_model(const uint8_t *px, int w, int h, double *mean_row) {
    size_t n = 0;
    double rows = 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const uint8_t *p = px + (size_t)y * w * 4 + (size_t)x * 4;
            if (abs(p[0] - px[0]) + abs(p[1] - px[1]) + abs(p[2] - px[2]) > 48) {
                n++;
                rows += y;
            }
        }
    }
    *mean_row = n ? rows / (double)n : 0;
    return n;
}

static int write_bmp(const char *path, const uint8_t *bgra, int w, int h) {
    uint8_t header[54] = {'B', 'M'};
    uint32_t bytes = (uint32_t)w * (uint32_t)h * 4;
    uint32_t size = bytes + sizeof header;
    int32_t top_down = -h;
    uint32_t offset = sizeof header;
    uint32_t info = 40;
    uint16_t planes = 1;
    uint16_t bits = 32;
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    memcpy(header + 2, &size, 4);
    memcpy(header + 10, &offset, 4);
    memcpy(header + 14, &info, 4);
    memcpy(header + 18, &w, 4);
    memcpy(header + 22, &top_down, 4);
    memcpy(header + 26, &planes, 2);
    memcpy(header + 28, &bits, 2);
    memcpy(header + 34, &bytes, 4);
    fwrite(header, 1, sizeof header, f);
    fwrite(bgra, 1, bytes, f);
    fclose(f);
    return 1;
}

int main(int argc, char **argv) {
    const char *gcode_path = argc > 1 ? argv[1] : NULL;
    const char *bmp_path = argc > 2 ? argv[2] : NULL;
    static uint8_t pixels[WIDTH * HEIGHT * 4];
    static uint8_t small[SMALL_W * SMALL_H * 4];
    zs_gcode *g = NULL;
    zs_view *view = NULL;
    double row = 0;
    size_t model;
    int status;

    status = load(gcode_path, &g);
    if (status != ZS_OK) return fail("read the G-code", status);
    status = zs_view_offscreen(WIDTH, HEIGHT, ZS_VIEW_BGRA, &view);
    if (status != ZS_OK) return fail("make the view", status);
    status = zs_view_load_gcode(view, g, 220, 220);
    if (status != ZS_OK) return fail("load the G-code", status);
    zs_view_frame_part(view, 0.8f);
    status = zs_view_draw(view);
    if (status != ZS_OK) return fail("draw", status);
    status = zs_view_read(view, pixels, sizeof pixels, WIDTH * 4);
    if (status != ZS_OK) return fail("read the frame", status);
    if (bmp_path && !write_bmp(bmp_path, pixels, WIDTH, HEIGHT)) {
        fprintf(stderr, "FAIL: write %s\n", bmp_path);
        return 1;
    }

    model = count_model(pixels, WIDTH, HEIGHT, &row);
    printf("%d x %d: %zu model pixels, mean row %.0f\n", WIDTH, HEIGHT, model, row);
    if (model < (size_t)WIDTH * HEIGHT / 50) {
        fprintf(stderr, "FAIL: the frame shows no model\n");
        return 1;
    }

    /* A new size makes the targets again. */
    zs_view_resize(view, SMALL_W, SMALL_H);
    zs_view_frame_part(view, 0.8f);
    status = zs_view_draw(view);
    if (status != ZS_OK) return fail("draw after a resize", status);
    status = zs_view_read(view, small, sizeof small, SMALL_W * 4);
    if (status != ZS_OK) return fail("read after a resize", status);
    model = count_model(small, SMALL_W, SMALL_H, &row);
    printf("%d x %d: %zu model pixels\n", SMALL_W, SMALL_H, model);
    if (model < (size_t)SMALL_W * SMALL_H / 50) {
        fprintf(stderr, "FAIL: the frame after a resize shows no model\n");
        return 1;
    }

    zs_view_free(view);
    zs_gcode_free(g);
    printf("ok\n");
    return 0;
}
