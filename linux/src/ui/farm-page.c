/* farm-page.c: see farm-page.h.
 *
 * One card for each printer with a connection: its camera (camera-view.c),
 * its name, a state badge, the job with its progress and the time left,
 * why it failed or paused, the temperatures, and the roll. The main action
 * is "Print the plate"; the rare ones are in the menu of the card. The
 * plates to print are at the top, and a row of counts is under the title.
 *
 * printdeck, OctoPrint, and Moonraker: the page reads each printer every
 * 10 s (printer-link.h). Bambu Lab: the page keeps an MQTT connection to
 * each printer while it shows (bambu-link.h). A camera plays only while
 * its card is in the visible part of the page.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "farm-page.h"

#include "../net/bambu-link.h"
#include "../net/printer-link.h"
#include "../prefs/printers.h"
#include "camera-view.h"
#include "pair-dialog.h"

#include <math.h>
#include <string.h>

enum { EVERY_S = 10 };

/* The states of zs_printer_status_farm_state. */
static const char *const state_keys[] = {"offline", "idle", "printing", "paused", "done", "failed"};
static const char *const state_texts[] = {"Offline", "Ready", "Printing", "Paused", "Done: clear the bed", "Failed"};
static const char *const count_texts[] = {"offline", "ready", "printing", "paused", "done", "failed"};

typedef struct Page Page;

static void build(Page *p);
static void refresh(Page *p);
static void start_bambu(Page *p);
static void on_tile_send(GtkButton *b, gpointer data);

typedef struct {
    Page *page;
    char *id; /* the id of the printer */
    GtkWidget *card, *cam, *badge, *job, *job_name, *bar, *facts, *why, *heat, *roll, *send;
    int state; /* 0 to 5, -1 before the first answer */
    gboolean needs_key; /* no key, or a key that the printer refuses */
    gboolean camera_read;
    char *stream, *snapshot; /* the HTTP camera */
    double bed_x, bed_y, time_left;
    char *heat_text;
    ZgBambuWatch *bambu;
} Tile;

struct Page {
    ZgModel *model;
    GtkWidget *scroll, *box, *grid, *queue, *qempty, *note, *counts;
    GPtrArray *tiles; /* Tile */
    guint timer, vis_idle;
    GCancellable *cancel;
    /* The large camera. */
    GtkWidget *large;
    Tile *large_tile;
};

static void tile_free(gpointer data) {
    Tile *t = data;
    zg_bambu_watch_stop(t->bambu);
    g_free(t->id);
    g_free(t->stream);
    g_free(t->snapshot);
    g_free(t->heat_text);
    g_free(t);
}

static gboolean has_link(const ZgPrinter *p) {
    return p->kind == ZG_LINK_PRINTDECK || p->kind == ZG_LINK_OCTOPRINT || p->kind == ZG_LINK_MOONRAKER || p->kind == ZG_LINK_BAMBU;
}

static char *time_text(double s) {
    int m = (int)(s / 60 + 0.5);
    return m >= 60 ? g_strdup_printf("%d h %d min", m / 60, m % 60) : g_strdup_printf("%d min", m);
}

static void render_queue(Page *p);
static void update_visible(Page *p);

/* ---- the counts ---- */

static void render_counts(Page *p) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(p->counts))) gtk_box_remove(GTK_BOX(p->counts), child);
    int n[6] = {0};
    for (guint i = 0; i < p->tiles->len; i++) {
        Tile *t = g_ptr_array_index(p->tiles, i);
        if (t->state >= 0 && t->state < 6) n[t->state]++;
    }
    const int order[] = {5, 4, 3, 2, 1, 0};
    for (int k = 0; k < 6; k++) {
        int s = order[k];
        if (!n[s]) continue;
        char *text = g_strdup_printf("%d %s", n[s], count_texts[s]);
        GtkWidget *l = gtk_label_new(text);
        g_free(text);
        gtk_widget_add_css_class(l, "zg-farm-count");
        gtk_box_append(GTK_BOX(p->counts), l);
    }
}

/* ---- a card ---- */

static void set_card_state(Tile *t, int state) {
    for (int k = 0; k < 6; k++) {
        gtk_widget_remove_css_class(t->card, state_keys[k]);
        gtk_widget_remove_css_class(t->badge, state_keys[k]);
    }
    t->state = state;
    gtk_widget_add_css_class(t->card, state_keys[state]);
    gtk_widget_add_css_class(t->badge, state_keys[state]);
    gtk_label_set_text(GTK_LABEL(t->badge), state_texts[state]);
}

