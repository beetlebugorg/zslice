/* profile-menus.c: see profile-menus.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "profile-menus.h"

#include "../prefs/printers.h"

#include <string.h>

static const char *group_dirs[] = {"machine", "filament", "project"};
static const char *group_titles[] = {"Printer", "Filament", "Quality"};
static const char *group_lower[] = {"printer", "filament", "part"};

typedef struct {
    ZgModel *model;
    int group;
    GtkWidget *button;
    /* The profile in use: its name, and the settings text right after it
     * was loaded (a change since then marks the label). */
    char *name;
    char *loaded;
    /* A switch that waits for the answer to "save the changes first?". */
    char *pending_name;
    char *pending_text;
    /* The update of the label after a change of a setting (see
     * on_setting_changed), or 0. */
    guint label_idle;
} Menu;

static char *profiles_dir(int group) {
    char *dir = zg_config_dir();
    char *path = g_build_filename(dir, "profiles", group_dirs[group], NULL);
    g_free(dir);
    return path;
}

static gboolean changed(Menu *m) {
    if (!m->loaded) return FALSE;
    char *now = zg_model_group_text(m->model, m->group);
    gboolean c = strcmp(now, m->loaded) != 0;
    g_free(now);
    return c;
}

/* The name of a quality for the screen: a built-in one (or "custom")
 * with a capital at the start ("Standard"); a name of the user as the
 * user wrote it. */
static char *quality_name(const char *n) {
    gboolean builtin = strcmp(n, "custom") == 0;
    for (size_t i = 0; !builtin && i < zs_builtin_profile_count(ZS_GROUP_PROJECT); i++)
        builtin = strcmp(zs_builtin_profile_name(ZS_GROUP_PROJECT, i), n) == 0;
    if (!builtin || !n[0]) return g_strdup(n);
    char *first = g_utf8_strup(n, 1);
    char *out = g_strconcat(first, n + 1, NULL);
    g_free(first);
    return out;
}

/* TRUE if this print has changes over the quality profile (the state of
 * the project group has a setting). */
static gboolean edits(Menu *m) {
    char *now = zg_model_group_text(m->model, ZS_GROUP_PROJECT);
    gboolean any = FALSE;
    for (const char *l = now; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
        if (*l != '#' && *l != '\n' && *l != '[') {
            any = TRUE;
            break;
        }
    }
    g_free(now);
    return any;
}

/* The label of the button wraps in a narrow window: it never shortens
 * with "…". */
static void ellipsize_labels(GtkWidget *w) {
    for (GtkWidget *c = gtk_widget_get_first_child(w); c; c = gtk_widget_get_next_sibling(c)) {
        if (GTK_IS_POPOVER(c)) continue;
        if (GTK_IS_LABEL(c)) {
            gtk_label_set_wrap(GTK_LABEL(c), TRUE);
            gtk_label_set_wrap_mode(GTK_LABEL(c), PANGO_WRAP_WORD);
        }
        else ellipsize_labels(c);
    }
}

static void update_label(Menu *m) {
    char *label;
    if (m->group == ZS_GROUP_FILAMENT) {
        /* The filament: its name (the roll, or the profile). */
        char *name = zg_model_get(m->model, "filament.name");
        label = g_strdup(name && name[0] ? name : (m->name ? m->name : "Filament"));
        g_free(name);
    } else {
        /* The quality profile, with a mark when this print has changes on
         * top of it. */
        const char *q = zg_model_quality(m->model);
        char *qn = quality_name(q && q[0] ? q : "custom");
        label = g_strdup_printf("Quality: %s%s", qn, edits(m) ? " •" : "");
        g_free(qn);
    }
    gtk_menu_button_set_label(GTK_MENU_BUTTON(m->button), label);
    ellipsize_labels(m->button);
    char *tip = g_strdup_printf("%s settings: %s%s. Pick a profile, or save these settings as one.", group_titles[m->group],
                                m->name ? m->name : "custom", changed(m) ? ", with changes" : "");
    gtk_widget_set_tooltip_text(m->button, tip);
    g_free(tip);
    g_free(label);
}

