/* main.c: the GtkApplication entry point.
 *
 * One window and one ZgModel for the life of the app. A file on the command
 * line opens in the window.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <gtk/gtk.h>

#include "model/app-model.h"
#include "ui/licenses.h"
#include "ui/window.h"

#define ZG_APP_ID "org.beetlebug.Zslice"

static const char *ZG_CSS =
    ".zg-status { padding: 6px 12px; }"
    "entry.error { color: @error_color; }";

static ZgModel *model;

static GtkWindow *main_window(GtkApplication *app) {
    GtkWindow *w = gtk_application_get_active_window(app);
    if (!w) w = zg_window_new(app, model);
    return w;
}

static void on_open_action(GSimpleAction *a, GVariant *p, gpointer app) {
    zg_window_open_dialog(main_window(app));
}

static void on_export_action(GSimpleAction *a, GVariant *p, gpointer app) {
    zg_window_export_dialog(main_window(app));
}

static void on_licenses_action(GSimpleAction *a, GVariant *p, gpointer app) {
    zg_licenses_show(main_window(app));
}

static void on_about_action(GSimpleAction *a, GVariant *p, gpointer app) {
    gtk_show_about_dialog(main_window(app),
        "program-name", "zslice",
        "version", ZG_VERSION,
        "comments", "A slicer for FDM 3D printers.\nThe Licenses window lists each component and its license.",
        "license-type", GTK_LICENSE_AGPL_3_0,
        NULL);
}

static void on_quit_action(GSimpleAction *a, GVariant *p, gpointer app) {
    g_application_quit(G_APPLICATION(app));
}

static const GActionEntry actions[] = {
    {.name = "open", .activate = on_open_action},
    {.name = "export", .activate = on_export_action},
    {.name = "licenses", .activate = on_licenses_action},
    {.name = "about", .activate = on_about_action},
    {.name = "quit", .activate = on_quit_action},
};

static void on_startup(GApplication *app, gpointer data) {
    model = zg_model_new();
    g_action_map_add_action_entries(G_ACTION_MAP(app), actions, G_N_ELEMENTS(actions), app);
    const char *open_keys[] = {"<Control>o", NULL};
    const char *export_keys[] = {"<Control>e", NULL};
    const char *quit_keys[] = {"<Control>q", NULL};
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "app.open", open_keys);
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "app.export", export_keys);
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "app.quit", quit_keys);

    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css, ZG_CSS);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
}

static void on_activate(GApplication *app, gpointer data) {
    gtk_window_present(main_window(GTK_APPLICATION(app)));
}

static void on_open(GApplication *app, GFile **files, int n, const char *hint, gpointer data) {
    GtkWindow *w = main_window(GTK_APPLICATION(app));
    if (n > 0) zg_window_open_file(w, files[0]);
    gtk_window_present(w);
}

static void on_shutdown(GApplication *app, gpointer data) {
    g_clear_object(&model);
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new(ZG_APP_ID, G_APPLICATION_HANDLES_OPEN);
    g_signal_connect(app, "startup", G_CALLBACK(on_startup), NULL);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    g_signal_connect(app, "open", G_CALLBACK(on_open), NULL);
    g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
