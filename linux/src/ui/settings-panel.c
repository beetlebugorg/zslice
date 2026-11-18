/* settings-panel.c: see settings-panel.h.
 *
 * The history: one list of the places of the panel, over both pages. A
 * place is the page ("selected"), or the page and the place in the
 * browser ("settings" and zg_settings_browser_get_place). Each move (a
 * section, a setting, a link from the Selected page, a click on a line)
 * puts the place before it on the list. The back button of the mouse and
 * Alt+Left go back to it. The arrows of the top row go up one level: the
 * column before in the settings, or the settings from the Selected page.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "settings-panel.h"

#include "inspector.h"
#include "settings-browser.h"

#include <string.h>

/* The longest history. */
enum { HISTORY_MAX = 50 };

typedef struct {
    ZgModel *model;
    GtkWidget *stack, *browser, *inspector, *top;
    /* The top row: the bar of the browser, or the title of the Selected
     * page with its back arrow. */
    GtkWidget *nav, *selected_top, *title;
    GPtrArray *history; /* char *, the oldest first */
    char *current;
    gboolean restoring;
} Panel;

static char *place_now(Panel *p) {
    GtkWidget *page = gtk_stack_get_visible_child(GTK_STACK(p->stack));
    if (page != p->browser) return g_strdup(gtk_stack_get_visible_child_name(GTK_STACK(p->stack)));
    char *b = zg_settings_browser_get_place(p->browser);
    char *place = g_strconcat("settings\n", b, NULL);
    g_free(b);
    return place;
}

/* After a move: the place before it goes on the history. */
static void moved(gpointer data) {
    Panel *p = data;
    if (p->restoring) return;
    char *now = place_now(p);
    if (p->current && strcmp(now, p->current) != 0) {
        g_ptr_array_add(p->history, p->current);
        if (p->history->len > HISTORY_MAX) g_ptr_array_remove_index(p->history, 0);
        p->current = now;
    } else {
        g_free(p->current);
        p->current = now;
    }
}

static void go_back(gpointer data) {
    Panel *p = data;
    if (p->history->len == 0) {
        /* No history: the column before, in the browser. */
        if (gtk_stack_get_visible_child(GTK_STACK(p->stack)) == p->browser) zg_settings_browser_up(p->browser);
        return;
    }
    char *place = g_ptr_array_steal_index(p->history, p->history->len - 1);
    p->restoring = TRUE;
    if (g_str_has_prefix(place, "settings\n")) {
        gtk_stack_set_visible_child(GTK_STACK(p->stack), p->browser);
        zg_settings_browser_set_place(p->browser, place + strlen("settings\n"));
    } else {
        gtk_stack_set_visible_child_name(GTK_STACK(p->stack), place);
    }
    p->restoring = FALSE;
    g_free(p->current);
    p->current = place;
}

static void on_page(GObject *stack, GParamSpec *pspec, gpointer data) {
    moved(data);
}

/* The back button of the mouse (button 8). */
static void on_mouse_back(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    go_back(data);
}

static gboolean on_alt_left(GtkWidget *w, GVariant *args, gpointer data) {
    go_back(data);
    return TRUE;
}

static void on_part_scope(ZgModel *model, gpointer data) {
    Panel *p = data;
    if (zg_model_part_scope(model) >= 0) gtk_stack_set_visible_child(GTK_STACK(p->stack), p->browser);
}

static void panel_free(gpointer data) {
    Panel *p = data;
    g_signal_handlers_disconnect_by_data(p->model, p);
    g_ptr_array_free(p->history, TRUE);
    g_free(p->current);
    g_free(p);
}

/* The top row follows the page: the path of the settings, or the title
 * of the selected line with its back arrow. */
static void update_top(Panel *p) {
    gboolean selected = gtk_stack_get_visible_child(GTK_STACK(p->stack)) == p->inspector;
    gtk_widget_set_visible(p->nav, !selected);
    gtk_widget_set_visible(p->selected_top, selected);
    gtk_label_set_text(GTK_LABEL(p->title), zg_inspector_title(p->inspector));
}

static void on_top_page(GObject *stack, GParamSpec *pspec, gpointer data) {
    update_top(data);
}

/* The page of the selection changed: a line, a part, or a gap. */
static void on_selection_kind(gpointer data) {
    update_top(data);
}

static void on_selected_back(GtkButton *b, gpointer data) {
    Panel *p = data;
    gtk_stack_set_visible_child(GTK_STACK(p->stack), p->browser);
}

