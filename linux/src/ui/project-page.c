/* project-page.c: see project-page.h.
 *
 * The plan (the parts and the plates) comes from the core
 * (zs_project_plan) as JSON. The page plans again at once after each
 * change of a count. The key of a plate for its status is the same as in
 * the web app: its printer, profile, material, and parts with their
 * counts.
 *
 * Async calls (a read of files, a request to GitHub) hold a reference to
 * the page. When the page goes, it cancels them, and their callbacks do
 * nothing.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "project-page.h"

#include "../net/project-source.h"
#include "../prefs/printers.h"

#include <glib/gstdio.h>
#include <json-glib/json-glib.h>
#include <string.h>

static const char *css =
    ".zg-proj { padding: 10px 12px; }\n"
    ".zg-proj-title { font-weight: bold; font-size: 1.05em; }\n"
    ".zg-proj-label { font-size: 0.85em; font-weight: bold; opacity: 0.75; margin-top: 6px; }\n"
    ".zg-proj-busy { font-size: 0.9em; color: @accent_color; }\n"
    ".zg-proj-error { color: #e01b24; }\n"
    ".zg-proj-h { margin-top: 8px; font-size: 0.85em; font-weight: bold; opacity: 0.7; }\n"
    ".zg-proj-plate { border-radius: 8px; padding: 8px 10px; background: alpha(currentColor, 0.05); }\n"
    ".zg-proj-plate.zg-proj-active { box-shadow: inset 3px 0 0 @accent_bg_color; background: alpha(@accent_bg_color, 0.15); }\n"
    ".zg-proj-plate.zg-proj-printed { opacity: 0.6; }\n"
    ".zg-proj-plate-title { font-weight: bold; }\n"
    ".zg-proj-small { font-size: 0.85em; }\n"
    ".zg-proj-printing .zg-proj-status { color: @accent_color; }\n"
    ".zg-proj-failed .zg-proj-status { color: #e01b24; }\n"
    ".zg-proj-group { font-size: 0.8em; font-weight: bold; opacity: 0.7; margin-top: 6px; }\n";

static void ensure_css(void) {
    static gboolean done = FALSE;
    if (done) return;
    done = TRUE;
    GtkCssProvider *p = gtk_css_provider_new();
    gtk_css_provider_load_from_string(p, css);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(p),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(p);
}

/* The status of a plate: the keys (as in project.json) and the labels. */
static const char *const status_keys[] = {"todo", "printing", "printed", "failed"};
static const char *const status_labels[] = {"To print", "Printing", "Printed", "Failed", NULL};

typedef struct {
    ZgModel *model;
    gboolean dead;
    GtkWidget *scroll, *box, *plates, *busy_label;
    ZgSource *source; /* NULL until the files of the project are there */
    /* The project (text NULL: no project). The source: "folder" with its
     * path, or "github" with owner, repo, and sha. */
    char *kind, *path, *owner, *repo, *sha;
    char *text;
    GArray *counts;     /* int for each part; -1: the count of printdeck.yml */
    GHashTable *status; /* plate key -> status key */
    char *active;       /* the key of the open plate, or NULL */
    JsonParser *plan;   /* the plan of text and counts */
    char *busy;         /* what runs now, or NULL */
    char *github_text;  /* the text of the GitHub entry */
    GCancellable *cancel;
    guint render_idle;
    /* The status lists of the plates and the count buttons of the parts
     * on the page now (for the test hook ZSLICE_PROJECT_DO). */
    GPtrArray *status_dds, *spins;
} Page;

static void render(Page *p);
static void test_plate(Page *p);

/* ---- the reference count of the page ---- */

static void page_clear(gpointer data) {
    Page *p = data;
    zg_source_unref(p->source);
    g_free(p->kind);
    g_free(p->path);
    g_free(p->owner);
    g_free(p->repo);
    g_free(p->sha);
    g_free(p->text);
    g_array_unref(p->counts);
    g_hash_table_unref(p->status);
    g_free(p->active);
    g_clear_object(&p->plan);
    g_free(p->busy);
    g_free(p->github_text);
    g_clear_object(&p->cancel);
    g_ptr_array_unref(p->status_dds);
    g_ptr_array_unref(p->spins);
    g_object_unref(p->model);
}

static Page *page_ref(Page *p) {
    return g_atomic_rc_box_acquire(p);
}

static void page_unref(Page *p) {
    g_atomic_rc_box_release_full(p, page_clear);
}

static void on_destroy(GtkWidget *w, gpointer data) {
    Page *p = data;
    p->dead = TRUE;
    g_cancellable_cancel(p->cancel);
    if (p->render_idle) g_source_remove(p->render_idle);
    p->render_idle = 0;
    g_signal_handlers_disconnect_by_data(p->model, p);
    page_unref(p);
}

/* ---- small helpers ---- */

static GtkWidget *label(const char *text, const char *cls) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(l), PANGO_WRAP_WORD_CHAR);
    if (cls) {
        char **c = g_strsplit(cls, " ", -1);
        for (int i = 0; c[i]; i++) gtk_widget_add_css_class(l, c[i]);
        g_strfreev(c);
    }
    return l;
}

static void show_error(Page *p, const char *message) {
    GtkRoot *root = gtk_widget_get_root(p->box);
    GtkAlertDialog *alert = gtk_alert_dialog_new("%s", message);
    gtk_alert_dialog_show(alert, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL);
    g_object_unref(alert);
}

static const char *str_member(JsonObject *o, const char *name) {
    JsonNode *n = o ? json_object_get_member(o, name) : NULL;
    return n && JSON_NODE_HOLDS_VALUE(n) && json_node_get_value_type(n) == G_TYPE_STRING ? json_node_get_string(n) : "";
}

static gint64 int_member(JsonObject *o, const char *name) {
    JsonNode *n = o ? json_object_get_member(o, name) : NULL;
    return n && JSON_NODE_HOLDS_VALUE(n) ? json_node_get_int(n) : 0;
}

static JsonArray *array_member(JsonObject *o, const char *name) {
    JsonNode *n = o ? json_object_get_member(o, name) : NULL;
    return n && JSON_NODE_HOLDS_ARRAY(n) ? json_node_get_array(n) : NULL;
}

