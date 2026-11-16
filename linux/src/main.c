/* main.c: the GtkApplication entry point.
 *
 * One window and one ZgModel for the life of the app. A file on the command
 * line opens in the window.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include <gtk/gtk.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <unistd.h>

#include "model/app-model.h"
#include "ui/licenses.h"
#include "ui/preferences.h"
#include "ui/window.h"

#define ZG_APP_ID "org.beetlebug.Zslice"

/* The window is transparent, so that the 3D view (a Vulkan subsurface
 * under the window) shows through the view widget. Each other part of the
 * window paints its own background. */
static const char *ZG_CSS =
    "window.zg-main { background: transparent; }"
    ".zg-panel { background: @theme_bg_color; }"
    ".zg-status { padding: 6px 12px; }"
    ".zg-side { padding: 8px 8px 8px 4px; }"
    "entry.error { color: @error_color; }"
    /* The inspector: the speed summary, and old numbers while a slice runs. */
    ".zg-stat { padding: 3px 4px; border-radius: 6px; background: alpha(@theme_fg_color, 0.05); }"
    ".zg-stat-value { font-weight: bold; font-feature-settings: 'tnum'; }"
    ".zg-stat-value.warning { color: @warning_color; }"
    ".zg-stat-caption { font-size: 0.8em; opacity: 0.65; }"
    ".zg-note { font-size: 0.85em; color: @warning_color; transition: opacity 150ms; }"
    ".zg-explain { font-size: 0.9em; opacity: 0.85; }"
    ".zg-unit { font-size: 0.9em; min-width: 3.2em; }"
    ".zg-slider { margin-top: -4px; margin-bottom: 2px; }"
    "entry.zg-unusual { color: @warning_color; }"
    /* The compact rows of the inspector. */
    "entry.zg-compact { min-height: 26px; padding-top: 0; padding-bottom: 0; }"
    ".zg-insp-title { font-size: 1.1em; }"
    "label.zg-overridden { color: @accent_color; font-weight: bold; }"
    /* The navigation bar of the settings browser. */
    ".zg-nav { padding: 2px 6px; }"
    "button.zg-crumb { padding: 2px 6px; min-height: 24px; font-weight: normal; }"
    "button.zg-crumb-here { font-weight: bold; }"
    "progressbar.zg-thin trough, progressbar.zg-thin progress { min-height: 3px; }"
    "button.zg-reset { min-height: 20px; min-width: 20px; padding: 0; }"
    /* The controls that float over the preview. */
    ".zg-float { background: alpha(@theme_bg_color, 0.88); border-radius: 10px; padding: 4px;"
    "  box-shadow: 0 1px 4px alpha(black, 0.25); }"
    ".zg-layers { padding: 6px 0 4px; min-width: 28px; border-radius: 14px; }"
    ".zg-layers label { font-size: 0.7em; font-feature-settings: 'tnum'; }"
    ".zg-layers scale { padding: 0 6px; }"
    ".zg-layers label { margin-top: 2px; }"
    ".zg-scrub { padding: 2px 12px; border-radius: 14px; }"
    ".zg-scrub-label { font-size: 0.8em; font-feature-settings: 'tnum'; min-width: 120px; }"
    ".zg-lost { opacity: 0.55; }"
    "button.zg-islands { color: @warning_color; padding: 0 8px; min-height: 20px; }"
    ".zg-why { font-size: 0.85em; color: @accent_color; margin: 2px 0 6px; }"
    ".zg-legend { font-size: 0.8em; padding: 0 6px; font-feature-settings: 'tnum'; }"
    ".zg-inspector, .zg-status-text { transition: opacity 200ms ease-out; }"
    ".zg-stale { opacity: 0.55; }"
    /* The slice indicator over the preview. */
    ".zg-busy { padding: 4px 10px; border-radius: 999px; margin: 10px;"
    "  background: alpha(@theme_bg_color, 0.85); box-shadow: 0 1px 4px alpha(black, 0.25); }"
    "entry { font-feature-settings: 'tnum'; }";

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
    const char *prefs_keys[] = {"<Control>comma", NULL};
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.preferences", prefs_keys);
    const char *save_keys[] = {"<Control>s", NULL};
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.save-plate", save_keys);
    /* The model loaded the printers and the app settings. */
    zg_preferences_apply_theme();

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
    /* Each file is a part of the plate. */
    for (int i = 0; i < n; i++) zg_window_open_file(w, files[i]);
    gtk_window_present(w);
}

