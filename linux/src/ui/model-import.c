/* model-import.c: see model-import.h. The steps and the rules are in the
 * core (zs_import_* in zslice.h, docs/internals/model-import.md). The
 * network part is net/model-download.c.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "model-import.h"

#include "../net/model-download.h"
#include "window.h"
#include "zslice-app.h"

#include <string.h>

/* The most preview images of one list. */
enum { MAX_PREVIEWS = 40, PREVIEW_SIZE = 64 };

typedef struct {
    GtkWindow *parent;
    GtkWidget *win, *stack;
    /* The page with the address field. */
    GtkWidget *entry, *ask_note, *find, *open_page;
    /* The page with the list. */
    GtkWidget *title, *sub, *note, *rows, *status, *progress, *cancel, *load;
    zs_import_page page;
    zs_import_list *list;
    GBytes *zip;
    char *zip_name;
    GCancellable *cancel_op;
    /* For each file of the list: its check box (or NULL), and its
     * picture (or NULL). */
    GPtrArray *checks, *pictures;
    guint preview_next, previews;
    /* The download: the next file, and the files so far. */
    gboolean loading;
    gsize next;
    guint index, total;
    zs_link link;
    GPtrArray *names, *bytes;
    GString *errors;
    /* The window is gone, and the operations that run. */
    gboolean closed;
    int pending;
} Import;

/* One import at a time. */
static Import *current;

static void import_free(Import *im) {
    if (current == im) current = NULL;
    if (im->list) zs_import_list_free(im->list);
    if (im->zip) g_bytes_unref(im->zip);
    g_free(im->zip_name);
    g_clear_object(&im->cancel_op);
    g_clear_object(&im->parent);
    if (im->checks) g_ptr_array_unref(im->checks);
    if (im->pictures) g_ptr_array_unref(im->pictures);
    if (im->names) g_ptr_array_unref(im->names);
    if (im->bytes) g_ptr_array_unref(im->bytes);
    if (im->errors) g_string_free(im->errors, TRUE);
    g_free(im);
}

/* An operation ended: TRUE if the import goes on. */
static gboolean op_done(Import *im) {
    im->pending--;
    if (im->closed) {
        if (im->pending == 0) import_free(im);
        return FALSE;
    }
    return TRUE;
}

static void on_destroy(GtkWidget *w, gpointer data) {
    Import *im = data;
    im->closed = TRUE;
    if (current == im) current = NULL;
    if (im->cancel_op) g_cancellable_cancel(im->cancel_op);
    if (im->pending == 0) import_free(im);
}

static void close_window(Import *im) {
    if (!im->closed) gtk_window_destroy(GTK_WINDOW(im->win));
}

static GtkWidget *wrap_label(const char *text, const char *css) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(l), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_selectable(GTK_LABEL(l), FALSE);
    if (css) gtk_widget_add_css_class(l, css);
    return l;
}

static void set_status(Import *im, const char *text, gboolean error) {
    gtk_label_set_text(GTK_LABEL(im->status), text);
    if (error)
        gtk_widget_add_css_class(im->status, "error");
    else
        gtk_widget_remove_css_class(im->status, "error");
}

/* ---- the choice ---- */

static void update_sum(Import *im) {
    if (im->loading || !im->list) return;
    size_t files = 0;
    uint64_t bytes = 0;
    int rc = zs_import_ready(im->list, &files, &bytes);
    gtk_widget_set_sensitive(im->load, rc == ZS_IMPORT_OK);
    if (rc != ZS_IMPORT_OK) {
        set_status(im, zs_import_message(rc), rc != ZS_IMPORT_NOTHING_CHECKED);
        return;
    }
    char *size = g_format_size(bytes);
    char *text = g_strdup_printf("%zu %s, %s. zslice downloads the checked files and puts their parts on plates. It does not start a print.",
                                 files, files == 1 ? "file" : "files", size);
    set_status(im, text, FALSE);
    g_free(text);
    g_free(size);
}

