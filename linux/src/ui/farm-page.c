/* farm-page.c: see farm-page.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "farm-page.h"

#include "../net/printer-link.h"
#include "../prefs/printers.h"

enum { EVERY_S = 10 };

typedef struct Page Page;

typedef struct {
    Page *page;
    char *id;                    /* the id of the printer */
    GtkWidget *tile, *state, *bar, *send;
    gboolean printing, answered;
    double bed_x, bed_y;
} Tile;

struct Page {
    ZgModel *model;
    GtkWidget *box, *grid, *queue, *note;
    GPtrArray *tiles; /* Tile */
    guint timer;
    GCancellable *cancel;
};

static void tile_free(gpointer data) {
    Tile *t = data;
    g_free(t->id);
    g_free(t);
}

static gboolean has_link(const ZgPrinter *p) {
    return p->kind == ZG_LINK_PRINTDECK || p->kind == ZG_LINK_OCTOPRINT || p->kind == ZG_LINK_MOONRAKER;
}

/* The status in words: "Printing · Benchy, 42 %, 1 h 5 min left · Navy". */
static char *status_text(const ZgPrinterInfo *in) {
    GString *s = g_string_new(in->state && in->state[0] ? in->state : "Connected");
    if (in->job && in->job[0]) {
        g_string_append_printf(s, " · %s", in->job);
        if (in->progress > 0) g_string_append_printf(s, ", %.0f %%", in->progress * 100);
        if (in->time_left > 0) {
            int m = (int)(in->time_left / 60 + 0.5);
            if (m >= 60) g_string_append_printf(s, ", %d h %d min left", m / 60, m % 60);
            else g_string_append_printf(s, ", %d min left", m);
        }
    }
    if (in->spool && in->spool[0]) g_string_append_printf(s, " · %s%s%s%s", in->spool, in->material ? " (" : "", in->material ? in->material : "", in->material ? ")" : "");
    else if (in->material && in->material[0]) g_string_append_printf(s, " · %s", in->material);
    return g_string_free(s, FALSE);
}

static void render_queue(Page *p);

static void on_status(ZgPrinterInfo *info, const char *error, gpointer data) {
    Tile *t = data;
    if (error && g_strcmp0(error, "Operation was cancelled") == 0) return;
    t->answered = info != NULL;
    if (!info) {
        gtk_label_set_text(GTK_LABEL(t->state), error ? error : "No answer.");
        gtk_widget_set_opacity(t->tile, 0.6);
        gtk_widget_set_visible(t->bar, FALSE);
        return;
    }
    gtk_widget_set_opacity(t->tile, 1);
    char *text = status_text(info);
    gtk_label_set_text(GTK_LABEL(t->state), text);
    g_free(text);
    t->printing = info->job && info->job[0] && info->progress > 0 && info->progress < 1;
    t->bed_x = info->bed_x;
    t->bed_y = info->bed_y;
    gtk_widget_set_visible(t->bar, t->printing);
    if (t->printing) gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(t->bar), info->progress);
    zg_printer_info_free(info);
    render_queue(t->page);
}

static void refresh(Page *p) {
    for (guint i = 0; i < p->tiles->len; i++) {
        Tile *t = g_ptr_array_index(p->tiles, i);
        ZgPrinter *pr = zg_printers_find(t->id);
        if (pr) zg_link_query(pr, p->cancel, on_status, t);
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
} Send;

static void send_free(Send *s) {
    g_free(s->id);
    g_free(s);
}

static void on_progress(double fraction, gpointer data) {}

static void on_sent(gboolean ok, const char *message, gpointer data) {
    Page *p = data;
    gtk_label_set_text(GTK_LABEL(p->note), message ? message : (ok ? "Sent." : "The send failed."));
    refresh(p);
}

static void on_confirmed(GObject *source, GAsyncResult *res, gpointer data) {
    Send *s = data;
    int button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), res, NULL);
    ZgPrinter *pr = zg_printers_find(s->id);
    if (button != 1 || !pr) {
        send_free(s);
        return;
    }
    zs_set *set = zg_model_plate_set(s->page->model);
    zs_app *app = s->plate < 0 ? zg_model_core(s->page->model) : zs_set_app(set, (size_t)s->plate);
    const uint8_t *g = NULL;
    size_t len = 0;
    if (!app || zs_app_gcode(app, &g, &len) != ZS_OK) {
        gtk_label_set_text(GTK_LABEL(s->page->note), "No G-code: the plate has no slice yet.");
        send_free(s);
        return;
    }
    GBytes *bytes = g_bytes_new(g, len);
    char *file = g_strdup_printf("plate-%d.gcode", (int)(s->plate < 0 ? (gint64)zs_set_active(set) : s->plate) + 1);
    zg_link_send(pr, file, bytes, TRUE, s->page->cancel, on_progress, on_sent, s->page);
    g_free(file);
    g_bytes_unref(bytes);
    send_free(s);
}

