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
#include "preferences.h"
#include "../net/printer-link.h"
#include "../prefs/printers.h"
#include "preview.h"
#include "settings-panel.h"

typedef struct {
    ZgModel *model;
    GtkWindow *window;
    GtkWidget *title;
    /* The island warning in the status bar, and the island it shows next. */
    GtkWidget *islands;
    size_t island_next;
    GtkWidget *export_button;
    GtkWidget *preview;
    GtkWidget *status;
    GtkWidget *progress;
    char *last_error;
    /* The text of the last result, shown dim while a new slice runs, so
     * the status bar does not change its size. */
    char *last_stats;
    /* Export was pressed while a slice ran: export when it is done. */
    gboolean export_pending;
    /* The printers: the current printer, the send button, and the state
     * of the printer in the status bar. */
    GtkWidget *printer_dd;
    GtkStringList *printer_names;
    gboolean filling_printers;
    GtkWidget *send_button;
    GtkWidget *send_menu;
    GtkWidget *printer_state;
    guint poll;
    GCancellable *poll_cancel;
    GCancellable *send_cancel;
    gboolean send_print;
    gboolean send_pending;
} Window;

static void send_now(Window *w);

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

/* ---- islands ---- */

/* The island warning: shapes that start in the air (see islands.zig). */
static void show_islands(Window *w, int state) {
    zs_app *core = zg_model_core(w->model);
    size_t n = state == ZS_STATE_DONE ? zs_app_island_count(core) : 0;
    gtk_widget_set_visible(w->islands, n > 0);
    if (n == 0) {
        w->island_next = 0;
        return;
    }
    if (w->island_next >= n) w->island_next = 0;
    char *label = g_strdup_printf("\u26a0 %zu island%s", n, n == 1 ? "" : "s");
    gtk_button_set_label(GTK_BUTTON(w->islands), label);
    g_free(label);
    GString *tip = g_string_new("Shapes that start in the air: nothing is under them on the layer below, so they fall or make strings. Add support there (right-click a line), or check the model. Click to go to each one.\n");
    for (size_t i = 0; i < n && i < 8; i++) {
        size_t layer;
        double x, y, area;
        if (zs_app_island_get(core, i, &layer, &x, &y, &area) != ZS_OK) continue;
        g_string_append_printf(tip, "\nLayer %zu: %.1f mm\u00b2 at %.1f, %.1f mm", layer + 1, area, x, y);
    }
    if (n > 8) g_string_append_printf(tip, "\n... and %zu more", n - 8);
    gtk_widget_set_tooltip_text(w->islands, tip->str);
    g_string_free(tip, TRUE);
}

static void on_islands_clicked(GtkButton *b, gpointer data) {
    Window *w = data;
    zs_app *core = zg_model_core(w->model);
    size_t n = zs_app_island_count(core);
    if (n == 0) return;
    size_t layer;
    if (zs_app_island_get(core, w->island_next % n, &layer, NULL, NULL, NULL) != ZS_OK) return;
    zg_preview_show_layer(w->preview, layer);
    w->island_next = (w->island_next + 1) % n;
}

