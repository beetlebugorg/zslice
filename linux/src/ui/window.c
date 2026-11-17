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
#include "cura-compare.h"
#include "../net/printer-link.h"
#include "../prefs/printers.h"
#include "printer-picker.h"
#include "profile-menus.h"
#include "preview.h"
#include "history.h"
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
    GtkWidget *settings_panel;
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
    /* The summary at the bottom of the side panel: the time, the
     * filament and the cost, and a button to print (or export). */
    GtkWidget *sum_box, *sum_time, *sum_detail, *sum_deck;
    GtkWidget *send_menu;
    GtkWidget *send_box; /* the print button and its menu */
    GtkWidget *printer_state;
    guint poll;
    GCancellable *poll_cancel;
    GCancellable *send_cancel;
    /* The estimate of a printdeck printer for the last slice: its timer,
     * the request, and the result (deck_ok). */
    guint deck_timer;
    /* The roll in the printer, from the last poll (printdeck): its name,
     * the grams left (< 0: not known), and its price for each gram (0:
     * not known). */
    char *spool;
    char *spool_material; /* the material of the roll before, for a change */
    char *printer_roll;   /* the key of the roll in the printer at the last poll */
    double spool_left;
    double spool_price_g;
    GCancellable *deck_cancel;
    ZgEstimate deck;
    gboolean deck_ok;
    gboolean send_print;
    gboolean send_pending;
    /* "Send all plates" and "Export all plates": the plate now, the
     * count, the plate to go back to, and the folder of an export. */
    struct {
        gboolean on, send;
        size_t i, n, back, done;
        GFile *dir;
    } batch;
} Window;

static void send_now(Window *w);
static void send_checked(Window *w);

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

/* The summary card: the numbers of the last result, faded while a new
 * slice runs. */
static void update_summary(Window *w, int state) {
    if (!w->sum_box) return;
    zs_app *core = zg_model_core(w->model);
    if (state == ZS_STATE_SLICING) gtk_widget_add_css_class(w->sum_box, "zg-stale");
    else gtk_widget_remove_css_class(w->sum_box, "zg-stale");
    if (state == ZS_STATE_SLICING) return;
    if (state != ZS_STATE_DONE) {
        gtk_label_set_text(GTK_LABEL(w->sum_time), state == ZS_STATE_FAILED ? "Slice failed" : "—");
        gtk_label_set_text(GTK_LABEL(w->sum_detail), "");
        gtk_widget_set_visible(w->sum_deck, FALSE);
        return;
    }
    zs_stats st;
    zs_app_stats(core, &st);
    char t[32];
    format_time(t, sizeof t, w->deck_ok ? w->deck.total : st.print_time_s);
    gtk_label_set_text(GTK_LABEL(w->sum_time), t);
    double per_g = w->spool_price_g;
    if (per_g <= 0) {
        char *v = zg_model_get(w->model, "filament.price_per_kg");
        per_g = g_ascii_strtod(v, NULL) / 1000;
        g_free(v);
    }
    char cost[32] = "";
    if (per_g > 0) g_snprintf(cost, sizeof cost, " · %.2f", st.filament_g * per_g);
    char *detail = g_strdup_printf("%.1f g · %.2f m%s · %u layers", st.filament_g, st.filament_mm / 1000.0, cost, st.layer_count);
    gtk_label_set_text(GTK_LABEL(w->sum_detail), detail);
    g_free(detail);
    if (w->deck_ok) {
        char prep[32], slice[32];
        format_time(prep, sizeof prep, w->deck.prep);
        format_time(slice, sizeof slice, st.print_time_s);
        char *d = g_strdup_printf("%s: with %s of start and heat. The slice alone: %s.", zg_printers_current()->name, prep, slice);
        gtk_label_set_text(GTK_LABEL(w->sum_deck), d);
        g_free(d);
    }
    gtk_widget_set_visible(w->sum_deck, w->deck_ok);
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
    /* The progress bar shows only while a slice runs. */
    gtk_widget_set_visible(w->progress, state == ZS_STATE_SLICING);
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
        g_snprintf(text, sizeof text, "Slicing…");
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
        /* A printdeck printer: its time of the print, with the start
         * macro and the factor that it learned from its past prints. */
        char deck[96] = "";
        if (w->deck_ok) {
            char total[32], prep[32];
            format_time(total, sizeof total, w->deck.total);
            format_time(prep, sizeof prep, w->deck.prep);
            g_snprintf(deck, sizeof deck, "   %s: %s (%s start)", zg_printers_current()->name, total, prep);
        }
        /* The cost of the plastic: at the price of the roll in the
         * printer, else at the price of the filament profile. */
        char cost[48] = "";
        double per_g = w->spool_price_g > 0 ? w->spool_price_g : 0;
        if (per_g <= 0) {
            char *v = zg_model_get(w->model, "filament.price_per_kg");
            per_g = g_ascii_strtod(v, NULL) / 1000;
            g_free(v);
        }
        if (per_g > 0) g_snprintf(cost, sizeof cost, ", cost %.2f", st.filament_g * per_g);
        /* The card shows the numbers; the status line says how long the
         * slice took. The full text is the tooltip of the card. */
        g_snprintf(text, sizeof text, "%u layers   %.2f m filament (%.1f g%s)   about %s%s%s",
                   st.layer_count, st.filament_mm / 1000.0, st.filament_g, cost, t, deck, took);
        gtk_widget_set_tooltip_text(w->sum_box, text);
        g_free(w->last_stats);
        w->last_stats = g_strdup(text);
        if (ms > 0) {
            g_strstrip(took);
            took[0] = g_ascii_toupper(took[0]);
            g_snprintf(text, sizeof text, "%s", took);
        } else {
            text[0] = 0;
        }
        break;
    }
    case ZS_STATE_FAILED:
        g_snprintf(text, sizeof text, "Slice failed: %s", w->last_error ? w->last_error : "");
        break;
    default:
        text[0] = 0;
    }
    gtk_label_set_text(GTK_LABEL(w->status), text);
    update_summary(w, state);
    zg_preview_refresh(w->preview);
    show_islands(w, state);
}