/* A fresh "Is the bed clear?" each time, then the send. */
static void ask_send(Page *p, const char *id, gint64 plate, gboolean busy) {
    ZgPrinter *pr = zg_printers_find(id);
    if (!pr) return;
    zs_set *set = zg_model_plate_set(p->model);
    size_t idx = plate < 0 ? zs_set_active(set) : (size_t)plate;
    zs_plate_info info;
    const char *pname = zs_set_plate_info(set, idx, &info) == ZS_OK && info.name[0] ? info.name : "the plate";
    ZgPrinter *cur = zg_printers_current();
    gboolean other = cur && g_strcmp0(cur->id, pr->id) != 0;
    char *detail = g_strdup_printf("Is the bed of %s clear? The print can start when the file is there.%s%s%s%s", pr->name, busy ? "\n\nThe printer looks busy now." : "",
                                   other ? "\n\nThe plate is sliced for " : "", other ? cur->name : "", other ? ", another printer." : "");
    char *msg = g_strdup_printf("Send \"%s\" to %s?", pname, pr->name);
    GtkAlertDialog *d = gtk_alert_dialog_new("%s", msg);
    gtk_alert_dialog_set_detail(d, detail);
    const char *buttons[] = {"Cancel", "Send", NULL};
    gtk_alert_dialog_set_buttons(d, buttons);
    gtk_alert_dialog_set_cancel_button(d, 0);
    gtk_alert_dialog_set_default_button(d, 1);
    Send *s = g_new0(Send, 1);
    s->page = p;
    s->id = g_strdup(id);
    s->plate = plate;
    GtkRoot *root = gtk_widget_get_root(p->box);
    gtk_alert_dialog_choose(d, GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL, NULL, on_confirmed, s);
    g_object_unref(d);
    g_free(msg);
    g_free(detail);
}

static void on_tile_send(GtkButton *b, gpointer data) {
    Tile *t = data;
    ask_send(t->page, t->id, -1, t->printing);
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
        if (g_strcmp0(t->id, id) == 0) busy = t->printing;
    }
    ask_send(q->page, id, q->plate, busy);
}

/* The plates with parts, each with the printers that fit, the free ones
 * first, and Send. */
static void render_queue(Page *p) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(p->queue))) gtk_box_remove(GTK_BOX(p->queue), child);
    zs_set *set = zg_model_plate_set(p->model);
    gboolean any = FALSE;
    for (size_t i = 0; set && i < zs_set_count(set); i++) {
        zs_plate_info info;
        if (zs_set_plate_info(set, i, &info) != ZS_OK || info.part_count == 0) continue;
        any = TRUE;
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        char *label = g_strdup_printf("%zu. %s · %zu parts%s", i + 1, info.name[0] ? info.name : "Plate", info.part_count, info.status == ZS_PLATE_STATUS_DONE ? "" : " (not sliced)");
        GtkWidget *l = gtk_label_new(label);
        g_free(label);
        gtk_label_set_xalign(GTK_LABEL(l), 0);
        gtk_widget_set_hexpand(l, TRUE);
        gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(row), l);
        GtkStringList *names = gtk_string_list_new(NULL);
        GtkStringList *ids = gtk_string_list_new(NULL);
        for (int free_pass = 1; free_pass >= 0; free_pass--) {
            for (guint k = 0; k < p->tiles->len; k++) {
                Tile *t = g_ptr_array_index(p->tiles, k);
                if ((!t->printing) != free_pass) continue;
                /* A printer with a known bed smaller than the plate bed
                 * does not fit. */
                if (t->bed_x > 0 && (t->bed_x + 0.5 < info.bed_x || t->bed_y + 0.5 < info.bed_y)) continue;
                ZgPrinter *pr = zg_printers_find(t->id);
                if (!pr) continue;
                char *n = g_strdup_printf("%s%s", pr->name, t->printing ? " (busy)" : "");
                gtk_string_list_append(names, n);
                gtk_string_list_append(ids, t->id);
                g_free(n);
            }
        }
        GtkWidget *drop = gtk_drop_down_new(G_LIST_MODEL(names), NULL);
        g_object_set_data_full(G_OBJECT(drop), "zg-ids", ids, g_object_unref);
        gtk_box_append(GTK_BOX(row), drop);
        GtkWidget *go = gtk_button_new_with_label("Send");
        gtk_widget_set_sensitive(go, info.status == ZS_PLATE_STATUS_DONE && g_list_model_get_n_items(G_LIST_MODEL(ids)) > 0);
        QueueRow *q = g_new0(QueueRow, 1);
        q->page = p;
        q->plate = (gint64)i;
        q->drop = drop;
        g_signal_connect_data(go, "clicked", G_CALLBACK(on_queue_send), q, (GClosureNotify)(void (*)(void))g_free, 0);
        gtk_box_append(GTK_BOX(row), go);
        gtk_box_append(GTK_BOX(p->queue), row);
    }
    if (!any) gtk_box_append(GTK_BOX(p->queue), gtk_label_new("No plate has parts."));
}

/* ---- the tiles ---- */