static void can_send(Tile *t) {
    if (t->needs_key) {
        ZgPrinter *pk = zg_printers_find(t->id);
        gtk_button_set_label(GTK_BUTTON(t->send), "Get a key");
        gtk_widget_set_sensitive(t->send, TRUE);
        gtk_widget_set_tooltip_text(t->send, pk && pk->kind == ZG_LINK_PRINTDECK ? "Connect zslice: tap Allow on the screen of the printdeck"
                                                                                : "Connect zslice: allow it in the web page of OctoPrint");
        return;
    }
    gtk_button_set_label(GTK_BUTTON(t->send), "Print the plate");
    zs_app *app = zg_model_core(t->page->model);
    const uint8_t *g = NULL;
    size_t len = 0;
    gboolean sliced = app && zs_app_gcode(app, &g, &len) == ZS_OK && len > 0;
    ZgPrinter *pr = zg_printers_find(t->id);
    gboolean bambu = pr && pr->kind == ZG_LINK_BAMBU;
    gtk_widget_set_sensitive(t->send, sliced && t->state == 1 && !bambu);
    gtk_widget_set_tooltip_text(t->send, bambu    ? "The Linux app reads a Bambu Lab printer, and cannot send it prints yet."
                                         : !sliced ? "Slice the plate first."
                                         : t->state == 4 ? "A print waits on the bed: clear it first."
                                         : t->state != 1 ? "The printer is busy, or does not answer."
                                                         : "Upload the G-code of the active plate, and start it after you confirm that the bed is clear");
}

static void heat_part(GString *s, const char *name, double v, double target) {
    if (isnan(v)) return;
    if (s->len) g_string_append(s, "    ");
    if (target > 0) g_string_append_printf(s, "%s %.0f / %.0f °C", name, v, target);
    else g_string_append_printf(s, "%s %.0f °C", name, v);
}

/* The card from the status of the core, or the error. */
static void update_card(Tile *t, const zs_printer_status *st, const char *error) {
    ZgPrinter *pr = zg_printers_find(t->id);
    t->needs_key = !st && pr && (pr->kind == ZG_LINK_PRINTDECK || pr->kind == ZG_LINK_OCTOPRINT) &&
                   (!pr->api_key[0] || (error && strstr(error, "did not accept the API key")));
    if (!st) {
        set_card_state(t, 0);
        gtk_widget_set_visible(t->job, FALSE);
        gtk_widget_set_visible(t->heat, FALSE);
        gtk_widget_set_visible(t->roll, FALSE);
        gtk_widget_set_visible(t->why, TRUE);
        gtk_widget_remove_css_class(t->why, "paused");
        gtk_widget_add_css_class(t->why, "offline");
        gtk_label_set_text(GTK_LABEL(t->why), error ? error : "No answer.");
        g_clear_pointer(&t->heat_text, g_free);
        can_send(t);
        render_counts(t->page);
        return;
    }
    zs_printer_info in;
    if (zs_printer_status_get(st, &in) != ZS_OK) return;
    int state = zs_printer_status_farm_state(st);
    /* A Bambu Lab printer that answers with no state yet: it is there. */
    if (state == 0 && !in.state[0]) state = 1;
    set_card_state(t, state);
    t->bed_x = in.bed_x;
    t->bed_y = in.bed_y;
    t->time_left = in.time_left;
    gboolean has_job = in.job[0] && state >= 2;
    gtk_widget_set_visible(t->job, has_job);
    if (has_job) {
        double f = state == 4 ? 1 : in.progress;
        gtk_label_set_text(GTK_LABEL(t->job_name), in.job);
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(t->bar), f);
        GString *s = g_string_new(NULL);
        g_string_append_printf(s, "%.0f %%", f * 100);
        if ((state == 2 || state == 3) && in.time_left > 0) {
            char *tt = time_text(in.time_left);
            g_string_append_printf(s, " · %s left", tt);
            g_free(tt);
        }
        if ((state == 2 || state == 3) && in.layers > 0) g_string_append_printf(s, " · layer %d of %d", in.layer, in.layers);
        gtk_label_set_text(GTK_LABEL(t->facts), s->str);
        g_string_free(s, TRUE);
    }
    const char *why = state == 5 || state == 3 ? zs_printer_status_message(st) : "";
    gtk_widget_set_visible(t->why, why[0] != 0);
    gtk_widget_remove_css_class(t->why, "offline");
    if (state == 3) gtk_widget_add_css_class(t->why, "paused");
    else gtk_widget_remove_css_class(t->why, "paused");
    gtk_label_set_text(GTK_LABEL(t->why), why);
    zs_printer_heat h;
    GString *hs = g_string_new(NULL);
    if (zs_printer_status_heat(st, &h) == ZS_OK) {
        heat_part(hs, "Nozzle", h.nozzle, h.nozzle_target);
        heat_part(hs, "Bed", h.bed, h.bed_target);
        heat_part(hs, "Chamber", h.chamber, 0);
    }
    gtk_label_set_text(GTK_LABEL(t->heat), hs->str);
    gtk_widget_set_visible(t->heat, hs->len > 0);
    g_free(t->heat_text);
    t->heat_text = g_string_free(hs, FALSE);
    GString *roll = g_string_new(in.spool.name[0] ? in.spool.name : in.material);
    if (in.spool.name[0] && in.material[0]) g_string_append_printf(roll, " (%s)", in.material);
    if (in.spool.name[0] && in.spool.left > 0) g_string_append_printf(roll, ", %.0f g left", in.spool.left);
    gtk_label_set_text(GTK_LABEL(t->roll), roll->str);
    gtk_widget_set_visible(t->roll, roll->len > 0);
    g_string_free(roll, TRUE);
    can_send(t);
    render_counts(t->page);
}

