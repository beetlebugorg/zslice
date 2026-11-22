/* preferences.c: see preferences.h.
 *
 * Printers: a list on the left, and the form of the selected printer on
 * the right: its name, its connection, a test of the connection, and what
 * the printer tells (the bed, the nozzle, the filament in it). "Use these
 * values" copies the bed and the nozzle to the machine settings, and "Use
 * this filament" the filament of the printer to the filament settings.
 *
 * General: the theme, the first view, the slicer threads, the draft slices,
 * the print as it forms after each slice, and the folder of the settings
 * files.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "preferences.h"

#include <math.h>
#include <string.h>

#include "../net/bambu-link.h"
#include "../net/printer-link.h"
#include "../net/signing.h"
#include "../prefs/printers.h"

typedef struct {
    GtkWindow *window;
    ZgModel *model;
    GtkWidget *list;
    GtkWidget *remove;
    /* The form of the selected printer. */
    ZgPrinter *printer;
    gboolean filling;
    GtkWidget *name, *kind, *url, *api_key, *device, *baud;
    GtkWidget *url_row[2], *key_row[2], *usb_row[4];
    /* Bambu Lab: the serial number, and its read from the printer. */
    GtkWidget *serial, *serial_row[2], *find_serial;
    ZgBambuWatch *bambu_test;
    GtkWidget *use, *test, *result, *use_machine, *use_filament;
    /* "Get a key": the button, and the request while the printer waits
     * for its user. */
    GtkWidget *get_key;
    GtkWidget *trust; /* verified or not verified (trust_text) */
    GCancellable *key_cancel;
    GCancellable *cancel;
    ZgPrinterInfo *info;
} Prefs;

static const int bauds[] = {250000, 115200, 230400, 500000, 1000000, 57600};

/* ---- the list ---- */

static void fill_form(Prefs *p);

static void fill_list(Prefs *p) {
    p->filling = TRUE;
    gtk_list_box_remove_all(GTK_LIST_BOX(p->list));
    ZgPrinter *cur = zg_printers_current();
    for (guint i = 0; i < zg_printers_count(); i++) {
        ZgPrinter *pr = zg_printers_get(i);
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_set_margin_start(box, 8);
        gtk_widget_set_margin_end(box, 8);
        gtk_widget_set_margin_top(box, 6);
        gtk_widget_set_margin_bottom(box, 6);
        GtkWidget *names = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_hexpand(names, TRUE);
        GtkWidget *name = gtk_label_new(pr->name);
        gtk_label_set_xalign(GTK_LABEL(name), 0);
        gtk_label_set_wrap(GTK_LABEL(name), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(name), PANGO_WRAP_WORD);
        gboolean unverified = pr->kind == ZG_LINK_OCTOPRINT || pr->kind == ZG_LINK_MOONRAKER;
        char *kind_text = g_strdup_printf("%s%s", zg_link_titles[pr->kind], unverified ? " · not verified" : "");
        GtkWidget *kind = gtk_label_new(kind_text);
        g_free(kind_text);
        gtk_label_set_xalign(GTK_LABEL(kind), 0);
        gtk_widget_add_css_class(kind, "dim-label");
        gtk_widget_add_css_class(kind, "caption");
        gtk_box_append(GTK_BOX(names), name);
        gtk_box_append(GTK_BOX(names), kind);
        gtk_box_append(GTK_BOX(box), names);
        if (pr == cur) {
            GtkWidget *check = gtk_image_new_from_icon_name("object-select-symbolic");
            gtk_widget_set_tooltip_text(check, "The current printer");
            gtk_box_append(GTK_BOX(box), check);
        }
        GtkWidget *row = gtk_list_box_row_new();
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
        g_object_set_data_full(G_OBJECT(row), "zg-id", g_strdup(pr->id), g_free);
        gtk_list_box_append(GTK_LIST_BOX(p->list), row);
        if (p->printer == pr || (!p->printer && pr == cur)) gtk_list_box_select_row(GTK_LIST_BOX(p->list), GTK_LIST_BOX_ROW(row));
    }
    gtk_widget_set_sensitive(p->remove, zg_printers_count() > 1);
    p->filling = FALSE;
}

static void on_row_selected(GtkListBox *box, GtkListBoxRow *row, gpointer data) {
    Prefs *p = data;
    if (!row) return;
    ZgPrinter *pr = zg_printers_find(g_object_get_data(G_OBJECT(row), "zg-id"));
    if (!pr || pr == p->printer) return;
    p->printer = pr;
    fill_form(p);
}

static void on_add(GtkButton *b, gpointer data) {
    Prefs *p = data;
    p->printer = zg_printers_add("New printer");
    fill_list(p);
    fill_form(p);
    gtk_widget_grab_focus(p->name);
}

static void on_remove(GtkButton *b, gpointer data) {
    Prefs *p = data;
    if (!p->printer || zg_printers_count() <= 1) return;
    gboolean was_current = p->printer == zg_printers_current();
    zg_printers_remove(p->printer->id);
    p->printer = NULL;
    if (was_current) zg_model_use_printer(p->model, zg_printers_current()->id);
    fill_list(p);
    p->printer = zg_printers_current();
    fill_form(p);
    zg_model_printers_edited(p->model);
}

/* ---- the form ---- */

