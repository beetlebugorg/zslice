/* printers.c: see printers.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "printers.h"

#include <glib/gstdio.h>
#include <string.h>

const char *const zg_link_titles[ZG_N_LINKS] = {
    "None (export a file)", "printdeck", "OctoPrint", "Moonraker (Klipper)", "USB (serial port)",
    "Bambu Lab (LAN mode)",
};

static const char *const link_keys[ZG_N_LINKS] = {"none", "printdeck", "octoprint", "moonraker", "usb", "bambu"};

static GPtrArray *printers;
static GKeyFile *general;
static char *current_id;
static gboolean first_start;

char *zg_config_dir(void) {
    const char *dir = g_getenv("ZSLICE_STATE_DIR");
    return dir ? g_strdup(dir) : g_build_filename(g_get_user_config_dir(), "zslice", NULL);
}

static char *ini_path(void) {
    char *dir = zg_config_dir();
    char *path = g_build_filename(dir, "app.ini", NULL);
    g_free(dir);
    return path;
}

char *zg_printer_profile_path(const ZgPrinter *p) {
    char *dir = zg_config_dir();
    char *file = g_strconcat(p->id, ".toml", NULL);
    char *path = g_build_filename(dir, "printers", file, NULL);
    g_free(file);
    g_free(dir);
    return path;
}

static void printer_free(gpointer data) {
    ZgPrinter *p = data;
    g_free(p->id);
    g_free(p->name);
    g_free(p->url);
    g_free(p->api_key);
    g_free(p->device);
    g_free(p->serial);
    g_free(p->tls_pin);
    g_free(p);
}

static ZgPrinter *printer_new(const char *id, const char *name) {
    ZgPrinter *p = g_new0(ZgPrinter, 1);
    p->id = g_strdup(id);
    p->name = g_strdup(name);
    p->url = g_strdup("");
    p->api_key = g_strdup("");
    p->device = g_strdup("");
    p->serial = g_strdup("");
    p->tls_pin = g_strdup("");
    p->baud = 250000;
    return p;
}

/* The file of the access code of a Bambu Lab printer:
 * <config>/bambu/<serial>.code, readable only by the user. The code is
 * not in app.ini. */
static char *code_path(const char *serial) {
    if (!serial || !serial[0] || strchr(serial, '/') || serial[0] == '.') return NULL;
    char *dir = zg_config_dir();
    char *file = g_strconcat(serial, ".code", NULL);
    char *path = g_build_filename(dir, "bambu", file, NULL);
    g_free(file);
    g_free(dir);
    return path;
}

static void read_code(ZgPrinter *p) {
    char *path = code_path(p->serial);
    char *text = NULL;
    if (path && g_file_get_contents(path, &text, NULL, NULL)) {
        g_free(p->api_key);
        p->api_key = g_strstrip(text);
    }
    g_free(path);
}

static void write_code(const ZgPrinter *p) {
    char *path = code_path(p->serial);
    if (!path || !p->api_key[0]) {
        g_free(path);
        return;
    }
    char *old = NULL;
    gboolean same = g_file_get_contents(path, &old, NULL, NULL) && strcmp(g_strstrip(old), p->api_key) == 0;
    g_free(old);
    if (!same) {
        char *dir = g_path_get_dirname(path);
        g_mkdir_with_parents(dir, 0700);
        g_free(dir);
        char *text = g_strconcat(p->api_key, "\n", NULL);
        if (g_file_set_contents_full(path, text, -1, G_FILE_SET_CONTENTS_CONSISTENT, 0600, NULL)) g_chmod(path, 0600);
        g_free(text);
    }
    g_free(path);
}

char *zg_printer_code_path(const ZgPrinter *p) {
    return code_path(p->serial);
}

static char *new_id(void) {
    for (int n = 1;; n++) {
        char *id = g_strdup_printf("printer-%d", n);
        if (!zg_printers_find(id)) return id;
        g_free(id);
    }
}

