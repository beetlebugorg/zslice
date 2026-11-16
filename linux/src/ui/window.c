/* window.c: see window.h.
 *
 * The window shows the state of the core. On each core event it reads the
 * state again (zs_app_state) and updates the title, the status bar, and the
 * preview. It does not depend on the event alone: an event from a slice
 * that a newer slice replaced can still arrive.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "window.h"

#include <string.h>

#include "licenses.h"
#include "preview.h"
#include "settings-panel.h"

typedef struct {
    ZgModel *model;
    GtkWindow *window;
    GtkWidget *title;
    GtkWidget *export_button;
    GtkWidget *preview;
    GtkWidget *status;
    GtkWidget *progress;
    char *last_error;
} Window;

static Window *get(GtkWindow *w) {
    return g_object_get_data(G_OBJECT(w), "zg-window");
}

static void format_time(char *buf, size_t cap, double seconds) {
    int minutes = (int)(seconds / 60 + 0.5);
    if (minutes < 60) {
        g_snprintf(buf, cap, "%d min", minutes);
    } else {
        g_snprintf(buf, cap, "%d h %d min", minutes / 60, minutes % 60);
    }
}

static void update(Window *w) {
    zs_app *core = zg_model_core(w->model);
    int state = zs_app_state(core);
    const char *name = zg_model_name(w->model);
    gtk_label_set_text(GTK_LABEL(w->title), name ? name : "zslice");
    gtk_widget_set_sensitive(w->export_button, state == ZS_STATE_DONE);
    gtk_widget_set_visible(w->progress, state == ZS_STATE_SLICING);

    char text[256];
    switch (state) {
    case ZS_STATE_EMPTY:
        g_snprintf(text, sizeof text, "No model");
        break;
    case ZS_STATE_READY:
        g_snprintf(text, sizeof text, "Ready");
        break;
    case ZS_STATE_SLICING:
        g_snprintf(text, sizeof text, "Slicing");
        break;
    case ZS_STATE_DONE: {
        zs_stats st;
        zs_app_stats(core, &st);
        char t[32];
        format_time(t, sizeof t, st.print_time_s);
        g_snprintf(text, sizeof text, "%u layers   %.2f m filament (%.1f g)   about %s",
                   st.layer_count, st.filament_mm / 1000.0, st.filament_g, t);
        break;
    }
    case ZS_STATE_FAILED:
        g_snprintf(text, sizeof text, "Slice failed: %s", w->last_error ? w->last_error : "");
        break;
    default:
        text[0] = 0;
    }
    gtk_label_set_text(GTK_LABEL(w->status), text);
    zg_preview_refresh(w->preview);
}

static void on_core_event(ZgModel *model, int event, double progress, int status, gpointer data) {
    Window *w = data;
    if (event == ZS_EVENT_PROGRESS) {
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(w->progress), progress);
        if (zs_app_state(zg_model_core(model)) == ZS_STATE_SLICING) return;
    }
    if (event == ZS_EVENT_FAILED) {
        g_free(w->last_error);
        w->last_error = g_strdup(zg_status_text(status));
    }
    update(w);
}

static void show_error(Window *w, const char *message, const char *detail) {
    GtkAlertDialog *alert = gtk_alert_dialog_new("%s", message);
    gtk_alert_dialog_set_detail(alert, detail);
    gtk_alert_dialog_show(alert, w->window);
    g_object_unref(alert);
}

/* ---- open ---- */

typedef struct {
    GtkWindow *window;
    char *name;
} LoadJob;

static void on_loaded(GObject *source, GAsyncResult *res, gpointer data) {
    LoadJob *job = data;
    Window *w = get(job->window);
    char *contents = NULL;
    gsize len = 0;
    GError *error = NULL;
    if (g_file_load_contents_finish(G_FILE(source), res, &contents, &len, NULL, &error)) {
        if (!zg_model_load(w->model, job->name, contents, len, &error)) {
            show_error(w, "The model did not open", error->message);
            g_error_free(error);
        }
        g_free(contents);
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(w->progress), 0);
        update(w);
    } else {
        show_error(w, "The file did not open", error->message);
        g_error_free(error);
    }
    g_object_unref(job->window);
    g_free(job->name);
    g_free(job);
}

void zg_window_open_file(GtkWindow *window, GFile *file) {
    LoadJob *job = g_new0(LoadJob, 1);
    job->window = g_object_ref(window);
    job->name = g_file_get_basename(file);
    g_file_load_contents_async(file, NULL, on_loaded, job);
}

static void on_open_chosen(GObject *source, GAsyncResult *res, gpointer data) {
    GtkWindow *window = data;
    GFile *file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), res, NULL);
    if (file) {
        zg_window_open_file(window, file);
        g_object_unref(file);
    }
    g_object_unref(window);
}

void zg_window_open_dialog(GtkWindow *window) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Open a model");
    GtkFileFilter *stl = gtk_file_filter_new();
    gtk_file_filter_set_name(stl, "STL files");
    gtk_file_filter_add_suffix(stl, "stl");
    gtk_file_filter_add_mime_type(stl, "model/stl");
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, stl);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_open(dialog, window, NULL, on_open_chosen, g_object_ref(window));
    g_object_unref(filters);
    g_object_unref(stl);
    g_object_unref(dialog);
}

/* ---- export ---- */

static void on_saved(GObject *source, GAsyncResult *res, gpointer data) {
    GtkWindow *window = data;
    GError *error = NULL;
    if (!g_file_replace_contents_finish(G_FILE(source), res, NULL, &error)) {
        show_error(get(window), "The G-code was not saved", error->message);
        g_error_free(error);
    }
    g_object_unref(window);
}