/* The line about the trust of a printer: printdeck checks the signatures
 * of the prints (with "Signed prints only" on the deck), and zslice
 * checks the certificate of an https deck. OctoPrint and Moonraker check
 * no signatures. NULL for USB and no connection. */
static const char *trust_text(const ZgPrinter *pr) {
    switch (pr->kind) {
    case ZG_LINK_PRINTDECK:
        if (g_str_has_prefix(pr->url, "https://"))
            return "Verified: zslice checks the certificate of the deck, and signs each print. "
                   "Turn on Settings › Signed prints on the deck to stop prints from other apps.";
        return "zslice signs each print, and the deck can check it (Settings › Signed prints). "
               "The address is http, so zslice cannot verify the deck: use its https address (on the System page of the deck).";
    case ZG_LINK_OCTOPRINT:
    case ZG_LINK_MOONRAKER:
        return "Not verified: this printer does not check the signatures of prints. Anyone with its key can send it a file.";
    case ZG_LINK_BAMBU:
        return "Read only: zslice reads the status and the camera of the printer, and sends it nothing. Turn on LAN Only Mode on the printer "
               "(and LAN Only Liveview for the camera). The access code is on its screen; zslice keeps it in the folder bambu of its "
               "settings, readable only by you.";
    default:
        return NULL;
    }
}

static void show_rows(Prefs *p) {
    ZgLinkKind k = p->printer->kind;
    const char *trust = trust_text(p->printer);
    gtk_label_set_text(GTK_LABEL(p->trust), trust ? trust : "");
    gtk_widget_set_visible(p->trust, trust != NULL);
    gboolean bambu = k == ZG_LINK_BAMBU;
    gboolean net = k == ZG_LINK_PRINTDECK || k == ZG_LINK_OCTOPRINT || k == ZG_LINK_MOONRAKER || bambu;
    gboolean key = k == ZG_LINK_PRINTDECK || k == ZG_LINK_OCTOPRINT || bambu;
    for (int i = 0; i < 2; i++) gtk_widget_set_visible(p->url_row[i], net);
    for (int i = 0; i < 2; i++) gtk_widget_set_visible(p->key_row[i], key);
    for (int i = 0; i < 2; i++) gtk_widget_set_visible(p->serial_row[i], bambu);
    gtk_widget_set_visible(p->get_key, !bambu);
    gtk_label_set_text(GTK_LABEL(p->key_row[0]), bambu ? "Access code" : "API key");
    gtk_entry_set_placeholder_text(GTK_ENTRY(p->url), bambu ? "The IP address of the printer, for example 192.168.1.50"
                                                            : "http://printdeck.local or http://192.168.1.20:5000");
    for (int i = 0; i < 4; i++) gtk_widget_set_visible(p->usb_row[i], k == ZG_LINK_USB);
    gtk_widget_set_sensitive(p->test, k != ZG_LINK_NONE);
    gtk_widget_set_visible(p->use, p->printer != zg_printers_current());
}

static void stop_key(Prefs *p) {
    if (p->key_cancel) g_cancellable_cancel(p->key_cancel);
    g_clear_object(&p->key_cancel);
    if (p->get_key) gtk_widget_set_sensitive(p->get_key, TRUE);
}

static void clear_info(Prefs *p) {
    if (p->cancel) g_cancellable_cancel(p->cancel);
    g_clear_object(&p->cancel);
    g_clear_pointer(&p->info, zg_printer_info_free);
    gtk_label_set_text(GTK_LABEL(p->result), "");
    gtk_widget_set_visible(p->use_machine, FALSE);
    gtk_widget_set_visible(p->use_filament, FALSE);
}

static void fill_form(Prefs *p) {
    if (!p->printer) return;
    p->filling = TRUE;
    stop_key(p);
    clear_info(p);
    gtk_editable_set_text(GTK_EDITABLE(p->name), p->printer->name);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(p->kind), (guint)p->printer->kind);
    gtk_editable_set_text(GTK_EDITABLE(p->url), p->printer->url);
    gtk_editable_set_text(GTK_EDITABLE(p->api_key), p->printer->api_key);
    gtk_editable_set_text(GTK_EDITABLE(p->device), p->printer->device);
    gtk_editable_set_text(GTK_EDITABLE(p->serial), p->printer->serial);
    guint b = 0;
    for (guint i = 0; i < G_N_ELEMENTS(bauds); i++) if (bauds[i] == p->printer->baud) b = i;
    gtk_drop_down_set_selected(GTK_DROP_DOWN(p->baud), b);
    show_rows(p);
    p->filling = FALSE;
}

static void store(Prefs *p) {
    if (p->filling || !p->printer) return;
    zg_printers_save();
    zg_model_printers_edited(p->model);
}

static void on_name(GtkEditable *e, gpointer data) {
    Prefs *p = data;
    if (p->filling || !p->printer) return;
    g_free(p->printer->name);
    p->printer->name = g_strdup(gtk_editable_get_text(e));
    store(p);
    /* The list shows the new name. */
    GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(p->list));
    if (row) {
        GtkWidget *box = gtk_list_box_row_get_child(row);
        GtkWidget *names = gtk_widget_get_first_child(box);
        gtk_label_set_text(GTK_LABEL(gtk_widget_get_first_child(names)), p->printer->name);
    }
}

