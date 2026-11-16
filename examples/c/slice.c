/* The example from docs/embedding/c.md, with a main function.
 * Build: zig build lib && zig cc -Izig-out/include examples/c/slice.c zig-out/lib/libzslice.a -lc -lpthread -o slice
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <stdio.h>
#include <zslice.h>

static int write_file(void *user, const uint8_t *data, size_t len) {
    return fwrite(data, 1, len, (FILE *)user) == len ? 0 : 1;
}

int slice(const uint8_t *stl, size_t stl_len, FILE *out) {
    zs_mesh *mesh = NULL;
    zs_settings *settings = NULL;
    zs_stats stats;
    int rc;

    rc = zs_mesh_load_stl(stl, stl_len, &mesh);
    if (rc != ZS_OK) goto done;

    rc = zs_settings_new(&settings);
    if (rc != ZS_OK) goto done;
    rc = zs_settings_set(settings, "project.wall_count", "3");
    if (rc != ZS_OK) goto done;

    rc = zs_slice(mesh, settings, write_file, out, &stats);
    if (rc == ZS_OK) {
        printf("%u layers, %.2f m filament\n", stats.layer_count, stats.filament_mm / 1000.0);
    }

done:
    if (rc != ZS_OK) fprintf(stderr, "zslice: %s\n", zs_status_string(rc));
    zs_settings_free(settings);
    zs_mesh_free(mesh);
    return rc;
}

#include <stdlib.h>

/* Usage: slice part.stl out.gcode */
int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s part.stl out.gcode\n", argv[0]);
        return 2;
    }
    FILE *in = fopen(argv[1], "rb");
    if (!in) return 1;
    fseek(in, 0, SEEK_END);
    long n = ftell(in);
    fseek(in, 0, SEEK_SET);
    uint8_t *buf = malloc(n);
    if (fread(buf, 1, n, in) != (size_t)n) return 1;
    fclose(in);
    FILE *out = fopen(argv[2], "wb");
    if (!out) return 1;
    int rc = slice(buf, n, out);
    fclose(out);
    free(buf);
    return rc;
}
