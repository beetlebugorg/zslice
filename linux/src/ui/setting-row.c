/* setting-row.c: see setting-row.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "setting-row.h"

#include "setting-editor.h"

#include <string.h>

void zg_setting_row_free(gpointer row) {
    ZgSettingRow *r = row;
    g_free(r->needle);
    g_free(r);
}

/* ---- what a focused setting does to the selected line ---- */

/* A text for the setting of the editor: what it does to the selected line,
 * with the numbers of that line. NULL with no selection. */
static char *why_text(GtkWidget *editor) {
    ZgModel *model = zg_setting_editor_model(editor);
    zs_app *core = zg_model_core(model);
    gint64 path = zg_model_selected(model);
    zs_inspect info;
    if (path < 0 || zs_app_inspect(core, (size_t)path, &info) != ZS_OK) return NULL;
    const char *key = zg_setting_editor_info(editor)->name;
    zs_setting_effect e = {0};
    zs_setting_get_effect(key, &e);
    gboolean known = info.feature >= 0 && info.feature < ZS_FEATURE_COUNT;
    gboolean mine = known && ((e.features >> info.feature) & 1) && !(e.first_layer_only && info.layer > 0);
    /* The name of the feature in lower case: "outer wall". */
    char *kind = known ? g_utf8_strdown(info.title, -1) : g_strdup("this");
    GString *t = g_string_new(NULL);
    double base = 0;
    if (zs_app_ratio_speed(core, key, "1", &base) == ZS_OK) {
        char *v = zg_model_get_for(model, key, TRUE);
        double ratio = g_ascii_strtod(v, NULL);
        g_free(v);
        if (mine) {
            g_string_append_printf(t, "This line: %.0f %% of %.0f mm/s = %.0f mm/s planned.", ratio * 100, base, info.planned_speed);
            if (info.speed < info.planned_speed - 0.5)
                g_string_append_printf(t, " It prints at %.0f mm/s: the layer is short, and it slows to cool.", info.speed);
        } else {
            g_string_append_printf(t, "Not this line: this %s line has its own speed (%.0f mm/s planned).", kind, info.planned_speed);
        }
    } else if (strcmp(key, "project.line_width") == 0 || strcmp(key, "project.first_layer_line_width") == 0) {
        if (mine) g_string_append_printf(t, "This line: %.2f mm planned; the bead is %.2f mm wide.", info.line_width, info.bead_width);
    } else if (strcmp(key, "project.layer_height") == 0 || strcmp(key, "project.first_layer_height") == 0) {
        g_string_append_printf(t, "This layer: %.2f mm high, at z %.2f mm.", info.height, info.z);
    } else if (strcmp(key, "filament.max_flow") == 0 || strcmp(key, "filament.flow_ratio") == 0) {
        g_string_append_printf(t, "This line: %.1f mm³/s of plastic at %.0f mm/s.", info.flow, info.speed);
    } else if (strcmp(key, "filament.min_layer_time") == 0 || strcmp(key, "filament.min_speed") == 0) {
        if (info.speed < info.planned_speed - 0.5) g_string_append_printf(t, "This layer is short: the line slows from %.0f to %.0f mm/s so that the layer cools.", info.planned_speed, info.speed);
        else g_string_append(t, "This layer is long enough: no slow-down.");
    }
    if (t->len == 0) {
        if (mine) {
            g_string_append_printf(t, "It changes this line, and all %s lines. The view shows the lines that it changes.", kind);
        } else if (e.features == 0) {
            g_string_append(t, e.note && e.note[0] ? e.note : "It changes no line in the view.");
        } else {
            g_string_append_printf(t, "It does not change this %s line. The view shows the lines that it changes.", kind);
        }
    }
    g_free(kind);
    return g_string_free(t, FALSE);
}

/* A row opens or closes: the text under it, and the lines of the setting
 * in the views (the selection stays yellow). */
static void show_why(GtkWidget *revealer, gboolean open) {
    GtkWidget *editor = g_object_get_data(G_OBJECT(revealer), "zg-entry");
    GtkWidget *why = g_object_get_data(G_OBJECT(revealer), "zg-why");
    if (!editor || !why) return;
    ZgModel *model = zg_setting_editor_model(editor);
    if (!open) {
        zg_model_set_focus(model, 0, FALSE);
        return;
    }
    char *text = why_text(editor);
    gtk_label_set_text(GTK_LABEL(why), text ? text : "");
    gtk_widget_set_visible(why, text != NULL);
    g_free(text);
    zs_setting_effect e = {0};
    zs_setting_get_effect(zg_setting_editor_info(editor)->name, &e);
    zg_model_set_focus(model, e.features, e.first_layer_only);
}

/* ---- the part under a compact row ---- */

/* A compact row shows its slider while the entry or the slider has the
 * focus. The check runs after the focus moves (in an idle), so a click
 * from the entry on the slider keeps the slider open. */
