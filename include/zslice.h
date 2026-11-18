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
    ZS_WRITE_FAILED = 9,
    ZS_CANCELED = 10,
    ZS_BUSY = 11,
    ZS_NO_MODEL = 12,
    ZS_NO_RESULT = 13,
    ZS_OUT_OF_RANGE = 14,
    ZS_NOT_SUPPORTED = 15, /* for example, no Vulkan for a 3D view */
    ZS_GPU_FAILED = 16,
    ZS_PART_TOO_THIN = 17 /* lower than half of the first layer */
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
/* A status in words for a person, with what to do where it helps (the same
 * texts in each app). */
const char *zs_status_message(int status);
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

/* ---- signed G-code (src/gcode_sign.zig) ----
 *
 * The last line of a signed file is a comment:
 *   ; zslice-signature: ed25519 <key id> <base64 signature>
 * The signature is Ed25519 over the SHA-256 hash of all bytes before that
 * line. The key id is the first 8 bytes of the SHA-256 hash of the public
 * key, in hex (16 characters).
 *
 * The key texts: "zslice-secret-key ed25519 <base64 seed>" and
 * "ed25519 <base64 public key>". Each fits in ZS_SIGN_TEXT_MAX bytes with
 * its NUL byte. */
#define ZS_SIGN_TEXT_MAX 128

enum zs_signature_result {
    ZS_SIGNATURE_OK = 0,          /* a good signature of a trusted key */
    ZS_SIGNATURE_UNSIGNED = 1,    /* no signature line */
    ZS_SIGNATURE_UNKNOWN_KEY = 2, /* the key is not in the trusted list */
    ZS_SIGNATURE_BAD = 3          /* a malformed line, or a changed file */
};

/* The secret key text of 32 random bytes from the OS (getrandom,
 * SecRandomCopyBytes). out gets cap bytes at most. */
int zs_sign_key_from_seed(const uint8_t *seed, size_t seed_len, char *out, size_t cap);
/* The public key text of a secret key text. */
int zs_sign_public_key(const char *secret, char *out, size_t cap);
/* The key id of a public key text (17 bytes with the NUL byte). */
int zs_sign_key_id(const char *public_key, char *out, size_t cap);
/* A copy of the G-code with the signature line at its end. An old
 * signature line goes away first. Free it with zs_buffer_free. */
int zs_sign_gcode(const char *secret, const uint8_t *gcode, size_t len, uint8_t **out, size_t *out_len);
/* Checks the signature of G-code. trusted: public key texts, one on each
 * line. result gets an enum zs_signature_result. key_id (17 bytes, or
 * NULL) gets the key id of the signature line, or "". */
int zs_verify_gcode(const uint8_t *gcode, size_t len, const char *trusted, int *result, char *key_id);

#ifdef __cplusplus
}
#endif

#endif