/* Loads a profile now: `text` is its profile text. */
static void load_now(Menu *m, const char *name, const char *text) {
    GError *error = NULL;
    if (!zg_model_load_profile(m->model, m->group, text, strlen(text), &error)) {
        g_warning("zslice: the profile %s was not loaded: %s", name, error->message);
        g_error_free(error);
        return;
    }
    g_free(m->name);
    m->name = g_strdup(name);
    g_free(m->loaded);
    m->loaded = zg_model_group_text(m->model, m->group);
    char *key = g_strconcat("profile_", group_dirs[m->group], NULL);
    zg_pref_set(key, name);
    g_free(key);
    update_label(m);
}

/* Writes the settings of the group as profile `name`. */
static gboolean save_profile(Menu *m, const char *name) {
    char *dir = profiles_dir(m->group);
    char *file = g_strconcat(name, ".toml", NULL);
    char *path = g_build_filename(dir, file, NULL);
    /* The full profile: for the quality, its values and the changes of
     * this print together. */
    char *text = m->group == ZS_GROUP_PROJECT ? zg_model_profile_text(m->model, m->group) : zg_model_group_text(m->model, m->group);
    GError *error = NULL;
    gboolean ok = g_mkdir_with_parents(dir, 0700) == 0 && g_file_set_contents(path, text, -1, &error);
    if (!ok) {
        g_warning("zslice: the profile was not saved to %s: %s", path, error ? error->message : g_strerror(errno));
        g_clear_error(&error);
    } else {
        g_free(m->name);
        m->name = g_strdup(name);
        g_free(m->loaded);
        m->loaded = g_strdup(text);
        char *key = g_strconcat("profile_", group_dirs[m->group], NULL);
        zg_pref_set(key, name);
        g_free(key);
        /* The new profile is the quality now, with no changes on top. */
        if (m->group == ZS_GROUP_PROJECT) {
            zg_model_set_quality(m->model, name, FALSE);
            g_free(m->loaded);
            m->loaded = zg_model_group_text(m->model, m->group);
        }
        update_label(m);
    }
    g_free(text);
    g_free(path);
    g_free(file);
    g_free(dir);
    return ok;
}

/* ---- "Save as profile…": a small window with a name ---- */

typedef struct {
    Menu *m;
    GtkWidget *window, *entry;
    gboolean then_load; /* a pending switch goes on after the save */
} SaveAs;

static void finish_pending(Menu *m, gboolean go) {
    if (go && m->pending_text) load_now(m, m->pending_name, m->pending_text);
    g_clear_pointer(&m->pending_name, g_free);
    g_clear_pointer(&m->pending_text, g_free);
}

static void on_save_as_ok(GtkWidget *w, gpointer data) {
    SaveAs *sa = data;
    const char *raw = gtk_editable_get_text(GTK_EDITABLE(sa->entry));
    /* A file name: letters, digits, spaces, dashes. */
    GString *name = g_string_new(NULL);
    for (const char *c = raw; *c; c++) g_string_append_c(name, g_ascii_isalnum(*c) || *c == '-' || *c == '_' ? *c : (*c == ' ' ? '-' : '_'));
    if (name->len > 0 && save_profile(sa->m, name->str)) {
        finish_pending(sa->m, sa->then_load);
        gtk_window_destroy(GTK_WINDOW(sa->window));
    }
    g_string_free(name, TRUE);
}

static void on_save_as_cancel(GtkWidget *w, gpointer data) {
    SaveAs *sa = data;
    finish_pending(sa->m, FALSE);
    gtk_window_destroy(GTK_WINDOW(sa->window));
}