static gboolean update_reveal(gpointer data) {
    GtkWidget *revealer = data;
    GtkWidget *entry = g_object_get_data(G_OBJECT(revealer), "zg-entry");
    GtkWidget *slider = g_object_get_data(G_OBJECT(revealer), "zg-slider-w");
    GtkRoot *root = gtk_widget_get_root(revealer);
    GtkWidget *focus = root ? gtk_root_get_focus(root) : NULL;
    gboolean open = focus && (focus == entry || gtk_widget_is_ancestor(focus, entry) ||
                              (slider && (focus == slider || gtk_widget_is_ancestor(focus, slider))));
    open = open || (slider && (gtk_widget_get_state_flags(slider) & GTK_STATE_FLAG_ACTIVE));
    if (open != gtk_revealer_get_reveal_child(GTK_REVEALER(revealer))) show_why(revealer, open);
    gtk_revealer_set_reveal_child(GTK_REVEALER(revealer), open);
    g_object_unref(revealer);
    return G_SOURCE_REMOVE;
}

static void on_row_focus(GtkEventControllerFocus *ctrl, gpointer data) {
    g_idle_add(update_reveal, g_object_ref(data));
}

static void watch_focus(GtkWidget *w, GtkWidget *revealer) {
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(on_row_focus), revealer);
    g_signal_connect(focus, "leave", G_CALLBACK(on_row_focus), revealer);
    gtk_widget_add_controller(w, focus);
}

/* ---- the scope ---- */

/* The scope look of an inspector row: in a layer scope, a setting for the
 * whole print is off, and a setting with an override of this layer has
 * the accent color and a reset button. */
static void show_scope(GtkWidget *editor) {
    ZgModel *model = zg_setting_editor_model(editor);
    const zs_setting_info *info = zg_setting_editor_info(editor);
    GtkWidget *label = g_object_get_data(G_OBJECT(editor), "zg-label");
    GtkWidget *reset = g_object_get_data(G_OBJECT(editor), "zg-reset");
    double z_min = 0;
    gboolean layer_scope = zg_model_scope(model, &z_min, NULL, NULL);
    /* The whole part: the project and filament settings. Some layers: the
     * settings that can change from layer to layer. */
    gboolean whole = z_min <= -1e5;
    gboolean usable = !layer_scope || (whole ? (strcmp(info->group, "project") == 0 || strcmp(info->group, "filament") == 0)
                                             : info->per_layer);
    gtk_widget_set_sensitive(editor, usable);
    if (label) gtk_widget_set_sensitive(label, usable);
    gboolean over = layer_scope && zg_model_overridden(model, info->name);
    if (label) {
        if (over) gtk_widget_add_css_class(label, "zg-overridden");
        else gtk_widget_remove_css_class(label, "zg-overridden");
    }
    if (reset) {
        gtk_widget_set_opacity(reset, over ? 1 : 0);
        gtk_widget_set_sensitive(reset, over);
    }
    if (!usable) {
        gtk_widget_set_tooltip_text(editor, whole ? "A printer setting: change it in the Settings page."
                                                  : "A setting for the whole part: it cannot change for some layers. Set \"Change for\" to This part.");
    }
}

static void on_scope_changed(ZgModel *model, gpointer data) {
    GtkWidget *editor = data;
    show_scope(editor);
    zg_setting_editor_refresh(editor);
}

static void on_scope_setting(ZgModel *model, const char *key, gpointer data) {
    GtkWidget *editor = data;
    if (g_strcmp0(key, zg_setting_editor_info(editor)->name) == 0) show_scope(editor);
}

static void on_reset_override(GtkButton *button, gpointer data) {
    GtkWidget *editor = data;
    zg_model_clear_override(zg_setting_editor_model(editor), zg_setting_editor_info(editor)->name);
}

