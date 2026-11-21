/* open-link.c: see open-link.h. The rules are in the core (zs_link_* in
 * zslice.h, docs/internals/open-links.md).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "open-link.h"

#include "../net/model-download.h"
#include "window.h"
#include "zslice.h"

/* One link at a time: the dialog or the download. */
static gboolean busy;
static GCancellable *cancel;

typedef struct {
    GtkWindow *window;
    zs_link link;
    char *shown;
} Ask;

static void ask_free(Ask *a) {
    g_object_unref(a->window);
    g_free(a->shown);
    g_free(a);
}

static void on_progress(double fraction, gpointer data) {
    Ask *a = data;
    if (!cancel) return;
    char *text = g_strdup_printf("Downloading %s… %d%%", a->shown, (int)(fraction * 100));
    zg_window_show_progress(a->window, text, fraction);
    g_free(text);
}

static void on_downloaded(GObject *source, GAsyncResult *res, gpointer data) {
    Ask *a = data;
    char *name = NULL;
    GError *error = NULL;
    GBytes *bytes = zg_model_download_finish(res, &name, &error);
    g_clear_object(&cancel);
    busy = FALSE;
    zg_window_show_progress(a->window, "", 0);
    if (bytes) {
        zg_window_open_bytes(a->window, name, bytes);
        g_bytes_unref(bytes);
    } else if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
        zg_window_show_error(a->window, "The model did not download", error->message);
    }
    g_clear_error(&error);
    g_free(name);
    ask_free(a);
}

static void on_answer(GObject *source, GAsyncResult *res, gpointer data) {
    Ask *a = data;
    int button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), res, NULL);
    if (button != 1) {
        busy = FALSE;
        ask_free(a);
        return;
    }
    cancel = g_cancellable_new();
    char *text = g_strdup_printf("Downloading %s…", a->shown);
    zg_window_show_progress(a->window, text, 0);
    g_free(text);
    zg_model_download(&a->link, cancel, on_progress, on_downloaded, a);
}

void zg_open_link(GtkWindow *window, const char *uri) {
    Ask *a = g_new0(Ask, 1);
    int rc = zs_link_check(uri, &a->link);
    if (rc != ZS_LINK_OK) {
        g_free(a);
        zg_window_show_error(window, "This link did not open", zs_link_message(rc));
        return;
    }
    if (busy) {
        g_free(a);
        zg_window_show_error(window, "This link did not open", "Finish the link that is open, then try this one.");
        return;
    }
    busy = TRUE;
    a->window = g_object_ref(window);
    a->shown = g_strdup(a->link.name[0] ? a->link.name : "the model");
    GtkAlertDialog *dialog = gtk_alert_dialog_new("Open this model?");
    char *detail = g_strdup_printf("%s\nFrom %s\n\nzslice downloads the file and opens it on a new plate. It does not start a print.",
                                   a->link.name[0] ? a->link.name : "A model file", a->link.host);
    gtk_alert_dialog_set_detail(dialog, detail);
    g_free(detail);
    const char *buttons[] = {"Cancel", "Download and open", NULL};
    gtk_alert_dialog_set_buttons(dialog, buttons);
    gtk_alert_dialog_set_cancel_button(dialog, 0);
    /* Enter must not start a download that the user did not read. */
    gtk_alert_dialog_set_default_button(dialog, 0);
    gtk_alert_dialog_choose(dialog, window, NULL, on_answer, a);
    g_object_unref(dialog);
}

void zg_open_link_cancel(void) {
    if (cancel) g_cancellable_cancel(cancel);
}
