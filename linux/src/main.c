/* main.c: the GtkApplication entry point.
 *
 * One window and one ZgModel for the life of the app. A file or a
 * zslice:// link on the command line opens in the window. A second start
 * hands its files and links to the first one.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "model/app-model.h"
#include "ui/licenses.h"
#include "ui/open-link.h"
#include "ui/preferences.h"
#include "ui/printer-picker.h"
#include "ui/window.h"
#include "ui/view3d.h"
#include "prefs/printers.h"
#include <string.h>

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
    /* The work bar of the view: 2 px, no trough, and a fade. */
    "progressbar.zg-work { opacity: 0; transition: opacity 200ms ease; }"
    "progressbar.zg-work.on { opacity: 1; }"
    "progressbar.zg-work trough { min-height: 2px; background: none; border: none; box-shadow: none; }"
    "progressbar.zg-work progress { min-height: 2px; min-width: 2px; border-radius: 0; }"
    /* What runs and its time: small dim text, with a fade. */
    ".zg-work-text { opacity: 0; transition: opacity 200ms ease; }"
    ".zg-work-text.on { opacity: 0.6; }"
    "button.zg-reset { min-height: 20px; min-width: 20px; padding: 0; }"
    /* The controls that float over the preview. */
    ".zg-measure-readout { padding: 4px 12px; border-radius: 8px; }\n"
    ".zg-note-view { padding: 6px 14px; border-radius: 8px; }"
    /* The Open button of an empty plate, on the plate: small and calm. */
    "button.zg-plate-open { padding: 2px 12px; min-height: 24px; border-radius: 999px; font-size: 0.9em;"
    "  background: alpha(@theme_bg_color, 0.88); border: 1px solid alpha(@theme_fg_color, 0.14); }"
    "button.zg-plate-open:hover { border-color: @accent_bg_color; }"
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
    /* A hint of the print card: a file in inches, or no support under
     * a large overhang. The web app uses the same amber. */
    ".zg-hint { color: #fff; background: #8a5a00; border-radius: 6px; padding: 6px 8px; margin-top: 4px; font-size: 0.88em; }"
    ".zg-hint button { color: #fff; min-height: 24px; padding: 2px 8px; }"
    ".zg-drawer { box-shadow: -2px 0 12px alpha(black, 0.30); }"
    /* The top row of the panel: the path or the title, Pin, and close. */
    ".zg-panel-top { padding: 6px 6px 4px 0; min-height: 38px; }"
    /* The Printers page over the view: it paints its whole area. */
    ".zg-farm-view { background: @theme_bg_color; }"
    ".zg-farm-bar { padding: 8px 12px; }"
    /* The cards of the Printers page (farm-page.c), and the cameras
     * (camera-view.c). */
    ".zg-farm-card { background: alpha(@theme_fg_color, 0.05); border: 1px solid alpha(@theme_fg_color, 0.1); border-radius: 10px; }"
    ".zg-farm-card.failed { border-color: alpha(@error_color, 0.6); }"
    ".zg-farm-card.done { border-color: alpha(@success_color, 0.5); }"
    ".zg-farm-card.offline .zg-farm-who { opacity: 0.6; }"
    ".zg-farm-badge { font-size: 0.8em; font-weight: bold; padding: 2px 8px; border-radius: 999px; background: alpha(@theme_fg_color, 0.1); }"
    ".zg-farm-badge.printing { color: @accent_color; background: alpha(@accent_color, 0.18); }"
    ".zg-farm-badge.paused { color: @warning_color; background: alpha(@warning_color, 0.18); }"
    ".zg-farm-badge.done { color: @success_color; background: alpha(@success_color, 0.16); }"
    ".zg-farm-badge.failed { color: @error_color; background: alpha(@error_color, 0.18); }"
    ".zg-farm-badge.offline { opacity: 0.7; }"
    ".zg-farm-count { font-size: 0.85em; padding: 2px 8px; border-radius: 999px; background: alpha(@theme_fg_color, 0.08); }"
    ".zg-farm-why { font-size: 0.9em; color: @error_color; }"
    ".zg-farm-why.paused { color: @warning_color; }"
    ".zg-farm-why.offline { color: alpha(@theme_fg_color, 0.6); }"
    ".zg-farm-small { font-size: 0.9em; }"
    ".zg-farm-queue { background: alpha(@theme_fg_color, 0.05); border-radius: 10px; }"
    ".camera { background: #111; border-radius: 10px 10px 0 0; }"
    ".camera-large { border-radius: 0; }"
    ".camera-msg { color: alpha(white, 0.75); font-size: 0.9em; }"
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
    ".zg-search.zg-search-docked { padding-top: 6px; }"
    ".zg-search-field { min-width: 180px; min-height: 32px; padding: 0 2px 0 8px; border-radius: 8px;"
    " background-color: alpha(@theme_fg_color, 0.06); border: 1px solid alpha(@theme_fg_color, 0.12); }"
    ".zg-search-field.zg-open, .zg-search-field:focus-within { border-color: @theme_selected_bg_color; }"
    ".zg-search-field entry { background: none; border: none; box-shadow: none; outline: none; min-height: 28px; padding: 0; }"
    ".zg-search-field button { min-height: 24px; min-width: 24px; padding: 0; }"
    ".zg-search-field .zg-keycap { margin-right: 4px; }"
    "button.zg-search-pin { min-height: 26px; min-width: 26px; padding: 0; opacity: 0.7; }"
    "button.zg-search-pin:hover { opacity: 1; }"
    ".zg-resize-grip { opacity: 0.5; margin: -4px -4px 0 0; }"
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
    /* The head of the print card, and its badge: the problems and the
     * warnings (red, as on the web) or the refinements. */
    ".zg-sum-head { padding: 2px 4px; }"
    ".zg-sum-badge { padding: 1px 8px; border-radius: 999px; font-size: 0.85em; font-weight: 600;"
    "  background: alpha(@accent_color, 0.18); }"
    ".zg-sum-badge.warn { background: #b42318; color: #ffffff; }"
    /* The count of the problems on the Check button (preview.c). */
    ".zg-check-count { min-width: 14px; min-height: 14px; padding: 0 3px; margin: -2px -4px 0 0; border-radius: 7px;"
    "  font-size: 10px; font-weight: 600; background: #d97706; color: #ffffff; }"
    ".zg-summary.zg-stale { opacity: 0.55; }"
    /* The source of a value in the settings (see zg_model_source_text):
     * dim, and the accent color for a change of this print or a part. */
    ".zg-source { opacity: 0.6; font-size: 0.8em; }"
    ".zg-source-mine { color: @accent_color; opacity: 1; }"
    /* Whose setting it is (settings-browser.c): a printer setting in blue,
     * a filament setting in orange, as on the web. */
    ".zg-owner-printer { color: #1c7ed6; }"
    ".zg-owner-filament { color: #d9480f; }"
    ".zg-owner-badge { font-size: 0.8em; font-weight: 600; padding: 0 6px; border-radius: 9px; }"
    ".zg-owner-badge.zg-owner-printer { background: alpha(#1c7ed6, 0.16); }"
    ".zg-owner-badge.zg-owner-filament { background: alpha(#d9480f, 0.14); }"
    ".zg-owner-banner { margin: 6px 10px; font-size: 0.9em; }"
    ".zg-owner-note { margin-top: 4px; font-size: 0.9em; }"
    ".zg-issue-problem { color: #e01b24; }"
    ".zg-issue-warning { color: #e5a50a; }"
    ".zg-knob-label { font-size: 0.75em; font-feature-settings: 'tnum'; color: #fff; background: alpha(#202326, 0.82);"
    "  border-radius: 6px; padding: 1px 6px; min-width: 2.2em; }"
    /* The dock: one bar at the bottom of the preview. Its groups (the
     * plates, the replay, the history) have no background of their own,
     * and a thin line separates them. */
    /* The dock: one bar, the full width of the view, at its bottom (as on
     * the web): the plates and the history, the replay under them, and
     * the print at the right, with a thin line before each group. */
    ".zg-dock { padding: 5px 12px 6px; background: alpha(@theme_bg_color, 0.96);"
    "  border-top: 1px solid alpha(currentColor, 0.12); box-shadow: 0 -2px 10px rgba(0, 0, 0, 0.25); }"
    ".zg-dock button { min-height: 28px; }"
    ".zg-dock-group { border-left: 1px solid alpha(currentColor, 0.15); padding-left: 8px; }"
    ".zg-dock-summary { border-left: 1px solid alpha(currentColor, 0.15); padding-left: 12px; }"
    ".zg-dock-summary .zg-summary-time { font-size: 1.3em; }"
    ".zg-dock-summary .zg-sum-head > grid > label.dim-label { font-size: 0.8em; }"
    ".zg-scrub-label { font-size: 0.8em; font-feature-settings: 'tnum'; }"
    /* The view buttons in the middle of the header bar. */
    ".zg-view-bar .zg-keycap { margin-left: 4px; }"
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
    "entry { font-feature-settings: 'tnum'; }"
    /* The filaments of the plate (ui/filaments.c). */
    ".zg-fil-chip { padding: 0; min-width: 0; min-height: 0; }"
    ".zg-fil-text { padding: 0 8px; border-radius: 13px; min-height: 26px; }"
    ".zg-fil-text.zg-on { box-shadow: inset 0 0 0 2px @theme_fg_color; }"
    ".zg-fil-note { font-size: 0.85em; opacity: 0.75; }";

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