static void on_toggled(GtkCheckButton *b, gpointer data) {
    Import *im = data;
    size_t i = GPOINTER_TO_SIZE(g_object_get_data(G_OBJECT(b), "zg-index"));
    zs_import_check(im->list, i, gtk_check_button_get_active(b));
    update_sum(im);
}

/* ---- the preview images ---- */

static void next_preview(Import *im);

static void on_preview(GObject *source, GAsyncResult *res, gpointer data) {
    Import *im = data;
    GError *error = NULL;
    GBytes *bytes = zg_net_request_finish(res, &error);
    if (!op_done(im)) {
        if (bytes) g_bytes_unref(bytes);
        g_clear_error(&error);
        return;
    }
    size_t i = im->preview_next - 1;
    if (bytes) {
        GdkTexture *t = gdk_texture_new_from_bytes(bytes, NULL);
        GtkWidget *pic = g_ptr_array_index(im->pictures, i);
        if (t && pic) gtk_picture_set_paintable(GTK_PICTURE(pic), GDK_PAINTABLE(t));
        g_clear_object(&t);
        g_bytes_unref(bytes);
    }
    g_clear_error(&error);
    next_preview(im);
}

/* The previews load one at a time, after the list shows. A preview that
 * does not load leaves its place empty. */
static void next_preview(Import *im) {
    if (im->loading) return;
    while (im->preview_next < im->pictures->len && im->previews < MAX_PREVIEWS) {
        size_t i = im->preview_next++;
        zs_import_file f;
        if (zs_import_file_get(im->list, i, &f) != ZS_IMPORT_OK || !f.preview[0]) continue;
        zs_link link;
        if (zs_link_check_url(f.preview, &link) != ZS_LINK_OK) continue;
        im->previews++;
        im->pending++;
        zg_net_request(&link, NULL, ZS_IMPORT_MAX_PREVIEW, im->cancel_op, on_preview, im);
        return;
    }
}

/* ---- the list ---- */

