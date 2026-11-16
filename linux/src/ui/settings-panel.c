/* settings-panel.c: see settings-panel.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "settings-panel.h"

#include "inspector.h"
#include "settings-browser.h"

GtkWidget *zg_settings_panel_new(ZgModel *model) {
    GtkWidget *stack = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_stack_set_transition_duration(GTK_STACK(stack), 120);
    gtk_stack_add_titled(GTK_STACK(stack), zg_inspector_new(model, stack), "selected", "Selected");
    GtkWidget *browser = zg_settings_browser_new(model, stack);
    gtk_stack_add_titled(GTK_STACK(stack), browser, "settings", "Settings");
    if (zg_settings_browser_opens_first(browser)) gtk_stack_set_visible_child(GTK_STACK(stack), browser);
    GtkWidget *switcher = gtk_stack_switcher_new();
    gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(switcher), GTK_STACK(stack));
    gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(switcher, 8);
    gtk_widget_set_margin_bottom(switcher, 4);
    /* The tabs scroll when the panel is narrow, so the panel can be as
     * narrow as the user wants. */
    GtkWidget *tabs = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(tabs), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(tabs), switcher);
    gtk_scrolled_window_set_propagate_natural_width(GTK_SCROLLED_WINDOW(tabs), TRUE);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_append(GTK_BOX(box), tabs);
    gtk_box_append(GTK_BOX(box), stack);
    gtk_widget_set_size_request(box, 220, -1);
    return box;
}