static void batch_take(Window *w);

/* ---- the estimate of a printdeck printer ---- */

static void on_deck_estimate(const ZgEstimate *est, const char *error, gpointer data) {
    Window *w = data;
    if (!est) return; /* an older printdeck, or no connection: the status stays */
    w->deck = *est;
    w->deck_ok = TRUE;
    update(w);
}

/* Some time after the last slice (a slider makes many slices), sends the
 * G-code to the printer for its estimate. */
static gboolean deck_estimate_now(gpointer data) {
    Window *w = data;
    w->deck_timer = 0;
    ZgPrinter *pr = zg_printers_current();
    const uint8_t *gcode = NULL;
    size_t len = 0;
    if (!pr || pr->kind != ZG_LINK_PRINTDECK || zs_app_state(zg_model_core(w->model)) != ZS_STATE_DONE ||
        zs_app_gcode(zg_model_core(w->model), &gcode, &len) != ZS_OK)
        return G_SOURCE_REMOVE;
    GBytes *bytes = g_bytes_new(gcode, len);
    w->deck_cancel = g_cancellable_new();
    zg_link_estimate(pr, bytes, w->deck_cancel, on_deck_estimate, w);
    g_bytes_unref(bytes);
    return G_SOURCE_REMOVE;
}

/* A new slice or another printer: the old estimate goes, and a new one
 * comes later. */
static void deck_estimate_soon(Window *w) {
    w->deck_ok = FALSE;
    if (w->deck_cancel) g_cancellable_cancel(w->deck_cancel);
    g_clear_object(&w->deck_cancel);
    if (w->deck_timer) g_source_remove(w->deck_timer);
    w->deck_timer = g_timeout_add(800, deck_estimate_now, w);
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
        if (zs_app_state(zg_model_core(model)) == ZS_STATE_DONE) send_checked(w);
    }
    if (w->batch.on && event == ZS_EVENT_SLICED) batch_take(w);
    if (event == ZS_EVENT_SLICED) deck_estimate_soon(w);
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

static void on_low_answer(GObject *source, GAsyncResult *res, gpointer data) {
    Window *w = data;
    if (gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), res, NULL) == 1) send_now(w);
}

/* Before a send: the print needs more plastic than the roll in the
 * printer has left. */