/* The text after the first "/" of a profile ("taz/pla" -> "pla"). */
static const char *profile_name(const char *profile) {
    const char *slash = strchr(profile, '/');
    return slash ? slash + 1 : profile;
}

/* The folder of a profile ("taz/pla" -> "taz"). Free with g_free. */
static char *profile_folder(const char *profile) {
    const char *slash = strchr(profile, '/');
    return g_strndup(profile, slash ? (size_t)(slash - profile) : strlen(profile));
}

/* "printer · profile · material", with no empty parts. */
static char *facts(JsonObject *o) {
    GString *s = g_string_new(NULL);
    const char *parts[] = {str_member(o, "printer"), profile_name(str_member(o, "profile")), str_member(o, "material")};
    for (size_t i = 0; i < G_N_ELEMENTS(parts); i++) {
        if (!parts[i][0]) continue;
        if (s->len) g_string_append(s, " · ");
        g_string_append(s, parts[i]);
    }
    return g_string_free(s, FALSE);
}

/* ---- the state file ---- */

static char *state_path(void) {
    char *dir = zg_config_dir();
    char *path = g_build_filename(dir, "project.json", NULL);
    g_free(dir);
    return path;
}

static void save(Page *p) {
    char *path = state_path();
    if (!p->text) {
        g_unlink(path);
        g_free(path);
        return;
    }
    JsonBuilder *b = json_builder_new();
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "source");
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "kind");
    json_builder_add_string_value(b, p->kind);
    if (g_strcmp0(p->kind, "folder") == 0) {
        json_builder_set_member_name(b, "path");
        json_builder_add_string_value(b, p->path);
    } else {
        json_builder_set_member_name(b, "owner");
        json_builder_add_string_value(b, p->owner);
        json_builder_set_member_name(b, "repo");
        json_builder_add_string_value(b, p->repo);
        json_builder_set_member_name(b, "sha");
        json_builder_add_string_value(b, p->sha);
    }
    json_builder_end_object(b);
    json_builder_set_member_name(b, "text");
    json_builder_add_string_value(b, p->text);
    json_builder_set_member_name(b, "counts");
    json_builder_begin_array(b);
    for (guint i = 0; i < p->counts->len; i++) {
        int c = g_array_index(p->counts, int, i);
        if (c < 0) json_builder_add_null_value(b);
        else json_builder_add_int_value(b, c);
    }
    json_builder_end_array(b);
    json_builder_set_member_name(b, "status");
    json_builder_begin_object(b);
    GHashTableIter it;
    gpointer k, v;
    g_hash_table_iter_init(&it, p->status);
    while (g_hash_table_iter_next(&it, &k, &v)) {
        json_builder_set_member_name(b, k);
        json_builder_add_string_value(b, v);
    }
    json_builder_end_object(b);
    json_builder_set_member_name(b, "active");
    if (p->active) json_builder_add_string_value(b, p->active);
    else json_builder_add_null_value(b);
    json_builder_end_object(b);
    JsonGenerator *gen = json_generator_new();
    JsonNode *root = json_builder_get_root(b);
    json_generator_set_root(gen, root);
    gsize len = 0;
    char *data = json_generator_to_data(gen, &len);
    char *dir = g_path_get_dirname(path);
    if (g_mkdir_with_parents(dir, 0700) != 0 || !g_file_set_contents(path, data, (gssize)len, NULL))
        g_warning("zslice: the project was not saved to %s", path);
    g_free(dir);
    g_free(data);
    json_node_unref(root);
    g_object_unref(gen);
    g_object_unref(b);
    g_free(path);
}

static void clear_state(Page *p) {
    g_clear_pointer(&p->kind, g_free);
    g_clear_pointer(&p->path, g_free);
    g_clear_pointer(&p->owner, g_free);
    g_clear_pointer(&p->repo, g_free);
    g_clear_pointer(&p->sha, g_free);
    g_clear_pointer(&p->text, g_free);
    g_clear_pointer(&p->active, g_free);
    g_array_set_size(p->counts, 0);
    g_hash_table_remove_all(p->status);
    g_clear_object(&p->plan);
}

static void load(Page *p) {
    char *path = state_path();
    char *data = NULL;
    gsize len = 0;
    if (!g_file_get_contents(path, &data, &len, NULL)) {
        g_free(path);
        return;
    }
    JsonParser *parser = json_parser_new();
    if (json_parser_load_from_data(parser, data, (gssize)len, NULL) && JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser))) {
        JsonObject *o = json_node_get_object(json_parser_get_root(parser));
        JsonNode *sn = json_object_get_member(o, "source");
        JsonObject *s = sn && JSON_NODE_HOLDS_OBJECT(sn) ? json_node_get_object(sn) : NULL;
        const char *kind = str_member(s, "kind");
        if (str_member(o, "text")[0] && (strcmp(kind, "folder") == 0 || strcmp(kind, "github") == 0)) {
            p->kind = g_strdup(kind);
            p->path = g_strdup(str_member(s, "path"));
            p->owner = g_strdup(str_member(s, "owner"));
            p->repo = g_strdup(str_member(s, "repo"));
            p->sha = g_strdup(str_member(s, "sha"));
            p->text = g_strdup(str_member(o, "text"));
            JsonArray *counts = array_member(o, "counts");
            for (guint i = 0; counts && i < json_array_get_length(counts); i++) {
                JsonNode *n = json_array_get_element(counts, i);
                int c = JSON_NODE_HOLDS_VALUE(n) ? (int)json_node_get_int(n) : -1;
                g_array_append_val(p->counts, c);
            }
            JsonNode *st = json_object_get_member(o, "status");
            if (st && JSON_NODE_HOLDS_OBJECT(st)) {
                JsonObject *so = json_node_get_object(st);
                GList *keys = json_object_get_members(so);
                for (GList *l = keys; l; l = l->next)
                    g_hash_table_insert(p->status, g_strdup(l->data), g_strdup(str_member(so, l->data)));
                g_list_free(keys);
            }
            const char *active = str_member(o, "active");
            p->active = active[0] ? g_strdup(active) : NULL;
        }
    }
    g_object_unref(parser);
    g_free(data);
    g_free(path);
}