static void update(Window *w) {
    zs_app *core = zg_model_core(w->model);
    int state = zs_app_state(core);
    const char *name = zg_model_name(w->model);
    gtk_label_set_text(GTK_LABEL(w->title), name ? name : "zslice");
    /* While a new slice runs, the old result stays on the screen, so the
     * export button stays on too (an export waits for the new result). */
    gboolean have_result = state == ZS_STATE_DONE || (state == ZS_STATE_SLICING && w->last_stats);
    gtk_widget_set_sensitive(w->export_button, have_result);
    /* A thin bar that is always there: full when the slice is done. */
    if (state == ZS_STATE_DONE) gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(w->progress), 1);
    if (state == ZS_STATE_EMPTY || state == ZS_STATE_FAILED) gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(w->progress), 0);
    if (state == ZS_STATE_SLICING) gtk_widget_add_css_class(w->status, "zg-stale");
    else gtk_widget_remove_css_class(w->status, "zg-stale");

    char text[256];
    switch (state) {
    case ZS_STATE_EMPTY:
        g_clear_pointer(&w->last_stats, g_free);
        g_snprintf(text, sizeof text, "No model");
        break;
    case ZS_STATE_READY:
        g_snprintf(text, sizeof text, "Ready");
        break;
    case ZS_STATE_SLICING:
        g_snprintf(text, sizeof text, "%s", w->last_stats ? w->last_stats : "Slicing");
        break;
    case ZS_STATE_DONE: {
        zs_stats st;
        zs_app_stats(core, &st);
        char t[32];
        format_time(t, sizeof t, st.print_time_s);
        double ms = zg_model_slice_ms(w->model);
        char took[48] = "";
        if (ms > 0) {
            if (ms < 1000) g_snprintf(took, sizeof took, "   sliced in %.0f ms", ms);
            else g_snprintf(took, sizeof took, "   sliced in %.1f s", ms / 1000);
        }
        g_snprintf(text, sizeof text, "%u layers   %.2f m filament (%.1f g)   about %s%s",
                   st.layer_count, st.filament_mm / 1000.0, st.filament_g, t, took);
        g_free(w->last_stats);
        w->last_stats = g_strdup(text);
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
    show_islands(w, state);
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
    if (w->send_pending && zs_app_state(zg_model_core(model)) != ZS_STATE_SLICING) {
        w->send_pending = FALSE;
        if (zs_app_state(zg_model_core(model)) == ZS_STATE_DONE) send_now(w);
    }
    if (w->export_pending && zs_app_state(zg_model_core(model)) != ZS_STATE_SLICING) {
        w->export_pending = FALSE;
        if (zs_app_state(zg_model_core(model)) == ZS_STATE_DONE) zg_window_export_dialog(w->window);
    }
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
        /* A new part on the plate (the first one loads the plate). */
        if (!zg_model_add(w->model, job->name, contents, len, &error)) {
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
    GListModel *files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(source), res, NULL);
    if (files) {
        for (guint i = 0; i < g_list_model_get_n_items(files); i++) {
            GFile *file = g_list_model_get_item(files, i);
            zg_window_open_file(window, file);
            g_object_unref(file);
        }
        g_object_unref(files);
    }
    g_object_unref(window);
}

void zg_window_open_dialog(GtkWindow *window) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Add models to the plate");
    GtkFileFilter *stl = gtk_file_filter_new();
    gtk_file_filter_set_name(stl, "Models (STL, 3MF)");
    gtk_file_filter_add_suffix(stl, "stl");
    gtk_file_filter_add_suffix(stl, "3mf");
    gtk_file_filter_add_mime_type(stl, "model/stl");
    gtk_file_filter_add_mime_type(stl, "model/3mf");
    GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
    g_list_store_append(filters, stl);
    gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    gtk_file_dialog_open_multiple(dialog, window, NULL, on_open_chosen, g_object_ref(window));
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
    int state = zs_app_state(zg_model_core(w->model));
    if (state == ZS_STATE_SLICING) {
        w->export_pending = TRUE;
        return;
    }
    if (state != ZS_STATE_DONE) return;
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

/* ---- save the plate ---- */

static void on_plate_saved(GObject *source, GAsyncResult *res, gpointer data) {
    GtkWindow *window = data;
    GError *error = NULL;
    if (!g_file_replace_contents_finish(G_FILE(source), res, NULL, &error)) {
        show_error(get(window), "The 3MF file was not saved", error->message);
        g_error_free(error);
    }
    g_object_unref(window);
}

static void on_save_plate_chosen(GObject *source, GAsyncResult *res, gpointer data) {
    GtkWindow *window = data;
    Window *w = get(window);
    GFile *file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), res, NULL);
    const uint8_t *bytes = NULL;
    size_t len = 0;
    if (file) {
        int st = zs_app_write_3mf(zg_model_core(w->model), &bytes, &len);
        if (st == ZS_OK) {
            GBytes *copy = g_bytes_new(bytes, len);
            g_file_replace_contents_bytes_async(file, copy, NULL, FALSE, G_FILE_CREATE_REPLACE_DESTINATION,
                                                NULL, on_plate_saved, g_object_ref(window));
            g_bytes_unref(copy);
        } else {
            show_error(w, "The 3MF file was not saved", zs_status_string(st));
        }
        g_object_unref(file);
    }
    g_object_unref(window);
}