/* ---- the session: the app comes back as it was after a quit ----
 *
 * The session file of the core (zs_session_snapshot_take) in the state
 * folder: the plates, the camera, and the window (its size, maximized). It is
 * written 1.5 s after a slice, at the close of the window, and at quit
 * (atomically: g_file_set_contents writes a new file, then renames it).
 *
 * The UI thread copies the session (a few ms). The bytes of the copy (the
 * 3MF text of the meshes and the deflate: about 300 ms for a 3DBenchy)
 * come on a thread of a GTask after a slice, and at once at the close and
 * at quit. Each save has a number: a thread writes the file only if no
 * later save started, so an old copy does not replace a newer file. */

static GMutex session_lock;
static guint session_serial;

static char *session_path(void) {
    char *dir = zg_config_dir();
    g_mkdir_with_parents(dir, 0700);
    char *p = g_build_filename(dir, "session.zslice", NULL);
    g_free(dir);
    return p;
}

typedef struct {
    zs_session_snapshot *snap;
    char *path;
    guint serial;
} SessionWrite;

static void session_write_free(gpointer data) {
    SessionWrite *sw = data;
    zs_session_snapshot_free(sw->snap);
    g_free(sw->path);
    g_free(sw);
}

/* Makes the bytes of the copy, and writes them if no later save started.
 * On the thread of a GTask, or on the UI thread at the close and at quit. */