static void on_shutdown(GApplication *app, gpointer data) {
    g_clear_object(&model);
}

/* ---- the hang watchdog ----
 *
 * The UI thread sets a heartbeat every 250 ms. A watchdog thread checks it
 * every second. If the UI thread is 3 s late, the watchdog runs eu-stack on
 * the app once for that hang, and writes the stacks of all threads to
 * <cache>/zslice/hang-<time>.txt, so that a rare lockup can be found. */

static gint64 heartbeat;

static gboolean on_heartbeat(gpointer data) {
    heartbeat = g_get_monotonic_time();
    return G_SOURCE_CONTINUE;
}

static gpointer watchdog(gpointer data) {
    gboolean reported = FALSE;
    char *eu = g_find_program_in_path("eu-stack");
    for (;;) {
        g_usleep(G_USEC_PER_SEC);
        gint64 last = heartbeat;
        gint64 late = g_get_monotonic_time() - last;
        if (last == 0 || late < 3 * G_USEC_PER_SEC) {
            reported = FALSE;
            continue;
        }
        if (reported) continue;
        reported = TRUE;
        char *dir = g_build_filename(g_get_user_cache_dir(), "zslice", NULL);
        g_mkdir_with_parents(dir, 0700);
        GDateTime *now = g_date_time_new_now_local();
        char *stamp = g_date_time_format(now, "%Y%m%d-%H%M%S");
        char *path = g_strdup_printf("%s/hang-%s.txt", dir, stamp);
        g_printerr("zslice: the UI thread is %.1f s late; stacks in %s\n", late / 1e6, path);
        if (eu) {
            char *pid = g_strdup_printf("%d", (int)getpid());
            char *argv[] = {eu, "-p", pid, NULL};
            char *out = NULL, *err = NULL;
            if (g_spawn_sync(NULL, argv, NULL, G_SPAWN_DEFAULT, NULL, NULL, &out, &err, NULL, NULL)) {
                char *text = g_strdup_printf("UI thread late by %.1f s\n\n%s\n%s", late / 1e6, out ? out : "", err ? err : "");
                g_file_set_contents(path, text, -1, NULL);
                g_free(text);
            }
            g_free(out);
            g_free(err);
            g_free(pid);
        }
        g_free(path);
        g_free(stamp);
        g_date_time_unref(now);
        g_free(dir);
    }
    return NULL;
}

static gboolean test_hang(gpointer data) {
    g_usleep((gulong)(atof(g_getenv("ZSLICE_TEST_HANG")) * G_USEC_PER_SEC));
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
    heartbeat = g_get_monotonic_time();
    g_timeout_add(250, on_heartbeat, NULL);
#ifdef PR_SET_PTRACER
    /* With Yama ptrace protection, a child cannot read its parent: let the
     * watchdog's eu-stack read the stacks of the app. */
    prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
#endif
    g_thread_unref(g_thread_new("zslice-watchdog", watchdog, NULL));
    /* For a test of the watchdog: ZSLICE_TEST_HANG=4 stops the UI thread
     * for 4 s, 3 s after the start. */
    if (g_getenv("ZSLICE_TEST_HANG")) g_timeout_add_seconds(3, test_hang, NULL);
    GApplicationFlags flags = G_APPLICATION_HANDLES_OPEN;
    /* For development and tests: ZSLICE_NON_UNIQUE=1 starts a separate
     * instance. Without it, a second start sends its file to the running
     * instance. */
    if (g_getenv("ZSLICE_NON_UNIQUE")) flags |= G_APPLICATION_NON_UNIQUE;
    GtkApplication *app = gtk_application_new(ZG_APP_ID, flags);
    g_signal_connect(app, "startup", G_CALLBACK(on_startup), NULL);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    g_signal_connect(app, "open", G_CALLBACK(on_open), NULL);
    g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
