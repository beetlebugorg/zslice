/* bed-model.c: see bed-model.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "bed-model.h"

#include <gio/gio.h>

static zs_printers *library(void) {
    static zs_printers *lib;
    static gboolean tried;
    if (!tried) {
        tried = TRUE;
        if (zs_printers_builtin(&lib) != ZS_OK) lib = NULL;
    }
    return lib;
}

static const char *beds_dir(void) {
    static char *dir;
    if (dir) return dir;
    const char *env = g_getenv("ZSLICE_BEDS_DIR");
    if (env && g_file_test(env, G_FILE_TEST_IS_DIR)) return dir = g_strdup(env);
    char *exe = g_file_read_link("/proc/self/exe", NULL);
    if (exe) {
        char *bin = g_path_get_dirname(exe);
        char *installed = g_build_filename(bin, "..", "share", "zslice", "beds", NULL);
        g_free(bin);
        g_free(exe);
        if (g_file_test(installed, G_FILE_TEST_IS_DIR)) return dir = installed;
        g_free(installed);
    }
#ifdef ZG_BEDS_SRC_DIR
    if (g_file_test(ZG_BEDS_SRC_DIR, G_FILE_TEST_IS_DIR)) return dir = g_strdup(ZG_BEDS_SRC_DIR);
#endif
    return NULL;
}

char *zg_bed_file_path(const char *name) {
    const char *dir = beds_dir();
    if (!name || !name[0] || !dir) return NULL;
    return g_build_filename(dir, name, NULL);
}

/* The bytes of a file in the bed folder, or NULL. */
static char *read_bed_file(const char *name, gsize *len) {
    *len = 0;
    const char *dir = beds_dir();
    if (!name || !name[0] || !dir) return NULL;
    char *path = g_build_filename(dir, name, NULL);
    char *data = NULL;
    if (!g_file_get_contents(path, &data, len, NULL)) {
        g_warning("zslice: the bed file %s did not load", path);
        data = NULL;
        *len = 0;
    }
    g_free(path);
    return data;
}

void zg_bed_model_update(zs_view *view, const zs_app *app) {
    static zs_view *shown_view;
    static ptrdiff_t shown = -2;
    zs_printers *lib = library();
    if (!view || !app || !lib) return;
    char model[256] = "", name[256] = "";
    size_t n;
    if (zs_app_setting_get(app, "machine.model", model, sizeof model, &n) != ZS_OK) model[0] = 0;
    if (zs_app_setting_get(app, "machine.name", name, sizeof name, &n) != ZS_OK) name[0] = 0;
    ptrdiff_t i = zs_printers_find_machine(lib, model, name);
    if (view == shown_view && i == shown) return;
    shown_view = view;
    shown = i;
    zs_printer_bed bed;
    if (i < 0 || zs_printers_bed(lib, (size_t)i, &bed) != ZS_OK) {
        zs_view_clear_bed(view);
        return;
    }
    gsize mesh_len, tex_len;
    char *mesh = read_bed_file(bed.mesh, &mesh_len);
    char *tex = read_bed_file(bed.texture, &tex_len);
    if (!mesh && !tex) {
        zs_view_clear_bed(view);
    } else if (zs_view_set_bed(view, lib, (size_t)i, (const uint8_t *)mesh, mesh_len, (const uint8_t *)tex, tex_len) != ZS_OK) {
        g_warning("zslice: the bed model %s did not load", bed.mesh);
        zs_view_clear_bed(view);
    }
    g_free(mesh);
    g_free(tex);
}