static void show_list(Import *im) {
    zs_import_info info;
    zs_import_list_info(im->list, &info);
    const char *title = info.title[0] ? info.title : im->zip_name ? im->zip_name : "The model";
    gtk_label_set_text(GTK_LABEL(im->title), title);
    GString *sub = g_string_new("");
    if (info.author[0]) g_string_append_printf(sub, "By %s", info.author);
    if (info.license[0]) g_string_append_printf(sub, "%sLicense: %s", sub->len ? ". " : "", info.license);
    if (info.page_url[0]) g_string_append_printf(sub, "%sFrom %s", sub->len ? ". " : "", info.page_url);
    if (im->zip_name) g_string_append(sub, "The files of the ZIP file");
    gtk_label_set_text(GTK_LABEL(im->sub), sub->str);
    g_string_free(sub, TRUE);
    gtk_label_set_text(GTK_LABEL(im->note), info.note);
    gtk_widget_set_visible(im->note, info.note[0] != 0);

    size_t n = zs_import_count(im->list);
    im->checks = g_ptr_array_new();
    im->pictures = g_ptr_array_new();
    const char *group = NULL;
    for (size_t i = 0; i < n; i++) {
        zs_import_file f;
        zs_import_file_get(im->list, i, &f);
        if (!group || strcmp(group, f.kind_label) != 0) {
            group = f.kind_label;
            GtkWidget *h = wrap_label(group, "heading");
            gtk_widget_set_margin_top(h, i ? 12 : 0);
            gtk_box_append(GTK_BOX(im->rows), h);
        }
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
        GtkWidget *check = gtk_check_button_new();
        gtk_check_button_set_active(GTK_CHECK_BUTTON(check), f.checked);
        gtk_widget_set_sensitive(check, f.can_load);
        gtk_widget_set_valign(check, GTK_ALIGN_CENTER);
        g_object_set_data(G_OBJECT(check), "zg-index", GSIZE_TO_POINTER(i));
        g_signal_connect(check, "toggled", G_CALLBACK(on_toggled), im);
        gtk_box_append(GTK_BOX(row), check);
        g_ptr_array_add(im->checks, f.can_load ? check : NULL);
        GtkWidget *pic = NULL;
        if (info.site != ZS_IMPORT_SITE_NONE) {
            pic = gtk_picture_new();
            gtk_picture_set_content_fit(GTK_PICTURE(pic), GTK_CONTENT_FIT_CONTAIN);
            gtk_widget_set_size_request(pic, PREVIEW_SIZE, PREVIEW_SIZE);
            gtk_widget_set_valign(pic, GTK_ALIGN_CENTER);
            gtk_box_append(GTK_BOX(row), pic);
        }
        g_ptr_array_add(im->pictures, pic);
        GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        gtk_widget_set_hexpand(text, TRUE);
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER);
        GtkWidget *name = wrap_label(f.name, NULL);
        if (!f.can_load) gtk_widget_add_css_class(name, "dim-label");
        gtk_box_append(GTK_BOX(text), name);
        GString *d = g_string_new(f.kind == ZS_IMPORT_KIND_OTHER ? "" : f.kind_label);
        if (f.size > 0) {
            char *size = g_format_size(f.size);
            g_string_append_printf(d, "%s%s", d->len ? ", " : "", size);
            g_free(size);
        }
        if (f.plates > 1) g_string_append_printf(d, ", %d plates", f.plates);
        if (f.folder[0]) g_string_append_printf(d, ". In the folder %s", f.folder);
        if (f.note[0]) g_string_append_printf(d, "%s%s", d->len ? ". " : "", f.note);
        if (d->len) gtk_box_append(GTK_BOX(text), wrap_label(d->str, "dim-label"));
        g_string_free(d, TRUE);
        gtk_box_append(GTK_BOX(row), text);
        gtk_box_append(GTK_BOX(im->rows), row);
    }
    gtk_stack_set_visible_child_name(GTK_STACK(im->stack), "list");
    update_sum(im);
    gtk_widget_grab_focus(im->cancel);
    next_preview(im);
    if (g_getenv("ZSLICE_IMPORT_YES") && gtk_widget_get_sensitive(im->load)) {
        g_message("zslice: import: %zu files listed; the test answers Load", n);
        g_signal_emit_by_name(im->load, "clicked");
    }
}

static void list_failed(Import *im, const char *text) {
    gtk_stack_set_visible_child_name(GTK_STACK(im->stack), "ask");
    gtk_label_set_text(GTK_LABEL(im->ask_note), text);
    gtk_widget_add_css_class(im->ask_note, "error");
    gtk_widget_set_sensitive(im->find, TRUE);
    gtk_widget_set_sensitive(im->entry, TRUE);
}

static void on_files(GObject *source, GAsyncResult *res, gpointer data) {
    Import *im = data;
    GError *error = NULL;
    GBytes *bytes = zg_net_request_finish(res, &error);
    if (!op_done(im)) {
        if (bytes) g_bytes_unref(bytes);
        g_clear_error(&error);
        return;
    }
    if (!bytes) {
        list_failed(im, error->message);
        g_error_free(error);
        return;
    }
    gsize len = 0;
    const char *json = g_bytes_get_data(bytes, &len);
    int rc = zs_import_list_read(&im->page, json, len, &im->list);
    g_bytes_unref(bytes);
    if (rc != ZS_IMPORT_OK) {
        list_failed(im, zs_import_message(rc));
        return;
    }
    show_list(im);
}

