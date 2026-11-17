/* cura-stack.c: see cura-stack.h.
 *
 * The Cura files (cura.cfg, the .cfg files of the stacks, and the
 * containers) are in the layout of Ultimaker Cura (see REFERENCES.md).
 * This file only reads them.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "cura-stack.h"

#include <json-glib/json-glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct ZgCuraStack {
    char *version;   /* "5.14" */
    char *data_dir;  /* ~/.local/share/cura/5.14 */
    char *resources; /* the resources of Cura, or NULL */
    char *title;
    char *json;      /* the cura.json text */
    GPtrArray *bytes; /* the texts that zg_cura_stack_read gave */
};

/* The layers of a [containers] list, from the top. */
enum { L_USER, L_QUALITY_CHANGES, L_INTENT, L_QUALITY, L_MATERIAL, L_VARIANT, L_DEFINITION_CHANGES, L_DEFINITION, L_COUNT };

/* ---- small readers ---- */

/* The value of `key` in `section` of an INI text, or NULL. Free with
 * g_free. Only the first line of a value. */
static char *ini_get(const char *text, const char *section, const char *key) {
    char **lines = g_strsplit(text, "\n", -1);
    char *result = NULL;
    gboolean in = FALSE;
    for (int i = 0; lines[i] && !result; i++) {
        char *line = g_strstrip(lines[i]);
        if (line[0] == '[') {
            char *end = strchr(line, ']');
            in = end && (size_t)(end - line - 1) == strlen(section) && strncmp(line + 1, section, strlen(section)) == 0;
            continue;
        }
        if (!in) continue;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        if (strcmp(g_strstrip(line), key) == 0) result = g_strdup(g_strstrip(eq + 1));
    }
    g_strfreev(lines);
    return result;
}

/* The ids of the [containers] list of a stack file, by layer. Only this
 * section is read: the [metadata] of a printer can hold a password or an
 * API key. */
static void read_containers(const char *text, char *ids[L_COUNT]) {
    for (int i = 0; i < L_COUNT; i++) {
        char key[4];
        g_snprintf(key, sizeof key, "%d", i);
        ids[i] = ini_get(text, "containers", key);
    }
}

static char *read_text(const char *path) {
    char *text = NULL;
    if (!g_file_get_contents(path, &text, NULL, NULL)) return NULL;
    return text;
}

/* The file name of a container id, as Cura writes it (Python
 * urllib.parse.quote_plus). */
static char *escape_id(const char *id) {
    GString *s = g_string_new(NULL);
    for (const unsigned char *p = (const unsigned char *)id; *p; p++) {
        if (g_ascii_isalnum(*p) || strchr("_.-~", *p)) g_string_append_c(s, (char)*p);
        else if (*p == ' ') g_string_append_c(s, '+');
        else g_string_append_printf(s, "%%%02X", *p);
    }
    return g_string_free(s, FALSE);
}

/* The text of a file name that Cura escaped. */
static char *unescape_name(const char *name) {
    GString *s = g_string_new(NULL);
    for (const char *p = name; *p; p++) {
        if (*p == '+') {
            g_string_append_c(s, ' ');
        } else if (*p == '%' && g_ascii_isxdigit(p[1]) && g_ascii_isxdigit(p[2])) {
            g_string_append_c(s, (char)(g_ascii_xdigit_value(p[1]) * 16 + g_ascii_xdigit_value(p[2])));
            p += 2;
        } else {
            g_string_append_c(s, *p);
        }
    }
    return g_string_free(s, FALSE);
}

/* Finds `name` in `dir` and, with `deep`, in its subfolders. */
static char *find_in(const char *dir, const char *name, gboolean deep) {
    char *path = g_build_filename(dir, name, NULL);
    if (g_file_test(path, G_FILE_TEST_IS_REGULAR)) return path;
    g_free(path);
    if (!deep) return NULL;
    GDir *d = g_dir_open(dir, 0, NULL);
    if (!d) return NULL;
    char *found = NULL;
    const char *entry;
    while (!found && (entry = g_dir_read_name(d))) {
        char *sub = g_build_filename(dir, entry, NULL);
        if (g_file_test(sub, G_FILE_TEST_IS_DIR)) found = find_in(sub, name, TRUE);
        g_free(sub);
    }
    g_dir_close(d);
    return found;
}

