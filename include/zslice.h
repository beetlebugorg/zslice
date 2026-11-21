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

/* ---- links that open a model (src/open_link.zig) ----
 *
 * The "Open in slicer" link of a model site:
 *   zslice://open?file=<percent-encoded https URL>
 * The web app takes web+zslice:// in place of zslice://. The rules are
 * the same in each app (docs/internals/open-links.md):
 *  1. zs_link_check reads the link. It takes only https URLs of public
 *     host names: no IP address, no local name, no user name, no port
 *     other than 443.
 *  2. The app shows link.name (or "a model file") and link.host, and asks
 *     the user. It downloads only after a yes.
 *  3. The app resolves link.host and refuses the download if
 *     zs_link_address_public is 0 for an address, where the platform
 *     lets it. It checks the address of the connection too. It sends no
 *     cookie, no key, and no credentials, and it uses no proxy.
 *  4. It follows no redirect by itself: zs_link_redirect checks each
 *     Location, at most ZS_LINK_MAX_REDIRECTS times.
 *  5. zs_link_check_reply checks the head of the answer, and the app stops
 *     a download at ZS_LINK_MAX_BYTES.
 *  6. zs_link_file_name gives the name of the file. The app refuses a
 *     zslice project (zs_project_file_is), and opens the file on a new
 *     plate if the active plate has parts. A link never starts a print.
 * Each call returns an enum zs_link_result. zs_link_message gives its
 * text for the user. */
#define ZS_LINK_MAX_BYTES ((uint64_t)512 << 20)
#define ZS_LINK_MAX_REDIRECTS 5
#define ZS_LINK_URL_MAX 12304
#define ZS_LINK_HOST_MAX 256
#define ZS_LINK_NAME_MAX 512

enum zs_link_result {
    ZS_LINK_OK = 0,
    ZS_LINK_NOT_A_LINK = 1,         /* not a zslice://open?file= link */
    ZS_LINK_NOT_PUBLIC = 2,         /* not an https URL of a public host name */
    ZS_LINK_LOCAL_ADDRESS = 3,      /* the name resolves to a local address */
    ZS_LINK_NOT_A_MODEL = 4,        /* no STL, 3MF, STEP, STP, or OBJ name */
    ZS_LINK_PROJECT = 5,            /* a zslice project */
    ZS_LINK_TOO_LARGE = 6,          /* over ZS_LINK_MAX_BYTES */
    ZS_LINK_WEB_PAGE = 7,           /* the answer is an HTML page */
    ZS_LINK_TOO_MANY_REDIRECTS = 8,
    ZS_LINK_BAD_REDIRECT = 9        /* a redirect to a URL that fails the check */
};

/* A checked link. Each field is UTF-8 with a NUL byte. url: the clean
 * https URL. host: its host name in lowercase. name: the file name, or ""
 * if the URL has no model file name. */
typedef struct zs_link {
    char url[ZS_LINK_URL_MAX];
    char host[ZS_LINK_HOST_MAX];
    char name[ZS_LINK_NAME_MAX];
} zs_link;

/* Reads a zslice:// or web+zslice:// link into out. */
int zs_link_check(const char *text, zs_link *out);
/* Checks a plain https URL of a model file into out. */
int zs_link_check_url(const char *url, zs_link *out);
/* A redirect: link->url and link->host become the checked URL of the
 * Location header (absolute, or a path on the same host). */
int zs_link_redirect(const char *location, zs_link *link);
/* Checks the head of the answer: the Content-Type and the
 * Content-Length (-1 if none). */
int zs_link_check_reply(const char *content_type, int64_t length);
/* Sets link->name from the Content-Disposition header (or NULL), else from
 * link->url, else the old link->name. ZS_LINK_NOT_A_MODEL if none of them
 * is a model name. */
int zs_link_file_name(const char *disposition, zs_link *link);
/* The URL of the link (link->url), and a way to set it, for a language
 * that cannot read the long array of the struct (Swift). */
const char *zs_link_url(const zs_link *link);
void zs_link_set_url(zs_link *link, const char *url);
/* 1 for a public address: 4 bytes (IPv4) or 16 bytes (IPv6), in network
 * order. 0 for loopback, private, link-local, multicast, and the other
 * local ranges. */
int zs_link_address_public(const uint8_t *address, size_t len);
/* 1 for text that starts with zslice: or web+zslice:. */
int zs_link_is_link(const char *text);
/* 1 for a name that ends in .stl, .3mf, .step, .stp, or .obj. */
int zs_link_is_model_name(const char *name);
/* The text for the user of an enum zs_link_result. */
const char *zs_link_message(int result);
/* The limits, for a shell with no C header: ZS_LINK_MAX_BYTES,
 * ZS_LINK_MAX_REDIRECTS, and sizeof(zs_link). Each pointer can be NULL. */
void zs_link_limits(uint64_t *max_bytes, int *max_redirects, size_t *link_size);

#ifdef __cplusplus
}
#endif

#endif