static void on_text(GtkEditable *e, gpointer data) {
    Prefs *p = data;
    if (p->filling || !p->printer) return;
    gpointer f = g_object_get_data(G_OBJECT(e), "zg-field");
    char **field = f == (gpointer)1 ? &p->printer->url
                 : f == (gpointer)2 ? &p->printer->api_key
                 : f == (gpointer)4 ? &p->printer->serial
                                    : &p->printer->device;
    g_free(*field);
    *field = g_strdup(gtk_editable_get_text(e));
    clear_info(p);
    store(p);
}

static void on_kind(GObject *dd, GParamSpec *pspec, gpointer data) {
    Prefs *p = data;
    if (p->filling || !p->printer) return;
    p->printer->kind = (ZgLinkKind)gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    if (p->printer->kind == ZG_LINK_MOONRAKER && !p->printer->url[0]) {
        /* Moonraker listens on 7125. */
        gtk_editable_set_text(GTK_EDITABLE(p->url), "http://");
    }
    show_rows(p);
    clear_info(p);
    store(p);
    fill_list(p);
}

static void on_port_found(GObject *dd, GParamSpec *pspec, gpointer data) {
    Prefs *p = data;
    GtkStringObject *item = gtk_drop_down_get_selected_item(GTK_DROP_DOWN(dd));
    if (item && !p->filling) gtk_editable_set_text(GTK_EDITABLE(p->device), gtk_string_object_get_string(item));
}

static void on_baud(GObject *dd, GParamSpec *pspec, gpointer data) {
    Prefs *p = data;
    if (p->filling || !p->printer) return;
    guint i = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    if (i < G_N_ELEMENTS(bauds)) p->printer->baud = bauds[i];
    store(p);
}

static void on_use(GtkButton *b, gpointer data) {
    Prefs *p = data;
    if (!p->printer) return;
    zg_model_use_printer(p->model, p->printer->id);
    fill_list(p);
    show_rows(p);
    zg_model_printers_edited(p->model);
}

/* ---- the test, and what the printer tells ---- */

static void on_info(ZgPrinterInfo *info, const char *error, gpointer data) {
    Prefs *p = data;
    if (!p->window) {
        zg_printer_info_free(info);
        return;
    }
    gtk_widget_set_sensitive(p->test, TRUE);
    if (!info) {
        char *m = g_strdup_printf("No connection: %s", error);
        gtk_label_set_text(GTK_LABEL(p->result), m);
        g_free(m);
        gtk_widget_add_css_class(p->result, "error");
        return;
    }
    gtk_widget_remove_css_class(p->result, "error");
    g_clear_pointer(&p->info, zg_printer_info_free);
    p->info = info;
    GString *s = g_string_new("Connected");
    if (info->state) g_string_append_printf(s, ": %s", info->state);
    g_string_append(s, ".");
    if (info->bed_x > 0) g_string_append_printf(s, "\nBed %.0f × %.0f × %.0f mm.", info->bed_x, info->bed_y, info->height);
    if (info->nozzle > 0) g_string_append_printf(s, " Nozzle %.2f mm.", info->nozzle);
    if (info->max_accel > 0) {
        g_string_append_printf(s, "\nMotion limits: %.0f mm/s, %.0f mm/s², corner %.0f mm/s", info->max_velocity, info->max_accel, info->corner_velocity);
        if (info->max_z_velocity > 0) g_string_append_printf(s, ", Z %.0f mm/s at %.0f mm/s²", info->max_z_velocity, info->max_z_accel);
        g_string_append(s, ".");
        /* A note when zslice plans with other limits. */
        char *acc = zg_model_get(p->model, "machine.max_accel");
        double mine = g_ascii_strtod(acc, NULL);
        g_free(acc);
        if (mine > 0 && fabs(mine - info->max_accel) > 1)
            g_string_append_printf(s, " zslice plans with %.0f mm/s² now: \"Use the printer's bed, nozzle, and motion\" takes the printer's limits.", mine);
    }
    if (info->material || info->spool) {
        g_string_append(s, "\nFilament in the printer:");
        if (info->spool) g_string_append_printf(s, " %s", info->spool);
        if (info->material) g_string_append_printf(s, " (%s", info->material);
        if (info->diameter > 0) g_string_append_printf(s, ", %.2f mm", info->diameter);
        if (info->material) g_string_append(s, ")");
        if (info->spool_left > 0) g_string_append_printf(s, ", %.0f g left", info->spool_left);
        g_string_append(s, ".");
    }
    if (info->spools && info->spools[0]) {
        g_string_append(s, "\nSpools:");
        for (int i = 0; info->spools[i]; i++) g_string_append_printf(s, "%s %s", i ? "," : "", info->spools[i]);
        g_string_append(s, ".");
    }
    if (info->job) {
        g_string_append_printf(s, "\nPrinting %s: %.0f %%", info->job, info->progress * 100);
        if (info->time_left > 0) g_string_append_printf(s, ", %d:%02d left", (int)info->time_left / 3600, (int)info->time_left / 60 % 60);
        g_string_append(s, ".");
    }
    gtk_label_set_text(GTK_LABEL(p->result), s->str);
    g_string_free(s, TRUE);
    gboolean current = p->printer == zg_printers_current();
    gtk_widget_set_visible(p->use_machine, current && (info->bed_x > 0 || info->nozzle > 0 || info->max_accel > 0));
    gtk_widget_set_visible(p->use_filament, current && (info->material || info->diameter > 0));
}