static void send_checked(Window *w) {
    zs_stats st;
    if (w->spool && w->spool_left >= 0 && zs_app_stats(zg_model_core(w->model), &st) == ZS_OK && st.filament_g > w->spool_left) {
        char *msg = g_strdup_printf("This print needs %.0f g of filament. The roll in the printer (%s) has %.0f g left.",
                                    st.filament_g, w->spool, w->spool_left);
        GtkAlertDialog *d = gtk_alert_dialog_new("Not enough filament on the roll");
        gtk_alert_dialog_set_detail(d, msg);
        const char *buttons[] = {"Cancel", "Send anyway", NULL};
        gtk_alert_dialog_set_buttons(d, buttons);
        gtk_alert_dialog_set_cancel_button(d, 0);
        gtk_alert_dialog_choose(d, GTK_WINDOW(w->window), NULL, on_low_answer, w);
        g_object_unref(d);
        g_free(msg);
        return;
    }
    send_now(w);
}

static void send(Window *w, gboolean print) {
    w->send_print = print;
    int state = zs_app_state(zg_model_core(w->model));
    if (state == ZS_STATE_SLICING) {
        w->send_pending = TRUE;
        return;
    }
    if (state == ZS_STATE_DONE) send_checked(w);
}

/* ---- all plates ---- */

static void batch_next(Window *w);

static void batch_finish(Window *w, const char *error) {
    w->batch.on = FALSE;
    g_clear_object(&w->batch.dir);
    gtk_widget_set_sensitive(w->send_button, TRUE);
    zg_model_plate_select(w->model, w->batch.back);
    if (error) {
        gtk_label_set_text(GTK_LABEL(w->printer_state), "");
        show_error(w, w->batch.send ? "Not all plates were sent" : "Not all plates were exported", error);
        return;
    }
    char *text = g_strdup_printf(w->batch.send ? "%zu plates sent to %s." : "%zu plates exported.", w->batch.done, zg_printers_current()->name);
    gtk_label_set_text(GTK_LABEL(w->printer_state), text);
    g_free(text);
}

static void on_batch_sent(gboolean ok, const char *message, gpointer data) {
    Window *w = data;
    g_clear_object(&w->send_cancel);
    if (!ok) {
        batch_finish(w, message ? message : "The printer did not take the file.");
        return;
    }
    w->batch.done++;
    w->batch.i++;
    batch_next(w);
}

/* The file name of plate i: the name of the plate, and its number. */
static char *batch_file(Window *w) {
    const char *name = zg_model_name(w->model);
    char *base = g_strdup(name && *name ? name : "plate");
    char *dot = strrchr(base, '.');
    if (dot) *dot = 0;
    char *file = g_strdup_printf("%s-plate-%zu.gcode", base, w->batch.i + 1);
    g_free(base);
    return file;
}

/* The slice of plate i is done: send it, or write it. */
static void batch_take(Window *w) {
    if (!w->batch.on || zs_app_plate_active(zg_model_core(w->model)) != w->batch.i) return;
    const uint8_t *gcode = NULL;
    size_t len = 0;
    if (zs_app_gcode(zg_model_core(w->model), &gcode, &len) != ZS_OK) {
        batch_finish(w, "A plate did not slice.");
        return;
    }
    char *file = batch_file(w);
    GBytes *bytes = g_bytes_new(gcode, len);
    if (w->batch.send) {
        char *text = g_strdup_printf("Sending plate %zu of %zu to %s\u2026", w->batch.i + 1, w->batch.n, zg_printers_current()->name);
        gtk_label_set_text(GTK_LABEL(w->printer_state), text);
        g_free(text);
        w->send_cancel = g_cancellable_new();
        zg_link_send(zg_printers_current(), file, bytes, FALSE, w->send_cancel, on_send_progress, on_batch_sent, w);
    } else {
        GFile *out = g_file_get_child(w->batch.dir, file);
        GError *error = NULL;
        gboolean ok = g_file_replace_contents(out, (const char *)gcode, len, NULL, FALSE, G_FILE_CREATE_REPLACE_DESTINATION, NULL, NULL, &error);
        g_object_unref(out);
        if (!ok) {
            batch_finish(w, error->message);
            g_error_free(error);
        } else {
            w->batch.done++;
            w->batch.i++;
            batch_next(w);
        }
    }
    g_bytes_unref(bytes);
    g_free(file);
}

static gboolean batch_take_later(gpointer data) {
    batch_take(data);
    return G_SOURCE_REMOVE;
}