/* ---- the plan ---- */

/* The counts for the core: "n,-,n" ("-": the count of printdeck.yml). */
static char *counts_text(Page *p) {
    GString *s = g_string_new(NULL);
    for (guint i = 0; i < p->counts->len; i++) {
        int c = g_array_index(p->counts, int, i);
        if (i) g_string_append_c(s, ',');
        if (c < 0) g_string_append_c(s, '-');
        else g_string_append_printf(s, "%d", c);
    }
    return g_string_free(s, FALSE);
}

static void replan(Page *p) {
    g_clear_object(&p->plan);
    if (!p->text) return;
    char *counts = counts_text(p);
    size_t len = 0;
    if (zs_project_plan(p->text, counts, NULL, 0, &len) == ZS_OK) {
        char *json = g_malloc(len + 1);
        zs_project_plan(p->text, counts, json, len + 1, NULL);
        JsonParser *parser = json_parser_new();
        if (json_parser_load_from_data(parser, json, (gssize)len, NULL) && JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser)))
            p->plan = parser;
        else
            g_object_unref(parser);
        g_free(json);
    }
    g_free(counts);
}

static JsonObject *plan_root(Page *p) {
    return p->plan ? json_node_get_object(json_parser_get_root(p->plan)) : NULL;
}

/* The error of the plan with its line ("printdeck.yml, line 3: ..."), or
 * NULL. Free with g_free. */
static char *plan_error(Page *p) {
    JsonObject *o = plan_root(p);
    if (!o) return p->text ? g_strdup("printdeck.yml: the plan did not load.") : NULL;
    if (!json_object_has_member(o, "error")) return NULL;
    gint64 line = int_member(o, "line");
    return line > 0 ? g_strdup_printf("printdeck.yml, line %" G_GINT64_FORMAT ": %s", line, str_member(o, "error"))
                    : g_strdup_printf("printdeck.yml: %s", str_member(o, "error"));
}

static JsonObject *part_at(Page *p, gint64 i) {
    JsonArray *parts = array_member(plan_root(p), "parts");
    if (!parts || i < 0 || (guint)i >= json_array_get_length(parts)) return NULL;
    return json_array_get_object_element(parts, (guint)i);
}

/* The key of a plate for its status (plateKey of project.js). Free with
 * g_free. */
static char *plate_key(Page *p, JsonObject *plate) {
    GString *s = g_string_new(NULL);
    g_string_append_printf(s, "%s|%s|%s|", str_member(plate, "printer"), str_member(plate, "profile"), str_member(plate, "material"));
    JsonArray *items = array_member(plate, "items");
    for (guint i = 0; items && i < json_array_get_length(items); i++) {
        JsonObject *it = json_array_get_object_element(items, i);
        if (i) g_string_append_c(s, ',');
        g_string_append_printf(s, "%sx%" G_GINT64_FORMAT, str_member(part_at(p, int_member(it, "part")), "name"), int_member(it, "count"));
    }
    return g_string_free(s, FALSE);
}

static const char *status_of(Page *p, const char *key) {
    const char *s = g_hash_table_lookup(p->status, key);
    return s ? s : "todo";
}

/* ---- busy ---- */

static void set_busy(Page *p, const char *text) {
    gboolean was = p->busy != NULL;
    g_free(p->busy);
    p->busy = g_strdup(text);
    if (was != (text != NULL) || !p->busy_label) render(p);
    else gtk_label_set_text(GTK_LABEL(p->busy_label), text);
}

/* ---- open a project ---- */

typedef struct {
    Page *page;
    ZgSource *src;
} UseJob;

static void on_yml_read(GHashTable *files, const char *error, gpointer data) {
    UseJob *j = data;
    Page *p = j->page;
    if (!p->dead) {
        GBytes *b = files ? g_hash_table_lookup(files, "printdeck.yml") : NULL;
        if (!b) {
            set_busy(p, NULL);
            show_error(p, error ? error : "printdeck.yml did not load.");
        } else {
            gsize len = 0;
            const char *d = g_bytes_get_data(b, &len);
            char *text = g_strndup(d, len);
            gboolean same = p->text && strcmp(p->text, text) == 0;
            ZgSource *src = j->src;
            /* The state of the new project: the counts, the status, and
             * the open plate stay if printdeck.yml is the same. */
            g_clear_pointer(&p->kind, g_free);
            g_clear_pointer(&p->path, g_free);
            g_clear_pointer(&p->owner, g_free);
            g_clear_pointer(&p->repo, g_free);
            g_clear_pointer(&p->sha, g_free);
            g_clear_pointer(&p->text, g_free);
            g_clear_object(&p->plan);
            if (!same) {
                g_array_set_size(p->counts, 0);
                g_hash_table_remove_all(p->status);
                g_clear_pointer(&p->active, g_free);
            }
            p->kind = g_strdup(src->kind == ZG_SOURCE_FOLDER ? "folder" : "github");
            p->path = g_strdup(src->path);
            p->owner = g_strdup(src->owner);
            p->repo = g_strdup(src->repo);
            p->sha = g_strdup(src->sha);
            p->text = text;
            zg_source_unref(p->source);
            p->source = zg_source_ref(src);
            replan(p);
            char *err = plan_error(p);
            if (!err) save(p);
            g_free(p->busy);
            p->busy = NULL;
            render(p);
            if (err) show_error(p, err);
            else test_plate(p);
            g_free(err);
        }
    }
    if (files) g_hash_table_unref(files);
    zg_source_unref(j->src);
    page_unref(p);
    g_free(j);
}

/* Opens a project from its source: reads printdeck.yml, and plans. */
static void use(Page *p, ZgSource *src) {
    if (!zg_source_has(src, "printdeck.yml")) {
        GString *s = g_string_new(NULL);
        if (src->kind == ZG_SOURCE_GITHUB) g_string_append_printf(s, "%s/%s", src->owner, src->repo);
        else g_string_append_printf(s, "The folder %s", src->path);
        g_string_append(s, " has no printdeck.yml at its root.");
        set_busy(p, NULL);
        show_error(p, s->str);
        g_string_free(s, TRUE);
        zg_source_unref(src);
        return;
    }
    UseJob *j = g_new0(UseJob, 1);
    j->page = page_ref(p);
    j->src = src;
    const char *paths[] = {"printdeck.yml", NULL};
    zg_source_read(src, paths, NULL, p->cancel, NULL, on_yml_read, j);
}