static void session_write(SessionWrite *sw) {
    uint8_t *out = NULL;
    size_t len = 0;
    if (zs_session_snapshot_write(sw->snap, &out, &len) != ZS_OK) {
        g_message("zslice: the session did not save: no memory");
        return;
    }
    g_mutex_lock(&session_lock);
    GError *error = NULL;
    if (sw->serial == session_serial && !g_file_set_contents(sw->path, (const char *)out, (gssize)len, &error)) {
        g_message("zslice: the session did not save: %s", error->message);
        g_error_free(error);
    }
    g_mutex_unlock(&session_lock);
    zs_buffer_free(out, len);
}

static void session_write_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancel) {
    session_write(data);
}

/* wait: write the file before the return (the close and quit). */
static void session_save(GtkWindow *w, gboolean wait) {
    if (!model || !w) return;
    gint64 t0 = g_get_monotonic_time();
    GtkWidget *view = zg_window_view3d(w);
    float cam[8];
    gboolean has_cam = view && zg_view3d_get_camera(view, cam);
    int width = 0, height = 0;
    gtk_window_get_default_size(w, &width, &height);
    /* The ids of the plates in the store of the refinements: letters,
     * digits, '-' and ','. */
    char *refine = zg_model_refine_ids(model);
    char *text = g_strdup_printf("{\"width\":%d,\"height\":%d,\"maximized\":%s,\"refine\":\"%s\"}", width, height,
                                 gtk_window_is_maximized(w) ? "true" : "false", refine);
    g_free(refine);
    zs_session_snapshot *snap = zg_model_session_snapshot(model, has_cam ? cam : NULL, text);
    g_free(text);
    if (!snap) return;
    SessionWrite *sw = g_new0(SessionWrite, 1);
    sw->snap = snap;
    sw->path = session_path();
    g_mutex_lock(&session_lock);
    sw->serial = ++session_serial;
    g_mutex_unlock(&session_lock);
    if (g_getenv("ZSLICE_BENCH")) g_message("bench: the session copy, %.0f ms", (g_get_monotonic_time() - t0) / 1000.0);
    if (wait) {
        session_write(sw);
        session_write_free(sw);
        return;
    }
    GTask *task = g_task_new(NULL, NULL, NULL, NULL);
    g_task_set_task_data(task, sw, session_write_free);
    g_task_run_in_thread(task, session_write_thread);
    g_object_unref(task);
}

