/* pair-dialog.c: see pair-dialog.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "pair-dialog.h"

#include "../net/printer-link.h"
#include "../net/signing.h"
#include "../prefs/printers.h"

#include <string.h>

typedef struct {
    GtkWidget *win, *text, *count, *list, *again, *close, *add;
    ZgModel *model;
    char *id;
    char *key;
    GCancellable *cancel;
    GPtrArray *checks; /* GtkCheckButton, with "zg-deck" data */
    gboolean ok, closed;
    void (*done)(gboolean ok, gpointer data);
    gpointer data;
} Pair;

static void pair_free(Pair *p) {
    g_free(p->id);
    g_free(p->key);
    g_clear_object(&p->cancel);
    if (p->checks) g_ptr_array_unref(p->checks);
    g_free(p);
}

static void start(Pair *p);

static void on_wait(int seconds, gpointer data) {
    Pair *p = data;
    if (p->closed) return;
    char *m = g_strdup_printf("Waiting for Allow: %d s left.", MAX(0, 120 - seconds));
    gtk_label_set_text(GTK_LABEL(p->count), m);
    g_free(m);
}

static void on_add(GtkButton *b, gpointer data) {
    Pair *p = data;
    ZgPrinter *deck = zg_printers_find(p->id);
    if (!deck) return;
    char *base = g_strdup(deck->url);
    gsize n = strlen(base);
    while (n > 0 && base[n - 1] == '/') base[--n] = 0;
    char *from = zg_printer_profile_path(deck);
    for (guint i = 0; i < p->checks->len; i++) {
        GtkWidget *cb = g_ptr_array_index(p->checks, i);
        if (!gtk_check_button_get_active(GTK_CHECK_BUTTON(cb))) continue;
        const char *name = g_object_get_data(G_OBJECT(cb), "zg-name");
        const char *path = g_object_get_data(G_OBJECT(cb), "zg-path");
        ZgPrinter *pr = zg_printers_add(name);
        pr->kind = ZG_LINK_PRINTDECK;
        g_free(pr->url);
        pr->url = g_strconcat(base, path, NULL);
        g_free(pr->api_key);
        pr->api_key = g_strdup(p->key);
        /* The machine settings of the deck to start with. */
        char *to = zg_printer_profile_path(pr);
        char *dir = g_path_get_dirname(to);
        g_mkdir_with_parents(dir, 0700);
        GFile *f = g_file_new_for_path(from), *t = g_file_new_for_path(to);
        g_file_copy(f, t, G_FILE_COPY_NONE, NULL, NULL, NULL, NULL);
        g_object_unref(f);
        g_object_unref(t);
        g_free(dir);
        g_free(to);
    }
    g_free(from);
    g_free(base);
    zg_printers_save();
    zg_model_printers_edited(p->model);
    gtk_window_destroy(GTK_WINDOW(p->win));
}

static void on_deck(GPtrArray *printers, const char *error, gpointer data) {
    Pair *p = data;
    if (p->closed || !printers) return;
    p->checks = g_ptr_array_new();
    for (guint i = 0; i < printers->len; i++) {
        ZgDeckPrinter *d = g_ptr_array_index(printers, i);
        /* The first printer is the deck itself; resin is not sliced here. */
        if (!d->path[0] || g_strcmp0(d->kind, "resin") == 0) continue;
        char *name = d->label && g_strcmp0(d->label, d->name) != 0 ? g_strdup_printf("%s (%s)", d->name, d->label) : g_strdup(d->name);
        gboolean have = FALSE;
        for (guint k = 0; k < zg_printers_count(); k++) {
            if (g_strcmp0(zg_printers_get(k)->name, name) == 0) have = TRUE;
        }
        GtkWidget *cb = gtk_check_button_new_with_label(name);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(cb), !have);
        g_object_set_data_full(G_OBJECT(cb), "zg-name", name, g_free);
        g_object_set_data_full(G_OBJECT(cb), "zg-path", g_strdup(d->path), g_free);
        gtk_box_append(GTK_BOX(p->list), cb);
        g_ptr_array_add(p->checks, cb);
    }
    if (p->checks->len == 0) return;
    ZgPrinter *deck = zg_printers_find(p->id);
    char *m = g_strdup_printf("Connected to %s. The deck drives more printers: pick the ones to add.", deck ? deck->name : "the deck");
    gtk_label_set_text(GTK_LABEL(p->text), m);
    g_free(m);
    gtk_widget_set_visible(p->list, TRUE);
    gtk_widget_set_visible(p->add, TRUE);
}

static void on_key(gboolean ok, const char *key, const char *message, gpointer data) {
    Pair *p = data;
    if (p->closed) return;
    gtk_label_set_text(GTK_LABEL(p->count), "");
    ZgPrinter *pr = zg_printers_find(p->id);
    if (!ok || !pr) {
        gtk_label_set_text(GTK_LABEL(p->text), message ? message : "No key came.");
        gtk_widget_add_css_class(p->text, "error");
        gtk_widget_set_visible(p->again, TRUE);
        return;
    }
    p->ok = TRUE;
    g_free(p->key);
    p->key = g_strdup(key);
    g_free(pr->api_key);
    pr->api_key = g_strdup(key);
    zg_printers_save();
    zg_model_printers_edited(p->model);
    char *m = g_strdup_printf("Connected to %s.", pr->name);
    gtk_label_set_text(GTK_LABEL(p->text), m);
    g_free(m);
    gtk_button_set_label(GTK_BUTTON(p->close), "Close");
    if (pr->kind == ZG_LINK_PRINTDECK) zg_link_deck_printers(pr, p->cancel, on_deck, p);
}