static void on_github_opened(ZgSource *src, const char *error, gpointer data) {
    Page *p = data;
    if (!p->dead) {
        if (src) {
            use(p, src);
            src = NULL;
        } else {
            set_busy(p, NULL);
            show_error(p, error);
        }
    }
    zg_source_unref(src);
    page_unref(p);
}

static void open_github(Page *p, const char *text) {
    char *owner = NULL, *repo = NULL, *ref = NULL;
    if (!zg_github_parse(text, &owner, &repo, &ref)) {
        show_error(p, "Type owner/repo, or the address of a repository on github.com.");
        return;
    }
    char *busy = g_strdup_printf("Opening %s/%s…", owner, repo);
    set_busy(p, busy);
    g_free(busy);
    zg_source_github_open(owner, repo, ref, NULL, p->cancel, on_github_opened, page_ref(p));
    g_free(owner);
    g_free(repo);
    g_free(ref);
}

static void on_folder_chosen(GObject *source, GAsyncResult *res, gpointer data) {
    Page *p = data;
    GFile *dir = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(source), res, NULL);
    if (dir && !p->dead) {
        char *path = g_file_get_path(dir);
        if (path) {
            set_busy(p, "Opening the folder…");
            use(p, zg_source_folder_new(path));
        }
        g_free(path);
    }
    if (dir) g_object_unref(dir);
    page_unref(p);
}

static void pick_folder(Page *p) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Open the folder of a project (with a printdeck.yml)");
    if (p->path && g_strcmp0(p->kind, "folder") == 0) {
        GFile *f = g_file_new_for_path(p->path);
        gtk_file_dialog_set_initial_folder(dialog, f);
        g_object_unref(f);
    }
    GtkRoot *root = gtk_widget_get_root(p->box);
    gtk_file_dialog_select_folder(dialog, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, NULL, on_folder_chosen, page_ref(p));
    g_object_unref(dialog);
}

/* GitHub again after a restart, at the commit of the saved project. */
static void on_reopened(ZgSource *src, const char *error, gpointer data) {
    Page *p = data;
    if (!p->dead && src && p->text && g_strcmp0(p->kind, "github") == 0) {
        zg_source_unref(p->source);
        p->source = src;
        src = NULL;
        render(p);
        test_plate(p);
    }
    /* No network: the plates show, and an open says why. */
    zg_source_unref(src);
    page_unref(p);
}

static void close_project(Page *p) {
    zg_source_unref(p->source);
    p->source = NULL;
    clear_state(p);
    save(p);
    render(p);
}

/* ---- open a plate ---- */

typedef struct {
    Page *page;
    guint plate;
    char *counts, *key, *title, *printer;
} PlateJob;

static void plate_job_free(PlateJob *j) {
    page_unref(j->page);
    g_free(j->counts);
    g_free(j->key);
    g_free(j->title);
    g_free(j->printer);
    g_free(j);
}

static void on_plate_progress(guint done, guint total, gpointer data) {
    PlateJob *j = data;
    if (j->page->dead) return;
    char *text = g_strdup_printf("Loading plate %u: %u of %u files…", j->plate + 1, done, total);
    set_busy(j->page, text);
    g_free(text);
}

static void on_plate_files(GHashTable *files, const char *error, gpointer data) {
    PlateJob *j = data;
    Page *p = j->page;
    if (p->dead) {
        if (files) g_hash_table_unref(files);
        plate_job_free(j);
        return;
    }
    set_busy(p, NULL);
    if (!files) {
        show_error(p, error);
        plate_job_free(j);
        return;
    }
    zs_files *zf = zs_files_new();
    GHashTableIter it;
    gpointer k, v;
    g_hash_table_iter_init(&it, files);
    int rc = ZS_OK;
    while (rc == ZS_OK && g_hash_table_iter_next(&it, &k, &v)) {
        gsize len = 0;
        const void *d = g_bytes_get_data(v, &len);
        rc = zs_files_add(zf, k, d, len);
    }
    g_hash_table_unref(files);
    if (rc != ZS_OK) {
        zs_files_free(zf);
        show_error(p, zg_status_text(rc));
        plate_job_free(j);
        return;
    }
    /* The profiles of the plate replace the profiles of the printer of
     * the user on the view, and do not change that printer. */
    char *message = NULL;
    rc = zg_model_project_load(p->model, zf, p->text, j->counts, j->plate, j->title, &message);
    zs_files_free(zf);
    if (rc != ZS_OK && rc != ZS_OUT_OF_RANGE) {
        char *text = g_strdup_printf("Plate %u: %s", j->plate + 1, message ? message : zg_status_text(rc));
        show_error(p, text);
        g_free(text);
    } else {
        if (rc == ZS_OUT_OF_RANGE && message) show_error(p, message);
        g_free(p->active);
        p->active = g_strdup(j->key);
        save(p);
        /* The printer of the plate, if the user has one with its name:
         * the print goes there. Its machine settings do not load. */
        for (guint i = 0; i < zg_printers_count(); i++) {
            ZgPrinter *pr = zg_printers_get(i);
            if (g_ascii_strcasecmp(pr->name, j->printer) != 0) continue;
            if (pr != zg_printers_current()) {
                zg_printers_set_current(pr->id);
                zg_model_printers_edited(p->model);
            }
            break;
        }
    }
    g_free(message);
    render(p);
    plate_job_free(j);
}