/* The test of a Bambu Lab printer: the first report over MQTT, then the
 * link closes. */
static void on_bambu_test(const zs_printer_status *st, const char *error, gpointer data) {
    Prefs *p = data;
    zg_bambu_watch_stop(p->bambu_test);
    p->bambu_test = NULL;
    if (!p->window) return;
    gtk_widget_set_sensitive(p->test, TRUE);
    zs_printer_info in;
    if (!st || zs_printer_status_get(st, &in) != ZS_OK) {
        gtk_label_set_text(GTK_LABEL(p->result), error ? error : "No answer.");
        gtk_widget_add_css_class(p->result, "error");
        return;
    }
    char *m = g_strdup_printf("Connected. The printer reports%s%s%s%s.", in.state[0] ? ": " : "", in.state, in.job[0] ? ", " : "", in.job);
    gtk_label_set_text(GTK_LABEL(p->result), m);
    g_free(m);
}

static void on_test(GtkButton *b, gpointer data) {
    Prefs *p = data;
    if (!p->printer) return;
    clear_info(p);
    p->cancel = g_cancellable_new();
    gtk_label_set_text(GTK_LABEL(p->result), "Connecting…");
    gtk_widget_remove_css_class(p->result, "error");
    gtk_widget_set_sensitive(p->test, FALSE);
    if (p->printer->kind == ZG_LINK_BAMBU) {
        zg_bambu_watch_stop(p->bambu_test);
        p->bambu_test = zg_bambu_watch(p->printer, on_bambu_test, p);
        return;
    }
    zg_link_query(p->printer, p->cancel, on_info, p);
}

/* "Read": the serial number from the certificate of the printer. */
static void on_serial_read(GObject *source, GAsyncResult *res, gpointer data) {
    Prefs *p = data;
    GError *e = NULL;
    char *pin = NULL;
    char *serial = zg_bambu_read_serial_finish(res, &pin, &e);
    if (p->window) {
        gtk_widget_set_sensitive(p->find_serial, TRUE);
        if (serial) {
            gtk_editable_set_text(GTK_EDITABLE(p->serial), serial);
            /* The user trusts the certificate of this printer now. */
            if (p->printer && p->printer->kind == ZG_LINK_BAMBU && pin) {
                g_free(p->printer->tls_pin);
                p->printer->tls_pin = g_strdup(pin);
                zg_printers_save();
            }
        } else {
            char *m = g_strdup_printf("The serial number did not read (%s).", e ? e->message : "no reason");
            gtk_label_set_text(GTK_LABEL(p->result), m);
            gtk_widget_add_css_class(p->result, "error");
            g_free(m);
        }
    }
    g_free(serial);
    g_free(pin);
    g_clear_error(&e);
}

static void on_find_serial(GtkButton *b, gpointer data) {
    Prefs *p = data;
    if (!p->printer || !p->printer->url[0]) {
        gtk_label_set_text(GTK_LABEL(p->result), "Set the IP address of the printer first.");
        return;
    }
    gtk_widget_set_sensitive(p->find_serial, FALSE);
    zg_bambu_read_serial(p->printer->url, NULL, on_serial_read, p);
}

/* ---- "Get a key": the App Keys flow (zg_link_request_key) ---- */

static void on_key_wait(int seconds, gpointer data) {
    Prefs *p = data;
    if (!p->window) return;
    /* A printdeck shows the key id of the request: the user checks that it
     * is the key of this app. */
    const char *id = p->printer && p->printer->kind == ZG_LINK_PRINTDECK ? zg_signing_key_id() : NULL;
    char *m = id ? g_strdup_printf("Allow zslice on the touch screen of the printer. Check that it shows the key %s. Waiting %d s of 120…", id, seconds)
                 : g_strdup_printf("Allow zslice on the printer: on its touch screen (printdeck), or in its web page (OctoPrint). Waiting %d s of 120…", seconds);
    gtk_label_set_text(GTK_LABEL(p->result), m);
    g_free(m);
}

static void on_key_done(gboolean ok, const char *key, const char *message, gpointer data) {
    Prefs *p = data;
    if (!p->window) return;
    g_clear_object(&p->key_cancel);
    gtk_widget_set_sensitive(p->get_key, TRUE);
    gtk_label_set_text(GTK_LABEL(p->result), message ? message : "");
    if (ok) {
        gtk_widget_remove_css_class(p->result, "error");
        /* The entry stores the key in app.ini (on_text). */
        gtk_editable_set_text(GTK_EDITABLE(p->api_key), key);
        gtk_label_set_text(GTK_LABEL(p->result), message);
    } else {
        gtk_widget_add_css_class(p->result, "error");
    }
}

static void on_get_key(GtkButton *b, gpointer data) {
    Prefs *p = data;
    if (!p->printer) return;
    stop_key(p);
    clear_info(p);
    p->key_cancel = g_cancellable_new();
    gtk_widget_set_sensitive(p->get_key, FALSE);
    gtk_widget_remove_css_class(p->result, "error");
    gtk_label_set_text(GTK_LABEL(p->result), "Asking the printer for a key…");
    zg_link_request_key(p->printer, p->key_cancel, on_key_wait, on_key_done, p);
}

static void get_key_hook(gpointer data) {
    Prefs *p = data;
    if (p->window) on_get_key(GTK_BUTTON(p->get_key), p);
}