static void start(Pair *p) {
    ZgPrinter *pr = zg_printers_find(p->id);
    if (!pr) return;
    gtk_widget_set_visible(p->again, FALSE);
    gtk_widget_remove_css_class(p->text, "error");
    const char *key_id = pr->kind == ZG_LINK_PRINTDECK ? zg_signing_key_id() : NULL;
    char *m = pr->kind == ZG_LINK_PRINTDECK
                  ? (key_id ? g_strdup_printf("Tap Allow on the screen of the printdeck, and check that it shows the key %s.", key_id)
                            : g_strdup("Tap Allow on the screen of the printdeck."))
                  : g_strdup("Allow zslice in the web page of OctoPrint: it shows a request for zslice.");
    gtk_label_set_text(GTK_LABEL(p->text), m);
    g_free(m);
    gtk_label_set_text(GTK_LABEL(p->count), "Waiting for Allow: 120 s left.");
    if (p->cancel) g_cancellable_cancel(p->cancel);
    g_clear_object(&p->cancel);
    p->cancel = g_cancellable_new();
    zg_link_request_key(pr, p->cancel, on_wait, on_key, p);
}

static void on_again(GtkButton *b, gpointer data) {
    start(data);
}

static void on_close(GtkButton *b, gpointer data) {
    Pair *p = data;
    gtk_window_destroy(GTK_WINDOW(p->win));
}

static void on_destroy(GtkWidget *w, gpointer data) {
    Pair *p = data;
    p->closed = TRUE;
    if (p->cancel) g_cancellable_cancel(p->cancel);
    if (p->done) p->done(p->ok, p->data);
    /* A request in flight sees `closed`: its callback frees nothing. The
     * cancel ends it, and the struct goes after a short wait. */
    g_timeout_add_seconds_once(3, (GSourceOnceFunc)pair_free, p);
}

void zg_pair_dialog_show(GtkWindow *parent, ZgModel *model, const char *printer_id, void (*done)(gboolean ok, gpointer data),
                         gpointer data) {
    ZgPrinter *pr = zg_printers_find(printer_id);
    if (!pr || (pr->kind != ZG_LINK_PRINTDECK && pr->kind != ZG_LINK_OCTOPRINT)) {
        if (done) done(FALSE, data);
        return;
    }
    Pair *p = g_new0(Pair, 1);
    p->model = model;
    p->id = g_strdup(printer_id);
    p->done = done;
    p->data = data;
    p->win = gtk_window_new();
    char *title = g_strdup_printf("Connect to %s", pr->name);
    gtk_window_set_title(GTK_WINDOW(p->win), title);
    g_free(title);
    if (parent) gtk_window_set_transient_for(GTK_WINDOW(p->win), parent);
    gtk_window_set_modal(GTK_WINDOW(p->win), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(p->win), 440, -1);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_start(box, 18);
    gtk_widget_set_margin_end(box, 18);
    gtk_widget_set_margin_top(box, 18);
    gtk_widget_set_margin_bottom(box, 18);
    p->text = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(p->text), TRUE);
    gtk_label_set_xalign(GTK_LABEL(p->text), 0);
    gtk_label_set_max_width_chars(GTK_LABEL(p->text), 44);
    gtk_widget_add_css_class(p->text, "title-4");
    p->count = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->count), 0);
    gtk_widget_add_css_class(p->count, "dim-label");
    p->list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_visible(p->list, FALSE);
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(bar, GTK_ALIGN_END);
    p->again = gtk_button_new_with_label("Try again");
    gtk_widget_set_visible(p->again, FALSE);
    g_signal_connect(p->again, "clicked", G_CALLBACK(on_again), p);
    p->close = gtk_button_new_with_label("Cancel");
    g_signal_connect(p->close, "clicked", G_CALLBACK(on_close), p);
    p->add = gtk_button_new_with_label("Add");
    gtk_widget_add_css_class(p->add, "suggested-action");
    gtk_widget_set_visible(p->add, FALSE);
    g_signal_connect(p->add, "clicked", G_CALLBACK(on_add), p);
    gtk_box_append(GTK_BOX(bar), p->again);
    gtk_box_append(GTK_BOX(bar), p->close);
    gtk_box_append(GTK_BOX(bar), p->add);
    gtk_box_append(GTK_BOX(box), p->text);
    gtk_box_append(GTK_BOX(box), p->count);
    gtk_box_append(GTK_BOX(box), p->list);
    gtk_box_append(GTK_BOX(box), bar);
    gtk_window_set_child(GTK_WINDOW(p->win), box);
    g_signal_connect(p->win, "destroy", G_CALLBACK(on_destroy), p);
    gtk_window_present(GTK_WINDOW(p->win));
    start(p);
}