GtkWidget *zg_settings_panel_new(ZgModel *model) {
    Panel *p = g_new0(Panel, 1);
    p->model = model;
    p->history = g_ptr_array_new_with_free_func(g_free);
    GtkWidget *stack = gtk_stack_new();
    p->stack = stack;
    gtk_stack_set_transition_type(GTK_STACK(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_stack_set_transition_duration(GTK_STACK(stack), 120);
    /* Settings first, and open at the start; Selected after it. */
    GtkWidget *browser = zg_settings_browser_new(model, stack);
    p->browser = browser;
    gtk_stack_add_named(GTK_STACK(stack), browser, "settings");
    p->inspector = zg_inspector_new(model, stack);
    gtk_stack_add_named(GTK_STACK(stack), p->inspector, "selected");
    gtk_stack_set_visible_child(GTK_STACK(stack), browser);

    /* The top row: the path of the settings with its back arrow, or the
     * title of the selected line with a back arrow to the settings. Pin
     * and close go at the end (zg_settings_panel_set_end). */
    p->nav = zg_settings_browser_nav(browser);
    GtkWidget *back = gtk_button_new_from_icon_name("go-previous-symbolic");
    gtk_widget_add_css_class(back, "flat");
    gtk_widget_set_tooltip_text(back, "Back to the settings");
    gtk_widget_set_valign(back, GTK_ALIGN_CENTER);
    g_signal_connect(back, "clicked", G_CALLBACK(on_selected_back), p);
    p->title = gtk_label_new("Selected line");
    gtk_widget_add_css_class(p->title, "heading");
    gtk_label_set_xalign(GTK_LABEL(p->title), 0);
    gtk_label_set_ellipsize(GTK_LABEL(p->title), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(p->title, TRUE);
    p->selected_top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_add_css_class(p->selected_top, "zg-nav");
    gtk_widget_set_hexpand(p->selected_top, TRUE);
    gtk_box_append(GTK_BOX(p->selected_top), back);
    gtk_box_append(GTK_BOX(p->selected_top), p->title);
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_add_css_class(top, "zg-panel-top");
    gtk_box_append(GTK_BOX(top), p->nav);
    gtk_box_append(GTK_BOX(top), p->selected_top);
    p->top = top;

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(box), top);
    gtk_box_append(GTK_BOX(box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(box), stack);
    gtk_widget_set_size_request(box, 220, -1);

    GtkGesture *mouse = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(mouse), 8);
    g_signal_connect(mouse, "pressed", G_CALLBACK(on_mouse_back), p);
    gtk_widget_add_controller(box, GTK_EVENT_CONTROLLER(mouse));
    GtkEventController *keys = gtk_shortcut_controller_new();
    gtk_shortcut_controller_set_scope(GTK_SHORTCUT_CONTROLLER(keys), GTK_SHORTCUT_SCOPE_GLOBAL);
    gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(keys),
                                         gtk_shortcut_new(gtk_keyval_trigger_new(GDK_KEY_Left, GDK_ALT_MASK),
                                                          gtk_callback_action_new(on_alt_left, p, NULL)));
    gtk_widget_add_controller(box, keys);

    g_object_set_data_full(G_OBJECT(box), "zg-panel", p, panel_free);
    p->current = place_now(p);
    g_signal_connect(stack, "notify::visible-child", G_CALLBACK(on_page), p);
    g_signal_connect(stack, "notify::visible-child", G_CALLBACK(on_top_page), p);
    zg_settings_browser_set_history(browser, moved, p);
    /* Settings for a part: the settings page shows them. */
    g_signal_connect(model, "part-scope-changed", G_CALLBACK(on_part_scope), p);
    /* After the inspector: it builds its page first. */
    g_signal_connect_swapped(model, "picked", G_CALLBACK(on_selection_kind), p);
    g_signal_connect_swapped(model, "part-selected", G_CALLBACK(on_selection_kind), p);
    g_signal_connect_swapped(model, "gaps-changed", G_CALLBACK(on_selection_kind), p);
    g_signal_connect_swapped(model, "selection-changed", G_CALLBACK(on_selection_kind), p);
    update_top(p);
    return box;
}

void zg_settings_panel_show_setting(GtkWidget *panel, const char *key) {
    Panel *p = g_object_get_data(G_OBJECT(panel), "zg-panel");
    if (!p) return;
    gtk_stack_set_visible_child(GTK_STACK(p->stack), p->browser);
    zg_settings_browser_show_setting(p->browser, key);
}

void zg_settings_panel_show_page(GtkWidget *panel, const char *name) {
    Panel *p = g_object_get_data(G_OBJECT(panel), "zg-panel");
    if (p && (strcmp(name, "settings") == 0 || strcmp(name, "selected") == 0))
        gtk_stack_set_visible_child_name(GTK_STACK(p->stack), name);
}

void zg_settings_panel_set_end(GtkWidget *panel, GtkWidget *widget) {
    Panel *p = g_object_get_data(G_OBJECT(panel), "zg-panel");
    if (!p) return;
    gtk_widget_set_valign(widget, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(p->top), widget);
}

void zg_settings_panel_refocus(GtkWidget *panel) {
    Panel *p = g_object_get_data(G_OBJECT(panel), "zg-panel");
    if (p) zg_settings_browser_send_focus(p->browser);
}