/* The file of container `id` with extension `ext`: first in the user
 * folder `sub`, then in the same folder of the resources (with its
 * subfolders). */
static char *find_container(const ZgCuraStack *st, const char *sub, const char *id, const char *ext) {
    char *escaped = escape_id(id);
    char *names[2] = {g_strconcat(escaped, ext, NULL), g_strconcat(id, ext, NULL)};
    g_free(escaped);
    char *found = NULL;
    char *user = g_build_filename(st->data_dir, sub, NULL);
    for (int i = 0; i < 2 && !found; i++) found = find_in(user, names[i], FALSE);
    g_free(user);
    if (!found && st->resources) {
        char *res = g_build_filename(st->resources, sub, NULL);
        for (int i = 0; i < 2 && !found; i++) found = find_in(res, names[i], TRUE);
        g_free(res);
    }
    g_free(names[0]);
    g_free(names[1]);
    return found;
}

/* The file of a material. The id of a material for one printer is the id
 * of its base file with more words after it ("generic_pla_175_<printer>"),
 * so the longest start of the id that names a file is the base file. */
static char *find_material(const ZgCuraStack *st, const char *id) {
    char *try = g_strdup(id);
    char *found = NULL;
    for (;;) {
        found = find_container(st, "materials", try, ".xml.fdm_material");
        if (found) break;
        char *cut = strrchr(try, '_');
        if (!cut) break;
        *cut = 0;
    }
    g_free(try);
    return found;
}

static gboolean is_empty_id(const char *id) {
    return !id || !id[0] || g_str_has_prefix(id, "empty_");
}

/* The newest version folder ("5.14") in `dir`, or NULL. */
static char *newest_version(const char *dir) {
    GDir *d = g_dir_open(dir, 0, NULL);
    if (!d) return NULL;
    char *best = NULL;
    int best_major = -1, best_minor = -1;
    const char *entry;
    while ((entry = g_dir_read_name(d))) {
        int major = 0, minor = 0;
        char end = 0;
        if (sscanf(entry, "%d.%d%c", &major, &minor, &end) != 2) continue;
        if (major > best_major || (major == best_major && minor > best_minor)) {
            best_major = major;
            best_minor = minor;
            g_free(best);
            best = g_strdup(entry);
        }
    }
    g_dir_close(d);
    return best;
}

static char *find_resources(void) {
    const char *env = g_getenv("ZSLICE_CURA_RESOURCES");
    if (env && env[0]) return g_strdup(env);
    const char *dirs[] = {"/opt/ultimaker-cura/share/cura/resources", "/usr/share/cura/resources", "/usr/local/share/cura/resources"};
    for (size_t i = 0; i < G_N_ELEMENTS(dirs); i++) {
        char *def = g_build_filename(dirs[i], "definitions", "fdmprinter.def.json", NULL);
        gboolean ok = g_file_test(def, G_FILE_TEST_IS_REGULAR);
        g_free(def);
        if (ok) return g_strdup(dirs[i]);
    }
    return NULL;
}

/* The extruder stack of `machine` with the lowest position, or NULL. */
static char *find_extruder_stack(const char *data_dir, const char *machine) {
    char *dir = g_build_filename(data_dir, "extruders", NULL);
    GDir *d = g_dir_open(dir, 0, NULL);
    char *best = NULL;
    int best_pos = G_MAXINT;
    const char *entry;
    while (d && (entry = g_dir_read_name(d))) {
        if (!g_str_has_suffix(entry, ".extruder.cfg")) continue;
        char *path = g_build_filename(dir, entry, NULL);
        char *text = read_text(path);
        char *m = text ? ini_get(text, "metadata", "machine") : NULL;
        char *pos = text ? ini_get(text, "metadata", "position") : NULL;
        int p = pos ? atoi(pos) : 0;
        if (m && strcmp(m, machine) == 0 && p < best_pos) {
            best_pos = p;
            g_free(best);
            best = g_strdup(path);
        }
        g_free(m);
        g_free(pos);
        g_free(text);
        g_free(path);
    }
    if (d) g_dir_close(d);
    g_free(dir);
    return best;
}

/* The global stack file of `machine`: the file whose name is the escaped
 * name of the printer. */