/* ---- the cameras ---- */

static void on_camera(const char *stream, const char *snapshot, const char *error, gpointer data) {
    Tile *t = data;
    if (error && g_strcmp0(error, "Operation was cancelled") == 0) return;
    ZgPrinter *pr = zg_printers_find(t->id);
    if (!pr) return;
    if (!stream && !snapshot) {
        gtk_widget_set_visible(t->cam, FALSE);
        return;
    }
    g_free(t->stream);
    g_free(t->snapshot);
    t->stream = g_strdup(stream);
    t->snapshot = g_strdup(snapshot);
    zg_camera_view_set_http(t->cam, stream, snapshot, pr->api_key, pr->kind == ZG_LINK_PRINTDECK);
    gtk_widget_set_visible(t->cam, TRUE);
    update_visible(t->page);
}

static void on_large_close(GtkWidget *win, gpointer data) {
    Page *p = data;
    p->large = NULL;
    p->large_tile = NULL;
    update_visible(p);
}

static void open_large(Tile *t) {
    Page *p = t->page;
    ZgPrinter *pr = zg_printers_find(t->id);
    if (!pr || !zg_camera_view_has_source(t->cam)) return;
    if (p->large) gtk_window_destroy(GTK_WINDOW(p->large));
    GtkWidget *win = gtk_window_new();
    GtkRoot *root = gtk_widget_get_root(p->box);
    if (GTK_IS_WINDOW(root)) gtk_window_set_transient_for(GTK_WINDOW(win), GTK_WINDOW(root));
    gtk_window_set_modal(GTK_WINDOW(win), TRUE);
    gtk_window_set_destroy_with_parent(GTK_WINDOW(win), TRUE);
    char *title = g_strdup_printf("%s · %s%s%s", pr->name, gtk_label_get_text(GTK_LABEL(t->badge)), t->heat_text && t->heat_text[0] ? " · " : "",
                                  t->heat_text ? t->heat_text : "");
    gtk_window_set_title(GTK_WINDOW(win), title);
    g_free(title);
    gtk_window_set_default_size(GTK_WINDOW(win), 960, 580);
    GtkWidget *view = zg_camera_view_new(TRUE);
    gtk_widget_add_css_class(view, "camera-large");
    if (pr->kind == ZG_LINK_BAMBU) zg_camera_view_set_bambu(view, pr, NULL);
    else zg_camera_view_set_http(view, t->stream, t->snapshot, pr->api_key, pr->kind == ZG_LINK_PRINTDECK);
    zg_camera_view_set_active(view, TRUE);
    gtk_window_set_child(GTK_WINDOW(win), view);
    p->large = win;
    p->large_tile = t;
    g_signal_connect(win, "destroy", G_CALLBACK(on_large_close), p);
    /* The small camera rests while the large one plays. */
    update_visible(p);
    gtk_window_present(GTK_WINDOW(win));
}

static void on_cam_click(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    open_large(data);
}

/* Each camera plays while its card is in the visible part of the page. */
static gboolean visible_now(gpointer data) {
    Page *p = data;
    p->vis_idle = 0;
    gboolean shown = gtk_widget_get_mapped(p->scroll);
    double top = gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(p->scroll)));
    double h = gtk_widget_get_height(p->scroll);
    for (guint i = 0; i < p->tiles->len; i++) {
        Tile *t = g_ptr_array_index(p->tiles, i);
        graphene_rect_t r;
        gboolean in = FALSE;
        if (shown && gtk_widget_get_visible(t->cam) && gtk_widget_compute_bounds(t->cam, p->box, &r))
            in = r.origin.y + r.size.height > top && r.origin.y < top + h;
        zg_camera_view_set_active(t->cam, in && p->large_tile != t && t->state != 0);
    }
    return G_SOURCE_REMOVE;
}

static void update_visible(Page *p) {
    if (!p->vis_idle) p->vis_idle = g_idle_add(visible_now, p);
}

static void on_scrolled(GtkAdjustment *a, gpointer data) {
    update_visible(data);
}

/* ---- reading ---- */