static void save_as(Menu *m, gboolean then_load) {
    SaveAs *sa = g_new0(SaveAs, 1);
    sa->m = m;
    sa->then_load = then_load;
    sa->window = gtk_window_new();
    char *title = g_strdup_printf("Save the %s settings", group_titles[m->group]);
    gtk_window_set_title(GTK_WINDOW(sa->window), title);
    g_free(title);
    gtk_window_set_modal(GTK_WINDOW(sa->window), TRUE);
    gtk_window_set_transient_for(GTK_WINDOW(sa->window), GTK_WINDOW(gtk_widget_get_root(m->button)));
    gtk_window_set_resizable(GTK_WINDOW(sa->window), FALSE);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_start(box, 16);
    gtk_widget_set_margin_end(box, 16);
    gtk_widget_set_margin_top(box, 16);
    gtk_widget_set_margin_bottom(box, 16);
    GtkWidget *label = gtk_label_new("The name of the profile:");
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    sa->entry = gtk_entry_new();
    gtk_widget_set_size_request(sa->entry, 280, -1);
    if (m->name) gtk_editable_set_text(GTK_EDITABLE(sa->entry), m->name);
    g_signal_connect(sa->entry, "activate", G_CALLBACK(on_save_as_ok), sa);
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(buttons, GTK_ALIGN_END);
    GtkWidget *cancel = gtk_button_new_with_label("Cancel");
    GtkWidget *ok = gtk_button_new_with_label("Save");
    gtk_widget_add_css_class(ok, "suggested-action");
    g_signal_connect(cancel, "clicked", G_CALLBACK(on_save_as_cancel), sa);
    g_signal_connect(ok, "clicked", G_CALLBACK(on_save_as_ok), sa);
    gtk_box_append(GTK_BOX(buttons), cancel);
    gtk_box_append(GTK_BOX(buttons), ok);
    gtk_box_append(GTK_BOX(box), label);
    gtk_box_append(GTK_BOX(box), sa->entry);
    gtk_box_append(GTK_BOX(box), buttons);
    gtk_window_set_child(GTK_WINDOW(sa->window), box);
    g_object_set_data_full(G_OBJECT(sa->window), "zg-save-as", sa, g_free);
    gtk_window_present(GTK_WINDOW(sa->window));
}

/* ---- a switch ---- */

static void on_changes_answer(GObject *source, GAsyncResult *res, gpointer data) {
    Menu *m = data;
    int button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), res, NULL);
    if (button == 2) save_as(m, TRUE);        /* save first, then switch */
    else finish_pending(m, button == 1);      /* 1: discard; else cancel */
}

/* Switches to a profile, after a question when the settings have
 * changes. */
static void switch_to(Menu *m, const char *name, const char *text) {
    g_free(m->pending_name);
    g_free(m->pending_text);
    m->pending_name = g_strdup(name);
    m->pending_text = g_strdup(text);
    char *now = zg_model_group_text(m->model, m->group);
    /* Changes: since a profile was loaded, or settings that came from no
     * profile (and that are not the defaults). */
    gboolean unsaved = m->loaded ? strcmp(now, m->loaded) != 0 : FALSE;
    if (!m->loaded && !m->name) {
        /* Settings of no profile: any setting that is not the default. */
        for (const char *l = now; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
            if (*l != '#' && *l != '\n' && *l != '[') {
                unsaved = TRUE;
                break;
            }
        }
    }
    g_free(now);
    if (!unsaved) {
        finish_pending(m, TRUE);
        return;
    }
    char *msg = g_strdup_printf("The %s settings have changes that are in no profile. Save them as a profile before you switch to %s?",
                                group_lower[m->group], name);
    GtkAlertDialog *d = gtk_alert_dialog_new("Save the changes first?");
    gtk_alert_dialog_set_detail(d, msg);
    const char *buttons[] = {"Cancel", "Discard", "Save as profile…", NULL};
    gtk_alert_dialog_set_buttons(d, buttons);
    gtk_alert_dialog_set_cancel_button(d, 0);
    gtk_alert_dialog_set_default_button(d, 2);
    gtk_alert_dialog_choose(d, GTK_WINDOW(gtk_widget_get_root(m->button)), NULL, on_changes_answer, m);
    g_object_unref(d);
    g_free(msg);
}