static char *find_global_stack(const char *data_dir, const char *machine) {
    char *dir = g_build_filename(data_dir, "machine_instances", NULL);
    GDir *d = g_dir_open(dir, 0, NULL);
    char *found = NULL;
    const char *entry;
    while (d && !found && (entry = g_dir_read_name(d))) {
        if (!g_str_has_suffix(entry, ".global.cfg")) continue;
        char *base = g_strndup(entry, strlen(entry) - strlen(".global.cfg"));
        char *name = unescape_name(base);
        if (strcmp(name, machine) == 0) found = g_build_filename(dir, entry, NULL);
        g_free(name);
        g_free(base);
    }
    if (d) g_dir_close(d);
    g_free(dir);
    return found;
}

/* ---- the stack ---- */

static void add_path(JsonBuilder *b, const char *key, const char *path) {
    if (!path) return;
    json_builder_set_member_name(b, key);
    json_builder_add_string_value(b, path);
}

static void free_ids(char *ids[L_COUNT]) {
    for (int i = 0; i < L_COUNT; i++) g_free(ids[i]);
}

/* The [general] name of an .inst.cfg file, or NULL. */
static char *container_name(const char *path) {
    if (!path) return NULL;
    char *text = read_text(path);
    char *name = text ? ini_get(text, "general", "name") : NULL;
    g_free(text);
    return name;
}

ZgCuraStack *zg_cura_stack_find(GError **error) {
    char *config_root = g_build_filename(g_get_user_config_dir(), "cura", NULL);
    char *version = newest_version(config_root);
    if (!version) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT, "Cura has no settings in %s.", config_root);
        g_free(config_root);
        return NULL;
    }
    char *cfg_path = g_build_filename(config_root, version, "cura.cfg", NULL);
    g_free(config_root);
    char *cfg = read_text(cfg_path);
    char *machine = cfg ? ini_get(cfg, "general", "active_machine") : NULL;
    if (!machine && cfg) machine = ini_get(cfg, "cura", "active_machine");
    g_free(cfg);
    if (!machine || !machine[0]) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT, "%s names no active printer.", cfg_path);
        g_free(cfg_path);
        g_free(machine);
        g_free(version);
        return NULL;
    }
    g_free(cfg_path);

    ZgCuraStack *st = g_new0(ZgCuraStack, 1);
    st->version = version;
    st->data_dir = g_build_filename(g_get_user_data_dir(), "cura", version, NULL);
    st->resources = find_resources();
    st->bytes = g_ptr_array_new_with_free_func(g_free);

    char *global_path = find_global_stack(st->data_dir, machine);
    char *extruder_path = find_extruder_stack(st->data_dir, machine);
    if (!global_path) {
        g_set_error(error, G_FILE_ERROR, G_FILE_ERROR_NOENT, "Cura %s has no stack file for the printer \"%s\".", version, machine);
        g_free(machine);
        g_free(extruder_path);
        zg_cura_stack_free(st);
        return NULL;
    }
    char *g_ids[L_COUNT] = {0}, *e_ids[L_COUNT] = {0};
    char *text = read_text(global_path);
    if (text) read_containers(text, g_ids);
    g_free(text);
    if (extruder_path) {
        text = read_text(extruder_path);
        if (text) read_containers(text, e_ids);
        g_free(text);
    }
    g_free(global_path);
    g_free(extruder_path);

    /* The files of the layers: [0] global, [1] extruder. */
    struct {
        const char *json_key;
        const char *sub;
        const char *ext;
    } layers[L_COUNT] = {
        [L_USER] = {"user", "user", ".inst.cfg"},
        [L_QUALITY_CHANGES] = {"quality_changes", "quality_changes", ".inst.cfg"},
        [L_INTENT] = {"intent", "intent", ".inst.cfg"},
        [L_QUALITY] = {"quality", "quality", ".inst.cfg"},
        [L_MATERIAL] = {"material", "materials", ".xml.fdm_material"},
        [L_VARIANT] = {"variant", "variants", ".inst.cfg"},
        [L_DEFINITION_CHANGES] = {"definition_changes", "definition_changes", ".inst.cfg"},
    };
    char *files[2][L_COUNT] = {{0}};
    char **ids[2] = {g_ids, e_ids};
    for (int s = 0; s < 2; s++) {
        for (int l = 0; l < L_DEFINITION; l++) {
            const char *id = ids[s][l];
            if (is_empty_id(id)) continue;
            files[s][l] = l == L_MATERIAL ? find_material(st, id) : find_container(st, layers[l].sub, id, layers[l].ext);
        }
    }

    JsonBuilder *b = json_builder_new();
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "cura");
    json_builder_add_string_value(b, st->version);
    add_path(b, "machine", g_ids[L_DEFINITION]);
    add_path(b, "extruder", e_ids[L_DEFINITION]);
    add_path(b, "definition_changes", files[0][L_DEFINITION_CHANGES]);
    add_path(b, "definition_changes_extruder", files[1][L_DEFINITION_CHANGES]);
    add_path(b, "variant", files[1][L_VARIANT] ? files[1][L_VARIANT] : files[0][L_VARIANT]);
    const char *material = files[1][L_MATERIAL] ? files[1][L_MATERIAL] : files[0][L_MATERIAL];
    json_builder_set_member_name(b, "profiles");
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "active");
    json_builder_begin_object(b);
    add_path(b, "material", material);
    for (int l = L_QUALITY; l >= L_USER; l--) {
        add_path(b, layers[l].json_key, files[0][l]);
        char *ext_key = g_strconcat(layers[l].json_key, "_extruder", NULL);
        add_path(b, ext_key, files[1][l]);
        g_free(ext_key);
    }
    json_builder_end_object(b);
    json_builder_end_object(b);
    if (material) {
        json_builder_set_member_name(b, "materials");
        json_builder_begin_object(b);
        json_builder_set_member_name(b, "active");
        json_builder_begin_object(b);
        add_path(b, "file", material);
        json_builder_end_object(b);
        json_builder_end_object(b);
    }
    json_builder_end_object(b);
    JsonNode *root = json_builder_get_root(b);
    st->json = json_to_string(root, TRUE);
    json_node_unref(root);
    g_object_unref(b);

    /* The title: the printer, the profile, and the material. */
    char *profile = container_name(files[0][L_QUALITY_CHANGES]);
    if (!profile) profile = container_name(files[0][L_QUALITY]);
    const char *mat_id = !is_empty_id(e_ids[L_MATERIAL]) ? e_ids[L_MATERIAL] : g_ids[L_MATERIAL];
    st->title = g_strdup_printf("Cura %s: %s, %s, %s", st->version, machine, profile ? profile : "no profile",
                                !is_empty_id(mat_id) ? mat_id : "no material");
    g_free(profile);
    for (int s = 0; s < 2; s++)
        for (int l = 0; l < L_COUNT; l++) g_free(files[s][l]);
    free_ids(g_ids);
    free_ids(e_ids);
    g_free(machine);
    return st;
}