static void on_status(ZgPrinterInfo *info, const char *error, gpointer data) {
    Tile *t = data;
    if (error && g_strcmp0(error, "Operation was cancelled") == 0) return;
    update_card(t, info ? info->core : NULL, error);
    if (info && !t->camera_read) {
        ZgPrinter *pr = zg_printers_find(t->id);
        t->camera_read = TRUE;
        if (pr) zg_link_camera(pr, t->page->cancel, on_camera, t);
    }
    zg_printer_info_free(info);
    render_queue(t->page);
    update_visible(t->page);
    /* For tests: ZSLICE_FARM_PAIR=1 presses Get a key on the first card
     * that needs a key, once. */
    static gboolean paired_test;
    if (t->needs_key && !paired_test && g_getenv("ZSLICE_FARM_PAIR")) {
        paired_test = TRUE;
        on_tile_send(GTK_BUTTON(t->send), t);
    }
}

static void on_bambu(const zs_printer_status *st, const char *error, gpointer data) {
    Tile *t = data;
    update_card(t, st, error);
    update_visible(t->page);
}

static void refresh(Page *p) {
    for (guint i = 0; i < p->tiles->len; i++) {
        Tile *t = g_ptr_array_index(p->tiles, i);
        ZgPrinter *pr = zg_printers_find(t->id);
        if (pr && pr->kind != ZG_LINK_BAMBU) zg_link_query(pr, p->cancel, on_status, t);
    }
}

static gboolean on_timer(gpointer data) {
    refresh(data);
    return G_SOURCE_CONTINUE;
}

/* ---- sending ---- */

typedef struct {
    Page *page;
    char *id;
    gint64 plate; /* -1: the active plate */
    gboolean print;
} Send;

static void send_free(Send *s) {
    g_free(s->id);
    g_free(s);
}

static void on_progress(double fraction, gpointer data) {}

static void on_sent(gboolean ok, const char *message, gpointer data) {
    Page *p = data;
    gtk_label_set_text(GTK_LABEL(p->note), message ? message : (ok ? "Sent." : "The send failed."));
    gtk_widget_set_visible(p->note, TRUE);
    refresh(p);
}

static void do_send(Send *s) {
    ZgPrinter *pr = zg_printers_find(s->id);
    if (!pr) return;
    zs_set *set = zg_model_plate_set(s->page->model);
    zs_app *app = s->plate < 0 ? zg_model_core(s->page->model) : zs_set_app(set, (size_t)s->plate);
    const uint8_t *g = NULL;
    size_t len = 0;
    if (!app || zs_app_gcode(app, &g, &len) != ZS_OK) {
        gtk_label_set_text(GTK_LABEL(s->page->note), "No G-code: the plate has no slice yet.");
        gtk_widget_set_visible(s->page->note, TRUE);
        return;
    }
    GBytes *bytes = g_bytes_new(g, len);
    /* The name of the core, from the first part of the plate. */
    size_t index = s->plate < 0 ? zs_set_active(set) : (size_t)s->plate;
    zs_part first = {0};
    const char *model = zs_app_part_count(app) > 0 && zs_app_part_get(app, 0, &first) == ZS_OK && first.name ? first.name : "plate";
    char base[256] = "";
    if (zs_app_gcode_name(app, model, zs_set_count(set) > 1 ? index + 1 : 0, base, sizeof base, NULL) != ZS_OK || !base[0])
        g_snprintf(base, sizeof base, "plate-%zu", index + 1);
    /* A Bambu Lab printer behind a deck prints a .gcode.3mf. */
    gboolean three = zg_link_wants_3mf(app, pr);
    char *file = g_strconcat(base, three ? ".gcode.3mf" : ".gcode", NULL);
    zg_link_send_wrapped(pr, file, bytes, three ? zg_link_bambu_wrap : NULL, (gpointer)app, s->print, s->page->cancel, on_progress, on_sent, s->page);
    g_free(file);
    g_bytes_unref(bytes);
}

static void on_confirmed(GObject *source, GAsyncResult *res, gpointer data) {
    Send *s = data;
    int button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), res, NULL);
    if (button == 1) do_send(s);
    send_free(s);
}

/* A fresh "Is the bed clear?" before each print, then the send. An upload
 * that does not start a print needs no confirmation. */