/* ---- the menu ---- */

static void on_pick(GSimpleAction *a, GVariant *v, gpointer data) {
    Menu *m = data;
    const char *what = g_variant_get_string(v, NULL);
    /* A quality profile: the changes of this print stay on top. */
    if (m->group == ZS_GROUP_PROJECT) {
        const char *name = g_str_has_prefix(what, "builtin:") ? what + 8 : g_str_has_prefix(what, "file:") ? what + 5 : what;
        if (zg_model_set_quality(m->model, name, TRUE)) {
            g_free(m->name);
            m->name = g_strdup(name);
            g_free(m->loaded);
            m->loaded = zg_model_group_text(m->model, m->group);
            update_label(m);
        }
        return;
    }
    if (g_str_has_prefix(what, "builtin:")) {
        char *text = g_strdup_printf("extends = \"%s\"\n", what + 8);
        switch_to(m, what + 8, text);
        g_free(text);
    } else if (g_str_has_prefix(what, "file:")) {
        char *dir = profiles_dir(m->group);
        char *file = g_strconcat(what + 5, ".toml", NULL);
        char *path = g_build_filename(dir, file, NULL);
        char *text = NULL;
        if (g_file_get_contents(path, &text, NULL, NULL)) switch_to(m, what + 5, text);
        g_free(text);
        g_free(path);
        g_free(file);
        g_free(dir);
    }
}

/* A material type: the built-in profile of the material. With a roll in
 * use, its settings stay in its file, so the switch needs no question. */
static void on_material(GSimpleAction *a, GVariant *v, gpointer data) {
    Menu *m = data;
    const char *mat = g_variant_get_string(v, NULL);
    char *lower = g_ascii_strdown(mat, -1);
    char *base = g_strconcat("generic-", lower, NULL);
    /* The diameter of the filament stays (a property of the printer: the
     * built-in profiles are for 1.75 mm). */
    char *dia = zg_model_get(m->model, "filament.diameter");
    char *text = g_strdup_printf("extends = \"%s\"\ndiameter = %s\n", base, dia && dia[0] ? dia : "1.75");
    g_free(dia);
    if (zg_model_roll(m->model)) {
        zg_model_set_roll(m->model, NULL);
        load_now(m, base, text);
    } else {
        switch_to(m, base, text);
    }
    g_free(text);
    g_free(base);
    g_free(lower);
}

/* A roll of the printer (by its ID): its settings. */
static void on_roll(GSimpleAction *a, GVariant *v, gpointer data) {
    Menu *m = data;
    const char *id = g_variant_get_string(v, NULL);
    size_t n = 0;
    const ZgRoll *rolls = zg_model_rolls(m->model, &n, NULL);
    for (size_t i = 0; i < n; i++) {
        if (g_strcmp0(rolls[i].id, id) != 0) continue;
        zg_model_use_roll(m->model, &rolls[i]);
        g_free(m->name);
        m->name = g_strdup(rolls[i].name);
        g_free(m->loaded);
        m->loaded = zg_model_group_text(m->model, m->group);
        update_label(m);
        return;
    }
}

static void on_save(GSimpleAction *a, GVariant *v, gpointer data) {
    save_as(data, FALSE);
}

/* The report of an import (zs_app_profile_import_report) in words: the
 * values that zslice set, the values that went into the limits of their
 * setting, and the keys with no zslice setting. */