void zg_cura_stack_free(ZgCuraStack *st) {
    if (!st) return;
    g_free(st->version);
    g_free(st->data_dir);
    g_free(st->resources);
    g_free(st->title);
    g_free(st->json);
    g_ptr_array_unref(st->bytes);
    g_free(st);
}

const char *zg_cura_stack_title(const ZgCuraStack *st) {
    return st->title;
}

const char *zg_cura_stack_read(void *ctx, const char *path, size_t *len) {
    ZgCuraStack *st = ctx;
    if (strcmp(path, "cura.json") == 0) {
        *len = strlen(st->json);
        return st->json;
    }
    char *found = NULL;
    if (g_str_has_prefix(path, "definitions/") && g_str_has_suffix(path, ".def.json")) {
        /* A definition: the user folders, then the resources. */
        const char *name = path + strlen("definitions/");
        const char *subs[] = {"definitions", "extruders"};
        for (size_t i = 0; i < G_N_ELEMENTS(subs) && !found; i++) {
            char *dir = g_build_filename(st->data_dir, subs[i], NULL);
            found = find_in(dir, name, FALSE);
            g_free(dir);
        }
        for (size_t i = 0; i < G_N_ELEMENTS(subs) && !found && st->resources; i++) {
            char *dir = g_build_filename(st->resources, subs[i], NULL);
            found = find_in(dir, name, TRUE);
            g_free(dir);
        }
    } else if (g_path_is_absolute(path)) {
        found = g_strdup(path);
    }
    if (!found) return NULL;
    char *text = NULL;
    gsize n = 0;
    gboolean ok = g_file_get_contents(found, &text, &n, NULL);
    g_free(found);
    if (!ok) return NULL;
    g_ptr_array_add(st->bytes, text);
    *len = n;
    return text;
}