/* Asks the site for the files of the model of im->page. */
static void find_files(Import *im) {
    if (im->page.site == ZS_IMPORT_SITE_THINGIVERSE) {
        gtk_stack_set_visible_child_name(GTK_STACK(im->stack), "ask");
        gtk_label_set_text(GTK_LABEL(im->ask_note), zs_import_message(ZS_IMPORT_NO_API));
        gtk_widget_remove_css_class(im->ask_note, "error");
        gtk_widget_set_visible(im->open_page, TRUE);
        gtk_widget_set_visible(im->find, FALSE);
        return;
    }
    size_t len = 0;
    if (zs_import_files_request(&im->page, NULL, 0, &len) != ZS_IMPORT_OK) return;
    char *body = g_malloc(len + 1);
    zs_import_files_request(&im->page, body, len + 1, NULL);
    zs_link api;
    if (zs_link_check_url(zs_import_api_url(im->page.site), &api) != ZS_LINK_OK) {
        g_free(body);
        return;
    }
    gtk_label_set_text(GTK_LABEL(im->ask_note), "Reading the list of files…");
    gtk_widget_remove_css_class(im->ask_note, "error");
    gtk_widget_set_sensitive(im->find, FALSE);
    gtk_widget_set_sensitive(im->entry, FALSE);
    im->pending++;
    zg_net_request(&api, body, ZS_IMPORT_MAX_ANSWER, im->cancel_op, on_files, im);
    g_free(body);
}

/* ---- the download ---- */

static void next_file(Import *im);

static void load_done(Import *im) {
    guint n = im->names->len;
    int plates = 0;
    if (n > 0) plates = zg_window_add_import(im->parent, (char **)im->names->pdata, (GBytes **)im->bytes->pdata, n, im->errors);
    zg_window_show_progress(im->parent, "", 0);
    if (im->errors->len) {
        char *head = n > 0 ? g_strdup_printf("%u of %u files loaded", n, im->total) : g_strdup("No file loaded");
        zg_window_show_error(im->parent, head, im->errors->str);
        g_free(head);
    } else if (n > 0) {
        char *text = g_strdup_printf("%u %s on %d %s.", n, n == 1 ? "file" : "files", plates, plates == 1 ? "plate" : "plates");
        zg_window_show_progress(im->parent, text, 0);
        g_free(text);
    }
    if (g_getenv("ZSLICE_IMPORT_YES")) g_message("zslice: import: %u files loaded on %d plates; %s", n, plates, im->errors->len ? im->errors->str : "no errors");
    close_window(im);
}

static void add_file(Import *im, const char *name, GBytes *bytes) {
    g_ptr_array_add(im->names, g_strdup(name));
    g_ptr_array_add(im->bytes, bytes);
}

static void file_error(Import *im, const char *name, const char *text) {
    g_string_append_printf(im->errors, "%s: %s\n", name, text);
}

static void on_progress(double fraction, gpointer data) {
    Import *im = data;
    if (im->closed) return;
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(im->progress), (im->index - 1 + fraction) / MAX(im->total, 1));
}

static void on_file(GObject *source, GAsyncResult *res, gpointer data) {
    Import *im = data;
    char *name = NULL;
    GError *error = NULL;
    GBytes *bytes = zg_model_download_finish(res, &name, &error);
    if (!op_done(im)) {
        if (bytes) g_bytes_unref(bytes);
        g_clear_error(&error);
        g_free(name);
        return;
    }
    if (bytes)
        add_file(im, name, bytes);
    else
        file_error(im, im->link.name, error->message);
    g_clear_error(&error);
    g_free(name);
    next_file(im);
}

static void on_link(GObject *source, GAsyncResult *res, gpointer data) {
    Import *im = data;
    GError *error = NULL;
    GBytes *answer = zg_net_request_finish(res, &error);
    if (!op_done(im)) {
        if (answer) g_bytes_unref(answer);
        g_clear_error(&error);
        return;
    }
    zs_import_file f;
    zs_import_file_get(im->list, im->next - 1, &f);
    if (!answer) {
        file_error(im, f.name, error->message);
        g_error_free(error);
        next_file(im);
        return;
    }
    gsize len = 0;
    const char *json = g_bytes_get_data(answer, &len);
    int rc = zs_import_link_read(im->list, im->next - 1, json, len, &im->link);
    g_bytes_unref(answer);
    if (rc != ZS_IMPORT_OK) {
        file_error(im, f.name, zs_import_message(rc));
        next_file(im);
        return;
    }
    im->pending++;
    zg_model_download(&im->link, im->cancel_op, on_progress, on_file, im);
}