/* Saves the parts, their places, and the changes for the parts (not the
 * global settings) in a 3MF file. */
void zg_window_save_plate_dialog(GtkWindow *window) {
    Window *w = get(window);
    if (zs_app_part_count(zg_model_core(w->model)) == 0) return;
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Save the plate as 3MF (parts and their changes)");
    const char *name = zg_model_name(w->model);
    char *base = g_strdup(name && *name ? name : "plate");
    char *dot = strrchr(base, '.');
    if (dot) *dot = 0;
    char *initial = g_strconcat(base, ".3mf", NULL);
    gtk_file_dialog_set_initial_name(dialog, initial);
    gtk_file_dialog_save(dialog, window, NULL, on_save_plate_chosen, g_object_ref(window));
    g_free(initial);
    g_free(base);
    g_object_unref(dialog);
}

static void on_save_plate_action(GSimpleAction *a, GVariant *v, gpointer data) {
    zg_window_save_plate_dialog(GTK_WINDOW(data));
}

/* ---- send to the printer ---- */

static void update_printer_ui(Window *w);

static void on_send_progress(double fraction, gpointer data) {
    Window *w = data;
    char *text = g_strdup_printf("Sending to %s: %.0f %%", zg_printers_current()->name, fraction * 100);
    gtk_label_set_text(GTK_LABEL(w->printer_state), text);
    g_free(text);
}

static void on_send_done(gboolean ok, const char *message, gpointer data) {
    Window *w = data;
    g_clear_object(&w->send_cancel);
    gtk_widget_set_sensitive(w->send_button, TRUE);
    if (ok) {
        char *text = g_strdup_printf(w->send_print ? "Sent to %s; it prints." : "Sent to %s.", zg_printers_current()->name);
        gtk_label_set_text(GTK_LABEL(w->printer_state), text);
        g_free(text);
    } else {
        gtk_label_set_text(GTK_LABEL(w->printer_state), "");
        show_error(w, "The G-code was not sent", message ? message : "");
    }
}

static void send_now(Window *w) {
    ZgPrinter *pr = zg_printers_current();
    const uint8_t *gcode = NULL;
    size_t len = 0;
    if (zs_app_gcode(zg_model_core(w->model), &gcode, &len) != ZS_OK) return;
    const char *name = zg_model_name(w->model);
    char *base = g_strdup(name ? name : "part.stl");
    char *dot = strrchr(base, '.');
    if (dot) *dot = 0;
    char *file = g_strconcat(base, ".gcode", NULL);
    GBytes *bytes = g_bytes_new(gcode, len);
    w->send_cancel = g_cancellable_new();
    gtk_widget_set_sensitive(w->send_button, FALSE);
    char *text = g_strdup_printf("Sending to %s…", pr->name);
    gtk_label_set_text(GTK_LABEL(w->printer_state), text);
    g_free(text);
    zg_link_send(pr, file, bytes, w->send_print, w->send_cancel, on_send_progress, on_send_done, w);
    g_bytes_unref(bytes);
    g_free(file);
    g_free(base);
}

static void send(Window *w, gboolean print) {
    w->send_print = print;
    int state = zs_app_state(zg_model_core(w->model));
    if (state == ZS_STATE_SLICING) {
        w->send_pending = TRUE;
        return;
    }
    if (state == ZS_STATE_DONE) send_now(w);
}

static void on_send_clicked(GtkButton *b, gpointer data) {
    Window *w = get(data);
    /* USB prints as it sends; the network kinds only upload here. */
    send(w, zg_printers_current()->kind == ZG_LINK_USB);
}

static void on_send_print(GSimpleAction *a, GVariant *v, gpointer data) {
    send(get(data), TRUE);
}

static void on_send_only(GSimpleAction *a, GVariant *v, gpointer data) {
    send(get(data), FALSE);
}

static void on_export_action(GSimpleAction *a, GVariant *v, gpointer data) {
    zg_window_export_dialog(data);
}