static void open_plate(Page *p, guint i) {
    JsonArray *plates = array_member(plan_root(p), "plates");
    if (!plates || i >= json_array_get_length(plates)) return;
    if (!p->source) {
        if (g_strcmp0(p->kind, "folder") == 0) {
            char *text = g_strdup_printf("The folder %s is not there. Open the folder of the project again.", p->path);
            show_error(p, text);
            g_free(text);
        } else {
            show_error(p, "GitHub did not answer. Try again.");
            zg_source_github_open(p->owner, p->repo, NULL, p->sha, p->cancel, on_reopened, page_ref(p));
        }
        return;
    }
    JsonObject *plate = json_array_get_object_element(plates, i);
    PlateJob *j = g_new0(PlateJob, 1);
    j->page = page_ref(p);
    j->plate = i;
    j->counts = counts_text(p);
    j->key = plate_key(p, plate);
    j->printer = g_strdup(str_member(plate, "printer"));
    /* The files: the model files of the parts, and profiles/<folder>/. */
    GPtrArray *paths = g_ptr_array_new_with_free_func(g_free);
    JsonArray *items = array_member(plate, "items");
    guint n_items = items ? json_array_get_length(items) : 0;
    for (guint k = 0; k < n_items; k++) {
        JsonObject *part = part_at(p, int_member(json_array_get_object_element(items, k), "part"));
        JsonArray *files = array_member(part, "files");
        for (guint f = 0; files && f < json_array_get_length(files); f++)
            g_ptr_array_add(paths, g_strdup(json_array_get_string_element(files, f)));
    }
    g_ptr_array_add(paths, NULL);
    const char *first = n_items ? str_member(part_at(p, int_member(json_array_get_object_element(items, 0), "part")), "name") : "";
    j->title = n_items <= 1 ? g_strdup(first) : g_strdup_printf("%s and %u more", first, n_items - 1);
    char *folder = profile_folder(str_member(plate, "profile"));
    char *profiles = folder[0] ? g_strconcat("profiles/", folder, NULL) : NULL;
    const char *folders[] = {profiles, NULL};
    char *busy = g_strdup_printf("Loading plate %u…", i + 1);
    set_busy(p, busy);
    g_free(busy);
    zg_source_read(p->source, (const char *const *)paths->pdata, folders, p->cancel, on_plate_progress, on_plate_files, j);
    g_free(profiles);
    g_free(folder);
    g_ptr_array_unref(paths);
}

/* ---- the page ---- */

static gboolean render_now(gpointer data) {
    Page *p = data;
    p->render_idle = 0;
    render(p);
    return G_SOURCE_REMOVE;
}

/* A render after the handler of a widget that the render replaces. */
static void render_soon(Page *p) {
    if (!p->render_idle) p->render_idle = g_idle_add(render_now, p);
}

static void on_status(GObject *dd, GParamSpec *pspec, gpointer data) {
    Page *p = data;
    const char *key = g_object_get_data(dd, "zg-key");
    guint s = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    if (!key || s >= G_N_ELEMENTS(status_keys)) return;
    g_hash_table_insert(p->status, g_strdup(key), g_strdup(status_keys[s]));
    save(p);
    render_soon(p);
}

static void on_open_plate(GtkButton *b, gpointer data) {
    open_plate(data, GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(b), "zg-plate")));
}

static void on_project_sent(ZgModel *model, gpointer data) {
    Page *p = data;
    if (!p->active || !p->text) return;
    g_hash_table_insert(p->status, g_strdup(p->active), g_strdup("printing"));
    save(p);
    render(p);
}

/* The plates of the plan, in the box p->plates. */
static void fill_plates(Page *p) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(p->plates))) gtk_box_remove(GTK_BOX(p->plates), child);
    g_ptr_array_set_size(p->status_dds, 0);
    JsonArray *plates = array_member(plan_root(p), "plates");
    guint n = plates ? json_array_get_length(plates) : 0;
    if (n == 0) gtk_box_append(GTK_BOX(p->plates), label("No parts are chosen.", "dim-label"));
    guint done = 0;
    for (guint i = 0; i < n; i++) {
        JsonObject *plate = json_array_get_object_element(plates, i);
        char *key = plate_key(p, plate);
        const char *status = status_of(p, key);
        if (strcmp(status, "printed") == 0) done++;
        gboolean active = p->active && strcmp(p->active, key) == 0;
        GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
        gtk_widget_add_css_class(card, "zg-proj-plate");
        if (active) gtk_widget_add_css_class(card, "zg-proj-active");
        char *cls = g_strconcat("zg-proj-", status, NULL);
        gtk_widget_add_css_class(card, cls);
        g_free(cls);
        /* The head: the title, the facts, and the status. */
        GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        char *title = g_strdup_printf("Plate %u", i + 1);
        GtkWidget *t = label(title, "zg-proj-plate-title");
        gtk_label_set_wrap(GTK_LABEL(t), FALSE);
        g_free(title);
        char *f = facts(plate);
        GtkWidget *fl = label(f, "dim-label zg-proj-small");
        gtk_widget_set_hexpand(fl, TRUE);
        g_free(f);
        GtkWidget *dd = gtk_drop_down_new_from_strings(status_labels);
        gtk_widget_add_css_class(dd, "zg-proj-status");
        gtk_widget_set_valign(dd, GTK_ALIGN_CENTER);
        for (guint s = 0; s < G_N_ELEMENTS(status_keys); s++)
            if (strcmp(status_keys[s], status) == 0) gtk_drop_down_set_selected(GTK_DROP_DOWN(dd), s);
        g_object_set_data_full(G_OBJECT(dd), "zg-key", g_strdup(key), g_free);
        g_signal_connect(dd, "notify::selected", G_CALLBACK(on_status), p);
        g_ptr_array_add(p->status_dds, dd);
        gtk_box_append(GTK_BOX(head), t);
        gtk_box_append(GTK_BOX(head), fl);
        gtk_box_append(GTK_BOX(head), dd);
        gtk_box_append(GTK_BOX(card), head);
        /* The parts, with their counts. */
        JsonArray *items = array_member(plate, "items");
        for (guint k = 0; items && k < json_array_get_length(items); k++) {
            JsonObject *it = json_array_get_object_element(items, k);
            gint64 count = int_member(it, "count");
            const char *name = str_member(part_at(p, int_member(it, "part")), "name");
            char *line = count > 1 ? g_strdup_printf("%s × %" G_GINT64_FORMAT, name, count) : g_strdup(name);
            gtk_box_append(GTK_BOX(card), label(line, "zg-proj-small"));
            g_free(line);
        }
        /* A plate with no Cura stack (cura.json) in its profile folder: a
         * resin plate, which zslice does not slice yet. */
        char *folder = profile_folder(str_member(plate, "profile"));
        gboolean resin = !folder[0];
        if (!resin && p->source) {
            char *cura = g_strconcat("profiles/", folder, "/cura.json", NULL);
            resin = !zg_source_has(p->source, cura);
            g_free(cura);
        }
        g_free(folder);
        GtkWidget *open = gtk_button_new_with_label(active ? "Open again" : "Open");
        if (!active) gtk_widget_add_css_class(open, "flat");
        gtk_widget_set_halign(open, GTK_ALIGN_START);
        gtk_widget_set_sensitive(open, !p->busy && !resin);
        gtk_widget_set_tooltip_text(open, resin ? "This plate has no Cura profile stack (a resin plate?). zslice slices FDM plates only, for now."
                                                : "Load the plate on the view, with its profiles and settings, and slice it.");
        g_object_set_data(G_OBJECT(open), "zg-plate", GUINT_TO_POINTER(i));
        g_signal_connect(open, "clicked", G_CALLBACK(on_open_plate), p);
        gtk_box_append(GTK_BOX(card), open);
        gtk_box_append(GTK_BOX(p->plates), card);
        g_free(key);
    }
    if (n > 0) {
        char *count = g_strdup_printf("%u of %u plates printed", done, n);
        gtk_box_append(GTK_BOX(p->plates), label(count, "dim-label zg-proj-small"));
        g_free(count);
    }
}