static void set_num(ZgModel *model, const char *key, double v) {
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_formatd(buf, sizeof buf, "%.6g", v);
    zg_model_set(model, key, buf, NULL);
}

/* The rules of both buttons are in the core (zs_app_apply_printer_status). */
static void on_use_machine(GtkButton *b, gpointer data) {
    Prefs *p = data;
    if (!p->info) return;
    zg_model_apply_printer_status(p->model, p->info->core, 1);
    gtk_widget_set_visible(p->use_machine, FALSE);
}

static void on_use_filament(GtkButton *b, gpointer data) {
    Prefs *p = data;
    if (!p->info) return;
    zg_model_apply_printer_status(p->model, p->info->core, 2);
    gtk_widget_set_visible(p->use_filament, FALSE);
}

static void on_follow_roll(GtkCheckButton *b, gpointer data) {
    zg_pref_set("follow_roll", gtk_check_button_get_active(b) ? "1" : "0");
}

/* ---- general ---- */

static void on_theme(GObject *dd, GParamSpec *pspec, gpointer data) {
    static const char *themes[] = {"system", "light", "dark"};
    guint i = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    zg_pref_set("theme", themes[i < 3 ? i : 0]);
    zg_preferences_apply_theme();
}

static void on_view(GObject *dd, GParamSpec *pspec, gpointer data) {
    zg_pref_set("view", gtk_drop_down_get_selected(GTK_DROP_DOWN(dd)) == 1 ? "3d" : "2d");
}

static void on_threads(GtkSpinButton *spin, gpointer data) {
    Prefs *p = data;
    set_num(p->model, "engine.threads", gtk_spin_button_get_value(spin));
}

/* A switch of an app preference (engine.draft_slices,
 * engine.auto_simulate): the model keeps it in Preferences. */
static gboolean on_pref_switch(GtkSwitch *sw, gboolean on, gpointer data) {
    Prefs *p = data;
    zg_model_set(p->model, g_object_get_data(G_OBJECT(sw), "zg-key"), on ? "true" : "false", NULL);
    return FALSE;
}

static GtkWidget *pref_switch(Prefs *p, const char *key, const char *tip) {
    GtkWidget *sw = gtk_switch_new();
    char *v = zg_model_get(p->model, key);
    gtk_switch_set_active(GTK_SWITCH(sw), strcmp(v, "false") != 0);
    g_free(v);
    gtk_widget_set_halign(sw, GTK_ALIGN_START);
    gtk_widget_set_tooltip_text(sw, tip);
    g_object_set_data(G_OBJECT(sw), "zg-key", (gpointer)key);
    g_signal_connect(sw, "state-set", G_CALLBACK(on_pref_switch), p);
    return sw;
}

static void on_open_folder(GtkButton *b, gpointer data) {
    Prefs *p = data;
    char *dir = zg_config_dir();
    GFile *f = g_file_new_for_path(dir);
    GtkFileLauncher *l = gtk_file_launcher_new(f);
    gtk_file_launcher_launch(l, p->window, NULL, NULL, NULL);
    g_object_unref(l);
    g_object_unref(f);
    g_free(dir);
}

void zg_preferences_apply_theme(void) {
    char *theme = zg_pref_get("theme", "system");
    GtkSettings *s = gtk_settings_get_default();
    if (s) {
        /* The system style: GTK follows the desktop; set nothing. GTK
         * 4.20 has gtk-interface-color-scheme (GtkInterfaceColorScheme:
         * 2 dark, 3 light); older GTK has only the dark flag. */
        if (strcmp(theme, "system") == 0) {
            /* Nothing. */
        } else if (g_object_class_find_property(G_OBJECT_GET_CLASS(s), "gtk-interface-color-scheme")) {
            g_object_set(s, "gtk-interface-color-scheme", strcmp(theme, "dark") == 0 ? 2 : 3, NULL);
        } else {
            g_object_set(s, "gtk-application-prefer-dark-theme", strcmp(theme, "dark") == 0, NULL);
        }
    }
    g_free(theme);
}

/* ---- the window ---- */

static GtkWidget *form_label(const char *text) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 1);
    gtk_widget_add_css_class(l, "dim-label");
    return l;
}

