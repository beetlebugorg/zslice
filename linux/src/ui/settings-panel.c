/* settings-panel.c: see settings-panel.h.
 *
 * The history: one list of the places of the panel, over both pages. A
 * place is the page ("selected", "history", "project"), or the page and the place in the
 * browser ("settings" and zg_settings_browser_get_place). Each move (a
 * tab, a section, a setting, a link from the Selected page, a click on a
 * line) puts the place before it on the list, and Back (the button at the
 * left of the tabs, the Back button of the browser, the back button of
 * the mouse, Alt+Left) goes back to it.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "settings-panel.h"

#include "history.h"
#include "inspector.h"
#include "project-page.h"
#include "settings-browser.h"

#include <string.h>

/* The longest history. */
enum { HISTORY_MAX = 50 };

typedef struct {
    GtkWidget *stack, *browser, *back, *top, *pad;
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

static void update_back(Panel *p) {
    gtk_widget_set_sensitive(p->back, p->history->len > 0);
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
    update_back(p);
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
    update_back(p);
}

static void on_back_clicked(GtkButton *b, gpointer data) {
    go_back(data);
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
    g_ptr_array_free(p->history, TRUE);
    g_free(p->current);
    g_free(p);
}

GtkWidget *zg_settings_panel_new(ZgModel *model) {
    Panel *p = g_new0(Panel, 1);
    p->history = g_ptr_array_new_with_free_func(g_free);
    GtkWidget *stack = gtk_stack_new();
    p->stack = stack;
    gtk_stack_set_transition_type(GTK_STACK(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_stack_set_transition_duration(GTK_STACK(stack), 120);
    /* Settings first, and open at the start; Selected after it. */
    GtkWidget *browser = zg_settings_browser_new(model, stack);
    p->browser = browser;
    gtk_stack_add_titled(GTK_STACK(stack), browser, "settings", "Settings");
    gtk_stack_add_titled(GTK_STACK(stack), zg_inspector_new(model, stack), "selected", "Selected");
    gtk_stack_add_titled(GTK_STACK(stack), zg_history_page_new(model, stack), "history", "History");
    gtk_stack_add_titled(GTK_STACK(stack), zg_project_page_new(model), "project", "Project");
    gtk_stack_set_visible_child(GTK_STACK(stack), browser);
    GtkWidget *switcher = gtk_stack_switcher_new();
    gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(switcher), GTK_STACK(stack));
    gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER);
    gtk_widget_set_hexpand(switcher, TRUE);
    /* The tabs scroll when the panel is narrow, so the panel can be as
     * narrow as the user wants. */
    GtkWidget *tabs = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(tabs), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(tabs), switcher);
    gtk_scrolled_window_set_propagate_natural_width(GTK_SCROLLED_WINDOW(tabs), TRUE);
    gtk_widget_set_hexpand(tabs, TRUE);
    /* Back: to the place before, on either page. */
    p->back = gtk_button_new_from_icon_name("go-previous-symbolic");
    gtk_widget_add_css_class(p->back, "flat");
    gtk_widget_set_tooltip_text(p->back, "Back to where you were (Alt+Left)");
    gtk_widget_set_valign(p->back, GTK_ALIGN_CENTER);
    g_signal_connect(p->back, "clicked", G_CALLBACK(on_back_clicked), p);
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_set_margin_start(top, 6);
    gtk_widget_set_margin_end(top, 6);
    gtk_widget_set_margin_top(top, 8);
    gtk_widget_set_margin_bottom(top, 4);
    gtk_box_append(GTK_BOX(top), p->back);
    gtk_box_append(GTK_BOX(top), tabs);
    /* The same width as Back at the right, so the tabs stay centered. */
    GtkWidget *pad = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_size_request(pad, 34, -1);
    gtk_box_append(GTK_BOX(top), pad);
    p->top = top;
    p->pad = pad;

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_append(GTK_BOX(box), top);
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
    zg_settings_browser_set_history(browser, moved, go_back, p);
    /* Settings for a part: the settings page shows them. */
    g_signal_connect(model, "part-scope-changed", G_CALLBACK(on_part_scope), p);
    update_back(p);
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
    if (p) gtk_stack_set_visible_child_name(GTK_STACK(p->stack), name);
}

void zg_settings_panel_set_end(GtkWidget *panel, GtkWidget *widget) {
    Panel *p = g_object_get_data(G_OBJECT(panel), "zg-panel");
    if (!p) return;
    if (p->pad) gtk_box_remove(GTK_BOX(p->top), p->pad);
    p->pad = NULL;
    gtk_widget_set_valign(widget, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(p->top), widget);
}