static char *report_text(const char *report, char **title) {
    GString *set = g_string_new(NULL), *clamp = g_string_new(NULL), *unused = g_string_new(NULL);
    guint n_set = 0, n_clamp = 0, n_unused = 0;
    *title = g_strdup("Profile");
    char **lines = g_strsplit(report, "\n", -1);
    for (char **l = lines; *l; l++) {
        char **f = g_strsplit(*l, "\t", -1);
        guint n = g_strv_length(f);
        if (n >= 2 && strcmp(f[0], "format") == 0) {
            g_free(*title);
            *title = g_strdup(f[1]);
        } else if (n >= 5 && strcmp(f[0], "set") == 0) {
            g_string_append_printf(set, "%s = %s\t→ %s = %s\n", f[1], f[2], f[3], f[4]);
            n_set++;
        } else if (n >= 6 && strcmp(f[0], "near") == 0) {
            g_string_append_printf(set, "%s = %s\t→ %s = %s (%s)\n", f[1], f[2], f[3], f[4], f[5]);
            n_set++;
        } else if (n >= 6 && strcmp(f[0], "clamp") == 0) {
            g_string_append_printf(clamp, "%s = %s\t→ %s = %s (wanted %s)\n", f[1], f[2], f[3], f[4], f[5]);
            n_clamp++;
        } else if (n >= 4 && strcmp(f[0], "unused") == 0) {
            g_string_append_printf(unused, "%s = %s\t%s\n", f[1], f[2], f[3]);
            n_unused++;
        }
        g_strfreev(f);
    }
    g_strfreev(lines);
    GString *out = g_string_new(NULL);
    if (n_set) g_string_append_printf(out, "Set (%u)\n%s\n", n_set, set->str);
    if (n_clamp) g_string_append_printf(out, "Clamped to the limits of the setting (%u)\n%s\n", n_clamp, clamp->str);
    if (n_unused) g_string_append_printf(out, "Not imported (%u)\n%s", n_unused, unused->str);
    g_string_free(set, TRUE);
    g_string_free(clamp, TRUE);
    g_string_free(unused, TRUE);
    return g_string_free(out, FALSE);
}

static void show_report(GtkWidget *parent, const char *file, const char *report) {
    char *format = NULL;
    char *text = report_text(report, &format);
    GtkWidget *win = gtk_window_new();
    char *title = g_strdup_printf("%s: %s", format, file);
    gtk_window_set_title(GTK_WINDOW(win), title);
    GtkRoot *root = gtk_widget_get_root(parent);
    if (GTK_IS_WINDOW(root)) gtk_window_set_transient_for(GTK_WINDOW(win), GTK_WINDOW(root));
    gtk_window_set_modal(GTK_WINDOW(win), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(win), 760, 520);
    GtkWidget *view = gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(view), FALSE);
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(view), FALSE);
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(view), 12);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(view), 12);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)), text, -1);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), view);
    gtk_window_set_child(GTK_WINDOW(win), scroll);
    gtk_window_present(GTK_WINDOW(win));
    g_free(title);
    g_free(text);
    g_free(format);
}

static void on_import_chosen(GObject *source, GAsyncResult *res, gpointer data) {
    Menu *m = data;
    GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), res, NULL);
    if (!file) return;
    char *bytes = NULL;
    gsize len = 0;
    GError *error = NULL;
    char *name = g_file_get_basename(file);
    if (g_file_load_contents(file, NULL, &bytes, &len, NULL, &error)) {
        char *report = zg_model_import_profile(m->model, name, (const guint8 *)bytes, len, &error);
        if (report) {
            show_report(m->button, name, report);
            g_free(report);
        }
    }
    if (error) {
        GtkAlertDialog *alert = gtk_alert_dialog_new("%s", error->message);
        GtkRoot *root = gtk_widget_get_root(m->button);
        gtk_alert_dialog_show(alert, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL);
        g_object_unref(alert);
        g_error_free(error);
    }
    g_free(name);
    g_free(bytes);
    g_object_unref(file);
}

/* "Import a profile…": a profile of PrusaSlicer, OrcaSlicer, Bambu
 * Studio, or Cura. Its values become changes of the settings now. */