/* The next plate with parts: switch to it, and wait for its slice. */
static void batch_next(Window *w) {
    zs_app *core = zg_model_core(w->model);
    while (w->batch.i < w->batch.n && zs_app_plate_parts(core, w->batch.i) == 0) w->batch.i++;
    if (w->batch.i >= w->batch.n) {
        batch_finish(w, NULL);
        return;
    }
    if (zs_app_plate_active(core) != w->batch.i) {
        zg_model_plate_select(w->model, w->batch.i);
    } else if (zs_app_state(core) == ZS_STATE_DONE) {
        g_idle_add(batch_take_later, w);
    }
}

static void batch_start(Window *w, gboolean send, GFile *dir) {
    zs_app *core = zg_model_core(w->model);
    w->batch.on = TRUE;
    w->batch.send = send;
    w->batch.i = 0;
    w->batch.done = 0;
    w->batch.n = zs_app_plate_count(core);
    w->batch.back = zs_app_plate_active(core);
    w->batch.dir = dir ? g_object_ref(dir) : NULL;
    gtk_widget_set_sensitive(w->send_button, FALSE);
    batch_next(w);
}

static void on_send_all_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    if (!w->batch.on) batch_start(w, TRUE, NULL);
}

static void on_export_all_chosen(GObject *source, GAsyncResult *res, gpointer data) {
    GtkWindow *window = data;
    GFile *dir = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(source), res, NULL);
    if (dir) {
        Window *w = get(window);
        if (!w->batch.on) batch_start(w, FALSE, dir);
        g_object_unref(dir);
    }
    g_object_unref(window);
}

static void on_export_all_action(GSimpleAction *a, GVariant *v, gpointer data) {
    GtkWindow *window = GTK_WINDOW(data);
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Export all plates: choose a folder");
    gtk_file_dialog_select_folder(dialog, window, NULL, on_export_all_chosen, g_object_ref(window));
    g_object_unref(dialog);
}