static GtkWidget *printers_page(Prefs *p) {
    p->list = gtk_list_box_new();
    gtk_widget_add_css_class(p->list, "navigation-sidebar");
    g_signal_connect(p->list, "row-selected", G_CALLBACK(on_row_selected), p);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), p->list);
    gtk_widget_set_vexpand(scroll, TRUE);
    GtkWidget *add = gtk_button_new_from_icon_name("list-add-symbolic");
    gtk_widget_set_tooltip_text(add, "Add a printer");
    g_signal_connect(add, "clicked", G_CALLBACK(on_add), p);
    p->remove = gtk_button_new_from_icon_name("list-remove-symbolic");
    gtk_widget_set_tooltip_text(p->remove, "Remove the selected printer and its machine settings");
    g_signal_connect(p->remove, "clicked", G_CALLBACK(on_remove), p);
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_append(GTK_BOX(buttons), add);
    gtk_box_append(GTK_BOX(buttons), p->remove);
    gtk_widget_set_margin_start(buttons, 6);
    gtk_widget_set_margin_bottom(buttons, 6);
    GtkWidget *left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_append(GTK_BOX(left), scroll);
    gtk_box_append(GTK_BOX(left), buttons);
    gtk_widget_set_size_request(left, 220, -1);

    GtkWidget *g = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(g), 8);
    gtk_grid_set_column_spacing(GTK_GRID(g), 12);
    gtk_widget_set_margin_start(g, 18);
    gtk_widget_set_margin_end(g, 18);
    gtk_widget_set_margin_top(g, 18);
    int row = 0;
    p->name = gtk_entry_new();
    gtk_widget_set_hexpand(p->name, TRUE);
    g_signal_connect(p->name, "changed", G_CALLBACK(on_name), p);
    gtk_grid_attach(GTK_GRID(g), form_label("Name"), 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), p->name, 1, row++, 2, 1);

    const char *kinds[ZG_N_LINKS + 1];
    for (int i = 0; i < ZG_N_LINKS; i++) kinds[i] = zg_link_titles[i];
    kinds[ZG_N_LINKS] = NULL;
    p->kind = gtk_drop_down_new_from_strings(kinds);
    g_signal_connect(p->kind, "notify::selected", G_CALLBACK(on_kind), p);
    gtk_grid_attach(GTK_GRID(g), form_label("Connection"), 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), p->kind, 1, row++, 2, 1);
    p->trust = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->trust), 0);
    gtk_label_set_wrap(GTK_LABEL(p->trust), TRUE);
    gtk_widget_add_css_class(p->trust, "dim-label");
    gtk_widget_add_css_class(p->trust, "caption");
    gtk_grid_attach(GTK_GRID(g), p->trust, 1, row++, 2, 1);

    p->url = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(p->url), "http://printdeck.local or http://192.168.1.20:5000");
    g_object_set_data(G_OBJECT(p->url), "zg-field", (gpointer)1);
    g_signal_connect(p->url, "changed", G_CALLBACK(on_text), p);
    p->url_row[0] = form_label("Address");
    p->url_row[1] = p->url;
    gtk_grid_attach(GTK_GRID(g), p->url_row[0], 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), p->url, 1, row++, 2, 1);

    p->api_key = gtk_password_entry_new();
    gtk_password_entry_set_show_peek_icon(GTK_PASSWORD_ENTRY(p->api_key), TRUE);
    g_object_set_data(G_OBJECT(p->api_key), "zg-field", (gpointer)2);
    g_signal_connect(p->api_key, "changed", G_CALLBACK(on_text), p);
    gtk_widget_set_hexpand(p->api_key, TRUE);
    p->get_key = gtk_button_new_with_label("Get a key");
    gtk_widget_set_tooltip_text(p->get_key, "Ask the printer for a key of its own for zslice. The printer asks \"Allow zslice?\" on its touch screen (printdeck), or in its web page (OctoPrint, with the App Keys plugin). Allow it within 2 minutes.");
    g_signal_connect(p->get_key, "clicked", G_CALLBACK(on_get_key), p);
    GtkWidget *key_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(key_box), p->api_key);
    gtk_box_append(GTK_BOX(key_box), p->get_key);
    p->key_row[0] = form_label("API key");
    /* A Bambu Lab printer: the serial number (the common name of its
     * certificate), for the MQTT topic. */
    p->serial = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(p->serial), "On the screen of the printer, or Read");
    gtk_widget_set_hexpand(p->serial, TRUE);
    g_object_set_data(G_OBJECT(p->serial), "zg-field", (gpointer)4);
    g_signal_connect(p->serial, "changed", G_CALLBACK(on_text), p);
    p->find_serial = gtk_button_new_with_label("Read");
    gtk_widget_set_tooltip_text(p->find_serial, "Read the serial number from the printer at the address (from its certificate, with no login).");
    g_signal_connect(p->find_serial, "clicked", G_CALLBACK(on_find_serial), p);
    GtkWidget *serial_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(serial_box), p->serial);
    gtk_box_append(GTK_BOX(serial_box), p->find_serial);
    p->serial_row[0] = form_label("Serial number");
    p->serial_row[1] = serial_box;
    p->key_row[1] = key_box;
    gtk_widget_set_tooltip_text(p->api_key, "The API key of the printer (in OctoPrint: Settings › API, or an application key; printdeck: its System page). It is kept in app.ini, readable only by you.");
    gtk_grid_attach(GTK_GRID(g), p->serial_row[0], 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), serial_box, 1, row++, 2, 1);
    gtk_grid_attach(GTK_GRID(g), p->key_row[0], 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), key_box, 1, row++, 2, 1);

    /* The port: an entry, and a list of the ports that the computer has. */
    p->device = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(p->device), "/dev/ttyACM0");
    gtk_widget_set_hexpand(p->device, TRUE);
    g_object_set_data(G_OBJECT(p->device), "zg-field", (gpointer)3);
    g_signal_connect(p->device, "changed", G_CALLBACK(on_text), p);
    char **ports = zg_link_serial_ports();
    GtkStringList *port_list = gtk_string_list_new((const char *const *)ports);
    g_strfreev(ports);
    GtkWidget *found = gtk_drop_down_new(G_LIST_MODEL(port_list), NULL);
    gtk_widget_set_tooltip_text(found, "The serial ports of this computer. Pick one to use it.");
    g_object_set_data(G_OBJECT(found), "zg-entry", p->device);
    g_signal_connect(found, "notify::selected", G_CALLBACK(on_port_found), p);
    GtkWidget *port_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_box_append(GTK_BOX(port_box), p->device);
    gtk_box_append(GTK_BOX(port_box), found);
    p->usb_row[0] = form_label("Serial port");
    p->usb_row[1] = port_box;
    gtk_grid_attach(GTK_GRID(g), p->usb_row[0], 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), port_box, 1, row++, 2, 1);
    const char *baud_names[] = {"250000", "115200", "230400", "500000", "1000000", "57600", NULL};
    p->baud = gtk_drop_down_new_from_strings(baud_names);
    g_signal_connect(p->baud, "notify::selected", G_CALLBACK(on_baud), p);
    p->usb_row[2] = form_label("Speed (baud)");
    p->usb_row[3] = p->baud;
    gtk_grid_attach(GTK_GRID(g), p->usb_row[2], 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), p->baud, 1, row++, 2, 1);

    p->test = gtk_button_new_with_label("Test the connection");
    g_signal_connect(p->test, "clicked", G_CALLBACK(on_test), p);
    p->use = gtk_button_new_with_label("Use this printer");
    gtk_widget_add_css_class(p->use, "suggested-action");
    g_signal_connect(p->use, "clicked", G_CALLBACK(on_use), p);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(actions), p->test);
    gtk_box_append(GTK_BOX(actions), p->use);
    gtk_grid_attach(GTK_GRID(g), actions, 1, row++, 2, 1);

    p->result = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(p->result), 0);
    gtk_label_set_wrap(GTK_LABEL(p->result), TRUE);
    gtk_label_set_selectable(GTK_LABEL(p->result), TRUE);
    gtk_grid_attach(GTK_GRID(g), p->result, 1, row++, 2, 1);
    p->use_machine = gtk_button_new_with_label("Use the printer's bed, nozzle, and motion");
    gtk_widget_set_tooltip_text(p->use_machine, "Copies the bed size, the height, and the nozzle that the printer tells to the machine settings of this printer.");
    g_signal_connect(p->use_machine, "clicked", G_CALLBACK(on_use_machine), p);
    p->use_filament = gtk_button_new_with_label("Use the filament in the printer");
    gtk_widget_set_tooltip_text(p->use_filament, "Sets the filament settings from the filament in the printer: the built-in profile of its material, its name, diameter, and color.");
    g_signal_connect(p->use_filament, "clicked", G_CALLBACK(on_use_filament), p);
    GtkWidget *use_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(use_box), p->use_machine);
    gtk_box_append(GTK_BOX(use_box), p->use_filament);
    gtk_grid_attach(GTK_GRID(g), use_box, 1, row++, 2, 1);

    /* The filament settings follow the roll in the printer (printdeck). */
    GtkWidget *follow = gtk_check_button_new_with_label("Keep filament settings for each roll in the printer");
    gtk_widget_set_tooltip_text(follow, "printdeck tells which roll is in the printer. Each roll keeps its own filament settings (its tuning too), and a change of the roll loads them. A new roll starts from the settings before, or from the built-in profile of another material.");
    char *on = zg_pref_get("follow_roll", "1");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(follow), strcmp(on, "1") == 0);
    g_free(on);
    g_signal_connect(follow, "toggled", G_CALLBACK(on_follow_roll), NULL);
    gtk_grid_attach(GTK_GRID(g), follow, 1, row++, 2, 1);

    GtkWidget *note = gtk_label_new("The machine settings of the current printer (bed, nozzle, speeds, start and end G-code) are in the Settings page, under Printer, and in the printer list of the header bar (Printer settings and G-code). Each printer keeps its own.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_widget_add_css_class(note, "dim-label");
    gtk_widget_set_margin_top(note, 12);
    gtk_grid_attach(GTK_GRID(g), note, 1, row++, 2, 1);

    GtkWidget *right = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(right), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(right), g);
    gtk_widget_set_hexpand(right, TRUE);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_append(GTK_BOX(box), left);
    gtk_box_append(GTK_BOX(box), gtk_separator_new(GTK_ORIENTATION_VERTICAL));
    gtk_box_append(GTK_BOX(box), right);
    return box;
}