static void on_export_chosen(GObject *source, GAsyncResult *res, gpointer data) {
    GtkWindow *window = data;
    Window *w = get(window);
    GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), res, NULL);
    const uint8_t *gcode = NULL;
    size_t len = 0;
    if (file && zs_app_gcode(zg_model_core(w->model), &gcode, &len) == ZS_OK) {
        /* A copy: the core can replace its G-code while the write runs. */
        GBytes *bytes = g_bytes_new(gcode, len);
        g_file_replace_contents_bytes_async(file, bytes, NULL, FALSE, G_FILE_CREATE_REPLACE_DESTINATION,
                                            NULL, on_saved, g_object_ref(window));
        g_bytes_unref(bytes);
    }
    if (file) g_object_unref(file);
    g_object_unref(window);
}

void zg_window_export_dialog(GtkWindow *window) {
    Window *w = get(window);
    if (zs_app_state(zg_model_core(w->model)) != ZS_STATE_DONE) return;
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Export G-code");
    const char *name = zg_model_name(w->model);
    char *base = g_strdup(name ? name : "part.stl");
    char *dot = strrchr(base, '.');
    if (dot) *dot = 0;
    char *initial = g_strconcat(base, ".gcode", NULL);
    gtk_file_dialog_set_initial_name(dialog, initial);
    gtk_file_dialog_save(dialog, window, NULL, on_export_chosen, g_object_ref(window));
    g_free(initial);
    g_free(base);
    g_object_unref(dialog);
}

/* ---- drop ---- */

static gboolean on_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    if (!G_VALUE_HOLDS(value, G_TYPE_FILE)) return FALSE;
    zg_window_open_file(GTK_WINDOW(data), g_value_get_object(value));
    return TRUE;
}

/* ---- window ---- */

static void on_open_clicked(GtkButton *b, gpointer data) {
    zg_window_open_dialog(GTK_WINDOW(data));
}

static void on_export_clicked(GtkButton *b, gpointer data) {
    zg_window_export_dialog(GTK_WINDOW(data));
}

static void window_free(gpointer data) {
    Window *w = data;
    g_signal_handlers_disconnect_by_data(w->model, w);
    g_object_unref(w->model);
    g_free(w->last_error);
    g_free(w);
}

GtkWindow *zg_window_new(GtkApplication *app, ZgModel *model) {
    Window *w = g_new0(Window, 1);
    w->model = g_object_ref(model);
    w->window = GTK_WINDOW(gtk_application_window_new(app));
    g_object_set_data_full(G_OBJECT(w->window), "zg-window", w, window_free);
    gtk_window_set_default_size(w->window, 1280, 820);
    gtk_widget_add_css_class(GTK_WIDGET(w->window), "zg-main");
    gtk_window_set_title(w->window, "zslice");

    /* Header bar. */
    GtkWidget *header = gtk_header_bar_new();
    GtkWidget *open = gtk_button_new_from_icon_name("document-open-symbolic");
    gtk_widget_set_tooltip_text(open, "Open a model (Ctrl+O)");
    g_signal_connect(open, "clicked", G_CALLBACK(on_open_clicked), w->window);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), open);

    w->export_button = gtk_button_new_with_label("Export G-code");
    gtk_widget_add_css_class(w->export_button, "suggested-action");
    gtk_widget_set_tooltip_text(w->export_button, "Save the G-code (Ctrl+E)");
    g_signal_connect(w->export_button, "clicked", G_CALLBACK(on_export_clicked), w->window);

    GMenu *menu = g_menu_new();
    g_menu_append(menu, "Licenses", "app.licenses");
    g_menu_append(menu, "About zslice", "app.about");
    GtkWidget *menu_button = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_button), "open-menu-symbolic");
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button), G_MENU_MODEL(menu));
    g_object_unref(menu);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), menu_button);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), w->export_button);

    w->title = gtk_label_new("zslice");
    gtk_widget_add_css_class(w->title, "title");
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), w->title);
    gtk_window_set_titlebar(w->window, header);

    /* Body: settings | preview. */
    w->preview = zg_preview_new(model);
    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget *panel = zg_settings_panel_new(model);
    gtk_widget_add_css_class(panel, "zg-panel");
    gtk_paned_set_start_child(GTK_PANED(paned), panel);
    gtk_paned_set_end_child(GTK_PANED(paned), w->preview);
    gtk_paned_set_resize_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
    gtk_widget_set_vexpand(paned, TRUE);

    /* Status bar. */
    w->status = gtk_label_new("");
    gtk_widget_set_halign(w->status, GTK_ALIGN_START);
    gtk_widget_set_hexpand(w->status, TRUE);
    gtk_widget_add_css_class(w->status, "numeric");
    w->progress = gtk_progress_bar_new();
    gtk_widget_set_size_request(w->progress, 200, -1);
    gtk_widget_set_valign(w->progress, GTK_ALIGN_CENTER);
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(bar, "zg-status");
    gtk_widget_add_css_class(bar, "zg-panel");
    gtk_box_append(GTK_BOX(bar), w->status);
    gtk_box_append(GTK_BOX(bar), w->progress);

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(body), paned);
    gtk_box_append(GTK_BOX(body), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(body), bar);
    gtk_window_set_child(w->window, body);

    GtkDropTarget *drop = gtk_drop_target_new(G_TYPE_FILE, GDK_ACTION_COPY);
    g_signal_connect(drop, "drop", G_CALLBACK(on_drop), w->window);
    gtk_widget_add_controller(GTK_WIDGET(w->window), GTK_EVENT_CONTROLLER(drop));

    g_signal_connect(model, "core-event", G_CALLBACK(on_core_event), w);
    update(w);
    return w->window;
}
