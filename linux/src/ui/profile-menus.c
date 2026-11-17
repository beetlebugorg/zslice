/* profile-menus.c: see profile-menus.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "profile-menus.h"

#include "../prefs/printers.h"

#include <string.h>

static const char *group_dirs[] = {"machine", "filament", "project"};
static const char *group_titles[] = {"Printer", "Filament", "Part"};
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

static void update_label(Menu *m) {
    char *label;
    if (m->group == ZS_GROUP_FILAMENT) {
        /* The filament: its name (the roll, or the profile). */
        char *name = zg_model_get(m->model, "filament.name");
        label = g_strdup(name && name[0] ? name : (m->name ? m->name : "Filament"));
        g_free(name);
    } else {
        label = g_strdup_printf("Part: %s%s", m->name ? m->name : "custom", changed(m) ? " •" : "");
    }
    gtk_menu_button_set_label(GTK_MENU_BUTTON(m->button), label);
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
    char *text = zg_model_group_text(m->model, m->group);
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

static void on_save(GSimpleAction *a, GVariant *v, gpointer data) {
    save_as(data, FALSE);
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
        g_menu_append(builtin, n, action);
        g_free(action);
    }
    g_menu_append_section(menu, "Built-in", G_MENU_MODEL(builtin));
    GMenu *save = g_menu_new();
    char *action = g_strdup_printf("profiles%d.save", m->group);
    g_menu_append(save, "Save as profile…", action);
    g_free(action);
    g_menu_append_section(menu, NULL, G_MENU_MODEL(save));
    gtk_menu_button_set_menu_model(button, G_MENU_MODEL(menu));
    g_object_unref(save);
    g_object_unref(builtin);
    g_object_unref(mine);
    g_object_unref(menu);
}

static void on_setting_changed(ZgModel *model, const char *key, gpointer data) {
    Menu *m = data;
    if (g_str_has_prefix(key, group_dirs[m->group])) update_label(m);
}

static void menu_free(gpointer data) {
    Menu *m = data;
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