static guint session_timer;
/* The time of the last input to the window (g_get_monotonic_time). */
static gint64 last_input;

/* The copy of the save holds the UI thread for a few ms: it waits for a
 * pause of 2 s in the input and in the moves of the view, so no drag or
 * orbit has a late frame for it. */
static gboolean on_session_timer(gpointer data) {
    GtkWidget *view = zg_window_view3d(GTK_WINDOW(data));
    if (g_get_monotonic_time() - last_input < 2 * G_USEC_PER_SEC || (view && zg_view3d_moving(view))) return G_SOURCE_CONTINUE;
    session_timer = 0;
    session_save(GTK_WINDOW(data), FALSE);
    return G_SOURCE_REMOVE;
}

static gboolean on_any_input(GtkEventControllerLegacy *c, GdkEvent *e, gpointer data) {
    last_input = g_get_monotonic_time();
    return FALSE;
}

/* After each slice: a save 1.5 s later (one save for many slices). */
static void on_core_event_session(ZgModel *m, int event, double progress, int status, gpointer data) {
    if (event != ZS_EVENT_SLICED) return;
    if (session_timer) g_source_remove(session_timer);
    session_timer = g_timeout_add(1500, on_session_timer, data);
    /* Again each 1.5 s, until a pause. */
}

/* A change of the list of plates (a plate added or gone): the same save,
 * also with no slice after it (an empty plate). */
static void on_plates_session(ZgModel *m, gpointer data) {
    if (session_timer) g_source_remove(session_timer);
    session_timer = g_timeout_add(1500, on_session_timer, data);
}

static gboolean on_close_session(GtkWindow *w, gpointer data) {
    if (session_timer) {
        g_source_remove(session_timer);
        session_timer = 0;
    }
    session_save(w, TRUE);
    return FALSE;
}

static gboolean session_restore(GtkWindow *w) {
    char *path = session_path();
    gchar *data = NULL;
    gsize len = 0;
    gboolean ok = g_file_get_contents(path, &data, &len, NULL);
    g_free(path);
    if (!ok) return FALSE;
    float cam[8];
    gboolean has_cam = FALSE;
    char *text = NULL;
    GError *error = NULL;
    ok = zg_model_session_open(model, data, len, cam, &has_cam, &text, &error);
    g_free(data);
    if (!ok) {
        g_message("zslice: the session did not open: %s", error->message);
        g_error_free(error);
        return FALSE;
    }
    if (has_cam && zg_window_view3d(w)) zg_view3d_set_camera(zg_window_view3d(w), cam);
    if (text) {
        int width = 0, height = 0;
        const char *pw = strstr(text, "\"width\":");
        const char *ph = strstr(text, "\"height\":");
        if (pw) width = atoi(pw + 8);
        if (ph) height = atoi(ph + 9);
        if (width > 200 && height > 200) gtk_window_set_default_size(w, width, height);
        if (strstr(text, "\"maximized\":true")) gtk_window_maximize(w);
        const char *pr = strstr(text, "\"refine\":\"");
        if (pr) {
            pr += 10;
            const char *end = strchr(pr, '"');
            char *ids = g_strndup(pr, end ? (gsize)(end - pr) : strlen(pr));
            zg_model_set_refine_ids(model, ids);
            g_free(ids);
        }
        g_free(text);
    }
    return TRUE;
}