/* The state of the current printer, each 5 s, in the status bar. */
static void on_poll_info(ZgPrinterInfo *info, const char *error, gpointer data) {
    Window *w = data;
    if (!w->printer_state) {
        zg_printer_info_free(info);
        return;
    }
    if (w->send_cancel) {
        zg_printer_info_free(info);
        return;
    }
    ZgPrinter *pr = zg_printers_current();
    char *text;
    if (!info) {
        text = g_strdup_printf("%s: no connection", pr->name);
    } else if (info->job && info->progress > 0) {
        if (info->time_left > 0) {
            text = g_strdup_printf("%s: %s %.0f %%, %d:%02d left", pr->name, info->state ? info->state : "Printing",
                                   info->progress * 100, (int)info->time_left / 3600, (int)info->time_left / 60 % 60);
        } else {
            text = g_strdup_printf("%s: %s %.0f %%", pr->name, info->state ? info->state : "Printing", info->progress * 100);
        }
    } else {
        text = g_strdup_printf("%s: %s", pr->name, info->state ? info->state : "connected");
    }
    gtk_label_set_text(GTK_LABEL(w->printer_state), text);
    gtk_widget_set_tooltip_text(w->printer_state, error);
    g_free(text);
    zg_printer_info_free(info);
}

static gboolean on_poll(gpointer data) {
    Window *w = data;
    ZgPrinter *pr = zg_printers_current();
    if (pr->kind == ZG_LINK_NONE || pr->kind == ZG_LINK_USB || w->send_cancel) return G_SOURCE_CONTINUE;
    if (w->poll_cancel) g_cancellable_cancel(w->poll_cancel);
    g_clear_object(&w->poll_cancel);
    w->poll_cancel = g_cancellable_new();
    zg_link_query(pr, w->poll_cancel, on_poll_info, w);
    return G_SOURCE_CONTINUE;
}

static void update_printer_ui(Window *w) {
    ZgPrinter *pr = zg_printers_current();
    w->filling_printers = TRUE;
    guint n = g_list_model_get_n_items(G_LIST_MODEL(w->printer_names));
    const char **names = g_new0(const char *, zg_printers_count() + 1);
    guint selected = 0;
    for (guint i = 0; i < zg_printers_count(); i++) {
        names[i] = zg_printers_get(i)->name;
        if (zg_printers_get(i) == pr) selected = i;
    }
    gtk_string_list_splice(w->printer_names, 0, n, names);
    g_free(names);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(w->printer_dd), selected);
    w->filling_printers = FALSE;
    gboolean linked = pr->kind != ZG_LINK_NONE;
    gtk_widget_set_visible(w->send_button, linked);
    gtk_widget_set_visible(w->send_menu, linked);
    if (linked) {
        /* A short label, so the window can be narrow; the printer is in
         * the menu at the left, and in the tooltip. */
        gtk_button_set_label(GTK_BUTTON(w->send_button), pr->kind == ZG_LINK_USB ? "Print" : "Send");
        char *tip = g_strdup_printf(pr->kind == ZG_LINK_USB ? "Print on %s over USB" : "Send the G-code to %s", pr->name);
        gtk_widget_set_tooltip_text(w->send_button, tip);
        g_free(tip);
    }
    /* The main button: send if the printer has a connection, else export. */
    if (linked) gtk_widget_remove_css_class(w->export_button, "suggested-action");
    else gtk_widget_add_css_class(w->export_button, "suggested-action");
    gtk_label_set_text(GTK_LABEL(w->printer_state), "");
    on_poll(w);
}

static void on_printer_dd(GObject *dd, GParamSpec *pspec, gpointer data) {
    Window *w = data;
    if (w->filling_printers) return;
    ZgPrinter *pr = zg_printers_get(gtk_drop_down_get_selected(GTK_DROP_DOWN(dd)));
    if (pr) zg_model_use_printer(w->model, pr->id);
}

static void on_printers_changed(ZgModel *model, gpointer data) {
    update_printer_ui(data);
}

static void on_prefs_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    zg_preferences_show(w->window, w->model);
}

/* ---- drop ---- */

static gboolean on_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    if (G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        for (GSList *l = gdk_file_list_get_files(g_value_get_boxed(value)); l; l = l->next) {
            zg_window_open_file(GTK_WINDOW(data), l->data);
        }
        return TRUE;
    }
    if (!G_VALUE_HOLDS(value, G_TYPE_FILE)) return FALSE;
    zg_window_open_file(GTK_WINDOW(data), g_value_get_object(value));
    return TRUE;
}