static void on_send_clicked(GtkButton *b, gpointer data) {
    Window *w = get(data);
    /* The main button prints: it uploads and starts the print. "Upload
     * only" is in its menu. */
    send(w, TRUE);
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
    /* The filament settings follow the roll in the printer (the
     * preference follow_roll, on by default): a roll that zslice saw
     * before gets its own settings back, and a new roll the settings of
     * its material, name, diameter, and color. */
    char *follow = zg_pref_get("follow_roll", "1");
    if (info) zg_model_set_rolls(w->model, pr->id, info->rolls, info->n_rolls);
    /* Only a change of the roll in the printer: a roll that the user picks
     * in the Filament menu stays until the printer has another roll. */
    if (info && info->spool_id && info->spool_id[0] && strcmp(follow, "1") == 0) {
        GString *key = g_string_new(NULL);
        char *k = zg_model_roll_key(pr->id, info->spool_id);
        g_string_append(key, k);
        g_free(k);
        gboolean moved = g_strcmp0(w->printer_roll, key->str) != 0;
        g_free(w->printer_roll);
        w->printer_roll = g_strdup(key->str);
        if (moved && g_strcmp0(zg_model_roll(w->model), key->str) != 0) {
            /* The first roll after a start: the settings are the ones of
             * this roll already (the last session saved them). */
            gboolean first = zg_model_roll(w->model) == NULL;
            if (!zg_model_set_roll(w->model, key->str) && !first) {
                /* A new roll: the settings of the roll before stay (its
                 * tuning), with the name, the diameter, and the color of
                 * the new roll; another material starts from the built-in
                 * profile of that material. */
                gboolean same = info->material && w->spool_material && g_ascii_strcasecmp(info->material, w->spool_material) == 0;
                zg_model_filament_from_printer(w->model, same ? NULL : info->material, info->spool ? info->spool : info->material,
                                               info->diameter, info->spool_color);
            } else if (first) {
                /* Keep the settings, and save them for this roll. */
                zg_model_save_soon(w->model, ZS_GROUP_FILAMENT);
            }
            if (!first && info->spool) {
                char *note = g_strdup_printf("Filament settings for %s", info->spool);
                gtk_label_set_text(GTK_LABEL(w->status), note);
                g_free(note);
            }
        }
        g_string_free(key, TRUE);
    }
    g_free(follow);
    if (info && info->material) {
        g_free(w->spool_material);
        w->spool_material = g_strdup(info->material);
    }
    /* The roll in the printer, and the grams left on it. */
    g_free(w->spool);
    w->spool = info && info->spool ? g_strdup(info->spool) : NULL;
    w->spool_left = info && info->spool ? info->spool_left : -1;
    w->spool_price_g = info && info->spool_price > 0 && info->spool_full > 0 ? info->spool_price / info->spool_full : 0;
    /* The label is short (the status bar is full): the state and the
     * roll. The tooltip has all of it, with the printer name. */
    const char *state_only = strchr(text, ':') ? strchr(text, ':') + 2 : text;
    char *label = w->spool ? g_strdup_printf("%s · %s, %.0f g left", state_only, w->spool, w->spool_left) : g_strdup(state_only);
    char *tip = error ? g_strdup_printf("%s\n%s", text, error) : w->spool ? g_strdup_printf("%s\nIn the printer: %s, %.0f g left", text, w->spool, w->spool_left) : g_strdup(text);
    gtk_label_set_text(GTK_LABEL(w->printer_state), label);
    gtk_widget_set_visible(w->printer_state, TRUE);
    gtk_widget_set_tooltip_text(w->printer_state, tip);
    g_free(label);
    g_free(tip);
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
    const char **names = g_new0(const char *, zg_printers_count() + 3);
    guint selected = 0;
    for (guint i = 0; i < zg_printers_count(); i++) {
        names[i] = zg_printers_get(i)->name;
        if (zg_printers_get(i) == pr) selected = i;
    }
    /* Then the settings of this printer (the Printer group of the
     * settings, at its start G-code), and the printer picker. */
    names[zg_printers_count()] = "Printer settings and G-code\u2026";
    names[zg_printers_count() + 1] = "Add a printer\u2026";
    gtk_string_list_splice(w->printer_names, 0, n, names);
    g_free(names);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(w->printer_dd), selected);
    w->filling_printers = FALSE;
    gboolean linked = pr->kind != ZG_LINK_NONE;
    gtk_widget_set_visible(w->send_button, linked);
    gtk_widget_set_visible(w->send_menu, linked);
    /* The card has one main button: print with a printer, else export
     * (the export is in the menu of the print button). */
    gtk_widget_set_visible(w->export_button, !linked);
    if (w->send_box) gtk_widget_set_visible(w->send_box, linked);
    if (linked) {
        /* The label names the kind of link; the printer is in the menu at
         * the left, and in the tooltip. */
        const char *label = pr->kind == ZG_LINK_PRINTDECK ? "Print to Printdeck"
                            : pr->kind == ZG_LINK_OCTOPRINT ? "Print to OctoPrint"
                            : pr->kind == ZG_LINK_MOONRAKER ? "Print to Moonraker"
                                                             : "Print";
        gtk_button_set_label(GTK_BUTTON(w->send_button), label);
        char *tip = g_strdup_printf(pr->kind == ZG_LINK_USB ? "Print on %s over USB" : "Upload the G-code to %s and start the print", pr->name);
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
    if (gtk_drop_down_get_selected(GTK_DROP_DOWN(dd)) == zg_printers_count()) {
        update_printer_ui(w);
        zg_settings_panel_show_setting(w->settings_panel, "machine.start_gcode");
        return;
    }
    if (gtk_drop_down_get_selected(GTK_DROP_DOWN(dd)) == zg_printers_count() + 1) {
        update_printer_ui(w);
        zg_printer_picker_show(w->window, w->model, FALSE);
        return;
    }
    ZgPrinter *pr = zg_printers_get(gtk_drop_down_get_selected(GTK_DROP_DOWN(dd)));
    if (pr) zg_model_use_printer(w->model, pr->id);
}

static void on_printers_changed(ZgModel *model, gpointer data) {
    update_printer_ui(data);
    deck_estimate_soon(data);
}

static void on_prefs_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    zg_preferences_show(w->window, w->model);
}

static void on_compare_cura_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    zg_cura_compare_show(w->window, w->model, FALSE);
}

/* ZSLICE_CURA_COMPARE=1 opens the comparison with Cura at the start, for
 * tests and screenshots. "all" shows all mapped settings, and "use-all"
 * also presses "Use all". */