ZgSettingRow *zg_setting_row_add(GtkWidget *grid, int *row, ZgModel *model, const zs_setting_info *info, int flags) {
    gboolean compact = flags & ZG_ROW_COMPACT;
    GtkWidget *label = gtk_label_new(info->label);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_hexpand(label, TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    if (compact) {
        gtk_label_set_wrap(GTK_LABEL(label), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD);
        char *tip = g_strdup_printf("%s (%s setting)\n\n%s", info->label, info->group, info->doc);
        gtk_widget_set_tooltip_text(label, tip);
        g_free(tip);
    } else {
        gtk_label_set_wrap(GTK_LABEL(label), TRUE);
        gtk_widget_set_tooltip_text(label, info->doc);
    }
    ZgSettingRow *r = g_new0(ZgSettingRow, 1);
    r->needle = g_utf8_strdown(info->label, -1);
    r->widgets[0] = label;
    GtkWidget *editor = zg_setting_editor_new(model, info, compact || (flags & ZG_ROW_SCOPED));
    if (compact) gtk_widget_add_css_class(editor, "zg-compact");
    gboolean number = (info->kind == ZS_SETTING_NUMBER || info->kind == ZS_SETTING_INTEGER) && !zg_setting_is_filament(info->name);
    if (number) zg_setting_editor_add_scrub(editor, label);
    if (info->kind == ZS_SETTING_TEXT && info->multiline) {
        GtkWidget *scroll = gtk_scrolled_window_new();
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), editor);
        gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 120);
        gtk_widget_add_css_class(scroll, "frame");
        gtk_grid_attach(GTK_GRID(grid), label, 0, (*row)++, 3, 1);
        gtk_grid_attach(GTK_GRID(grid), scroll, 0, (*row)++, 3, 1);
        r->widgets[1] = scroll;
        return r;
    }
    gtk_grid_attach(GTK_GRID(grid), label, 0, *row, 1, 1);
    r->widgets[1] = editor;
    if (compact) {
        /* The scope: a reset button for an override of this layer. */
        GtkWidget *reset = gtk_button_new_from_icon_name("edit-undo-symbolic");
        gtk_widget_add_css_class(reset, "flat");
        gtk_widget_add_css_class(reset, "zg-reset");
        gtk_widget_set_tooltip_text(reset, "Remove the change for these layers: use the value for all layers.");
        gtk_widget_set_valign(reset, GTK_ALIGN_CENTER);
        g_signal_connect(reset, "clicked", G_CALLBACK(on_reset_override), editor);
        gtk_grid_attach(GTK_GRID(grid), reset, 3, *row, 1, 1);
        g_object_set_data(G_OBJECT(editor), "zg-label", label);
        g_object_set_data(G_OBJECT(editor), "zg-reset", reset);
        g_signal_connect_object(model, "scope-changed", G_CALLBACK(on_scope_changed), editor, 0);
        char *signal = g_strconcat("setting-changed::", zg_setting_editor_info(editor)->name, NULL);
        g_signal_connect_object(model, signal, G_CALLBACK(on_scope_setting), editor, 0);
        g_free(signal);
        show_scope(editor);
    }
    if (number) {
        gtk_grid_attach(GTK_GRID(grid), editor, 1, *row, 1, 1);
        GtkWidget *unit = gtk_label_new(info->unit);
        gtk_widget_add_css_class(unit, "dim-label");
        gtk_widget_add_css_class(unit, "zg-unit");
        gtk_label_set_xalign(GTK_LABEL(unit), 0);
        /* One width for the unit column in all sections (each section
         * is its own grid), so the fields line up down the page. */
        gtk_label_set_width_chars(GTK_LABEL(unit), 13);
        gtk_label_set_max_width_chars(GTK_LABEL(unit), 13);
        gtk_label_set_wrap(GTK_LABEL(unit), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(unit), PANGO_WRAP_WORD);
        gtk_grid_attach(GTK_GRID(grid), unit, 2, (*row)++, 1, 1);
        r->widgets[2] = unit;
        zg_setting_editor_show_speed(editor, unit);
        if (info->slider_max > info->slider_min) {
            GtkWidget *slider = zg_setting_editor_slider_new(editor);
            if (compact) {
                g_object_set_data(G_OBJECT(editor), "zg-slider-w", slider);
            } else {
                gtk_grid_attach(GTK_GRID(grid), slider, 0, (*row)++, 3, 1);
                r->widgets[3] = slider;
            }
        }
    } else {
        gtk_widget_set_halign(editor, GTK_ALIGN_END);
        gtk_grid_attach(GTK_GRID(grid), editor, 1, (*row)++, 2, 1);
    }
    if (compact) {
        /* Under the row while it has the focus: its slider, and what this
         * setting does to the selected line. */
        GtkWidget *slider = g_object_get_data(G_OBJECT(editor), "zg-slider-w");
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        if (slider) gtk_box_append(GTK_BOX(box), slider);
        GtkWidget *why = gtk_label_new("");
        gtk_label_set_wrap(GTK_LABEL(why), TRUE);
        gtk_label_set_xalign(GTK_LABEL(why), 0);
        gtk_widget_add_css_class(why, "zg-why");
        gtk_box_append(GTK_BOX(box), why);
        GtkWidget *revealer = gtk_revealer_new();
        gtk_revealer_set_transition_type(GTK_REVEALER(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN);
        gtk_revealer_set_transition_duration(GTK_REVEALER(revealer), 120);
        gtk_revealer_set_child(GTK_REVEALER(revealer), box);
        g_object_set_data(G_OBJECT(revealer), "zg-entry", editor);
        g_object_set_data(G_OBJECT(revealer), "zg-slider-w", slider);
        g_object_set_data(G_OBJECT(revealer), "zg-why", why);
        watch_focus(editor, revealer);
        if (slider) watch_focus(slider, revealer);
        gtk_grid_attach(GTK_GRID(grid), revealer, 0, (*row)++, 3, 1);
        r->widgets[3] = revealer;
    }
    return r;
}
