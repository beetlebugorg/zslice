/* zslice: a slicer for FDM 3D printers. C API.
 *
 * Each function returns a status code. ZS_OK (0) is success.
 * zs_status_string gives the name of a code.
 *
 * Use:
 *   zs_mesh *mesh;
 *   zs_mesh_load_stl(bytes, len, &mesh);
 *   zs_settings *settings;
 *   zs_settings_new(&settings);
 *   zs_settings_set(settings, "project.wall_count", "3");
 *   zs_stats stats;
 *   zs_slice(mesh, settings, my_write, my_user_data, &stats);
 *   zs_settings_free(settings);
 *   zs_mesh_free(mesh);
 *
 * Settings have three groups: "machine.", "filament.", and "project.".
 * The group "engine." has options that do not change the print.
 * zs_setting_names lists all names.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#ifndef ZSLICE_H
#define ZSLICE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum zs_status {
    ZS_OK = 0,
    ZS_OUT_OF_MEMORY = 1,
    ZS_INVALID_ARGUMENT = 2,
    ZS_INVALID_MESH = 3,
    ZS_EMPTY_MESH = 4,
    ZS_UNKNOWN_SETTING = 5,
    ZS_INVALID_VALUE = 6,
    ZS_INVALID_SETTINGS = 7,
    ZS_PART_TOO_LARGE = 8,
    ZS_WRITE_FAILED = 9
};

typedef struct zs_mesh zs_mesh;
typedef struct zs_settings zs_settings;

typedef struct zs_stats {
    uint32_t layer_count;
    uint32_t retractions;
    double filament_mm;
    double filament_g;
    /* Distance / speed, without acceleration. The real print takes longer. */
    double print_time_s;
    double travel_mm;
} zs_stats;

/* Gets the G-code in parts. Return 0 to continue. Any other value stops the
 * slice with ZS_WRITE_FAILED. */
typedef int (*zs_write_fn)(void *user, const uint8_t *data, size_t len);

const char *zs_version(void);
const char *zs_status_string(int status);
/* All setting names ("group.name"), one on each line. */
const char *zs_setting_names(void);

/* Loads a binary or ASCII STL file from memory. */
int zs_mesh_load_stl(const uint8_t *data, size_t len, zs_mesh **out);
/* xyz has 9 floats for each triangle: x, y, z of each of 3 vertices, in mm,
 * counterclockwise as seen from outside. */
int zs_mesh_from_triangles(const float *xyz, size_t triangle_count, zs_mesh **out);
void zs_mesh_free(zs_mesh *mesh);

int zs_settings_new(zs_settings **out);
/* Sets one setting from text. The library copies the value. */
int zs_settings_set(zs_settings *settings, const char *key, const char *value);
void zs_settings_free(zs_settings *settings);

/* Slices the mesh and sends the G-code to write as it is made. settings can
 * be NULL (all defaults). stats can be NULL. */
int zs_slice(const zs_mesh *mesh, const zs_settings *settings, zs_write_fn write, void *user, zs_stats *stats);
/* Slices the mesh into one buffer. Free it with zs_buffer_free. */
int zs_slice_to_buffer(const zs_mesh *mesh, const zs_settings *settings, uint8_t **out, size_t *out_len, zs_stats *stats);
void zs_buffer_free(uint8_t *ptr, size_t len);

/* Memory for the host to pass data in (for wasm). */
uint8_t *zs_alloc(size_t len);
void zs_free(uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