static GtkWidget *general_page(Prefs *p) {
    GtkWidget *g = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(g), 10);
    gtk_grid_set_column_spacing(GTK_GRID(g), 12);
    gtk_widget_set_margin_start(g, 18);
    gtk_widget_set_margin_end(g, 18);
    gtk_widget_set_margin_top(g, 18);
    int row = 0;

    const char *themes[] = {"The system style", "Light", "Dark", NULL};
    GtkWidget *theme = gtk_drop_down_new_from_strings(themes);
    char *t = zg_pref_get("theme", "system");
    gtk_drop_down_set_selected(GTK_DROP_DOWN(theme), strcmp(t, "light") == 0 ? 1 : strcmp(t, "dark") == 0 ? 2 : 0);
    g_free(t);
    g_signal_connect(theme, "notify::selected", G_CALLBACK(on_theme), p);
    gtk_grid_attach(GTK_GRID(g), form_label("Theme"), 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), theme, 1, row++, 1, 1);

    const char *views[] = {"2D (one layer)", "3D", NULL};
    GtkWidget *view = gtk_drop_down_new_from_strings(views);
    char *v = zg_pref_get("view", "3d");
    gtk_drop_down_set_selected(GTK_DROP_DOWN(view), strcmp(v, "2d") == 0 ? 0 : 1);
    g_free(v);
    g_signal_connect(view, "notify::selected", G_CALLBACK(on_view), p);
    gtk_grid_attach(GTK_GRID(g), form_label("First view"), 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), view, 1, row++, 1, 1);

    GtkWidget *threads = gtk_spin_button_new_with_range(0, 256, 1);
    char *tv = zg_model_get(p->model, "engine.threads");
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(threads), g_ascii_strtod(tv, NULL));
    g_free(tv);
    gtk_widget_set_tooltip_text(threads, "The threads of the slicer. 0: one for each processor core.");
    g_signal_connect(threads, "value-changed", G_CALLBACK(on_threads), p);
    gtk_grid_attach(GTK_GRID(g), form_label("Slicer threads"), 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), threads, 1, row++, 1, 1);

    GtkWidget *draft = pref_switch(p, "engine.draft_slices", "After a change, the view first shows a draft in about a third of the time, then the exact slice. A draft never goes to the G-code. Off: only exact slices.");
    gtk_grid_attach(GTK_GRID(g), form_label("Draft slices during edits"), 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), draft, 1, row++, 1, 1);

    GtkWidget *sim = pref_switch(p, "engine.auto_simulate", "Runs after each slice; off saves CPU, and the Check has no simulated failures until you run it by hand (Show the print as it forms).");
    gtk_grid_attach(GTK_GRID(g), form_label("Show the print as it forms after each slice"), 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), sim, 1, row++, 1, 1);

    char *dir = zg_config_dir();
    GtkWidget *folder = gtk_label_new(dir);
    g_free(dir);
    gtk_label_set_xalign(GTK_LABEL(folder), 0);
    gtk_label_set_selectable(GTK_LABEL(folder), TRUE);
    gtk_label_set_wrap(GTK_LABEL(folder), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(folder), PANGO_WRAP_WORD);
    GtkWidget *open = gtk_button_new_with_label("Open");
    g_signal_connect(open, "clicked", G_CALLBACK(on_open_folder), p);
    GtkWidget *fbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_hexpand(folder, TRUE);
    gtk_box_append(GTK_BOX(fbox), folder);
    gtk_box_append(GTK_BOX(fbox), open);
    gtk_grid_attach(GTK_GRID(g), form_label("Settings files"), 0, row, 1, 1);
    gtk_grid_attach(GTK_GRID(g), fbox, 1, row++, 1, 1);
    GtkWidget *note = gtk_label_new("The defaults of all prints are in the Settings page of the main window. The app saves them here: filament.toml, project.toml, and printers/ for the machine settings of each printer.");
    gtk_label_set_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(note), 0);
    gtk_widget_add_css_class(note, "dim-label");
    gtk_grid_attach(GTK_GRID(g), note, 1, row++, 1, 1);
    /* A small window scrolls the page. */
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), g);
    return scroll;
}