/* A count changed: plan again, and show the new plates. */
static void set_count(Page *p, guint part, int value, int file_count) {
    while (p->counts->len <= part) {
        int none = -1;
        g_array_append_val(p->counts, none);
    }
    g_array_index(p->counts, int, part) = value == file_count ? -1 : value;
    save(p);
    replan(p);
    char *err = plan_error(p);
    if (err) {
        g_free(err);
        render_soon(p);
        return;
    }
    fill_plates(p);
}

static void on_count(GtkSpinButton *spin, gpointer data) {
    Page *p = data;
    guint part = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(spin), "zg-part"));
    int file_count = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(spin), "zg-file-count"));
    int value = gtk_spin_button_get_value_as_int(spin);
    GtkWidget *check = g_object_get_data(G_OBJECT(spin), "zg-check");
    g_signal_handlers_block_matched(check, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, p);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(check), value > 0);
    g_signal_handlers_unblock_matched(check, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, p);
    set_count(p, part, value, file_count);
}

static void on_check(GtkCheckButton *check, gpointer data) {
    GtkWidget *spin = g_object_get_data(G_OBJECT(check), "zg-spin");
    int file_count = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(spin), "zg-file-count"));
    /* The spin button sets the count (on_count). */
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(spin), gtk_check_button_get_active(check) ? MAX(1, file_count) : 0);
}

static GtkWidget *parts_list(Page *p) {
    GtkWidget *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    JsonArray *parts = array_member(plan_root(p), "parts");
    const char *group = NULL;
    for (guint i = 0; parts && i < json_array_get_length(parts); i++) {
        JsonObject *part = json_array_get_object_element(parts, i);
        const char *g = str_member(part, "group");
        if (g[0] && g_strcmp0(g, group) != 0) {
            group = g;
            gtk_box_append(GTK_BOX(list), label(g, "zg-proj-group"));
        }
        int file_count = (int)int_member(part, "count");
        int count = i < p->counts->len && g_array_index(p->counts, int, i) >= 0 ? g_array_index(p->counts, int, i) : file_count;
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *check = gtk_check_button_new();
        gtk_check_button_set_active(GTK_CHECK_BUTTON(check), count > 0);
        gtk_widget_set_valign(check, GTK_ALIGN_CENTER);
        GtkWidget *spin = gtk_spin_button_new_with_range(0, 99, 1);
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(spin), count);
        gtk_widget_set_valign(spin, GTK_ALIGN_CENTER);
        gtk_widget_set_tooltip_text(spin, "The copies of each file on the plate");
        g_object_set_data(G_OBJECT(spin), "zg-part", GUINT_TO_POINTER(i));
        g_object_set_data(G_OBJECT(spin), "zg-file-count", GINT_TO_POINTER(file_count));
        g_object_set_data(G_OBJECT(spin), "zg-check", check);
        g_object_set_data(G_OBJECT(check), "zg-spin", spin);
        g_signal_connect(spin, "value-changed", G_CALLBACK(on_count), p);
        g_signal_connect(check, "toggled", G_CALLBACK(on_check), p);
        g_ptr_array_add(p->spins, spin);
        GtkWidget *info = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_hexpand(info, TRUE);
        GtkWidget *name = label(str_member(part, "name"), NULL);
        gtk_label_set_wrap(GTK_LABEL(name), FALSE);
        gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
        char *f = facts(part);
        GtkWidget *fl = label(f, "dim-label zg-proj-small");
        g_free(f);
        gtk_box_append(GTK_BOX(info), name);
        gtk_box_append(GTK_BOX(info), fl);
        /* The tooltip: the description and the settings of the part. */
        GString *tip = g_string_new(str_member(part, "description"));
        JsonArray *settings = array_member(part, "settings");
        guint ns = settings ? json_array_get_length(settings) : 0;
        if (ns > 0) {
            if (tip->len) g_string_append(tip, "\n\n");
            g_string_append(tip, "Settings: ");
            for (guint s = 0; s < ns; s++) {
                JsonObject *so = json_array_get_object_element(settings, s);
                JsonNode *v = json_object_get_member(so, "value");
                char *value = v && JSON_NODE_HOLDS_VALUE(v) && json_node_get_value_type(v) == G_TYPE_STRING ? g_strdup(json_node_get_string(v))
                                                                                                              : v ? json_to_string(v, FALSE) : g_strdup("");
                g_string_append_printf(tip, "%s%s = %s", s ? ", " : "", str_member(so, "key"), value);
                g_free(value);
            }
        }
        if (tip->len) gtk_widget_set_tooltip_text(info, tip->str);
        g_string_free(tip, TRUE);
        gtk_box_append(GTK_BOX(row), check);
        gtk_box_append(GTK_BOX(row), info);
        gtk_box_append(GTK_BOX(row), spin);
        gtk_box_append(GTK_BOX(list), row);
    }
    return list;
}