static void session_hook(GtkWindow *w) {
    static gboolean hooked;
    if (hooked) return;
    hooked = TRUE;
    g_signal_connect(model, "core-event", G_CALLBACK(on_core_event_session), w);
    g_signal_connect(model, "plates-changed", G_CALLBACK(on_plates_session), w);
    g_signal_connect(w, "close-request", G_CALLBACK(on_close_session), NULL);
    GtkEventController *input = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(input, GTK_PHASE_CAPTURE);
    g_signal_connect(input, "event", G_CALLBACK(on_any_input), NULL);
    gtk_widget_add_controller(GTK_WIDGET(w), input);
}

/* The start of the window: the session of the last run (once, before the
 * first frame), and the hooks that save it. */
static GtkWindow *start_window(GApplication *app) {
    GtkWindow *w = main_window(GTK_APPLICATION(app));
    static gboolean restored_once;
    if (!restored_once) {
        restored_once = TRUE;
        session_restore(w);
    }
    session_hook(w);
    return w;
}

static void on_activate(GApplication *app, gpointer data) {
    if (g_getenv("ZSLICE_BENCH")) g_message("bench: activate, %.0f ms after the start", (g_get_monotonic_time() - zg_start_us) / 1000.0);
    GtkWindow *w = start_window(app);
    if (g_getenv("ZSLICE_BENCH")) g_message("bench: the window built, %.0f ms after the start", (g_get_monotonic_time() - zg_start_us) / 1000.0);
    gtk_window_present(w);
    /* The first start (no printer set up): the printer picker. */
    static gboolean once;
    if (!once) zg_printer_picker_startup(w, model);
    once = TRUE;
}

/* Files and links from outside the app: the command line, the file
 * manager, a zslice:// link, or a second start (GtkApplication hands its
 * files to this one). The session comes back first. The files go on a
 * new plate if the plate has parts. A link asks first (ui/open-link). */
static void on_open(GApplication *app, GFile **files, int n, const char *hint, gpointer data) {
    GtkWindow *w = start_window(app);
    gtk_window_present(w);
    GPtrArray *models = g_ptr_array_new();
    for (int i = 0; i < n; i++) {
        if (g_file_has_uri_scheme(files[i], "zslice")) {
            char *uri = g_file_get_uri(files[i]);
            zg_open_link(w, uri);
            g_free(uri);
        } else {
            g_ptr_array_add(models, files[i]);
        }
    }
    if (models->len) zg_window_open_external(w, (GFile **)models->pdata, (int)models->len);
    g_ptr_array_free(models, TRUE);
}