static void on_destroy(GtkWidget *w, gpointer data) {
    Prefs *p = data;
    p->window = NULL;
    stop_key(p);
    zg_bambu_watch_stop(p->bambu_test);
    p->bambu_test = NULL;
    clear_info(p);
    g_object_set_data(G_OBJECT(p->model), "zg-preferences", NULL);
    g_object_unref(p->model);
    /* A query in flight keeps p: its callback sees window == NULL. The
     * cancel above ends it, and its callback frees nothing of p. */
}

void zg_preferences_show(GtkWindow *parent, ZgModel *model) {
    GtkWindow *open = g_object_get_data(G_OBJECT(model), "zg-preferences");
    if (open) {
        gtk_window_present(open);
        return;
    }
    Prefs *p = g_new0(Prefs, 1);
    p->model = g_object_ref(model);
    p->window = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(p->window, "Preferences");
    gtk_window_set_transient_for(p->window, parent);
    gtk_window_set_default_size(p->window, 820, 560);
    g_object_set_data(G_OBJECT(model), "zg-preferences", p->window);

    GtkWidget *stack = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    gtk_stack_add_titled(GTK_STACK(stack), printers_page(p), "printers", "Printers");
    gtk_stack_add_titled(GTK_STACK(stack), general_page(p), "general", "General");
    GtkWidget *switcher = gtk_stack_switcher_new();
    gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(switcher), GTK_STACK(stack));
    GtkWidget *header = gtk_header_bar_new();
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), switcher);
    gtk_window_set_titlebar(p->window, header);
    gtk_window_set_child(p->window, stack);
    /* For tests: ZSLICE_PREFS=general opens the General page. */
    if (g_strcmp0(g_getenv("ZSLICE_PREFS"), "general") == 0) gtk_stack_set_visible_child_name(GTK_STACK(stack), "general");

    p->printer = zg_printers_current();
    fill_list(p);
    fill_form(p);
    /* The Prefs block lives as long as the app: a query in flight can
     * still call back after the window closes. */
    g_signal_connect(p->window, "destroy", G_CALLBACK(on_destroy), p);
    gtk_window_present(p->window);
    /* For tests: ZSLICE_GET_KEY=1 presses "Get a key" for the current
     * printer. */
    if (g_getenv("ZSLICE_GET_KEY")) g_timeout_add_once(500, get_key_hook, p);
}