static void ask_send(Page *p, const char *id, gint64 plate, gboolean busy, gboolean print) {
    ZgPrinter *pr = zg_printers_find(id);
    if (!pr) return;
    Send *s = g_new0(Send, 1);
    s->page = p;
    s->id = g_strdup(id);
    s->plate = plate;
    s->print = print;
    if (!print) {
        do_send(s);
        send_free(s);
        return;
    }
    zs_set *set = zg_model_plate_set(p->model);
    size_t idx = plate < 0 ? zs_set_active(set) : (size_t)plate;
    zs_plate_info info;
    const char *pname = zs_set_plate_info(set, idx, &info) == ZS_OK && info.name[0] ? info.name : "the plate";
    ZgPrinter *cur = zg_printers_current();
    gboolean other = cur && g_strcmp0(cur->id, pr->id) != 0;
    /* A printdeck set to ask waits for a press of Print on the deck. */
    char *detail = g_strdup_printf(pr->kind == ZG_LINK_PRINTDECK ? "Is the bed of %s clear? The print can start when the file is there (a deck set to ask waits for a press of Print on it).%s%s%s%s" : "Is the bed of %s clear? The print can start when the file is there.%s%s%s%s", pr->name, busy ? "\n\nThe printer looks busy now." : "",
                                   other ? "\n\nThe plate is sliced for " : "", other ? cur->name : "", other ? ", another printer." : "");
    char *msg = g_strdup_printf("Send \"%s\" to %s?", pname, pr->name);
    GtkAlertDialog *d = gtk_alert_dialog_new("%s", msg);
    gtk_alert_dialog_set_detail(d, detail);
    const char *buttons[] = {"Cancel", "Send", NULL};
    gtk_alert_dialog_set_buttons(d, buttons);
    gtk_alert_dialog_set_cancel_button(d, 0);
    gtk_alert_dialog_set_default_button(d, 1);
    GtkRoot *root = gtk_widget_get_root(p->box);
    gtk_alert_dialog_choose(d, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, NULL, on_confirmed, s);
    g_object_unref(d);
    g_free(msg);
    g_free(detail);
}

static void on_paired(gboolean ok, gpointer data) {
    Page *p = data;
    if (!ok || !gtk_widget_get_mapped(p->scroll)) return;
    /* A deck can bring more printers: build the cards again. */
    if (p->cancel) g_cancellable_cancel(p->cancel);
    g_clear_object(&p->cancel);
    p->cancel = g_cancellable_new();
    build(p);
    refresh(p);
    start_bambu(p);
}

static void on_tile_send(GtkButton *b, gpointer data) {
    Tile *t = data;
    if (t->needs_key) {
        GtkRoot *root = gtk_widget_get_root(t->card);
        zg_pair_dialog_show(GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, t->page->model, t->id, on_paired, t->page);
        return;
    }
    ask_send(t->page, t->id, -1, t->state != 1, TRUE);
}

/* The actions of the menu of a card. */
static void on_upload(GSimpleAction *a, GVariant *v, gpointer data) {
    Tile *t = data;
    ask_send(t->page, t->id, -1, FALSE, FALSE);
}

static void on_show_large(GSimpleAction *a, GVariant *v, gpointer data) {
    open_large(data);
}

static void on_open_page(GSimpleAction *a, GVariant *v, gpointer data) {
    Tile *t = data;
    ZgPrinter *pr = zg_printers_find(t->id);
    if (!pr || !pr->url[0]) return;
    char *url = g_str_has_prefix(pr->url, "http") ? g_strdup(pr->url) : g_strconcat("http://", pr->url, NULL);
    GtkUriLauncher *l = gtk_uri_launcher_new(url);
    GtkRoot *root = gtk_widget_get_root(t->card);
    gtk_uri_launcher_launch(l, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, NULL, NULL, NULL);
    g_object_unref(l);
    g_free(url);
}

typedef struct {
    Page *page;
    gint64 plate;
    GtkWidget *drop;
} QueueRow;

static void on_queue_send(GtkButton *b, gpointer data) {
    QueueRow *q = data;
    guint i = gtk_drop_down_get_selected(GTK_DROP_DOWN(q->drop));
    GtkStringList *ids = g_object_get_data(G_OBJECT(q->drop), "zg-ids");
    const char *id = ids ? gtk_string_list_get_string(ids, i) : NULL;
    if (!id) return;
    gboolean busy = FALSE;
    for (guint k = 0; k < q->page->tiles->len; k++) {
        Tile *t = g_ptr_array_index(q->page->tiles, k);
        if (g_strcmp0(t->id, id) == 0) busy = t->state != 1;
    }
    ask_send(q->page, id, q->plate, busy, TRUE);
}

static GtkWidget *small_label(const char *css) {
    GtkWidget *l = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(l), PANGO_WRAP_WORD_CHAR);
    /* A long text wraps, and does not make its card wide. */
    gtk_label_set_max_width_chars(GTK_LABEL(l), 30);
    if (css) gtk_widget_add_css_class(l, css);
    return l;
}

/* The plates with parts, each with the printers that fit, the ready ones
 * first, and Send. */