static void on_github_activate(GtkWidget *w, gpointer data) {
    Page *p = data;
    GtkWidget *entry = g_object_get_data(G_OBJECT(w), "zg-entry");
    const char *text = gtk_editable_get_text(GTK_EDITABLE(entry ? entry : w));
    g_free(p->github_text);
    p->github_text = g_strdup(text);
    open_github(p, p->github_text);
}

static void on_folder_clicked(GtkButton *b, gpointer data) {
    pick_folder(data);
}

static void on_close_clicked(GtkButton *b, gpointer data) {
    close_project(data);
}

static GtkWidget *open_form(Page *p) {
    GtkWidget *form = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_box_append(GTK_BOX(form), label("Open a project", "zg-proj-title"));
    gtk_box_append(GTK_BOX(form), label("A project is a repository with a printdeck.yml: the parts, their printers, Cura profiles, and settings. "
                                        "zslice puts the parts on plates, and keeps the status of each plate.", "dim-label"));
    gtk_box_append(GTK_BOX(form), label("From GitHub (a public repository)", "zg-proj-label"));
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "owner/repo or a github.com address");
    gtk_widget_set_hexpand(entry, TRUE);
    if (p->github_text) gtk_editable_set_text(GTK_EDITABLE(entry), p->github_text);
    g_signal_connect(entry, "activate", G_CALLBACK(on_github_activate), p);
    GtkWidget *go = gtk_button_new_with_label("Open");
    g_object_set_data(G_OBJECT(go), "zg-entry", entry);
    gtk_widget_set_sensitive(go, !p->busy);
    g_signal_connect(go, "clicked", G_CALLBACK(on_github_activate), p);
    gtk_box_append(GTK_BOX(row), entry);
    gtk_box_append(GTK_BOX(row), go);
    gtk_box_append(GTK_BOX(form), row);
    gtk_box_append(GTK_BOX(form), label("From this computer", "zg-proj-label"));
    GtkWidget *folder = gtk_button_new_with_label("Open a folder…");
    gtk_widget_set_halign(folder, GTK_ALIGN_START);
    gtk_widget_set_sensitive(folder, !p->busy);
    g_signal_connect(folder, "clicked", G_CALLBACK(on_folder_clicked), p);
    gtk_box_append(GTK_BOX(form), folder);
    return form;
}

static void render(Page *p) {
    if (p->dead) return;
    if (p->render_idle) {
        g_source_remove(p->render_idle);
        p->render_idle = 0;
    }
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(p->box))) gtk_box_remove(GTK_BOX(p->box), child);
    p->busy_label = NULL;
    p->plates = NULL;
    g_ptr_array_set_size(p->status_dds, 0);
    g_ptr_array_set_size(p->spins, 0);
    if (!p->text) {
        gtk_box_append(GTK_BOX(p->box), open_form(p));
    } else {
        /* The head: the name, the source, and Close. */
        GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        gtk_widget_set_hexpand(names, TRUE);
        const char *pname = str_member(plan_root(p), "name");
        GString *title = g_string_new(pname);
        if (!title->len) {
            if (g_strcmp0(p->kind, "github") == 0) g_string_append_printf(title, "%s/%s", p->owner, p->repo);
            else {
                char *base = g_path_get_basename(p->path);
                g_string_append(title, base);
                g_free(base);
            }
        }
        gtk_box_append(GTK_BOX(names), label(title->str, "zg-proj-title"));
        g_string_free(title, TRUE);
        char *from = g_strcmp0(p->kind, "github") == 0 ? g_strdup_printf("GitHub %s/%s @ %.7s", p->owner, p->repo, p->sha)
                                                       : g_strdup_printf("Folder %s", p->path);
        gtk_box_append(GTK_BOX(names), label(from, "dim-label zg-proj-small"));
        g_free(from);
        GtkWidget *close = gtk_button_new_with_label("Close");
        gtk_widget_add_css_class(close, "flat");
        gtk_widget_set_valign(close, GTK_ALIGN_START);
        gtk_widget_set_tooltip_text(close, "Close the project. The status of its plates goes too.");
        g_signal_connect(close, "clicked", G_CALLBACK(on_close_clicked), p);
        gtk_box_append(GTK_BOX(head), names);
        gtk_box_append(GTK_BOX(head), close);
        gtk_box_append(GTK_BOX(p->box), head);
    }
    if (p->busy) {
        p->busy_label = label(p->busy, "zg-proj-busy");
        gtk_box_append(GTK_BOX(p->box), p->busy_label);
    }
    if (!p->text) return;
    if (g_strcmp0(p->kind, "folder") == 0 && !p->source) {
        char *text = g_strdup_printf("The folder %s is not there.", p->path);
        gtk_box_append(GTK_BOX(p->box), label(text, "dim-label"));
        g_free(text);
        GtkWidget *again = gtk_button_new_with_label("Open the folder again…");
        gtk_widget_set_halign(again, GTK_ALIGN_START);
        g_signal_connect(again, "clicked", G_CALLBACK(on_folder_clicked), p);
        gtk_box_append(GTK_BOX(p->box), again);
    }
    char *err = plan_error(p);
    if (err) {
        gtk_box_append(GTK_BOX(p->box), label(err, "zg-proj-error"));
        g_free(err);
        return;
    }
    gtk_box_append(GTK_BOX(p->box), label("PLATES", "zg-proj-h"));
    p->plates = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(GTK_BOX(p->box), p->plates);
    fill_plates(p);
    gtk_box_append(GTK_BOX(p->box), label("PARTS", "zg-proj-h"));
    gtk_box_append(GTK_BOX(p->box), parts_list(p));
}

/* ---- test hooks (docs/app/README.md) ----
 *
 * ZSLICE_PROJECT=dir or owner/repo: opens the project at the start, and
 * shows the page. ZSLICE_PROJECT_PLATE=n: opens plate n (from 1) when the
 * files of the project are there (also a project of the last session).
 * ZSLICE_PROJECT_DO="status 1 printed; count 2 0; close": changes the
 * widgets of the page 3 s after the start, one step each second, as a
 * click would (the status of plate 1, the count of part 2). The other
 * steps: "check 2 on" (or off), "scroll 600" (pixels), "sent" (a print
 * went to the printer), "set machine.max_height 300" (a setting), and
 * "end" (the end of project mode). */