static void build(Page *p) {
    GtkFlowBoxChild *child;
    while ((child = gtk_flow_box_get_child_at_index(GTK_FLOW_BOX(p->grid), 0))) gtk_flow_box_remove(GTK_FLOW_BOX(p->grid), GTK_WIDGET(child));
    g_ptr_array_set_size(p->tiles, 0);
    for (guint i = 0; i < zg_printers_count(); i++) {
        ZgPrinter *pr = zg_printers_get(i);
        if (!has_link(pr)) continue;
        Tile *t = g_new0(Tile, 1);
        t->page = p;
        t->id = g_strdup(pr->id);
        t->tile = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
        gtk_widget_add_css_class(t->tile, "card");
        gtk_widget_set_size_request(t->tile, 180, -1);
        GtkWidget *name = gtk_label_new(pr->name);
        gtk_widget_add_css_class(name, "heading");
        gtk_label_set_xalign(GTK_LABEL(name), 0);
        GtkWidget *kind = gtk_label_new(zg_link_titles[pr->kind]);
        gtk_widget_add_css_class(kind, "dim-label");
        gtk_label_set_xalign(GTK_LABEL(kind), 0);
        t->state = gtk_label_new("…");
        gtk_label_set_wrap(GTK_LABEL(t->state), TRUE);
        gtk_label_set_xalign(GTK_LABEL(t->state), 0);
        t->bar = gtk_progress_bar_new();
        gtk_widget_set_visible(t->bar, FALSE);
        t->send = gtk_button_new_with_label("Send the plate");
        gtk_widget_set_tooltip_text(t->send, "Upload the G-code of the active plate, and start it after you confirm that the bed is clear");
        g_signal_connect(t->send, "clicked", G_CALLBACK(on_tile_send), t);
        gtk_box_append(GTK_BOX(t->tile), name);
        gtk_box_append(GTK_BOX(t->tile), kind);
        gtk_box_append(GTK_BOX(t->tile), t->state);
        gtk_box_append(GTK_BOX(t->tile), t->bar);
        gtk_box_append(GTK_BOX(t->tile), t->send);
        gtk_widget_set_margin_start(t->tile, 4);
        gtk_widget_set_margin_end(t->tile, 4);
        gtk_flow_box_append(GTK_FLOW_BOX(p->grid), t->tile);
        g_ptr_array_add(p->tiles, t);
    }
    gtk_label_set_text(GTK_LABEL(p->note), p->tiles->len ? "The tiles read again every 10 s." : "No printer has a connection. Add one in Preferences › Printers: printdeck, OctoPrint, or Moonraker (Klipper).");
    render_queue(p);
}

static void on_map(GtkWidget *w, gpointer data) {
    Page *p = data;
    if (p->cancel) g_cancellable_cancel(p->cancel);
    g_clear_object(&p->cancel);
    p->cancel = g_cancellable_new();
    build(p);
    refresh(p);
    if (!p->timer) p->timer = g_timeout_add_seconds(EVERY_S, on_timer, p);
}

static void on_unmap(GtkWidget *w, gpointer data) {
    Page *p = data;
    if (p->timer) g_source_remove(p->timer);
    p->timer = 0;
    if (p->cancel) g_cancellable_cancel(p->cancel);
}

static void page_free(gpointer data) {
    Page *p = data;
    if (p->timer) g_source_remove(p->timer);
    if (p->cancel) g_cancellable_cancel(p->cancel);
    g_clear_object(&p->cancel);
    g_ptr_array_unref(p->tiles);
    g_free(p);
}

GtkWidget *zg_farm_page_new(ZgModel *model) {
    Page *p = g_new0(Page, 1);
    p->model = model;
    p->tiles = g_ptr_array_new_with_free_func(tile_free);
    p->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(p->box, 12);
    gtk_widget_set_margin_end(p->box, 12);
    gtk_widget_set_margin_top(p->box, 8);
    GtkWidget *title = gtk_label_new("Printers");
    gtk_widget_add_css_class(title, "heading");
    gtk_label_set_xalign(GTK_LABEL(title), 0);
    p->note = gtk_label_new("");
    gtk_widget_add_css_class(p->note, "dim-label");
    gtk_label_set_wrap(GTK_LABEL(p->note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(p->note), 0);
    p->grid = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(p->grid), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(p->grid), 4);
    GtkWidget *qtitle = gtk_label_new("Plates to print");
    gtk_widget_add_css_class(qtitle, "heading");
    gtk_label_set_xalign(GTK_LABEL(qtitle), 0);
    gtk_widget_set_margin_top(qtitle, 10);
    p->queue = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(GTK_BOX(p->box), title);
    gtk_box_append(GTK_BOX(p->box), p->note);
    gtk_box_append(GTK_BOX(p->box), p->grid);
    gtk_box_append(GTK_BOX(p->box), qtitle);
    gtk_box_append(GTK_BOX(p->box), p->queue);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), p->box);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    g_object_set_data_full(G_OBJECT(scroll), "zg-farm", p, page_free);
    g_signal_connect(scroll, "map", G_CALLBACK(on_map), p);
    g_signal_connect(scroll, "unmap", G_CALLBACK(on_unmap), p);
    return scroll;
}