/* The next checked file: one at a time, in the order of the list. */
static void next_file(Import *im) {
    size_t n = zs_import_count(im->list);
    while (im->next < n) {
        size_t i = im->next++;
        zs_import_file f;
        if (zs_import_file_get(im->list, i, &f) != ZS_IMPORT_OK || !f.checked) continue;
        im->index++;
        char *text = g_strdup_printf("File %u of %u: %s", im->index, im->total, f.name);
        set_status(im, text, FALSE);
        g_free(text);
        gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(im->progress), (im->index - 1) / (double)MAX(im->total, 1));
        if (im->zip) {
            gsize len = 0;
            const uint8_t *zip = g_bytes_get_data(im->zip, &len);
            uint8_t *out = NULL;
            size_t out_len = 0;
            if (zs_import_zip_file(im->list, zip, len, i, &out, &out_len) != ZS_IMPORT_OK) {
                file_error(im, f.name, zs_import_message(ZS_IMPORT_NOT_ZIP));
                continue;
            }
            if (zs_project_file_is(out, out_len)) {
                file_error(im, f.name, zs_link_message(ZS_LINK_PROJECT));
                zs_buffer_free(out, out_len);
                continue;
            }
            add_file(im, f.name, g_bytes_new(out, out_len));
            zs_buffer_free(out, out_len);
            continue;
        }
        size_t len = 0;
        if (zs_import_link_request(im->list, i, NULL, 0, &len) != ZS_IMPORT_OK) {
            file_error(im, f.name, zs_import_message(ZS_IMPORT_NO_API));
            continue;
        }
        char *body = g_malloc(len + 1);
        zs_import_link_request(im->list, i, body, len + 1, NULL);
        zs_link api;
        zs_link_check_url(zs_import_api_url(im->page.site), &api);
        im->pending++;
        zg_net_request(&api, body, ZS_IMPORT_MAX_ANSWER, im->cancel_op, on_link, im);
        g_free(body);
        return;
    }
    load_done(im);
}

static void on_load(GtkButton *b, gpointer data) {
    Import *im = data;
    size_t files = 0;
    if (zs_import_ready(im->list, &files, NULL) != ZS_IMPORT_OK) return;
    im->loading = TRUE;
    im->total = (guint)files;
    im->names = g_ptr_array_new_with_free_func(g_free);
    im->bytes = g_ptr_array_new_with_free_func((GDestroyNotify)g_bytes_unref);
    im->errors = g_string_new("");
    for (guint i = 0; i < im->checks->len; i++) {
        GtkWidget *c = g_ptr_array_index(im->checks, i);
        if (c) gtk_widget_set_sensitive(c, FALSE);
    }
    gtk_widget_set_sensitive(im->load, FALSE);
    gtk_widget_set_visible(im->progress, TRUE);
    next_file(im);
}

static void on_cancel(GtkButton *b, gpointer data) {
    close_window(data);
}

/* ---- the address ---- */

static void on_find(GtkWidget *w, gpointer data) {
    Import *im = data;
    const char *text = gtk_editable_get_text(GTK_EDITABLE(im->entry));
    gtk_widget_set_visible(im->open_page, FALSE);
    gtk_widget_set_visible(im->find, TRUE);
    if (zs_import_page_check(text, &im->page) != ZS_IMPORT_OK) {
        list_failed(im, zs_import_message(ZS_IMPORT_NOT_A_PAGE));
        return;
    }
    find_files(im);
}