static void on_import(GSimpleAction *a, GVariant *v, gpointer data) {
    Menu *m = data;
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Import a profile of PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Profiles (.ini, .json, .3mf, .curaprofile)");
    const char *patterns[] = {"*.ini", "*.INI", "*.json", "*.3mf", "*.3MF", "*.curaprofile", "*.cfg", "*.gcode"};
    for (size_t i = 0; i < G_N_ELEMENTS(patterns); i++) gtk_file_filter_add_pattern(filter, patterns[i]);
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, filter);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    GtkRoot *root = gtk_widget_get_root(m->button);
    gtk_file_dialog_open(dialog, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, NULL, on_import_chosen, m);
    g_object_unref(filters);
    g_object_unref(filter);
    g_object_unref(dialog);
}

/* A click on a quality of the menu: the action of its item. */
static void on_quality_clicked(GtkButton *b, gpointer data) {
    Menu *m = data;
    const char *target = g_object_get_data(G_OBJECT(b), "zg-target");
    char *action = g_strdup_printf("profiles%d.pick", m->group);
    gtk_widget_activate_action(m->button, action, "s", target);
    g_free(action);
    gtk_menu_button_popdown(GTK_MENU_BUTTON(m->button));
}

/* A quality in the menu, as on the web: a check mark on the quality in
 * use, its name, and its main points in small dim text under it
 * (zs_quality_summary). */
static GtkWidget *quality_item(Menu *m, const char *n, gboolean current) {
    GtkWidget *b = gtk_button_new();
    gtk_widget_add_css_class(b, "flat");
    gtk_widget_add_css_class(b, "zg-quality-item");
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *check = gtk_image_new_from_icon_name("object-select-symbolic");
    gtk_widget_set_opacity(check, current ? 1 : 0);
    gtk_widget_set_valign(check, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(row), check);
    GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    char *name = quality_name(n);
    GtkWidget *title = gtk_label_new(name);
    g_free(name);
    gtk_label_set_xalign(GTK_LABEL(title), 0);
    gtk_box_append(GTK_BOX(texts), title);
    size_t len = 0;
    if (zs_quality_summary(n, NULL, 0, &len) == ZS_OK && len > 0) {
        char *sum = g_malloc(len + 1);
        zs_quality_summary(n, sum, len + 1, NULL);
        GtkWidget *detail = gtk_label_new(sum);
        g_free(sum);
        gtk_label_set_xalign(GTK_LABEL(detail), 0);
        gtk_label_set_wrap(GTK_LABEL(detail), TRUE);
        gtk_widget_add_css_class(detail, "dim-label");
        gtk_widget_add_css_class(detail, "caption");
        gtk_box_append(GTK_BOX(texts), detail);
    }
    gtk_box_append(GTK_BOX(row), texts);
    gtk_button_set_child(GTK_BUTTON(b), row);
    char *target = g_strdup_printf("builtin:%s", n);
    g_object_set_data_full(G_OBJECT(b), "zg-target", target, g_free);
    g_signal_connect(b, "clicked", G_CALLBACK(on_quality_clicked), m);
    return b;
}