static gboolean test_do_step(gpointer data) {
    Page *p = data;
    char **steps = g_object_get_data(G_OBJECT(p->scroll), "zg-test-steps");
    int *i = g_object_get_data(G_OBJECT(p->scroll), "zg-test-step");
    if (p->dead || !steps || !steps[*i < 0 ? 0 : *i]) return G_SOURCE_REMOVE;
    /* The first steps wait: 3 s after the start. */
    if (*i < 0) {
        GtkWidget *stack = gtk_widget_get_ancestor(p->scroll, GTK_TYPE_STACK);
        if (stack) gtk_stack_set_visible_child(GTK_STACK(stack), p->scroll);
        (*i)++;
        return G_SOURCE_CONTINUE;
    }
    char **w = g_strsplit(g_strstrip(steps[(*i)++]), " ", -1);
    guint n = g_strv_length(w);
    guint k = n > 1 ? (guint)g_ascii_strtoull(w[1], NULL, 10) : 0;
    g_message("zslice: project test step: %s %s %s", n > 0 ? w[0] : "", n > 1 ? w[1] : "", n > 2 ? w[2] : "");
    if (n == 3 && strcmp(w[0], "status") == 0 && k >= 1 && k <= p->status_dds->len) {
        for (guint s = 0; s < G_N_ELEMENTS(status_keys); s++)
            if (strcmp(status_keys[s], w[2]) == 0) gtk_drop_down_set_selected(g_ptr_array_index(p->status_dds, k - 1), s);
    } else if (n == 3 && strcmp(w[0], "count") == 0 && k >= 1 && k <= p->spins->len) {
        gtk_spin_button_set_value(g_ptr_array_index(p->spins, k - 1), g_ascii_strtod(w[2], NULL));
    } else if (n == 3 && strcmp(w[0], "check") == 0 && k >= 1 && k <= p->spins->len) {
        GtkWidget *check = g_object_get_data(G_OBJECT(g_ptr_array_index(p->spins, k - 1)), "zg-check");
        gtk_check_button_set_active(GTK_CHECK_BUTTON(check), strcmp(w[2], "on") == 0);
    } else if (n == 2 && strcmp(w[0], "scroll") == 0) {
        GtkAdjustment *adj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(p->scroll));
        gtk_adjustment_set_value(adj, g_ascii_strtod(w[1], NULL));
    } else if (n == 3 && strcmp(w[0], "set") == 0) {
        zg_model_set(p->model, w[1], w[2], NULL);
    } else if (n == 1 && strcmp(w[0], "end") == 0) {
        zg_model_project_end(p->model);
    } else if (n == 1 && strcmp(w[0], "close") == 0) {
        close_project(p);
    } else if (n == 1 && strcmp(w[0], "sent") == 0) {
        zg_model_project_sent(p->model);
    }
    g_strfreev(w);
    return G_SOURCE_CONTINUE;
}

static void test_do(Page *p) {
    const char *what = g_getenv("ZSLICE_PROJECT_DO");
    if (!what) return;
    g_object_set_data_full(G_OBJECT(p->scroll), "zg-test-steps", g_strsplit(what, ";", -1), (GDestroyNotify)g_strfreev);
    int *i = g_new0(int, 1);
    *i = -3;
    g_object_set_data_full(G_OBJECT(p->scroll), "zg-test-step", i, g_free);
    g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, 1, test_do_step, page_ref(p), (GDestroyNotify)page_unref);
}

static void test_plate(Page *p) {
    static gboolean done = FALSE;
    const char *n = g_getenv("ZSLICE_PROJECT_PLATE");
    if (done || !n || !p->source) return;
    done = TRUE;
    guint i = (guint)g_ascii_strtoull(n, NULL, 10);
    if (i > 0) open_plate(p, i - 1);
}

static gboolean test_open(gpointer data) {
    Page *p = data;
    if (!p->dead) {
        GtkWidget *stack = gtk_widget_get_ancestor(p->scroll, GTK_TYPE_STACK);
        if (stack) gtk_stack_set_visible_child(GTK_STACK(stack), p->scroll);
        const char *what = g_getenv("ZSLICE_PROJECT");
        if (what && what[0]) {
            if (g_file_test(what, G_FILE_TEST_IS_DIR)) {
                set_busy(p, "Opening the folder\u2026");
                use(p, zg_source_folder_new(what));
            } else {
                g_free(p->github_text);
                p->github_text = g_strdup(what);
                open_github(p, what);
            }
        } else {
            test_plate(p);
        }
    }
    page_unref(p);
    return G_SOURCE_REMOVE;
}

GtkWidget *zg_project_page_new(ZgModel *model) {
    ensure_css();
    Page *p = g_atomic_rc_box_new0(Page);
    p->model = g_object_ref(model);
    p->counts = g_array_new(FALSE, FALSE, sizeof(int));
    p->status = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    p->cancel = g_cancellable_new();
    p->status_dds = g_ptr_array_new();
    p->spins = g_ptr_array_new();
    p->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(p->box, "zg-proj");
    p->scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(p->scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(p->scroll), p->box);
    gtk_widget_set_vexpand(p->scroll, TRUE);
    g_signal_connect(p->scroll, "destroy", G_CALLBACK(on_destroy), p);
    g_signal_connect(model, "project-sent", G_CALLBACK(on_project_sent), p);
    load(p);
    if (p->text) {
        replan(p);
        /* After a restart: the folder again from its path, or the list of
         * files of the saved commit from GitHub. */
        if (g_strcmp0(p->kind, "folder") == 0) {
            if (g_file_test(p->path, G_FILE_TEST_IS_DIR)) p->source = zg_source_folder_new(p->path);
        } else {
            zg_source_github_open(p->owner, p->repo, NULL, p->sha, p->cancel, on_reopened, page_ref(p));
        }
    }
    render(p);
    if (g_getenv("ZSLICE_PROJECT") || g_getenv("ZSLICE_PROJECT_PLATE")) g_timeout_add(500, test_open, page_ref(p));
    test_do(p);
    return p->scroll;
}