/* A new address: the List button comes back. */
static void on_entry_changed(GtkEditable *e, gpointer data) {
    Import *im = data;
    gtk_widget_set_visible(im->open_page, FALSE);
    gtk_widget_set_visible(im->find, TRUE);
}

static void on_open_page(GtkButton *b, gpointer data) {
    Import *im = data;
    GtkUriLauncher *l = gtk_uri_launcher_new(im->page.url);
    gtk_uri_launcher_launch(l, GTK_WINDOW(im->win), NULL, NULL, NULL);
    g_object_unref(l);
    close_window(im);
}

static void on_clipboard(GObject *source, GAsyncResult *res, gpointer data) {
    Import *im = data;
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), res, NULL);
    if (op_done(im) && text && !gtk_editable_get_text(GTK_EDITABLE(im->entry))[0]) {
        zs_import_page p;
        if (zs_import_page_check(text, &p) == ZS_IMPORT_OK) gtk_editable_set_text(GTK_EDITABLE(im->entry), text);
    }
    g_free(text);
}

static GtkWidget *button_bar(GtkWidget **cancel, GtkWidget **go, const char *go_label, Import *im, GCallback go_fn) {
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(bar, GTK_ALIGN_END);
    *cancel = gtk_button_new_with_label("Cancel");
    g_signal_connect(*cancel, "clicked", G_CALLBACK(on_cancel), im);
    *go = gtk_button_new_with_label(go_label);
    gtk_widget_add_css_class(*go, "suggested-action");
    g_signal_connect(*go, "clicked", go_fn, im);
    gtk_box_append(GTK_BOX(bar), *cancel);
    gtk_box_append(GTK_BOX(bar), *go);
    return bar;
}

static Import *import_new(GtkWindow *parent) {
    if (current) {
        zg_window_show_error(parent, "The import did not start", "Finish the import that is open, then try this one.");
        return NULL;
    }
    Import *im = g_new0(Import, 1);
    current = im;
    im->parent = g_object_ref(parent);
    im->cancel_op = g_cancellable_new();
    im->win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(im->win), "Import a model");
    gtk_window_set_transient_for(GTK_WINDOW(im->win), parent);
    gtk_window_set_modal(GTK_WINDOW(im->win), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(im->win), 620, -1);
    g_signal_connect(im->win, "destroy", G_CALLBACK(on_destroy), im);
    im->stack = gtk_stack_new();
    gtk_stack_set_vhomogeneous(GTK_STACK(im->stack), FALSE);

    /* The address. */
    GtkWidget *ask = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_box_append(GTK_BOX(ask), wrap_label("Paste the address of a model page on Printables or Thingiverse.", "title-4"));
    im->entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(im->entry), "https://www.printables.com/model/…");
    gtk_widget_set_hexpand(im->entry, TRUE);
    g_signal_connect(im->entry, "activate", G_CALLBACK(on_find), im);
    g_signal_connect(im->entry, "changed", G_CALLBACK(on_entry_changed), im);
    gtk_box_append(GTK_BOX(ask), im->entry);
    im->ask_note = wrap_label("zslice reads the list of files of the model. You choose the files to load next.", "dim-label");
    gtk_box_append(GTK_BOX(ask), im->ask_note);
    GtkWidget *ask_cancel;
    GtkWidget *ask_bar = button_bar(&ask_cancel, &im->find, "List the files", im, G_CALLBACK(on_find));
    im->open_page = gtk_button_new_with_label("Open the page");
    gtk_widget_add_css_class(im->open_page, "suggested-action");
    gtk_widget_set_visible(im->open_page, FALSE);
    g_signal_connect(im->open_page, "clicked", G_CALLBACK(on_open_page), im);
    gtk_box_insert_child_after(GTK_BOX(ask_bar), im->open_page, ask_cancel);
    gtk_box_append(GTK_BOX(ask), ask_bar);
    gtk_stack_add_named(GTK_STACK(im->stack), ask, "ask");

    /* The list. */
    GtkWidget *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    im->title = wrap_label("", "title-3");
    im->sub = wrap_label("", "dim-label");
    im->note = wrap_label("", NULL);
    gtk_widget_set_visible(im->note, FALSE);
    im->rows = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_top(im->rows, 6);
    gtk_widget_set_margin_bottom(im->rows, 6);
    gtk_widget_set_margin_end(im->rows, 12);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), im->rows);
    gtk_widget_set_vexpand(scroll, TRUE);
    /* The list grows with its rows up to a height that leaves the buttons
     * on a small screen. */
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 360);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroll), 420);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroll), TRUE);
    im->status = wrap_label("", NULL);
    im->progress = gtk_progress_bar_new();
    gtk_widget_set_visible(im->progress, FALSE);
    GtkWidget *bar = button_bar(&im->cancel, &im->load, "Download and load", im, G_CALLBACK(on_load));
    gtk_box_append(GTK_BOX(list), im->title);
    gtk_box_append(GTK_BOX(list), im->sub);
    gtk_box_append(GTK_BOX(list), im->note);
    gtk_box_append(GTK_BOX(list), scroll);
    gtk_box_append(GTK_BOX(list), im->status);
    gtk_box_append(GTK_BOX(list), im->progress);
    gtk_box_append(GTK_BOX(list), bar);
    gtk_stack_add_named(GTK_STACK(im->stack), list, "list");

    gtk_widget_set_margin_start(im->stack, 18);
    gtk_widget_set_margin_end(im->stack, 18);
    gtk_widget_set_margin_top(im->stack, 18);
    gtk_widget_set_margin_bottom(im->stack, 18);
    gtk_window_set_child(GTK_WINDOW(im->win), im->stack);
    return im;
}