static void render_queue(Page *p) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(p->queue))) gtk_box_remove(GTK_BOX(p->queue), child);
    zs_set *set = zg_model_plate_set(p->model);
    gboolean any = FALSE;
    for (size_t i = 0; set && i < zs_set_count(set); i++) {
        zs_plate_info info;
        if (zs_set_plate_info(set, i, &info) != ZS_OK || info.part_count == 0) continue;
        if (any) gtk_box_append(GTK_BOX(p->queue), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
        any = TRUE;
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_set_margin_start(row, 12);
        gtk_widget_set_margin_end(row, 12);
        gtk_widget_set_margin_top(row, 8);
        gtk_widget_set_margin_bottom(row, 8);
        GtkWidget *what = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_hexpand(what, TRUE);
        GtkWidget *l = small_label("heading");
        char *name = g_strdup_printf("%zu. %s", i + 1, info.name[0] ? info.name : "Plate");
        gtk_label_set_text(GTK_LABEL(l), name);
        g_free(name);
        GtkWidget *f = small_label("dim-label");
        gtk_widget_add_css_class(f, "zg-farm-small");
        char *facts = g_strdup_printf("%zu part%s · %s", info.part_count, info.part_count == 1 ? "" : "s", info.status == ZS_PLATE_STATUS_DONE ? "sliced" : "not sliced yet");
        gtk_label_set_text(GTK_LABEL(f), facts);
        g_free(facts);
        gtk_box_append(GTK_BOX(what), l);
        gtk_box_append(GTK_BOX(what), f);
        gtk_box_append(GTK_BOX(row), what);
        GtkStringList *names = gtk_string_list_new(NULL);
        GtkStringList *ids = gtk_string_list_new(NULL);
        for (int ready_pass = 1; ready_pass >= 0; ready_pass--) {
            for (guint k = 0; k < p->tiles->len; k++) {
                Tile *t = g_ptr_array_index(p->tiles, k);
                if ((t->state == 1) != ready_pass || t->state == 0) continue;
                /* A printer with a known bed smaller than the plate bed
                 * does not fit. */
                if (t->bed_x > 0 && (t->bed_x + 0.5 < info.bed_x || t->bed_y + 0.5 < info.bed_y)) continue;
                ZgPrinter *pr = zg_printers_find(t->id);
                if (!pr || pr->kind == ZG_LINK_BAMBU) continue;
                char *left = t->state != 1 && t->time_left > 0 ? time_text(t->time_left) : NULL;
                char *n = t->state == 1 ? g_strdup_printf("%s (ready)", pr->name)
                        : left           ? g_strdup_printf("%s (busy, free in %s)", pr->name, left)
                                         : g_strdup_printf("%s (busy)", pr->name);
                gtk_string_list_append(names, n);
                gtk_string_list_append(ids, t->id);
                g_free(n);
                g_free(left);
            }
        }
        GtkWidget *drop = gtk_drop_down_new(G_LIST_MODEL(names), NULL);
        gtk_widget_set_valign(drop, GTK_ALIGN_CENTER);
        g_object_set_data_full(G_OBJECT(drop), "zg-ids", ids, g_object_unref);
        gtk_box_append(GTK_BOX(row), drop);
        GtkWidget *go = gtk_button_new_with_label("Send");
        gtk_widget_set_valign(go, GTK_ALIGN_CENTER);
        gtk_widget_set_sensitive(go, info.status == ZS_PLATE_STATUS_DONE && g_list_model_get_n_items(G_LIST_MODEL(ids)) > 0);
        QueueRow *q = g_new0(QueueRow, 1);
        q->page = p;
        q->plate = (gint64)i;
        q->drop = drop;
        g_signal_connect_data(go, "clicked", G_CALLBACK(on_queue_send), q, (GClosureNotify)(void (*)(void))g_free, 0);
        gtk_box_append(GTK_BOX(row), go);
        gtk_box_append(GTK_BOX(p->queue), row);
    }
    gtk_widget_set_visible(p->queue, any);
    gtk_widget_set_visible(p->qempty, !any);
}

/* ---- the cards ---- */

