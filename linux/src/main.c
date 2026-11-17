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
#include "ui/printer-picker.h"
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
    ".zg-profile-bar { padding: 8px 12px; background: alpha(@accent_bg_color, 0.14); }"
    "button.zg-crumb { padding: 2px 6px; min-height: 24px; font-weight: normal; }"
    "button.zg-crumb-here { font-weight: bold; }"
    "progressbar.zg-thin trough, progressbar.zg-thin progress { min-height: 3px; }"
    "button.zg-reset { min-height: 20px; min-width: 20px; padding: 0; }"
    /* The controls that float over the preview. */
    ".zg-measure-readout { padding: 4px 12px; border-radius: 8px; }\n"
    ".zg-float { background: alpha(@theme_bg_color, 0.88); border-radius: 10px; padding: 4px;"
    "  box-shadow: 0 1px 4px alpha(black, 0.25); }"
    /* The layer slider on the 3D view: a thin track, white knobs with a
     * soft shadow, and the numbers in small bubbles beside the knobs. */
    ".zg-layers { padding: 10px 6px; }"
    ".zg-layers trough { min-width: 4px; border-radius: 2px; background: alpha(#000, 0.18); }"
    ".zg-layers highlight { border-radius: 2px; background: @accent_bg_color; }"
    ".zg-layers slider { min-width: 18px; min-height: 18px; border-radius: 9px; background: #ffffff;"
    "  border: 1px solid alpha(#000, 0.25); box-shadow: 0 1px 3px alpha(#000, 0.3); }"
    ".zg-layers slider:hover { box-shadow: 0 1px 4px alpha(#000, 0.4), 0 0 0 3px alpha(@accent_bg_color, 0.25); }"
    ".zg-summary { padding: 12px 14px 14px; }"
    /* The cards over the view (float.h), and the drawer of the panel. */
    ".zg-card { background: @theme_bg_color; border-radius: 12px; padding: 10px 12px;"
    "  box-shadow: 0 2px 10px alpha(black, 0.30); border: 1px solid alpha(@theme_fg_color, 0.08); }"
    ".zg-card-head { min-height: 24px; }"
    ".zg-card-title { font-weight: 700; }"
    ".zg-card-handle { }"
    ".zg-card-moving { opacity: 0.92; }"
    "button.zg-card-close { min-height: 22px; min-width: 22px; padding: 0; }"
    ".zg-print-card { padding: 12px 14px 14px; }"
    ".zg-drawer { box-shadow: -2px 0 12px alpha(black, 0.30); }"
    /* The tool strip at the left of the view: a glyph and its key. */
    ".zg-strip { padding: 4px; }"
    "button.zg-strip-button { min-width: 34px; min-height: 34px; padding: 3px; }"
    "button.zg-strip-button:checked { background: alpha(@theme_selected_bg_color, 0.45); }"
    ".zg-strip-key { font-size: 0.62em; font-weight: 700; opacity: 0.7; margin: -3px -2px; }"
    ".zg-lc-why { font-size: 0.8em; color: mix(@theme_selected_bg_color, @theme_fg_color, 0.45); }"
    ".zg-keys-group { font-weight: 700; margin-top: 12px; margin-bottom: 2px; }"
    ".zg-card-heading { font-size: 0.8em; font-weight: 700; opacity: 0.6; margin-top: 4px; }"
    "button.zg-card-action { min-height: 26px; padding: 2px 8px; }"
    /* The facts of the print card: small buttons. */
    "button.zg-fact { min-height: 22px; padding: 1px 7px; font-size: 0.85em; font-weight: normal; border-radius: 11px; }"
    "flowboxchild { padding: 0; }"
    /* The search (search.c). */
    ".zg-search { padding: 8px 8px 6px; }"
    ".zg-sr { padding: 4px 8px; border-radius: 8px; }"
    ".zg-sr.zg-sr-on { background-color: alpha(@theme_selected_bg_color, 0.30); }"
    ".zg-sr:focus-visible { outline: 2px solid alpha(@theme_selected_bg_color, 0.8); outline-offset: -2px; }"
    ".zg-sr-tag { font-size: 0.8em; opacity: 0.6; }"
    ".zg-sr-group { font-size: 0.8em; font-weight: 700; opacity: 0.6; padding: 8px 8px 2px; }"
    ".zg-sr-note { font-size: 0.9em; opacity: 0.7; padding: 8px; }"
    ".zg-sr-scope { font-weight: 700; color: @theme_selected_bg_color; }"
    "button.zg-sr-eye { min-height: 24px; min-width: 24px; padding: 2px; }"
    "button.zg-sr-eye:checked { color: @theme_selected_bg_color; }"
    ".zg-keycap { font-size: 0.8em; padding: 1px 6px; border-radius: 5px; border: 1px solid alpha(@theme_fg_color, 0.25);"
    "  background: alpha(@theme_fg_color, 0.06); font-feature-settings: 'tnum'; }"
    ".zg-summary-time { font-size: 1.6em; font-weight: 700; font-feature-settings: 'tnum'; }"
    ".zg-summary.zg-stale { opacity: 0.55; }"
    /* The source of a value in the settings (see zg_model_source_text):
     * dim, and the accent color for a change of this print or a part. */
    ".zg-source { opacity: 0.6; font-size: 0.8em; }"
    ".zg-source-mine { color: @accent_color; opacity: 1; }"
    ".zg-issue-problem { color: #e01b24; }"
    ".zg-issue-warning { color: #e5a50a; }"
    ".zg-knob-label { font-size: 0.75em; font-feature-settings: 'tnum'; color: #fff; background: alpha(#202326, 0.82);"
    "  border-radius: 6px; padding: 1px 6px; min-width: 2.2em; }"
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
    /* The printer picker. */
    ".zg-pick-hero { padding: 18px 24px 14px; background: alpha(@accent_bg_color, 0.10); }"
    ".zg-pick-hero-title { font-size: 1.6em; font-weight: 800; }"
    ".zg-pick-side, .zg-pick-mid { padding: 12px; }"
    ".zg-pick-card { padding: 18px 22px; }"
    ".zg-pick-form { padding: 18px 22px; }"
    ".zg-pick-section { font-size: 0.8em; font-weight: 700; letter-spacing: 0.06em; opacity: 0.6; }"
    ".zg-pick-title { font-size: 1.45em; font-weight: 800; }"
    ".zg-pick-name { font-weight: 600; }"
    ".zg-pick-row { padding: 5px 4px; }"
    ".zg-brand-row { padding: 2px 2px; }"
    ".zg-found-row { padding: 6px 8px; }"
    ".zg-pick-group { font-size: 0.8em; font-weight: 700; opacity: 0.55; padding: 10px 8px 2px; }"
    ".zg-pick-facts { padding: 10px 12px; border-radius: 10px; background: alpha(@theme_fg_color, 0.04); }"
    ".zg-pick-hint { padding: 8px 12px; border-radius: 8px; background: alpha(@accent_bg_color, 0.14); }"
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
    const char *undo_keys[] = {"<Control>z", NULL};
    const char *redo_keys[] = {"<Control><Shift>z", "<Control>y", NULL};
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.undo", undo_keys);
    gtk_application_set_accels_for_action(GTK_APPLICATION(app), "win.redo", redo_keys);
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
    GtkWindow *w = main_window(GTK_APPLICATION(app));
    gtk_window_present(w);
    /* The first start (no printer set up): the printer picker. */
    static gboolean once;
    if (!once) zg_printer_picker_startup(w, model);
    once = TRUE;
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