static void on_arrange_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    if (!zg_model_plate_arrange(w->model)) {
        show_error(w, "The parts do not all fit on the bed", "Some parts are past the edge of the bed. Remove a part, or use a printer with a larger bed.");
    }
}

static void on_smart_place_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    if (!zg_model_plate_smart_place(w->model)) {
        show_error(w, "The parts do not all fit on the bed", "Some parts are past the edge of the bed. Remove a part, or use a printer with a larger bed.");
    }
}

static void on_clear_action(GSimpleAction *a, GVariant *v, gpointer data) {
    zg_model_plate_clear(get(data)->model);
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
    if (w->poll) g_source_remove(w->poll);
    if (w->poll_cancel) g_cancellable_cancel(w->poll_cancel);
    if (w->send_cancel) g_cancellable_cancel(w->send_cancel);
    g_clear_object(&w->poll_cancel);
    w->printer_state = NULL;
    g_object_unref(w->model);
    g_free(w->last_error);
    g_free(w->last_stats);
    g_free(w);
}

/* The start width of the settings panel, after the window has its size. */
static gboolean place_paned(gpointer data) {
    GtkWidget *paned = data;
    /* The position is the width of the start child (the preview). */
    int width = gtk_widget_get_width(paned);
    if (width > 800) gtk_paned_set_position(GTK_PANED(paned), width - 560);
    g_object_unref(paned);
    return G_SOURCE_REMOVE;
}

