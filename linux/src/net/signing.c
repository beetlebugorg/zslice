/* signing.c: see signing.h.
 *
 * Ed25519 (RFC 8032) and SHA-256 (FIPS 180-4) are in the core
 * (zs_sign_gcode). See docs/references/formats-and-protocols.md.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "signing.h"

#include <errno.h>
#include <string.h>
#include <sys/random.h>
#include <zslice.h>

#include "../prefs/printers.h"

static gboolean loaded;
static char secret[ZS_SIGN_TEXT_MAX];
static char public_key[ZS_SIGN_TEXT_MAX];
static char key_id[17];

static gboolean random_bytes(uint8_t *out, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = getrandom(out + got, n - got, 0);
        if (r < 0) {
            if (errno == EINTR) continue;
            return FALSE;
        }
        got += (size_t)r;
    }
    return TRUE;
}

/* Reads the key file, or makes a new key and writes it. */
static void load(void) {
    if (loaded) return;
    loaded = TRUE;
    char *dir = zg_config_dir();
    char *path = g_build_filename(dir, "signing.key", NULL);
    char *text = NULL;
    gboolean ok = FALSE;
    if (g_file_get_contents(path, &text, NULL, NULL)) {
        g_strstrip(text);
        ok = strlen(text) < sizeof secret && zs_sign_public_key(text, public_key, sizeof public_key) == ZS_OK;
        if (ok) g_strlcpy(secret, text, sizeof secret);
        else g_warning("zslice: %s does not read: prints go out with no signature", path);
    } else {
        uint8_t seed[32];
        GError *error = NULL;
        if (!random_bytes(seed, sizeof seed) || zs_sign_key_from_seed(seed, sizeof seed, secret, sizeof secret) != ZS_OK) {
            g_warning("zslice: no random bytes for a signing key");
        } else {
            char *line = g_strconcat(secret, "\n", NULL);
            g_mkdir_with_parents(dir, 0700);
            ok = g_file_set_contents_full(path, line, -1, G_FILE_SET_CONTENTS_CONSISTENT, 0600, &error) &&
                 zs_sign_public_key(secret, public_key, sizeof public_key) == ZS_OK;
            if (error) {
                g_warning("zslice: %s was not saved: %s", path, error->message);
                g_error_free(error);
            }
            g_free(line);
        }
        memset(seed, 0, sizeof seed);
    }
    if (ok && zs_sign_key_id(public_key, key_id, sizeof key_id) != ZS_OK) ok = FALSE;
    if (!ok) {
        memset(secret, 0, sizeof secret);
        public_key[0] = key_id[0] = 0;
    }
    if (text) {
        memset(text, 0, strlen(text));
        g_free(text);
    }
    g_free(path);
    g_free(dir);
}

const char *zg_signing_public_key(void) {
    load();
    return public_key[0] ? public_key : NULL;
}

const char *zg_signing_key_id(void) {
    load();
    return key_id[0] ? key_id : NULL;
}

GBytes *zg_sign_gcode(GBytes *gcode) {
    load();
    if (!secret[0]) return g_bytes_ref(gcode);
    gsize len = 0;
    const uint8_t *data = g_bytes_get_data(gcode, &len);
    uint8_t *out = NULL;
    size_t out_len = 0;
    if (zs_sign_gcode(secret, data, len, &out, &out_len) != ZS_OK) {
        g_warning("zslice: the G-code was not signed");
        return g_bytes_ref(gcode);
    }
    GBytes *copy = g_bytes_new(out, out_len);
    zs_buffer_free(out, out_len);
    return copy;
}