static Tile *make_tile(Page *p, ZgPrinter *pr) {
    Tile *t = g_new0(Tile, 1);
    t->page = p;
    t->id = g_strdup(pr->id);
    t->state = -1;
    t->card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(t->card, "zg-farm-card");
    gtk_widget_set_size_request(t->card, 260, -1);
    t->cam = zg_camera_view_new(FALSE);
    gtk_widget_set_size_request(t->cam, -1, 160);
    gtk_widget_set_visible(t->cam, FALSE);
    gtk_widget_set_cursor_from_name(t->cam, "zoom-in");
    gtk_widget_set_tooltip_text(t->cam, "Show the camera large");
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "released", G_CALLBACK(on_cam_click), t);
    gtk_widget_add_controller(t->cam, GTK_EVENT_CONTROLLER(click));
    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start(body, 12);
    gtk_widget_set_margin_end(body, 12);
    gtk_widget_set_margin_top(body, 10);
    gtk_widget_set_margin_bottom(body, 10);
    GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *who = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(who, "zg-farm-who");
    gtk_widget_set_hexpand(who, TRUE);
    GtkWidget *name = small_label("heading");
    gtk_label_set_text(GTK_LABEL(name), pr->name);
    GtkWidget *kind = small_label("dim-label");
    gtk_widget_add_css_class(kind, "caption");
    gtk_label_set_text(GTK_LABEL(kind), zg_link_titles[pr->kind]);
    gtk_box_append(GTK_BOX(who), name);
    gtk_box_append(GTK_BOX(who), kind);
    t->badge = gtk_label_new("Reading");
    gtk_widget_add_css_class(t->badge, "zg-farm-badge");
    gtk_widget_set_valign(t->badge, GTK_ALIGN_START);
    gtk_label_set_wrap(GTK_LABEL(t->badge), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(t->badge), 14);
    gtk_label_set_justify(GTK_LABEL(t->badge), GTK_JUSTIFY_CENTER);
    gtk_box_append(GTK_BOX(top), who);
    gtk_box_append(GTK_BOX(top), t->badge);
    t->job = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    t->job_name = small_label("heading");
    t->bar = gtk_progress_bar_new();
    t->facts = small_label("dim-label");
    gtk_widget_add_css_class(t->facts, "zg-farm-small");
    gtk_box_append(GTK_BOX(t->job), t->job_name);
    gtk_box_append(GTK_BOX(t->job), t->bar);
    gtk_box_append(GTK_BOX(t->job), t->facts);
    gtk_widget_set_visible(t->job, FALSE);
    t->why = small_label("zg-farm-why");
    gtk_widget_set_visible(t->why, FALSE);
    t->heat = small_label("zg-farm-small");
    gtk_widget_set_visible(t->heat, FALSE);
    t->roll = small_label("dim-label");
    gtk_widget_add_css_class(t->roll, "zg-farm-small");
    gtk_widget_set_visible(t->roll, FALSE);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(actions, 4);
    t->send = gtk_button_new_with_label("Print the plate");
    gtk_widget_add_css_class(t->send, "suggested-action");
    gtk_widget_set_hexpand(t->send, TRUE);
    gtk_widget_set_sensitive(t->send, FALSE);
    g_signal_connect(t->send, "clicked", G_CALLBACK(on_tile_send), t);
    /* The rare actions: a menu. */
    GSimpleActionGroup *group = g_simple_action_group_new();
    const GActionEntry entries[] = {
        {.name = "upload", .activate = on_upload},
        {.name = "camera", .activate = on_show_large},
        {.name = "open", .activate = on_open_page},
    };
    g_action_map_add_action_entries(G_ACTION_MAP(group), entries, G_N_ELEMENTS(entries), t);
    if (pr->kind == ZG_LINK_BAMBU) {
        g_simple_action_set_enabled(G_SIMPLE_ACTION(g_action_map_lookup_action(G_ACTION_MAP(group), "upload")), FALSE);
        /* A Bambu Lab printer has no web page. */
        g_simple_action_set_enabled(G_SIMPLE_ACTION(g_action_map_lookup_action(G_ACTION_MAP(group), "open")), FALSE);
    }
    gtk_widget_insert_action_group(t->card, "card", G_ACTION_GROUP(group));
    g_object_unref(group);
    GMenu *menu = g_menu_new();
    g_menu_append(menu, "Upload the plate only", "card.upload");
    g_menu_append(menu, "Show the camera large", "card.camera");
    g_menu_append(menu, "Open the page of the printer", "card.open");
    GtkWidget *more = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(more), "view-more-symbolic");
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(more), G_MENU_MODEL(menu));
    gtk_widget_set_tooltip_text(more, "More");
    g_object_unref(menu);
    gtk_box_append(GTK_BOX(actions), t->send);
    gtk_box_append(GTK_BOX(actions), more);
    gtk_box_append(GTK_BOX(body), top);
    gtk_box_append(GTK_BOX(body), t->job);
    gtk_box_append(GTK_BOX(body), t->why);
    gtk_box_append(GTK_BOX(body), t->heat);
    gtk_box_append(GTK_BOX(body), t->roll);
    gtk_box_append(GTK_BOX(body), actions);
    gtk_box_append(GTK_BOX(t->card), t->cam);
    gtk_box_append(GTK_BOX(t->card), body);
    if (pr->kind == ZG_LINK_BAMBU) {
        zg_camera_view_set_bambu(t->cam, pr, NULL);
        gtk_widget_set_visible(t->cam, zg_camera_view_has_source(t->cam));
        t->camera_read = TRUE;
    }
    return t;
}