static void fill_menu(GtkMenuButton *button, gpointer data) {
    Menu *m = data;
    GMenu *menu = g_menu_new();
    GMenu *mine = g_menu_new();
    char *dir = profiles_dir(m->group);
    GDir *d = g_dir_open(dir, 0, NULL);
    GPtrArray *names = g_ptr_array_new_with_free_func(g_free);
    if (d) {
        const char *f;
        while ((f = g_dir_read_name(d))) {
            if (g_str_has_suffix(f, ".toml")) g_ptr_array_add(names, g_strndup(f, strlen(f) - 5));
        }
        g_dir_close(d);
    }
    g_ptr_array_sort(names, (GCompareFunc)g_strcmp0);
    for (guint i = 0; i < names->len; i++) {
        const char *n = names->pdata[i];
        char *action = g_strdup_printf("profiles%d.pick('file:%s')", m->group, n);
        g_menu_append(mine, n, action);
        g_free(action);
    }
    g_ptr_array_free(names, TRUE);
    g_free(dir);
    if (g_menu_model_get_n_items(G_MENU_MODEL(mine)) > 0) g_menu_append_section(menu, "Your profiles", G_MENU_MODEL(mine));
    GMenu *builtin = g_menu_new();
    for (size_t i = 0; i < zs_builtin_profile_count(m->group); i++) {
        const char *n = zs_builtin_profile_name(m->group, i);
        char *action = g_strdup_printf("profiles%d.pick('builtin:%s')", m->group, n);
        if (m->group == ZS_GROUP_PROJECT) {
            /* A quality: a widget of its own (quality_item), in the place
             * of this item. The popover menu shows markup as text, so a
             * plain item cannot have the small dim second line. */
            char *id = g_strdup_printf("quality-%zu", i);
            GMenuItem *item = g_menu_item_new(NULL, NULL);
            g_menu_item_set_attribute(item, "custom", "s", id);
            g_menu_append_item(builtin, item);
            g_object_unref(item);
            g_free(id);
        } else {
            g_menu_append(builtin, n, action);
        }
        g_free(action);
    }
    if (m->group == ZS_GROUP_FILAMENT) {
        /* The filament: first the type of plastic, then a roll of that
         * type in the printer, then the profiles. */
        GMenu *mats = g_menu_new();
        char *now = zg_model_get(m->model, "filament.material");
        for (size_t i = 0; i < zs_builtin_profile_count(m->group); i++) {
            const char *n = zs_builtin_profile_name(m->group, i);
            if (!g_str_has_prefix(n, "generic-")) continue;
            char *mat = g_ascii_strup(n + 8, -1);
            gboolean current = now && g_ascii_strcasecmp(now, mat) == 0;
            char *label = g_strdup_printf("%s%s", current ? "✓ " : "    ", mat);
            char *action = g_strdup_printf("profiles%d.material('%s')", m->group, mat);
            g_menu_append(mats, label, action);
            g_free(action);
            g_free(label);
            g_free(mat);
        }
        g_menu_prepend_section(menu, "Material", G_MENU_MODEL(mats));
        g_object_unref(mats);
        size_t nr = 0;
        const ZgRoll *rolls = zg_model_rolls(m->model, &nr, NULL);
        GMenu *rmenu = g_menu_new();
        const char *in_use = zg_model_roll(m->model);
        for (size_t i = 0; i < nr; i++) {
            if (!rolls[i].id || (now && rolls[i].material && g_ascii_strcasecmp(now, rolls[i].material) != 0)) continue;
            char *key = zg_model_roll_key(NULL, rolls[i].id);
            gboolean current = in_use && g_str_has_suffix(in_use, key);
            g_free(key);
            char *label = rolls[i].left > 0 ? g_strdup_printf("%s%s · %.0f g", current ? "✓ " : "    ", rolls[i].name ? rolls[i].name : "?", rolls[i].left)
                                            : g_strdup_printf("%s%s", current ? "✓ " : "    ", rolls[i].name ? rolls[i].name : "?");
            GMenuItem *item = g_menu_item_new(label, NULL);
            g_menu_item_set_action_and_target_value(item, "profiles1.roll", g_variant_new_string(rolls[i].id));
            g_menu_append_item(rmenu, item);
            g_object_unref(item);
            g_free(label);
        }
        if (g_menu_model_get_n_items(G_MENU_MODEL(rmenu)) > 0) {
            char *title = g_strdup_printf("Rolls of %s", now ? now : "filament");
            g_menu_insert_section(menu, 1, title, G_MENU_MODEL(rmenu));
            g_free(title);
        }
        g_object_unref(rmenu);
        g_free(now);
    } else {
        g_menu_append_section(menu, "Built-in", G_MENU_MODEL(builtin));
    }
    GMenu *save = g_menu_new();
    char *action = g_strdup_printf("profiles%d.save", m->group);
    g_menu_append(save, "Save as profile…", action);
    g_free(action);
    action = g_strdup_printf("profiles%d.import", m->group);
    g_menu_append(save, "Import a profile…", action);
    g_free(action);
    g_menu_append_section(menu, NULL, G_MENU_MODEL(save));
    gtk_menu_button_set_menu_model(button, G_MENU_MODEL(menu));
    if (m->group == ZS_GROUP_PROJECT) {
        GtkPopover *pop = gtk_menu_button_get_popover(button);
        const char *q = zg_model_quality(m->model);
        for (size_t i = 0; GTK_IS_POPOVER_MENU(pop) && i < zs_builtin_profile_count(m->group); i++) {
            const char *n = zs_builtin_profile_name(m->group, i);
            char *id = g_strdup_printf("quality-%zu", i);
            gtk_popover_menu_add_child(GTK_POPOVER_MENU(pop), quality_item(m, n, q && strcmp(q, n) == 0), id);
            g_free(id);
        }
    }
    g_object_unref(save);
    g_object_unref(builtin);
    g_object_unref(mine);
    g_object_unref(menu);
}

