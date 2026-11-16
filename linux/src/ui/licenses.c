/* licenses.c: see licenses.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "licenses.h"

#include "zslice-app.h"

/* The libraries that the GTK shell links. The shell links them as shared
 * libraries from the system; their code is not in the zslice binary. */
static const struct {
    const char *name;
    const char *license;
    const char *text;
} shell_components[] = {
    {"GTK 4", "LGPL-2.1-or-later",
     "GTK is free software under the GNU Lesser General Public License, version 2.1 or later.\n\n"
     "zslice links GTK as a shared library from your system. Your system has the full license text, "
     "usually in /usr/share/licenses/ or /usr/share/doc/."},
    {"GLib", "LGPL-2.1-or-later",
     "GLib is free software under the GNU Lesser General Public License, version 2.1 or later.\n\n"
     "zslice links GLib as a shared library from your system. Your system has the full license text, "
     "usually in /usr/share/licenses/ or /usr/share/doc/."},
    {"cairo", "LGPL-2.1-only OR MPL-1.1",
     "cairo is free software under the GNU Lesser General Public License, version 2.1, or the Mozilla "
     "Public License, version 1.1.\n\n"
     "zslice links cairo as a shared library from your system. Your system has the full license text, "
     "usually in /usr/share/licenses/ or /usr/share/doc/."},
};

typedef struct {
    GtkWidget *view;
} Licenses;

static void show_text(Licenses *l, const char *text) {
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(l->view)), text, -1);
}

static void on_row(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    if (!row) return;
    show_text(data, g_object_get_data(G_OBJECT(row), "zg-text"));
}

static void add_row(GtkWidget *list, const char *name, const char *license, const char *text) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_margin_start(box, 10);
    gtk_widget_set_margin_end(box, 10);
    gtk_widget_set_margin_top(box, 6);
    gtk_widget_set_margin_bottom(box, 6);
    GtkWidget *title = gtk_label_new(name);
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    GtkWidget *sub = gtk_label_new(license);
    gtk_widget_set_halign(sub, GTK_ALIGN_START);
    gtk_widget_add_css_class(sub, "dim-label");
    gtk_widget_add_css_class(sub, "caption");
    gtk_box_append(GTK_BOX(box), title);
    gtk_box_append(GTK_BOX(box), sub);
    GtkWidget *row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data(G_OBJECT(row), "zg-text", (gpointer)text);
    gtk_list_box_append(GTK_LIST_BOX(list), row);
}

void zg_licenses_show(GtkWindow *parent) {
    Licenses *l = g_new0(Licenses, 1);
    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), "Licenses");
    gtk_window_set_transient_for(GTK_WINDOW(win), parent);
    gtk_window_set_default_size(GTK_WINDOW(win), 900, 600);
    g_object_set_data_full(G_OBJECT(win), "zg-licenses", l, g_free);

    GtkWidget *list = gtk_list_box_new();
    for (size_t i = 0; i < zs_license_count(); i++) {
        zs_license lic;
        if (zs_license_get(i, &lic) == ZS_OK) add_row(list, lic.name, lic.license, lic.text);
    }
    for (size_t i = 0; i < G_N_ELEMENTS(shell_components); i++) {
        add_row(list, shell_components[i].name, shell_components[i].license, shell_components[i].text);
    }
    g_signal_connect(list, "row-selected", G_CALLBACK(on_row), l);

    l->view = gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(l->view), FALSE);
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(l->view), TRUE);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(l->view), 12);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(l->view), 12);

    GtkWidget *list_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(list_scroll), list);
    gtk_widget_set_size_request(list_scroll, 260, -1);
    GtkWidget *text_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(text_scroll), l->view);

    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_paned_set_start_child(GTK_PANED(paned), list_scroll);
    gtk_paned_set_end_child(GTK_PANED(paned), text_scroll);
    gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
    gtk_window_set_child(GTK_WINDOW(win), paned);

    gtk_list_box_select_row(GTK_LIST_BOX(list), gtk_list_box_get_row_at_index(GTK_LIST_BOX(list), 0));
    gtk_window_present(GTK_WINDOW(win));
}