void zg_model_import_ask(GtkWindow *window, const char *text) {
    Import *im = import_new(window);
    if (!im) return;
    gtk_stack_set_visible_child_name(GTK_STACK(im->stack), "ask");
    if (text && *text) {
        gtk_editable_set_text(GTK_EDITABLE(im->entry), text);
    } else {
        im->pending++;
        gdk_clipboard_read_text_async(gtk_widget_get_clipboard(im->win), im->cancel_op, on_clipboard, im);
    }
    gtk_window_present(GTK_WINDOW(im->win));
    gtk_widget_grab_focus(im->entry);
    /* For tests: ZSLICE_IMPORT_LIST lists the files of the address at once.
     * ZSLICE_IMPORT_YES also presses Download and load. */
    if (text && *text && (g_getenv("ZSLICE_IMPORT_YES") || g_getenv("ZSLICE_IMPORT_LIST"))) on_find(im->entry, im);
}

void zg_model_import_page(GtkWindow *window, const zs_import_page *page) {
    Import *im = import_new(window);
    if (!im) return;
    im->page = *page;
    gtk_editable_set_text(GTK_EDITABLE(im->entry), page->url);
    gtk_stack_set_visible_child_name(GTK_STACK(im->stack), "ask");
    gtk_window_present(GTK_WINDOW(im->win));
    find_files(im);
}

void zg_model_import_zip(GtkWindow *window, const char *name, GBytes *bytes) {
    gsize len = 0;
    const uint8_t *data = g_bytes_get_data(bytes, &len);
    zs_import_list *list = NULL;
    int rc = zs_import_list_zip(data, len, &list);
    if (rc != ZS_IMPORT_OK) {
        zg_window_show_error(window, "The ZIP file did not open", zs_import_message(rc));
        return;
    }
    Import *im = import_new(window);
    if (!im) {
        zs_import_list_free(list);
        return;
    }
    im->list = list;
    im->zip = g_bytes_ref(bytes);
    im->zip_name = g_strdup(name);
    gtk_window_present(GTK_WINDOW(im->win));
    show_list(im);
}

void zg_model_import_cancel(void) {
    if (current) close_window(current);
}