static gboolean on_label_idle(gpointer data) {
    Menu *m = data;
    m->label_idle = 0;
    update_label(m);
    return G_SOURCE_REMOVE;
}

/* A switch of the plate announces each setting: one update of the label
 * for all of them, as each update writes the settings of the group. */
static void on_setting_changed(ZgModel *model, const char *key, gpointer data) {
    Menu *m = data;
    if (g_str_has_prefix(key, group_dirs[m->group]) && !m->label_idle)
        m->label_idle = g_idle_add_full(G_PRIORITY_HIGH_IDLE, on_label_idle, m, NULL);
}

static void menu_free(gpointer data) {
    Menu *m = data;
    if (m->label_idle) g_source_remove(m->label_idle);
    g_signal_handlers_disconnect_by_data(m->model, m);
    g_free(m->name);
    g_free(m->loaded);
    g_free(m->pending_name);
    g_free(m->pending_text);
    g_free(m);
}

GtkWidget *zg_profile_menu_new(ZgModel *model, int group) {
    Menu *m = g_new0(Menu, 1);
    m->model = model;
    m->group = group;
    m->button = gtk_menu_button_new();
    gtk_menu_button_set_always_show_arrow(GTK_MENU_BUTTON(m->button), TRUE);
    gtk_menu_button_set_create_popup_func(GTK_MENU_BUTTON(m->button), fill_menu, m, NULL);
    /* The profile of the last session, if the settings still match it
     * (the saved settings are the ones of the profile). */
    char *key = g_strconcat("profile_", group_dirs[group], NULL);
    char *name = zg_pref_get(key, "");
    g_free(key);
    if (name[0]) {
        m->name = g_strdup(name);
        m->loaded = zg_model_group_text(model, group);
    }
    g_free(name);
    static const GActionEntry entries[] = {
        {.name = "pick", .activate = on_pick, .parameter_type = "s"},
        {.name = "save", .activate = on_save},
        {.name = "import", .activate = on_import},
        {.name = "material", .activate = on_material, .parameter_type = "s"},
        {.name = "roll", .activate = on_roll, .parameter_type = "s"},
    };
    GSimpleActionGroup *actions = g_simple_action_group_new();
    g_action_map_add_action_entries(G_ACTION_MAP(actions), entries, G_N_ELEMENTS(entries), m);
    char *prefix = g_strdup_printf("profiles%d", group);
    gtk_widget_insert_action_group(m->button, prefix, G_ACTION_GROUP(actions));
    g_free(prefix);
    g_object_unref(actions);
    g_signal_connect(model, "setting-changed", G_CALLBACK(on_setting_changed), m);
    g_object_set_data_full(G_OBJECT(m->button), "zg-profile-menu", m, menu_free);
    update_label(m);
    return m->button;
}