static void on_shutdown(GApplication *app, gpointer data) {
    zg_open_link_cancel();
    GtkWindow *w = gtk_application_get_active_window(GTK_APPLICATION(app));
    if (w) session_save(w, TRUE);
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

/* ---- the stall log ----
 *
 * For tests of the frame rate: ZSLICE_STALLS=<ms> logs each gap of the UI
 * thread over <ms> ms. A timer of high priority sets a tick every 2 ms. A
 * second thread looks at the tick each ms. When the UI thread is late, it
 * sends SIGPROF to the UI thread every 10 ms, and the signal handler keeps
 * the stack. ZSLICE_STALLS_ALL=1 also gets the stacks of all other threads
 * once in each gap. At the end of the gap, the thread logs the gap and the
 * stacks as module+offset (for addr2line). */

#define STALL_FRAMES 48
#define STALL_SAMPLES 48

static pthread_t stall_ui;
static _Atomic gint64 stall_tick;
static gint64 stall_limit_us;
static void *stall_stack[STALL_SAMPLES][STALL_FRAMES];
static int stall_depth[STALL_SAMPLES];
static int stall_tid[STALL_SAMPLES];
static atomic_int stall_done[STALL_SAMPLES];
static atomic_int stall_taken;

static void on_stall_signal(int sig) {
    int i = atomic_fetch_add(&stall_taken, 1);
    if (i >= STALL_SAMPLES) return;
    stall_tid[i] = (int)gettid();
    stall_depth[i] = backtrace(stall_stack[i], STALL_FRAMES);
    atomic_store(&stall_done[i], 1);
}

static gboolean on_stall_tick(gpointer data) {
    atomic_store(&stall_tick, g_get_monotonic_time());
    return G_SOURCE_CONTINUE;
}

static void stall_print(gint64 gap) {
    int n = MIN(atomic_load(&stall_taken), STALL_SAMPLES);
    GString *s = g_string_new(NULL);
    g_string_append_printf(s, "stall: %.1f ms\n", gap / 1000.0);
    int ui = (int)getpid();
    for (int i = 0; i < n; i++) {
        if (!atomic_load(&stall_done[i])) continue;
        if (stall_tid[i] == ui) g_string_append_printf(s, "  sample %d:", i);
        else g_string_append_printf(s, "  thread %d:", stall_tid[i]);
        for (int k = 2; k < stall_depth[i]; k++) {
            Dl_info info;
            if (dladdr(stall_stack[i][k], &info) && info.dli_fname) {
                const char *base = strrchr(info.dli_fname, '/');
                g_string_append_printf(s, " %s+0x%lx", base ? base + 1 : info.dli_fname,
                                       (unsigned long)((char *)stall_stack[i][k] - (char *)info.dli_fbase - 1));
            } else {
                g_string_append_printf(s, " %p", stall_stack[i][k]);
            }
        }
        g_string_append_c(s, '\n');
    }
    fputs(s->str, stderr);
    g_string_free(s, TRUE);
}

static gpointer stall_watch(gpointer data) {
    gint64 next_sample;
    gboolean in_stall = FALSE;
    gint64 start = 0;
    for (;;) {
        g_usleep(1000);
        gint64 tick = atomic_load(&stall_tick);
        gint64 now = g_get_monotonic_time();
        if (in_stall && tick >= start) {
            stall_print(tick - start);
            in_stall = FALSE;
            continue;
        }
        if (in_stall || now - tick < stall_limit_us) continue;
        in_stall = TRUE;
        start = tick;
        for (int i = 0; i < STALL_SAMPLES; i++) atomic_store(&stall_done[i], 0);
        atomic_store(&stall_taken, 0);
        next_sample = now;
        if (g_getenv("ZSLICE_STALLS_ALL")) {
            GDir *d = g_dir_open("/proc/self/task", 0, NULL);
            const char *name;
            int self = (int)gettid(), ui = (int)getpid();
            while (d && (name = g_dir_read_name(d))) {
                int tid = atoi(name);
                if (tid != self && tid != ui) syscall(SYS_tgkill, ui, tid, SIGPROF);
            }
            if (d) g_dir_close(d);
        }
        while (atomic_load(&stall_tick) == tick) {
            now = g_get_monotonic_time();
            if (now >= next_sample) {
                pthread_kill(stall_ui, SIGPROF);
                next_sample = now + 10000;
            }
            g_usleep(500);
        }
    }
    return NULL;
}

static void stall_start(void) {
    const char *env = g_getenv("ZSLICE_STALLS");
    if (!env) return;
    stall_limit_us = (gint64)(atof(env) * 1000);
    if (stall_limit_us <= 0) stall_limit_us = 20000;
    stall_ui = pthread_self();
    /* backtrace loads libgcc on the first call: do it here, and not in the
     * signal handler. */
    void *warm[4];
    backtrace(warm, 4);
    struct sigaction sa = {0};
    sa.sa_handler = on_stall_signal;
    sa.sa_flags = SA_RESTART;
    sigaction(SIGPROF, &sa, NULL);
    atomic_store(&stall_tick, g_get_monotonic_time());
    g_timeout_add_full(G_PRIORITY_HIGH, 2, on_stall_tick, NULL, NULL);
    g_thread_unref(g_thread_new("zslice-stalls", stall_watch, NULL));
}

int main(int argc, char **argv) {
    heartbeat = g_get_monotonic_time();
    zg_start_us = heartbeat;
    g_timeout_add(250, on_heartbeat, NULL);
#ifdef PR_SET_PTRACER
    /* With Yama ptrace protection, a child cannot read its parent: let the
     * watchdog's eu-stack read the stacks of the app. */
    prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
#endif
    g_thread_unref(g_thread_new("zslice-watchdog", watchdog, NULL));
    stall_start();
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