void zg_printers_load(void) {
    if (!printers) printers = g_ptr_array_new_with_free_func(printer_free);
    g_ptr_array_set_size(printers, 0);
    if (general) g_key_file_unref(general);
    general = g_key_file_new();
    char *path = ini_path();
    GKeyFile *kf = g_key_file_new();
    if (g_key_file_load_from_file(kf, path, G_KEY_FILE_KEEP_COMMENTS, NULL)) {
        gsize n = 0;
        char **groups = g_key_file_get_groups(kf, &n);
        for (gsize i = 0; i < n; i++) {
            if (g_str_has_prefix(groups[i], "printer ")) {
                const char *id = groups[i] + strlen("printer ");
                char *name = g_key_file_get_string(kf, groups[i], "name", NULL);
                ZgPrinter *p = printer_new(id, name ? name : id);
                g_free(name);
                char *kind = g_key_file_get_string(kf, groups[i], "connection", NULL);
                for (int k = 0; kind && k < ZG_N_LINKS; k++) {
                    if (strcmp(kind, link_keys[k]) == 0) p->kind = (ZgLinkKind)k;
                }
                g_free(kind);
                char *v;
                if ((v = g_key_file_get_string(kf, groups[i], "url", NULL))) { g_free(p->url); p->url = v; }
                if ((v = g_key_file_get_string(kf, groups[i], "api_key", NULL))) { g_free(p->api_key); p->api_key = v; }
                if ((v = g_key_file_get_string(kf, groups[i], "device", NULL))) { g_free(p->device); p->device = v; }
                if ((v = g_key_file_get_string(kf, groups[i], "serial", NULL))) { g_free(p->serial); p->serial = v; }
                if ((v = g_key_file_get_string(kf, groups[i], "tls_pin", NULL))) { g_free(p->tls_pin); p->tls_pin = v; }
                p->tls_since = g_key_file_get_int64(kf, groups[i], "tls_since", NULL);
                int baud = g_key_file_get_integer(kf, groups[i], "baud", NULL);
                if (baud > 0) p->baud = baud;
                if (p->kind == ZG_LINK_BAMBU) read_code(p);
                g_ptr_array_add(printers, p);
            } else if (strcmp(groups[i], "general") == 0) {
                gsize nk = 0;
                char **keys = g_key_file_get_keys(kf, "general", &nk, NULL);
                for (gsize k = 0; k < nk; k++) {
                    char *v = g_key_file_get_string(kf, "general", keys[k], NULL);
                    if (v) g_key_file_set_string(general, "general", keys[k], v);
                    g_free(v);
                }
                g_strfreev(keys);
            }
        }
        g_strfreev(groups);
    }
    g_key_file_unref(kf);
    g_free(path);

    g_free(current_id);
    current_id = g_key_file_get_string(general, "general", "printer", NULL);
    if (printers->len == 0) {
        /* The first start: one printer, with the machine settings of an
         * older version (machine.toml), if there are any. */
        ZgPrinter *p = printer_new("printer-1", "My printer");
        g_ptr_array_add(printers, p);
        char *dir = zg_config_dir();
        char *old = g_build_filename(dir, "machine.toml", NULL);
        char *profile = zg_printer_profile_path(p);
        char *pdir = g_path_get_dirname(profile);
        g_mkdir_with_parents(pdir, 0700);
        if (g_file_test(old, G_FILE_TEST_EXISTS)) g_rename(old, profile);
        else first_start = TRUE;
        g_free(pdir);
        g_free(profile);
        g_free(old);
        g_free(dir);
        g_free(current_id);
        current_id = g_strdup(p->id);
        zg_printers_save();
    }
    if (!current_id || !zg_printers_find(current_id)) {
        g_free(current_id);
        current_id = g_strdup(((ZgPrinter *)g_ptr_array_index(printers, 0))->id);
    }
}