static void build(Page *p) {
    GtkFlowBoxChild *child;
    while ((child = gtk_flow_box_get_child_at_index(GTK_FLOW_BOX(p->grid), 0))) gtk_flow_box_remove(GTK_FLOW_BOX(p->grid), GTK_WIDGET(child));
    g_ptr_array_set_size(p->tiles, 0);
    for (guint i = 0; i < zg_printers_count(); i++) {
        ZgPrinter *pr = zg_printers_get(i);
        if (!has_link(pr)) continue;
        Tile *t = make_tile(p, pr);
        gtk_flow_box_append(GTK_FLOW_BOX(p->grid), t->card);
        g_ptr_array_add(p->tiles, t);
    }
    gtk_label_set_text(GTK_LABEL(p->note), p->tiles->len ? "" : "No printer has a connection. Add one in Preferences › Printers: printdeck, OctoPrint, Moonraker (Klipper), or Bambu Lab (LAN mode).");
    gtk_widget_set_visible(p->note, p->tiles->len == 0);
    render_queue(p);
    render_counts(p);
}

static void start_bambu(Page *p) {
    for (guint i = 0; i < p->tiles->len; i++) {
        Tile *t = g_ptr_array_index(p->tiles, i);
        ZgPrinter *pr = zg_printers_find(t->id);
        if (pr && pr->kind == ZG_LINK_BAMBU && !t->bambu) t->bambu = zg_bambu_watch(pr, on_bambu, t);
    }
}

static void on_map(GtkWidget *w, gpointer data) {
    Page *p = data;
    if (p->cancel) g_cancellable_cancel(p->cancel);
    g_clear_object(&p->cancel);
    p->cancel = g_cancellable_new();
    build(p);
    refresh(p);
    start_bambu(p);
    if (!p->timer) p->timer = g_timeout_add_seconds(EVERY_S, on_timer, p);
    update_visible(p);
}

static void on_unmap(GtkWidget *w, gpointer data) {
    Page *p = data;
    if (p->timer) g_source_remove(p->timer);
    p->timer = 0;
    if (p->cancel) g_cancellable_cancel(p->cancel);
    if (p->large) gtk_window_destroy(GTK_WINDOW(p->large));
    for (guint i = 0; i < p->tiles->len; i++) {
        Tile *t = g_ptr_array_index(p->tiles, i);
        zg_camera_view_set_active(t->cam, FALSE);
        zg_bambu_watch_stop(t->bambu);
        t->bambu = NULL;
    }
}

static void page_free(gpointer data) {
    Page *p = data;
    if (p->timer) g_source_remove(p->timer);
    if (p->vis_idle) g_source_remove(p->vis_idle);
    if (p->cancel) g_cancellable_cancel(p->cancel);
    g_clear_object(&p->cancel);
    g_ptr_array_unref(p->tiles);
    g_free(p);
}

GtkWidget *zg_farm_page_new(ZgModel *model) {
    Page *p = g_new0(Page, 1);
    p->model = model;
    p->tiles = g_ptr_array_new_with_free_func(tile_free);
    p->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_start(p->box, 16);
    gtk_widget_set_margin_end(p->box, 16);
    gtk_widget_set_margin_top(p->box, 12);
    gtk_widget_set_margin_bottom(p->box, 16);
    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    GtkWidget *title = gtk_label_new("Printers");
    gtk_widget_add_css_class(title, "title-2");
    gtk_label_set_xalign(GTK_LABEL(title), 0);
    p->counts = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_valign(p->counts, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(head), title);
    gtk_box_append(GTK_BOX(head), p->counts);
    p->note = small_label("dim-label");
    GtkWidget *qtitle = gtk_label_new("Plates to print");
    gtk_widget_add_css_class(qtitle, "heading");
    gtk_label_set_xalign(GTK_LABEL(qtitle), 0);
    p->queue = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(p->queue, "zg-farm-queue");
    p->qempty = small_label("dim-label");
    gtk_label_set_text(GTK_LABEL(p->qempty), "Add parts to a plate, and it shows here to print.");
    p->grid = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(p->grid), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(p->grid), 5);
    gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(p->grid), TRUE);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(p->grid), 12);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(p->grid), 12);
    gtk_widget_set_valign(p->grid, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(p->box), head);
    gtk_box_append(GTK_BOX(p->box), p->note);
    gtk_box_append(GTK_BOX(p->box), qtitle);
    gtk_box_append(GTK_BOX(p->box), p->qempty);
    gtk_box_append(GTK_BOX(p->box), p->queue);
    gtk_box_append(GTK_BOX(p->box), p->grid);
    p->scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(p->scroll), p->box);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(p->scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    GtkAdjustment *adj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(p->scroll));
    g_signal_connect(adj, "value-changed", G_CALLBACK(on_scrolled), p);
    g_signal_connect(adj, "changed", G_CALLBACK(on_scrolled), p);
    g_object_set_data_full(G_OBJECT(p->scroll), "zg-farm", p, page_free);
    g_signal_connect(p->scroll, "map", G_CALLBACK(on_map), p);
    g_signal_connect(p->scroll, "unmap", G_CALLBACK(on_unmap), p);
    return p->scroll;
}