static gboolean open_cura_compare_test(gpointer data) {
    Window *w = data;
    zg_cura_compare_show(w->window, w->model, g_str_has_suffix(g_getenv("ZSLICE_CURA_COMPARE"), "all"));
    return G_SOURCE_REMOVE;
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

/* Undo and redo of the settings (Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y). */
static void on_undo_action(GSimpleAction *a, GVariant *v, gpointer data) {
    zg_model_undo(get(data)->model);
}

static void on_redo_action(GSimpleAction *a, GVariant *v, gpointer data) {
    zg_model_redo(get(data)->model);
}

static void on_undo_changed(ZgModel *model, gpointer data) {
    Window *w = data;
    GAction *u = g_action_map_lookup_action(G_ACTION_MAP(w->window), "undo");
    GAction *r = g_action_map_lookup_action(G_ACTION_MAP(w->window), "redo");
    /* Undo stays on: a change can wait in its burst (zg_model_can_undo). */
    if (u) g_simple_action_set_enabled(G_SIMPLE_ACTION(u), TRUE);
    if (r) g_simple_action_set_enabled(G_SIMPLE_ACTION(r), zg_model_can_redo(model));
}

/* For development: ZSLICE_UNDO_TEST=1 changes the infill density twice,
 * then undoes and redoes, and logs each value. */
static gboolean undo_test_step(gpointer data) {
    Window *w = data;
    static int step = 0;
    char *v;
    switch (step++) {
    case 0: zg_model_set(w->model, "project.infill_density", "0.55", NULL); break;
    case 1: zg_model_set(w->model, "project.infill_density", "0.6", NULL);
            zg_model_set(w->model, "project.infill_density", "0.7", NULL); break;
    case 2: zg_model_undo(w->model); break;
    case 3: zg_model_undo(w->model); break;
    case 4: zg_model_redo(w->model); break;
    case 5: zg_model_part_move(w->model, 0, 60, 70); break;
    case 6: break; /* the step of the move ends */
    case 7: zg_model_undo(w->model); break;
    default: return G_SOURCE_REMOVE;
    }
    if (step - 1 >= 5) {
        zs_part part;
        if (zs_app_part_get(zg_model_core(w->model), 0, &part) == ZS_OK)
            g_message("undo test %d: part 0 at %.1f, %.1f", step - 1, part.x, part.y);
    }
    v = zg_model_get(w->model, "project.infill_density");
    g_message("undo test %d: infill_density = %s", step - 1, v);
    g_free(v);
    return G_SOURCE_CONTINUE;
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
    if (w->deck_timer) g_source_remove(w->deck_timer);
    if (w->deck_cancel) g_cancellable_cancel(w->deck_cancel);
    g_clear_object(&w->deck_cancel);
    g_clear_object(&w->poll_cancel);
    w->printer_state = NULL;
    g_object_unref(w->model);
    g_free(w->last_error);
    g_free(w->last_stats);
    g_free(w->spool);
    g_free(w->spool_material);
    g_free(w->printer_roll);
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
    w->spool_left = -1;
    w->model = g_object_ref(model);
    w->window = GTK_WINDOW(gtk_application_window_new(app));
    g_object_set_data_full(G_OBJECT(w->window), "zg-window", w, window_free);
    gtk_window_set_default_size(w->window, 1280, 820);
    gtk_widget_add_css_class(GTK_WIDGET(w->window), "zg-main");
    gtk_window_set_title(w->window, "zslice");

    /* Header bar. */
    GtkWidget *header = gtk_header_bar_new();
    GtkWidget *open = gtk_button_new_from_icon_name("document-open-symbolic");
    gtk_widget_set_tooltip_text(open, "Add models to the plate (Ctrl+O). Ctrl+click a part to select it; Ctrl+drag moves it, and Ctrl+wheel turns it. Shift+click adds a line to the selection.");
    g_signal_connect(open, "clicked", G_CALLBACK(on_open_clicked), w->window);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), open);

    w->export_button = gtk_button_new_with_label("Export G-code…");
    gtk_widget_add_css_class(w->export_button, "suggested-action");
    gtk_widget_set_tooltip_text(w->export_button, "Save the G-code (Ctrl+E)");
    g_signal_connect(w->export_button, "clicked", G_CALLBACK(on_export_clicked), w->window);

    /* The printer, and the send button with its menu. */
    w->printer_names = gtk_string_list_new(NULL);
    w->printer_dd = gtk_drop_down_new(G_LIST_MODEL(w->printer_names), NULL);
    gtk_widget_set_tooltip_text(w->printer_dd, "The printer: its machine settings, and where Send goes. From this list: the settings and the start and end G-code of the printer, or add a printer. Edit the connections in Preferences.");
    g_signal_connect(w->printer_dd, "notify::selected", G_CALLBACK(on_printer_dd), w);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), w->printer_dd);
    /* The three profiles of the settings: printer, filament, part. */
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), zg_profile_menu_new(model, ZS_GROUP_FILAMENT));
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), zg_profile_menu_new(model, ZS_GROUP_PROJECT));
    w->send_button = gtk_button_new_with_label("Print");
    gtk_widget_add_css_class(w->send_button, "suggested-action");
    g_signal_connect(w->send_button, "clicked", G_CALLBACK(on_send_clicked), w->window);
    GMenu *send_menu = g_menu_new();
    g_menu_append(send_menu, "Upload only", "win.send-only");
    g_menu_append(send_menu, "Export a G-code file…", "win.export");
    w->send_menu = gtk_menu_button_new();
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(w->send_menu), G_MENU_MODEL(send_menu));
    gtk_widget_add_css_class(w->send_menu, "suggested-action");
    g_object_unref(send_menu);
    GtkWidget *send_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    w->send_box = send_box;
    gtk_widget_add_css_class(send_box, "linked");
    gtk_box_append(GTK_BOX(send_box), w->send_button);
    gtk_box_append(GTK_BOX(send_box), w->send_menu);
    const GActionEntry win_actions[] = {
        {.name = "send-print", .activate = on_send_print},
        {.name = "send-only", .activate = on_send_only},
        {.name = "export", .activate = on_export_action},
        {.name = "preferences", .activate = on_prefs_action},
        {.name = "compare-cura", .activate = on_compare_cura_action},
        {.name = "arrange", .activate = on_arrange_action},
        {.name = "smart-place", .activate = on_smart_place_action},
        {.name = "send-all", .activate = on_send_all_action},
        {.name = "export-all", .activate = on_export_all_action},
        {.name = "save-plate", .activate = on_save_plate_action},
        {.name = "clear-plate", .activate = on_clear_action},
        {.name = "undo", .activate = on_undo_action},
        {.name = "redo", .activate = on_redo_action},
    };
    g_action_map_add_action_entries(G_ACTION_MAP(w->window), win_actions, G_N_ELEMENTS(win_actions), w->window);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_undo_changed), w);
    on_undo_changed(model, w);
    if (g_getenv("ZSLICE_UNDO_TEST")) g_timeout_add(1000, undo_test_step, w);
    if (g_getenv("ZSLICE_CURA_COMPARE")) g_timeout_add(1500, open_cura_compare_test, w);

    GMenu *menu = g_menu_new();
    GMenu *edit = g_menu_new();
    g_menu_append(edit, "Undo", "win.undo");
    g_menu_append(edit, "Redo", "win.redo");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(edit));
    g_object_unref(edit);
    g_menu_append(menu, "Save the plate as 3MF…", "win.save-plate");
    g_menu_append(menu, "Send all plates", "win.send-all");
    g_menu_append(menu, "Export all plates\u2026", "win.export-all");
    g_menu_append(menu, "Smart placement", "win.smart-place");
    g_menu_append(menu, "Arrange the plate", "win.arrange");
    g_menu_append(menu, "Clear the plate", "win.clear-plate");
    g_menu_append(menu, "Compare with Cura\u2026", "win.compare-cura");
    g_menu_append(menu, "Preferences", "win.preferences");
    g_menu_append(menu, "Licenses", "app.licenses");
    g_menu_append(menu, "About zslice", "app.about");
    GtkWidget *menu_button = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_button), "open-menu-symbolic");
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button), G_MENU_MODEL(menu));
    g_object_unref(menu);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), menu_button);

    w->title = gtk_label_new("zslice");
    gtk_widget_add_css_class(w->title, "title");
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), w->title);
    gtk_window_set_titlebar(w->window, header);

    /* Body: settings | preview. */
    w->preview = zg_preview_new(model);
    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget *settings = zg_settings_panel_new(model);
    w->settings_panel = settings;
    gtk_widget_set_vexpand(settings, TRUE);
    /* The summary card under the settings. */
    w->sum_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_add_css_class(w->sum_box, "zg-summary");
    w->sum_time = gtk_label_new("—");
    gtk_widget_add_css_class(w->sum_time, "zg-summary-time");
    gtk_label_set_xalign(GTK_LABEL(w->sum_time), 0);
    w->sum_detail = gtk_label_new("");
    gtk_widget_add_css_class(w->sum_detail, "dim-label");
    gtk_label_set_xalign(GTK_LABEL(w->sum_detail), 0);
    gtk_label_set_ellipsize(GTK_LABEL(w->sum_detail), PANGO_ELLIPSIZE_END);
    w->sum_deck = gtk_label_new("");
    gtk_widget_add_css_class(w->sum_deck, "dim-label");
    gtk_widget_add_css_class(w->sum_deck, "caption");
    gtk_label_set_xalign(GTK_LABEL(w->sum_deck), 0);
    gtk_label_set_wrap(GTK_LABEL(w->sum_deck), TRUE);
    gtk_widget_set_visible(w->sum_deck, FALSE);
    /* The buttons: print (with its menu: upload only, export), or export
     * with no printer. They fill the width of the card. */
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_margin_top(actions, 8);
    gtk_widget_set_hexpand(send_box, TRUE);
    gtk_widget_set_hexpand(w->send_button, TRUE);
    gtk_widget_set_hexpand(w->export_button, TRUE);
    gtk_box_append(GTK_BOX(actions), send_box);
    gtk_box_append(GTK_BOX(actions), w->export_button);
    /* The state of the slice, and messages (an upload, an error). */
    w->status = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(w->status), 0);
    gtk_label_set_wrap(GTK_LABEL(w->status), TRUE);
    gtk_widget_add_css_class(w->status, "dim-label");
    gtk_widget_add_css_class(w->status, "caption");
    gtk_widget_add_css_class(w->status, "numeric");
    /* Islands: a warning that goes to each island in turn. */
    w->islands = gtk_button_new();
    gtk_widget_add_css_class(w->islands, "flat");
    gtk_widget_add_css_class(w->islands, "zg-islands");
    gtk_widget_set_halign(w->islands, GTK_ALIGN_START);
    gtk_widget_set_visible(w->islands, FALSE);
    g_signal_connect(w->islands, "clicked", G_CALLBACK(on_islands_clicked), w);
    w->progress = gtk_progress_bar_new();
    gtk_widget_add_css_class(w->progress, "zg-thin");
    gtk_widget_set_tooltip_text(w->progress, "The progress of the slice.");
    gtk_widget_set_margin_top(w->progress, 4);
    /* The printer: its state and the roll in it. */
    w->printer_state = gtk_label_new("");
    gtk_widget_add_css_class(w->printer_state, "dim-label");
    gtk_widget_add_css_class(w->printer_state, "caption");
    gtk_label_set_xalign(GTK_LABEL(w->printer_state), 0);
    gtk_label_set_ellipsize(GTK_LABEL(w->printer_state), PANGO_ELLIPSIZE_END);
    gtk_widget_set_margin_top(w->printer_state, 6);
    gtk_widget_set_visible(w->printer_state, FALSE); /* until a printer answers */
    gtk_box_append(GTK_BOX(w->sum_box), w->sum_time);
    gtk_box_append(GTK_BOX(w->sum_box), w->sum_detail);
    gtk_box_append(GTK_BOX(w->sum_box), w->sum_deck);
    gtk_box_append(GTK_BOX(w->sum_box), w->status);
    gtk_box_append(GTK_BOX(w->sum_box), w->islands);
    gtk_box_append(GTK_BOX(w->sum_box), w->progress);
    gtk_box_append(GTK_BOX(w->sum_box), w->printer_state);
    gtk_box_append(GTK_BOX(w->sum_box), actions);
    GtkWidget *panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(panel), settings);
    gtk_box_append(GTK_BOX(panel), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(panel), w->sum_box);
    gtk_widget_add_css_class(panel, "zg-panel");
    /* The model on the left, the settings on the right, as in other
     * slicers. */
    /* The preview, with the timeline of the history floating at its
     * bottom. */
    GtkWidget *left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(w->preview, TRUE);
    gtk_box_append(GTK_BOX(left), w->preview);
    zg_preview_set_timeline(w->preview, zg_timeline_new(model));
    gtk_paned_set_start_child(GTK_PANED(paned), left);
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

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(body), paned);
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