static void on_paned_map(GtkWidget *paned, gpointer data) {
    if (g_object_get_data(G_OBJECT(paned), "zg-placed")) return;
    g_object_set_data(G_OBJECT(paned), "zg-placed", GINT_TO_POINTER(1));
    g_timeout_add(30, place_paned, g_object_ref(paned));
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
    gtk_widget_set_tooltip_text(open, "Add models to the plate (Ctrl+O). Shift+click a part to select it; Shift+drag moves it, and Shift+wheel turns it.");
    g_signal_connect(open, "clicked", G_CALLBACK(on_open_clicked), w->window);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), open);

    w->export_button = gtk_button_new_with_label("Export");
    gtk_widget_add_css_class(w->export_button, "suggested-action");
    gtk_widget_set_tooltip_text(w->export_button, "Save the G-code (Ctrl+E)");
    g_signal_connect(w->export_button, "clicked", G_CALLBACK(on_export_clicked), w->window);

    /* The printer, and the send button with its menu. */
    w->printer_names = gtk_string_list_new(NULL);
    w->printer_dd = gtk_drop_down_new(G_LIST_MODEL(w->printer_names), NULL);
    gtk_widget_set_tooltip_text(w->printer_dd, "The printer: its machine settings, and where Send goes. Edit the printers in Preferences.");
    g_signal_connect(w->printer_dd, "notify::selected", G_CALLBACK(on_printer_dd), w);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), w->printer_dd);
    w->send_button = gtk_button_new_with_label("Send");
    gtk_widget_add_css_class(w->send_button, "suggested-action");
    g_signal_connect(w->send_button, "clicked", G_CALLBACK(on_send_clicked), w->window);
    GMenu *send_menu = g_menu_new();
    g_menu_append(send_menu, "Send and print", "win.send-print");
    g_menu_append(send_menu, "Send only", "win.send-only");
    g_menu_append(send_menu, "Export a G-code file…", "win.export");
    w->send_menu = gtk_menu_button_new();
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(w->send_menu), G_MENU_MODEL(send_menu));
    gtk_widget_add_css_class(w->send_menu, "suggested-action");
    g_object_unref(send_menu);
    GtkWidget *send_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(send_box, "linked");
    gtk_box_append(GTK_BOX(send_box), w->send_button);
    gtk_box_append(GTK_BOX(send_box), w->send_menu);
    const GActionEntry win_actions[] = {
        {.name = "send-print", .activate = on_send_print},
        {.name = "send-only", .activate = on_send_only},
        {.name = "export", .activate = on_export_action},
        {.name = "preferences", .activate = on_prefs_action},
        {.name = "arrange", .activate = on_arrange_action},
        {.name = "smart-place", .activate = on_smart_place_action},
        {.name = "save-plate", .activate = on_save_plate_action},
        {.name = "clear-plate", .activate = on_clear_action},
    };
    g_action_map_add_action_entries(G_ACTION_MAP(w->window), win_actions, G_N_ELEMENTS(win_actions), w->window);

    GMenu *menu = g_menu_new();
    g_menu_append(menu, "Save the plate as 3MF…", "win.save-plate");
    g_menu_append(menu, "Smart placement", "win.smart-place");
    g_menu_append(menu, "Arrange the plate", "win.arrange");
    g_menu_append(menu, "Clear the plate", "win.clear-plate");
    g_menu_append(menu, "Preferences", "win.preferences");
    g_menu_append(menu, "Licenses", "app.licenses");
    g_menu_append(menu, "About zslice", "app.about");
    GtkWidget *menu_button = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_button), "open-menu-symbolic");
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button), G_MENU_MODEL(menu));
    g_object_unref(menu);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), menu_button);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), send_box);
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
    /* The model on the left, the settings on the right, as in other
     * slicers. */
    gtk_paned_set_start_child(GTK_PANED(paned), w->preview);
    gtk_paned_set_end_child(GTK_PANED(paned), panel);
    gtk_paned_set_resize_end_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_shrink_end_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_wide_handle(GTK_PANED(paned), TRUE);
    /* The start width of the settings panel: the last two columns of the
     * settings browser. The user can drag it to 220. The position is from
     * the left, so it is set when the width of the window is known. */
    g_signal_connect(paned, "map", G_CALLBACK(on_paned_map), NULL);
    gtk_widget_set_vexpand(paned, TRUE);

    /* Status bar. */
    w->status = gtk_label_new("");
    gtk_widget_set_halign(w->status, GTK_ALIGN_START);
    gtk_widget_set_hexpand(w->status, TRUE);
    gtk_widget_add_css_class(w->status, "numeric");
    w->progress = gtk_progress_bar_new();
    gtk_widget_set_size_request(w->progress, 120, -1);
    gtk_widget_add_css_class(w->progress, "zg-thin");
    gtk_widget_set_tooltip_text(w->progress, "The progress of the slice.");
    gtk_widget_set_valign(w->progress, GTK_ALIGN_CENTER);
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(bar, "zg-status");
    gtk_widget_add_css_class(bar, "zg-panel");
    gtk_box_append(GTK_BOX(bar), w->status);
    /* Islands: a warning that goes to each island in turn. */
    w->islands = gtk_button_new();
    gtk_widget_add_css_class(w->islands, "flat");
    gtk_widget_add_css_class(w->islands, "zg-islands");
    gtk_widget_set_visible(w->islands, FALSE);
    g_signal_connect(w->islands, "clicked", G_CALLBACK(on_islands_clicked), w);
    gtk_box_append(GTK_BOX(bar), w->islands);
    w->printer_state = gtk_label_new("");
    gtk_widget_add_css_class(w->printer_state, "dim-label");
    gtk_label_set_ellipsize(GTK_LABEL(w->printer_state), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(bar), w->printer_state);
    gtk_box_append(GTK_BOX(bar), w->progress);

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(body), paned);
    gtk_box_append(GTK_BOX(body), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(body), bar);
    gtk_window_set_child(w->window, body);

    GtkDropTarget *drop = gtk_drop_target_new(G_TYPE_INVALID, GDK_ACTION_COPY);
    GType drop_types[] = {GDK_TYPE_FILE_LIST, G_TYPE_FILE};
    gtk_drop_target_set_gtypes(drop, drop_types, G_N_ELEMENTS(drop_types));
    g_signal_connect(drop, "drop", G_CALLBACK(on_drop), w->window);
    gtk_widget_add_controller(GTK_WIDGET(w->window), GTK_EVENT_CONTROLLER(drop));

    g_signal_connect(model, "core-event", G_CALLBACK(on_core_event), w);
    g_signal_connect_swapped(model, "plate-changed", G_CALLBACK(update), w);
    g_signal_connect(model, "printer-changed", G_CALLBACK(on_printers_changed), w);
    g_signal_connect(model, "printers-edited", G_CALLBACK(on_printers_changed), w);
    update_printer_ui(w);
    w->poll = g_timeout_add_seconds(5, on_poll, w);
    update(w);
    return w->window;
}