void zg_printers_save(void) {
    GKeyFile *kf = g_key_file_new();
    g_key_file_set_comment(kf, NULL, NULL, " zslice: the printers and the app settings. The machine settings of each\n printer are in printers/<id>.toml.", NULL);
    gsize nk = 0;
    char **keys = general ? g_key_file_get_keys(general, "general", &nk, NULL) : NULL;
    for (gsize k = 0; k < nk; k++) {
        char *v = g_key_file_get_string(general, "general", keys[k], NULL);
        g_key_file_set_string(kf, "general", keys[k], v);
        g_free(v);
    }
    g_strfreev(keys);
    if (current_id) g_key_file_set_string(kf, "general", "printer", current_id);
    for (guint i = 0; printers && i < printers->len; i++) {
        ZgPrinter *p = g_ptr_array_index(printers, i);
        char *group = g_strconcat("printer ", p->id, NULL);
        g_key_file_set_string(kf, group, "name", p->name);
        g_key_file_set_string(kf, group, "connection", link_keys[p->kind]);
        if (p->url[0]) g_key_file_set_string(kf, group, "url", p->url);
        if (p->kind == ZG_LINK_BAMBU) write_code(p);
        else if (p->api_key[0]) g_key_file_set_string(kf, group, "api_key", p->api_key);
        if (p->device[0]) g_key_file_set_string(kf, group, "device", p->device);
        if (p->serial[0]) g_key_file_set_string(kf, group, "serial", p->serial);
        if (p->tls_pin[0]) {
            g_key_file_set_string(kf, group, "tls_pin", p->tls_pin);
            g_key_file_set_int64(kf, group, "tls_since", p->tls_since);
        }
        if (p->kind == ZG_LINK_USB) g_key_file_set_integer(kf, group, "baud", p->baud);
        g_free(group);
    }
    char *path = ini_path();
    char *dir = g_path_get_dirname(path);
    g_mkdir_with_parents(dir, 0700);
    gsize len = 0;
    char *text = g_key_file_to_data(kf, &len, NULL);
    GError *error = NULL;
    if (!g_file_set_contents_full(path, text, (gssize)len, G_FILE_SET_CONTENTS_CONSISTENT, 0600, &error)) {
        g_warning("zslice: %s was not saved: %s", path, error->message);
        g_error_free(error);
    }
    g_free(text);
    g_free(dir);
    g_free(path);
    g_key_file_unref(kf);
}

guint zg_printers_count(void) {
    return printers ? printers->len : 0;
}

ZgPrinter *zg_printers_get(guint index) {
    return printers && index < printers->len ? g_ptr_array_index(printers, index) : NULL;
}

ZgPrinter *zg_printers_find(const char *id) {
    for (guint i = 0; id && printers && i < printers->len; i++) {
        ZgPrinter *p = g_ptr_array_index(printers, i);
        if (strcmp(p->id, id) == 0) return p;
    }
    return NULL;
}

ZgPrinter *zg_printers_current(void) {
    ZgPrinter *p = zg_printers_find(current_id);
    return p ? p : zg_printers_get(0);
}

void zg_printers_set_current(const char *id) {
    if (!zg_printers_find(id)) return;
    g_free(current_id);
    current_id = g_strdup(id);
    zg_printers_save();
}

ZgPrinter *zg_printers_add(const char *name) {
    char *id = new_id();
    ZgPrinter *p = printer_new(id, name);
    g_free(id);
    g_ptr_array_add(printers, p);
    zg_printers_save();
    return p;
}

void zg_printers_remove(const char *id) {
    if (zg_printers_count() <= 1) return;
    for (guint i = 0; i < printers->len; i++) {
        ZgPrinter *p = g_ptr_array_index(printers, i);
        if (strcmp(p->id, id) != 0) continue;
        char *profile = zg_printer_profile_path(p);
        g_unlink(profile);
        g_free(profile);
        g_ptr_array_remove_index(printers, i);
        break;
    }
    if (!zg_printers_find(current_id)) {
        g_free(current_id);
        current_id = g_strdup(((ZgPrinter *)g_ptr_array_index(printers, 0))->id);
    }
    zg_printers_save();
}

char *zg_pref_get(const char *key, const char *fallback) {
    char *v = general ? g_key_file_get_string(general, "general", key, NULL) : NULL;
    return v ? v : g_strdup(fallback);
}

void zg_pref_set(const char *key, const char *value) {
    if (!general) general = g_key_file_new();
    g_key_file_set_string(general, "general", key, value);
    zg_printers_save();
}

gboolean zg_printers_first_start(void) {
    return first_start;
}

void zg_printers_set_first_start(gboolean on) {
    first_start = on;
}
