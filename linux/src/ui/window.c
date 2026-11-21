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

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "licenses.h"
#include "preferences.h"
#include "cura-compare.h"
#include "../net/printer-link.h"
#include "../net/signing.h"
#include "../prefs/printers.h"
#include "printer-picker.h"
#include "filaments.h"
#include "profile-menus.h"
#include "preview.h"
#include "history.h"
#include "farm-page.h"
#include "project-page.h"
#include "settings-panel.h"
#include "setting-editor.h"
#include "float.h"
#include "search.h"
#include "part-card.h"
#include "range-card.h"
#include "line-card.h"
#include "shortcuts.h"
#include "view3d.h"

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
    /* The panel is a drawer (docs/internals/one-view.md): hidden, over the
     * view, or pinned beside it. The body overlay holds it over the view;
     * the paned holds it beside the view. */
    GtkWidget *body, *paned, *panel, *panel_toggle, *pin;
    /* The other places of the old tabs: the dock (the popover of History has
     * the list of the changes), the Project dialog, and the Printers page
     * over the view with its button in the header bar. */
    GtkWidget *timeline, *project_dialog, *farm_view, *printers_button;
    /* The search of settings and actions (/), over the view. */
    GtkWidget *search;
    /* The main settings of the print on the print card. */
    GtkWidget *facts;
    int panel_mode; /* enum PanelMode */
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
    /* The head of the print card (a click opens the details), its badge
     * ("Check" for a warning, or the count of the refinements), the
     * details pane, and the refinements in it. */
    GtkWidget *sum_more, *sum_badge, *sum_pop, *refine_box;
    guint refine_timer;
    /* The hint under the status line: its text and its buttons. */
    GtkWidget *hint, *hint_label, *hint_support, *hint_inches, *hint_meters;
    /* The area in mm² that hangs in the air with no support, from the
     * check after the last slice of the plate of overhang_core. */
    double overhang;
    zs_app *overhang_core;
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


/* The setting of the editor that has the focus (the editor, its slider,
 * or a part of them), or NULL, for the history of the model. */
static void on_focus_widget(GtkWindow *win, GParamSpec *pspec, gpointer data) {
    const char *key = NULL;
    for (GtkWidget *f = gtk_window_get_focus(win); f; f = gtk_widget_get_parent(f)) {
        const zs_setting_info *info = g_object_get_data(G_OBJECT(f), "zg-info");
        if (info) {
            key = info->name;
            break;
        }
    }
    zg_model_history_set_focus(data, key);
}

static void send_now(Window *w);
static void send_checked(Window *w);
static void fill_facts(Window *w);
static void action_hook(gpointer data);
static void stress_hook(gpointer data);

enum PanelMode { PANEL_HIDDEN, PANEL_OVER, PANEL_PINNED };
static const char *panel_modes[] = {"hidden", "overlay", "pinned"};

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

/* ---- the hints of the print card ---- */

/* The area that hangs in the air (mm²) over which the print card says to
 * turn on support. The check of the print measures it (overhangs and
 * islands, as warnings or problems; a bridge does not count), so a Benchy
 * has none. The web app uses the same limit. */
#define OVERHANG_HINT_MM2 20.0
/* A part with its largest side under this size (mm) comes from a file in
 * inches or in meters. */
#define TINY_PART_MM 3.0

/* With support off: the check of the print after each slice, for the
 * hint. The thread of the slice runs it after the slice shows
 * (zs_app_set_auto_checks): ZS_BUSY until ZS_EVENT_CHECKED, then at once. */
static void check_overhang(Window *w) {
    zs_app *core = zg_model_core(w->model);
    w->overhang = 0;
    w->overhang_core = core;
    if (zs_app_state(core) != ZS_STATE_DONE) return;
    char *support = zg_model_get(w->model, "project.support");
    gboolean off = !support[0] || strcmp(support, "off") == 0;
    g_free(support);
    if (!off) return;
    const zs_issue *issues = NULL;
    size_t n = 0;
    const char *text = NULL;
    if (zs_app_checks(core, &issues, &n, &text) != ZS_OK) return;
    for (size_t i = 0; i < n; i++) {
        if ((issues[i].kind == ZS_ISSUE_OVERHANG || issues[i].kind == ZS_ISSUE_ISLAND) && issues[i].severity >= 1) w->overhang += issues[i].value;
    }
}

static double part_size(const zs_part *p) {
    return MAX(p->size_x, MAX(p->size_y, p->size_z));
}

/* Scales each part with its largest side under TINY_PART_MM by k: a file
 * in inches (25.4) or in meters (1000). */
static void scale_tiny(Window *w, double k) {
    zs_app *core = zg_model_core(w->model);
    size_t n = zs_app_part_count(core);
    for (size_t i = 0; i < n; i++) {
        zs_part p;
        if (zs_app_part_get(core, i, &p) != ZS_OK || part_size(&p) >= TINY_PART_MM) continue;
        zg_model_part_scale(w->model, i, p.scale_x * k);
    }
}

/* The actions of the buttons of the hint: win.scale-tiny(25.4) and
 * win.support-on. ZSLICE_ACTION can run them for a test. */
static void on_scale_tiny_action(GSimpleAction *a, GVariant *v, gpointer data) {
    scale_tiny(get(data), g_variant_get_double(v));
}

/* "win.print-details": the details of the print card. */
static void on_print_details_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    if (w->sum_pop && gtk_widget_get_mapped(w->sum_more)) gtk_popover_popup(GTK_POPOVER(w->sum_pop));
}

static void on_support_on_action(GSimpleAction *a, GVariant *v, gpointer data) {
    zg_model_set(get(data)->model, "project.support", "everywhere", NULL);
}

/* One hint at a time, after the red warning of the status line (a part
 * off the bed): a part from a file in inches or in meters, else a large
 * area in the air with support off. */
static void show_hint(Window *w, int state, gboolean fits) {
    if (!w->hint) return;
    zs_app *core = zg_model_core(w->model);
    gboolean inches = FALSE, support = FALSE;
    char *text = NULL;
    if (state == ZS_STATE_DONE && fits) {
        size_t n = zs_app_part_count(core);
        for (size_t i = 0; i < n && !text; i++) {
            zs_part p;
            if (zs_app_part_get(core, i, &p) != ZS_OK || part_size(&p) >= TINY_PART_MM) continue;
            text = g_strdup_printf("%s is only %.2f mm. Was the file in inches or in meters?", p.name && p.name[0] ? p.name : "The part",
                                   part_size(&p));
            inches = TRUE;
        }
        /* The simulated print, when it ran: where it fails, or how far it
         * droops, in place of the area that hangs in the air. */
        zs_print_sim_stats st;
        gboolean simulated = !text && zs_app_sim_stats(core, &st) == ZS_OK;
        if (simulated) {
            char *v = zg_model_get(w->model, "project.support");
            gboolean off = !v[0] || strcmp(v, "off") == 0;
            g_free(v);
            const char *as = st.material_exact ? "" : " (simulated as the nearest plastic with data)";
            if (st.failed > 0 && st.first_failed_layer >= 0)
                text = g_strdup_printf("The print fails at layer %td: the plastic over air falls%s. %s", st.first_failed_layer + 1, as,
                                       off ? "Turn on support or turn the part." : "Turn the part, or add support there.");
            else if (st.max_drop > 0.5)
                text = g_strdup_printf("The plastic droops up to %.1f mm where nothing holds it%s.", st.max_drop, as);
            support = text != NULL && off;
        }
        if (!text && !simulated && w->overhang_core == core && w->overhang >= OVERHANG_HINT_MM2) {
            char *v = zg_model_get(w->model, "project.support");
            if (!v[0] || strcmp(v, "off") == 0) {
                text = g_strdup_printf("About %.0f mm\u00b2 of the part hangs in the air with no support. It can droop or fail.", w->overhang);
                support = TRUE;
            }
            g_free(v);
        }
    }
    gtk_widget_set_visible(w->hint, text != NULL);
    gtk_widget_set_visible(w->hint_inches, inches);
    gtk_widget_set_visible(w->hint_meters, inches);
    gtk_widget_set_visible(w->hint_support, support);
    if (text) gtk_label_set_text(GTK_LABEL(w->hint_label), text);
    g_free(text);
}

/* ---- the badge of the print card, and the refinements ----
 *
 * A click on the head of the print card opens its details: the main
 * settings, the warnings, and the usual refinements. The badge on the head
 * counts the warnings and the refinements. */

/* The text of the warning in the details, or NULL. */
static const char *warning_text(Window *w) {
    if (gtk_widget_has_css_class(w->status, "error")) return gtk_label_get_text(GTK_LABEL(w->status));
    if (gtk_widget_get_visible(w->hint)) return gtk_label_get_text(GTK_LABEL(w->hint_label));
    if (gtk_widget_get_visible(w->islands)) return "islands";
    return NULL;
}

static void update_badge(Window *w) {
    if (!w->sum_badge) return;
    const char *warn = warning_text(w);
    int tips = 0;
    for (GtkWidget *c = gtk_widget_get_first_child(w->refine_box); c; c = gtk_widget_get_next_sibling(c))
        if (g_object_get_data(G_OBJECT(c), "zg-line")) tips++;
    if (warn) gtk_widget_add_css_class(w->sum_badge, "warn");
    else gtk_widget_remove_css_class(w->sum_badge, "warn");
    gtk_widget_set_visible(w->sum_badge, warn || tips > 0);
    char text[32];
    if (warn) g_snprintf(text, sizeof text, "Check");
    else if (tips == 1) g_snprintf(text, sizeof text, "1 refinement");
    else g_snprintf(text, sizeof text, "%d refinements", tips);
    gtk_label_set_text(GTK_LABEL(w->sum_badge), text);
    /* A warning does not open the details: they cover the part. The badge
     * in the warning color is the sign, and a click opens them. */
}

/* The store of the refinements on this device: the records of the past
 * projects (zs_refine_merge), and the refinements that the user hid. */
static char *refine_file(const char *name) {
    char *dir = zg_config_dir();
    char *p = g_build_filename(dir, name, NULL);
    g_free(dir);
    return p;
}

static char *read_file(const char *name) {
    char *p = refine_file(name), *text = NULL;
    if (!g_file_get_contents(p, &text, NULL, NULL)) text = g_strdup("");
    g_free(p);
    return text;
}

static void write_file(const char *name, const char *text) {
    char *dir = zg_config_dir();
    g_mkdir_with_parents(dir, 0700);
    g_free(dir);
    char *p = refine_file(name);
    g_file_set_contents(p, text, -1, NULL);
    g_free(p);
}

/* A line of "x" hidden: one line of the hidden file. */
static gboolean refine_hidden(const char *hidden, const char *line) {
    char **lines = g_strsplit(hidden, "\n", -1);
    gboolean found = g_strv_contains((const char *const *)lines, line);
    g_strfreev(lines);
    return found;
}

static void refine_soon(Window *w);

static void on_refine_apply(GtkButton *b, gpointer data) {
    Window *w = data;
    const char *line = g_object_get_data(G_OBJECT(b), "zg-line");
    if (zg_model_refine_apply(w->model, line)) refine_soon(w);
}

static void on_refine_all(GtkButton *b, gpointer data) {
    Window *w = data;
    GPtrArray *lines = g_ptr_array_new_with_free_func(g_free);
    for (GtkWidget *c = gtk_widget_get_first_child(w->refine_box); c; c = gtk_widget_get_next_sibling(c)) {
        const char *line = g_object_get_data(G_OBJECT(c), "zg-line");
        if (line) g_ptr_array_add(lines, g_strdup(line));
    }
    for (guint i = 0; i < lines->len; i++) zg_model_refine_apply(w->model, g_ptr_array_index(lines, i));
    g_ptr_array_free(lines, TRUE);
    refine_soon(w);
}

static void on_refine_hide(GtkButton *b, gpointer data) {
    Window *w = data;
    const char *line = g_object_get_data(G_OBJECT(b), "zg-line");
    char *hidden = read_file("refine-hidden.txt");
    char *more = g_strdup_printf("%s%s\n", hidden, line);
    write_file("refine-hidden.txt", more);
    g_free(more);
    g_free(hidden);
    gtk_box_remove(GTK_BOX(w->refine_box), gtk_widget_get_parent(GTK_WIDGET(b)));
    if (!gtk_widget_get_first_child(w->refine_box) || !g_object_get_data(G_OBJECT(gtk_widget_get_last_child(w->refine_box)), "zg-line"))
        gtk_widget_set_visible(w->refine_box, FALSE);
    update_badge(w);
}

/* The text of a call that writes into a buffer: its size first. */
#define READ_TEXT(call_null, call_buf, out)                                   \
    do {                                                                      \
        size_t len_ = 0;                                                      \
        char *buf_ = NULL;                                                    \
        if ((call_null) == ZS_OK) {                                           \
            size_t cap_ = len_ + 1;                                           \
            buf_ = g_malloc0(cap_);                                           \
            if ((call_buf) != ZS_OK) g_clear_pointer(&buf_, g_free);          \
        }                                                                     \
        out = buf_;                                                           \
    } while (0)

/* The refinements of the plate (its changes from the first slice) go in
 * the store, in place of its last records. The core finds the changes that
 * the user made in two or more other projects with the same material and
 * nozzle, and the details offer them. */
static void refine_refresh(Window *w) {
    zs_app *core = zg_model_core(w->model);
    if (zs_app_state(core) != ZS_STATE_DONE) return;
    const char *project = zg_model_refine_id(w->model);
    char *store = read_file("refine-store.txt"), *records, *merged, *text;
    READ_TEXT(zs_app_refine_records(core, NULL, 0, &len_), zs_app_refine_records(core, buf_, cap_, &len_), records);
    if (!records) records = g_strdup("");
    READ_TEXT(zs_refine_merge(store, strlen(store), project, records, strlen(records), NULL, 0, &len_),
              zs_refine_merge(store, strlen(store), project, records, strlen(records), buf_, cap_, &len_), merged);
    if (merged && strcmp(merged, store) != 0) write_file("refine-store.txt", merged);
    if (!merged) merged = g_strdup(store);
    READ_TEXT(zs_app_refine_suggest(core, merged, strlen(merged), project, NULL, 0, &len_),
              zs_app_refine_suggest(core, merged, strlen(merged), project, buf_, cap_, &len_), text);
    char *hidden = read_file("refine-hidden.txt");
    GtkWidget *c;
    while ((c = gtk_widget_get_first_child(w->refine_box))) gtk_box_remove(GTK_BOX(w->refine_box), c);
    GPtrArray *rows = g_ptr_array_new();
    char **lines = g_strsplit(text ? text : "", "\n", -1);
    for (char **l = lines; *l; l++) {
        char **f = g_strsplit(*l, "\t", -1);
        if (g_strv_length(f) >= 7 && !refine_hidden(hidden, *l)) {
            /* The words of the change, as the history writes them. */
            char *scope = strcmp(f[0], "layers") == 0 ? g_strdup_printf("layers:%s:%s", f[5], f[6])
                                                      : g_strdup(strcmp(f[0], "part") == 0 ? "part:each part" : "print");
            char *change = g_strdup_printf("%s\t%s\t\t%s\n", scope, f[2], f[3]), *words;
            READ_TEXT(zs_app_history_describe(core, change, strlen(change), NULL, 0, &len_),
                      zs_app_history_describe(core, change, strlen(change), buf_, cap_, &len_), words);
            char **ww = g_strsplit(g_strstrip(words ? words : g_strdup("")), "\t", 2);
            GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
            g_object_set_data_full(G_OBJECT(row), "zg-line", g_strdup(*l), g_free);
            GtkWidget *texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
            gtk_widget_set_hexpand(texts, TRUE);
            char *what = g_strdup_printf("%s: %s", ww[0] ? ww[0] : "", ww[0] && ww[1] ? ww[1] : f[2]);
            GtkWidget *label = gtk_label_new(what);
            gtk_label_set_xalign(GTK_LABEL(label), 0);
            gtk_label_set_wrap(GTK_LABEL(label), TRUE);
            gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD);
            char *n = g_strdup_printf("You made this change in %s other prints.", f[4]);
            GtkWidget *count = gtk_label_new(n);
            gtk_label_set_xalign(GTK_LABEL(count), 0);
            gtk_label_set_wrap(GTK_LABEL(count), TRUE);
            gtk_widget_add_css_class(count, "dim-label");
            gtk_widget_add_css_class(count, "caption");
            gtk_box_append(GTK_BOX(texts), label);
            gtk_box_append(GTK_BOX(texts), count);
            GtkWidget *apply = gtk_button_new_with_label("Apply");
            gtk_widget_set_valign(apply, GTK_ALIGN_CENTER);
            g_object_set_data_full(G_OBJECT(apply), "zg-line", g_strdup(*l), g_free);
            g_signal_connect(apply, "clicked", G_CALLBACK(on_refine_apply), w);
            GtkWidget *hide = gtk_button_new_from_icon_name("window-close-symbolic");
            gtk_widget_add_css_class(hide, "flat");
            gtk_widget_set_valign(hide, GTK_ALIGN_CENTER);
            gtk_widget_set_tooltip_text(hide, "Do not offer this again");
            g_object_set_data_full(G_OBJECT(hide), "zg-line", g_strdup(*l), g_free);
            g_signal_connect(hide, "clicked", G_CALLBACK(on_refine_hide), w);
            gtk_box_append(GTK_BOX(row), texts);
            gtk_box_append(GTK_BOX(row), apply);
            gtk_box_append(GTK_BOX(row), hide);
            g_ptr_array_add(rows, row);
            g_free(n);
            g_free(what);
            g_strfreev(ww);
            g_free(words);
            g_free(change);
            g_free(scope);
        }
        g_strfreev(f);
    }
    if (rows->len > 0) {
        GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        char *t = rows->len == 1 ? g_strdup("Your usual refinement") : g_strdup_printf("Your usual refinements: %u", rows->len);
        GtkWidget *title = gtk_label_new(t);
        g_free(t);
        gtk_widget_add_css_class(title, "heading");
        gtk_label_set_xalign(GTK_LABEL(title), 0);
        gtk_widget_set_hexpand(title, TRUE);
        gtk_box_append(GTK_BOX(head), title);
        if (rows->len > 1) {
            GtkWidget *all = gtk_button_new_with_label("Apply all");
            gtk_widget_set_tooltip_text(all, "Apply each refinement (one undo step each)");
            g_signal_connect(all, "clicked", G_CALLBACK(on_refine_all), w);
            gtk_box_append(GTK_BOX(head), all);
        }
        gtk_box_append(GTK_BOX(w->refine_box), head);
        for (guint i = 0; i < rows->len; i++) gtk_box_append(GTK_BOX(w->refine_box), g_ptr_array_index(rows, i));
    }
    gtk_widget_set_visible(w->refine_box, rows->len > 0);
    g_ptr_array_free(rows, TRUE);
    g_strfreev(lines);
    g_free(hidden);
    g_free(text);
    g_free(merged);
    g_free(records);
    g_free(store);
    update_badge(w);
}

static gboolean on_refine_timer(gpointer data) {
    Window *w = data;
    w->refine_timer = 0;
    gint64 t0 = g_get_monotonic_time();
    refine_refresh(w);
    if (g_getenv("ZSLICE_BENCH")) g_message("bench: the refinements, %.0f ms", (g_get_monotonic_time() - t0) / 1000.0);
    return G_SOURCE_REMOVE;
}

static void refine_soon(Window *w) {
    if (w->refine_timer) g_source_remove(w->refine_timer);
    w->refine_timer = g_timeout_add(800, on_refine_timer, w);
}

/* The summary card: the numbers of the last result, faded while a new
 * slice runs. */
static void update_summary(Window *w, int state) {
    if (!w->sum_box) return;
    /* An empty plate has no print: no card. */
    gtk_widget_set_visible(w->sum_box, state != ZS_STATE_EMPTY);
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
    fill_facts(w);
    double per_g = w->spool_price_g;
    if (per_g <= 0) {
        char *v = zg_model_get(w->model, "filament.price_per_kg");
        per_g = g_ascii_strtod(v, NULL) / 1000;
        g_free(v);
    }
    /* The cost: the filament, and the time of the printer (as on the web). */
    char *rate = zg_model_get(w->model, "machine.hour_rate");
    double per_h = rate ? g_ascii_strtod(rate, NULL) : 0;
    g_free(rate);
    double c = st.filament_g * MAX(per_g, 0) + st.print_time_s / 3600 * MAX(per_h, 0);
    char cost[32] = "";
    if (c > 0) g_snprintf(cost, sizeof cost, " · cost %.2f", c);
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


/* ---- the facts of the print card ----
 *
 * The main settings of the print, as small buttons. A click opens the
 * search on that setting, to change it there. */

static double num(Window *w, const char *key) {
    char *v = zg_model_get(w->model, key);
    double d = g_ascii_strtod(v, NULL);
    g_free(v);
    return d;
}

static void on_fact(GtkButton *b, gpointer data) {
    Window *w = data;
    zg_search_show(w->search, g_object_get_data(G_OBJECT(b), "zg-query"), -1);
}

static void add_fact(Window *w, char *text, const char *query, const char *tip) {
    GtkWidget *b = gtk_button_new_with_label(text);
    gtk_widget_add_css_class(b, "zg-fact");
    char *t = g_strdup_printf("%s. Click to change it.", tip);
    gtk_widget_set_tooltip_text(b, t);
    g_free(t);
    g_object_set_data_full(G_OBJECT(b), "zg-query", g_strdup(query), g_free);
    g_signal_connect(b, "clicked", G_CALLBACK(on_fact), w);
    gtk_flow_box_append(GTK_FLOW_BOX(w->facts), b);
    g_free(text);
}

/* A length in mm with 3 digits at most: "0.2 mm". */
static char *mm(double v) {
    char buf[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_formatd(buf, sizeof buf, "%.3g", v);
    return g_strdup_printf("%s mm", buf);
}

static void fill_facts(Window *w) {
    gtk_flow_box_remove_all(GTK_FLOW_BOX(w->facts));
    double lh = num(w, "project.layer_height"), first = num(w, "project.first_layer_height");
    if (lh > 0) {
        char *a = mm(lh), *b = mm(first);
        add_fact(w, first > 0 && fabs(first - lh) > 1e-6 ? g_strdup_printf("%s layers (first %s)", a, b) : g_strdup_printf("%s layers", a),
                 "layer height", "The layer height, and the height of the first layer");
        g_free(a);
        g_free(b);
    }
    double walls = num(w, "project.wall_count");
    if (walls > 0) add_fact(w, g_strdup_printf("%.0f walls", walls), "wall count", "The number of walls");
    double density = num(w, "project.infill_density");
    char *pattern = zg_model_get(w->model, "project.infill_pattern");
    add_fact(w, density > 0 ? g_strdup_printf("%.0f %% %s", density * 100, pattern) : g_strdup("no infill"), "infill density",
             "The infill density and pattern");
    g_free(pattern);
    char *support = zg_model_get(w->model, "project.support");
    char *style = zg_model_get(w->model, "project.support_style");
    if (support[0] && strcmp(support, "off") != 0) {
        add_fact(w, g_strdup_printf("support: %s%s", strcmp(support, "buildplate") == 0 ? "on the bed" : support,
                                    strcmp(style, "tree") == 0 ? ", tree" : ""),
                 "support", "Support under overhangs");
    } else {
        add_fact(w, g_strdup("no support"), "support", "Support under overhangs");
    }
    g_free(support);
    g_free(style);
    double brim = num(w, "project.brim_width"), skirt = num(w, "project.skirt_loops");
    if (brim > 0) {
        char *b = mm(brim);
        add_fact(w, g_strdup_printf("brim %s", b), "brim width", "The brim, or the skirt");
        g_free(b);
    } else {
        add_fact(w, skirt > 0 ? g_strdup_printf("skirt %.0f", skirt) : g_strdup("no skirt"), "skirt loops", "The brim, or the skirt");
    }
    double nozzle = num(w, "filament.nozzle_temp"), bed = num(w, "filament.bed_temp");
    if (nozzle > 0)
        add_fact(w, bed > 0 ? g_strdup_printf("%.0f °C / bed %.0f °C", nozzle, bed) : g_strdup_printf("%.0f °C", nozzle), "nozzle temperature",
                 "The temperatures of the nozzle and the bed");
    double nd = num(w, "machine.nozzle_diameter");
    if (nd > 0) {
        char *b = mm(nd);
        add_fact(w, g_strdup_printf("%s nozzle", b), "nozzle diameter", "The diameter of the nozzle (printer settings)");
        g_free(b);
    }
}

/* The window after a change of the state. With refresh, the preview and
 * the 3D view too. */
static void update_window(Window *w, gboolean refresh) {
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

    gtk_widget_remove_css_class(w->status, "error");
    gboolean fits = state != ZS_STATE_DONE || zs_app_plate_fits(core) != 0;
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
            if (g_getenv("ZSLICE_BENCH")) g_message("bench: a slice of %.0f ms, %.0f ms after the start", ms, (g_get_monotonic_time() - zg_start_us) / 1000.0);
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
        /* A part off the bed, or on another part: the printer can hit its
         * frame. The status line says so in red. */
        if (!fits) {
            g_snprintf(text, sizeof text, "A part is off the bed or on another part. Move, turn, scale, or cut it before you print.");
            gtk_widget_add_css_class(w->status, "error");
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
    show_hint(w, state, fits);
    if (refresh) zg_preview_refresh(w->preview);
    show_islands(w, state);
    update_badge(w);
    if (state == ZS_STATE_DONE) refine_soon(w);
}

static void update(Window *w) {
    update_window(w, TRUE);
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
        /* A progress event changes the state only at the start of a slice
         * (the print card goes stale once). Late progress events of a slice
         * that ended update nothing: a load of many plates queued about a
         * hundred of them. */
        if (zs_app_state(zg_model_core(model)) != ZS_STATE_SLICING || gtk_widget_has_css_class(w->sum_box, "zg-stale")) return;
    }
    if (event == ZS_EVENT_FAILED) {
        g_free(w->last_error);
        w->last_error = g_strdup(zg_status_text(status));
    }
    if (event == ZS_EVENT_SLICED || event == ZS_EVENT_CHECKED) check_overhang(w);
    /* The simulated print of the slice: the view and the hint show it. */
    if (event == ZS_EVENT_SIMULATED && zs_app_sim_adopt(zg_model_core(model))) zg_preview_simulated(w->preview);
    /* A switch of the active plate: its "plate-changed" refreshed the
     * preview and loaded the view of the new plate. */
    update_window(w, !zg_model_plate_switching(model));
    if (w->send_pending && zs_app_state(zg_model_core(model)) != ZS_STATE_SLICING) {
        w->send_pending = FALSE;
        if (zs_app_state(zg_model_core(model)) == ZS_STATE_DONE) send_checked(w);
    }
    if (w->batch.on && event == ZS_EVENT_SLICED) batch_take(w);
    if (event == ZS_EVENT_SLICED) deck_estimate_soon(w);
    static gboolean stress_hooked;
    if (event == ZS_EVENT_SLICED && !stress_hooked && g_getenv("ZSLICE_STRESS")) {
        stress_hooked = TRUE;
        g_timeout_add_once(1500, stress_hook, w);
    }
    static gboolean action_hooked;
    if (event == ZS_EVENT_SLICED && !action_hooked && g_getenv("ZSLICE_ACTION")) {
        action_hooked = TRUE;
        g_timeout_add_once(1500, action_hook, w);
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
        /* A model file of the user ends project mode: the machine
         * settings of the printer of the user load again. */
        zg_model_project_end(w->model);
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

GtkWidget *zg_window_view3d(GtkWindow *window) {
    Window *w = get(window);
    return w && w->preview ? zg_preview_view3d(w->preview) : NULL;
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
        /* A copy: the core can replace its G-code while the write runs.
         * The file has the signature of this install (signing.h). */
        GBytes *raw = g_bytes_new(gcode, len);
        GBytes *bytes = zg_sign_gcode(raw);
        g_bytes_unref(raw);
        g_file_replace_contents_bytes_async(file, bytes, NULL, FALSE, G_FILE_CREATE_REPLACE_DESTINATION,
                                            NULL, on_saved, g_object_ref(window));
        g_bytes_unref(bytes);
    }
    if (file) g_object_unref(file);
    g_object_unref(window);
}

/* The name of the G-code file of the active plate, from the core: the
 * model, the plate, the layer height, the material, the printer, and the
 * time. Free it with g_free. */
static char *gcode_file_name(Window *w) {
    const char *name = zg_model_name(w->model);
    zs_set *set = zg_model_plate_set(w->model);
    size_t plate = set && zs_set_count(set) > 1 ? zs_set_active(set) + 1 : 0;
    char base[256] = "";
    if (zs_app_gcode_name(zg_model_core(w->model), name && *name ? name : "part", plate, base, sizeof base, NULL) != ZS_OK || !base[0])
        g_strlcpy(base, "part", sizeof base);
    return g_strconcat(base, ".gcode", NULL);
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
    char *initial = gcode_file_name(w);
    gtk_file_dialog_set_initial_name(dialog, initial);
    gtk_file_dialog_save(dialog, window, NULL, on_export_chosen, g_object_ref(window));
    g_free(initial);
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
        /* All plates in one project file (a 3MF file). */
        char *base = g_file_get_basename(file);
        char *dot = strrchr(base, '.');
        if (dot) *dot = 0;
        GBytes *copy = zg_model_project_bytes(w->model, base);
        g_free(base);
        if (copy) {
            g_file_replace_contents_bytes_async(file, copy, NULL, FALSE, G_FILE_CREATE_REPLACE_DESTINATION,
                                                NULL, on_plate_saved, g_object_ref(window));
            g_bytes_unref(copy);
        } else {
            show_error(w, "The 3MF file was not saved", "The project did not write.");
        }
        g_object_unref(file);
    }
    (void)bytes;
    (void)len;
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
        /* A printdeck waits for a press of Print on the deck. */
        ZgPrinter *cur = zg_printers_current();
        const char *fmt = !w->send_print ? "Sent to %s."
                          : cur->kind == ZG_LINK_PRINTDECK ? "Sent to %s. It prints, or waits for a press of Print if the deck is set to ask."
                                                           : "Sent to %s; it prints.";
        char *text = g_strdup_printf(fmt, cur->name);
        gtk_label_set_text(GTK_LABEL(w->printer_state), text);
        g_free(text);
        /* The plate of a project prints now. */
        if (w->send_print) zg_model_project_sent(w->model);
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
    char *file = gcode_file_name(w);
    GBytes *bytes = g_bytes_new(gcode, len);
    w->send_cancel = g_cancellable_new();
    gtk_widget_set_sensitive(w->send_button, FALSE);
    char *text = g_strdup_printf("Sending to %s…", pr->name);
    gtk_label_set_text(GTK_LABEL(w->printer_state), text);
    g_free(text);
    /* A Bambu Lab printer behind a deck prints a .gcode.3mf. */
    zs_app *core = zg_model_core(w->model);
    if (zg_link_wants_3mf(core, pr)) {
        char *file3 = g_strconcat(file, ".3mf", NULL);
        zg_link_send_wrapped(pr, file3, bytes, zg_link_bambu_wrap, core, w->send_print, w->send_cancel, on_send_progress, on_send_done, w);
        g_free(file3);
    } else {
        zg_link_send(pr, file, bytes, w->send_print, w->send_cancel, on_send_progress, on_send_done, w);
    }
    g_bytes_unref(bytes);
    g_free(file);
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

static void send_go(Window *w) {
    int state = zs_app_state(zg_model_core(w->model));
    if (state == ZS_STATE_SLICING) {
        w->send_pending = TRUE;
        return;
    }
    if (state == ZS_STATE_DONE) send_checked(w);
}

static void on_bed_clear_answer(GObject *src, GAsyncResult *res, gpointer data) {
    Window *w = data;
    int choice = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(src), res, NULL);
    if (choice == 1) send_go(w);
}

/* A print can start as soon as the file is there: a fresh yes of the
 * person, each time. (A printdeck set to ask waits for a press on it.) */
static void send(Window *w, gboolean print) {
    w->send_print = print;
    ZgPrinter *pr = zg_printers_current();
    if (!print || !pr) {
        send_go(w);
        return;
    }
    char *msg = g_strdup_printf("Is the bed of %s clear?", pr->name);
    GtkAlertDialog *d = gtk_alert_dialog_new("%s", msg);
    gtk_alert_dialog_set_detail(d, pr->kind == ZG_LINK_PRINTDECK ? "The print starts when the file is there. A deck set to ask waits for a press of Print on it."
                                                                  : "The print starts when the file is there.");
    const char *buttons[] = {"Cancel", "Print", NULL};
    gtk_alert_dialog_set_buttons(d, buttons);
    gtk_alert_dialog_set_cancel_button(d, 0);
    gtk_alert_dialog_set_default_button(d, 1);
    gtk_alert_dialog_choose(d, GTK_WINDOW(w->window), NULL, on_bed_clear_answer, w);
    g_object_unref(d);
    g_free(msg);
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
    if (!w->batch.on || zs_set_active(zg_model_plate_set(w->model)) != w->batch.i) return;
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
        GBytes *signed_gcode = zg_sign_gcode(bytes);
        gsize slen = 0;
        const char *sdata = g_bytes_get_data(signed_gcode, &slen);
        gboolean ok = g_file_replace_contents(out, sdata, slen, NULL, FALSE, G_FILE_CREATE_REPLACE_DESTINATION, NULL, NULL, &error);
        g_bytes_unref(signed_gcode);
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
    zs_set *set = zg_model_plate_set(w->model);
    zs_plate_info info;
    while (w->batch.i < w->batch.n &&
           (zs_set_plate_info(set, w->batch.i, &info) != ZS_OK || info.part_count == 0 || info.status == ZS_PLATE_STATUS_CANNOT))
        w->batch.i++;
    if (w->batch.i >= w->batch.n) {
        batch_finish(w, NULL);
        return;
    }
    if (zs_set_active(set) != w->batch.i) {
        zg_model_plate_select(w->model, w->batch.i);
    } else if (zs_app_state(zg_model_core(w->model)) == ZS_STATE_DONE) {
        g_idle_add(batch_take_later, w);
    }
}

static void batch_start(Window *w, gboolean send, GFile *dir) {
    zs_set *set = zg_model_plate_set(w->model);
    w->batch.on = TRUE;
    w->batch.send = send;
    w->batch.i = 0;
    w->batch.done = 0;
    w->batch.n = zs_set_count(set);
    w->batch.back = zs_set_active(set);
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
    /* A plate of a project keeps the filament settings of the project. */
    if (info && info->spool_id && info->spool_id[0] && strcmp(follow, "1") == 0 && !zg_model_project_active(w->model)) {
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
        char *tip = g_strdup_printf(pr->kind == ZG_LINK_USB ? "Print on %s over USB"
                                    : pr->kind == ZG_LINK_PRINTDECK ? "Upload the G-code to %s and start the print (a deck set to ask waits for a press of Print on it)"
                                                                    : "Upload the G-code to %s and start the print",
                                    pr->name);
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

/* For tests: ZSLICE_ACTION=name runs an action 1.5 s after the first
 * slice, as a click would: a detailed name, for example
 * "win.search-part(int64 0)" or "win.show-page('history')". */
static void action_hook(gpointer data) {
    Window *w = data;
    char *name = NULL;
    GVariant *target = NULL;
    GError *error = NULL;
    if (!g_action_parse_detailed_name(g_getenv("ZSLICE_ACTION"), &name, &target, &error)) {
        g_warning("ZSLICE_ACTION: %s", error->message);
        g_error_free(error);
        return;
    }
    gtk_widget_activate_action_variant(w->preview, name, target);
    g_free(name);
}

/* For tests of the frame rate (with ZSLICE_STALLS): ZSLICE_STRESS=n makes
 * n fast changes after the first slice, 20 to 400 ms apart: values of the
 * infill density and the wall count, the simulated print on and off, and
 * plate switches. ZSLICE_STRESS_FILE=path first adds a second plate with
 * that file. ZSLICE_STRESS_ONLY=set, sim, or plate makes one kind of
 * change. */
typedef struct {
    Window *w;
    int left;
    guint32 seed;
} Stress;

static guint32 stress_rand(Stress *s) {
    s->seed = s->seed * 1103515245u + 12345u;
    return s->seed >> 8;
}

static gboolean stress_step(gpointer data) {
    Stress *s = data;
    Window *w = s->w;
    if (s->left-- <= 0) {
        g_message("stress: done");
        g_free(s);
        return G_SOURCE_REMOVE;
    }
    zs_set *set = zg_model_plate_set(w->model);
    guint32 r = stress_rand(s) % 100;
    const char *only = g_getenv("ZSLICE_STRESS_ONLY");
    if (g_strcmp0(only, "set") == 0) r = r * 60 / 100;
    else if (g_strcmp0(only, "sim") == 0) r = 70;
    else if (g_strcmp0(only, "plate") == 0) r = 90;
    if (r < 45) {
        char v[16];
        g_snprintf(v, sizeof v, "%u", 5 + stress_rand(s) % 40);
        zg_model_set(w->model, "project.infill_density", v, NULL);
    } else if (r < 60) {
        char v[16];
        g_snprintf(v, sizeof v, "%u", 1 + stress_rand(s) % 4);
        zg_model_set(w->model, "project.wall_count", v, NULL);
    } else if (r < 80) {
        gtk_widget_activate_action(w->preview, "preview.simulate", NULL);
    } else if (zs_set_count(set) > 1) {
        zg_model_plate_select(w->model, (zs_set_active(set) + 1) % zs_set_count(set));
    }
    g_timeout_add(20 + stress_rand(s) % 380, stress_step, s);
    return G_SOURCE_REMOVE;
}

static void stress_hook(gpointer data) {
    Window *w = data;
    Stress *s = g_new0(Stress, 1);
    s->w = w;
    s->left = atoi(g_getenv("ZSLICE_STRESS"));
    s->seed = 7;
    const char *file = g_getenv("ZSLICE_STRESS_FILE");
    guint wait = 0;
    if (file && zs_set_count(zg_model_plate_set(w->model)) == 1) {
        zg_model_plate_add(w->model);
        GFile *f = g_file_new_for_path(file);
        zg_window_open_file(w->window, f);
        g_object_unref(f);
        wait = 4000;
    }
    g_message("stress: %d changes", s->left);
    g_timeout_add(wait + 100, stress_step, s);
}

/* For tests: ZSLICE_PREFS=1 opens Preferences at the start. */
static gboolean open_prefs_test(gpointer data) {
    Window *w = data;
    zg_preferences_show(w->window, w->model);
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

/* "Remove this plate": a plate with parts asks first. The plates are not
 * in the undo list, so the question says that the removal is final. */
static void on_remove_plate_answer(GObject *source, GAsyncResult *res, gpointer data) {
    Window *w = data;
    int button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), res, NULL);
    size_t i = GPOINTER_TO_SIZE(g_object_get_data(source, "zg-plate"));
    if (button == 1) zg_model_plate_remove(w->model, i);
}

static void on_remove_plate_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    zs_set *set = zg_model_plate_set(w->model);
    size_t i = zs_set_active(set);
    zs_plate_info info;
    if (zs_set_plate_info(set, i, &info) != ZS_OK) return;
    if (info.part_count == 0) {
        zg_model_plate_remove(w->model, i);
        return;
    }
    GtkAlertDialog *d = info.part_count == 1 ? gtk_alert_dialog_new("Remove plate %zu and its part?", i + 1)
                                             : gtk_alert_dialog_new("Remove plate %zu and its %zu parts?", i + 1, info.part_count);
    gtk_alert_dialog_set_detail(d, "This cannot be undone.");
    const char *buttons[] = {"Cancel", "Remove", NULL};
    gtk_alert_dialog_set_buttons(d, buttons);
    gtk_alert_dialog_set_cancel_button(d, 0);
    gtk_alert_dialog_set_default_button(d, 0);
    g_object_set_data(G_OBJECT(d), "zg-plate", GSIZE_TO_POINTER(i));
    gtk_alert_dialog_choose(d, GTK_WINDOW(w->window), NULL, on_remove_plate_answer, w);
    g_object_unref(d);
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

/* ---- the panel: a drawer ----
 *
 * Hidden: the view has the whole window. Over: the panel slides over the
 * right of the view. Pinned: the panel is beside the view, with the
 * splitter of the paned. N or the button of the header bar shows and hides
 * it; Pin switches between over and beside. The choice stays in the app
 * settings (panel, panel_pinned). */

static void set_panel_mode(Window *w, int mode) {
    GtkWidget *parent = gtk_widget_get_parent(w->panel);
    gboolean in_paned = parent == w->paned;
    if (mode == PANEL_PINNED && !in_paned) {
        g_object_ref(w->panel);
        if (parent) gtk_overlay_remove_overlay(GTK_OVERLAY(w->body), w->panel);
        gtk_paned_set_end_child(GTK_PANED(w->paned), w->panel);
        g_object_unref(w->panel);
        gtk_widget_remove_css_class(w->panel, "zg-drawer");
    } else if (mode == PANEL_OVER && in_paned) {
        g_object_ref(w->panel);
        gtk_paned_set_end_child(GTK_PANED(w->paned), NULL);
        gtk_overlay_add_overlay(GTK_OVERLAY(w->body), w->panel);
        g_object_unref(w->panel);
        gtk_widget_add_css_class(w->panel, "zg-drawer");
    }
    gtk_widget_set_visible(w->panel, mode != PANEL_HIDDEN);
    w->panel_mode = mode;
    if (mode != PANEL_HIDDEN) zg_pref_set("panel_pinned", mode == PANEL_PINNED ? "1" : "0");
    zg_pref_set("panel", panel_modes[mode]);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(w->panel_toggle), mode != PANEL_HIDDEN);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(w->pin), mode == PANEL_PINNED);
    /* A hidden panel gives the keys to the view. */
    if (mode == PANEL_HIDDEN && gtk_widget_get_mapped(w->preview)) gtk_widget_grab_focus(w->preview);
}

/* Shows the panel: over the view, or pinned if the user pinned it last. */
static void show_panel(Window *w) {
    if (w->panel_mode != PANEL_HIDDEN) return;
    char *pinned = zg_pref_get("panel_pinned", "0");
    set_panel_mode(w, strcmp(pinned, "1") == 0 ? PANEL_PINNED : PANEL_OVER);
    g_free(pinned);
}

static void on_panel_toggled(GtkToggleButton *b, gpointer data) {
    Window *w = data;
    gboolean on = gtk_toggle_button_get_active(b);
    if (on == (w->panel_mode != PANEL_HIDDEN)) return;
    if (on) show_panel(w);
    else set_panel_mode(w, PANEL_HIDDEN);
}

static void on_pin_toggled(GtkToggleButton *b, gpointer data) {
    Window *w = data;
    gboolean on = gtk_toggle_button_get_active(b);
    if (on == (w->panel_mode == PANEL_PINNED) || w->panel_mode == PANEL_HIDDEN) return;
    set_panel_mode(w, on ? PANEL_PINNED : PANEL_OVER);
}

static void on_panel_close(GtkButton *b, gpointer data) {
    set_panel_mode(data, PANEL_HIDDEN);
}

static void on_panel_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    if (w->panel_mode == PANEL_HIDDEN) show_panel(w);
    else set_panel_mode(w, PANEL_HIDDEN);
}

/* The Printers page over the view. The page reads the printers only
 * while it shows (farm-page.h). It has the width of the view, so a panel
 * over the view hides. */
static void show_farm(Window *w, gboolean show) {
    gtk_widget_set_visible(w->farm_view, show);
    if (show && w->panel_mode == PANEL_OVER) set_panel_mode(w, PANEL_HIDDEN);
    if (gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(w->printers_button)) != show)
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(w->printers_button), show);
    if (show) gtk_widget_grab_focus(w->farm_view);
    else gtk_widget_grab_focus(w->preview);
}

static void on_printers_toggled(GtkToggleButton *b, gpointer data) {
    Window *w = data;
    gboolean on = gtk_toggle_button_get_active(b);
    if (on != gtk_widget_get_visible(w->farm_view)) show_farm(w, on);
}

static void on_farm_back(GtkButton *b, gpointer data) {
    show_farm(data, FALSE);
}

/* Esc on the Printers page goes back to the plate. */
static gboolean on_farm_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    if (key != GDK_KEY_Escape) return FALSE;
    show_farm(data, FALSE);
    return TRUE;
}

static GtkWidget *farm_view_new(Window *w) {
    GtkWidget *view = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(view, "zg-farm-view");
    gtk_widget_set_focusable(view, TRUE);
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(bar, "zg-farm-bar");
    GtkWidget *back = gtk_button_new();
    GtkWidget *inner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_append(GTK_BOX(inner), gtk_image_new_from_icon_name("go-previous-symbolic"));
    gtk_box_append(GTK_BOX(inner), gtk_label_new("Back to the plate"));
    gtk_button_set_child(GTK_BUTTON(back), inner);
    gtk_widget_set_tooltip_text(back, "Back to the plate (Esc)");
    g_signal_connect(back, "clicked", G_CALLBACK(on_farm_back), w);
    gtk_box_append(GTK_BOX(bar), back);
    GtkWidget *page = zg_farm_page_new(w->model);
    gtk_widget_set_vexpand(page, TRUE);
    gtk_box_append(GTK_BOX(view), bar);
    gtk_box_append(GTK_BOX(view), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(view), page);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_farm_key), w);
    gtk_widget_add_controller(view, keys);
    gtk_widget_set_visible(view, FALSE);
    return view;
}

/* The Project dialog: a printdeck.yml project and its plates. The page
 * lives as long as the window, so the dialog only hides on close. */
static gboolean on_dialog_escape(GtkWidget *widget, GVariant *args, gpointer data) {
    gtk_window_close(GTK_WINDOW(widget));
    return TRUE;
}

static GtkWidget *project_dialog_new(Window *w) {
    GtkWidget *d = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(d), "Project");
    gtk_window_set_titlebar(GTK_WINDOW(d), gtk_header_bar_new());
    gtk_window_set_transient_for(GTK_WINDOW(d), w->window);
    gtk_window_set_modal(GTK_WINDOW(d), TRUE);
    gtk_window_set_hide_on_close(GTK_WINDOW(d), TRUE);
    gtk_window_set_destroy_with_parent(GTK_WINDOW(d), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(d), 620, 720);
    gtk_window_set_child(GTK_WINDOW(d), zg_project_page_new(w->model));
    GtkEventController *keys = gtk_shortcut_controller_new();
    gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(keys),
                                         gtk_shortcut_new(gtk_keyval_trigger_new(GDK_KEY_Escape, 0),
                                                          gtk_callback_action_new(on_dialog_escape, NULL, NULL)));
    gtk_widget_add_controller(d, keys);
    return d;
}

/* Shows a place: "settings" or "selected" in the panel, "history" (the
 * popover over the dock), "project" (the dialog), or "farm" (the
 * Printers page). */
static void on_show_page_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    const char *name = g_variant_get_string(v, NULL);
    if (strcmp(name, "history") == 0) {
        zg_timeline_show_history(w->timeline);
    } else if (strcmp(name, "project") == 0) {
        gtk_window_present(GTK_WINDOW(w->project_dialog));
    } else if (strcmp(name, "farm") == 0) {
        show_farm(w, TRUE);
    } else {
        if (gtk_widget_get_visible(w->farm_view)) show_farm(w, FALSE);
        show_panel(w);
        zg_settings_panel_show_page(w->settings_panel, name);
    }
}

/* Shows the panel at the setting of the name (for example
 * "project.infill_density"). */
static void on_show_setting_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    if (gtk_widget_get_visible(w->farm_view)) show_farm(w, FALSE);
    show_panel(w);
    zg_settings_panel_show_setting(w->settings_panel, g_variant_get_string(v, NULL));
}

/* The search (/), with a text (a string), or the search of one part
 * (search-part, the index of the part). */
static void on_search_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    zg_search_show(w->search, v ? g_variant_get_string(v, NULL) : "", -1);
}

static void on_search_part_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    zg_search_show(w->search, "", g_variant_get_int64(v));
}

/* "win.view-2d": the 2D layer view (TRUE) or the 3D view (FALSE). The
 * main menu shows it as the check "2D view", and the key 2 turns it. */
static void on_view_2d_change(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    gtk_stack_set_visible_child_name(GTK_STACK(zg_preview_stack(w->preview)), g_variant_get_boolean(v) ? "2d" : "3d");
}

/* The state of "win.view-2d" follows the stack: the replay also turns to
 * 3D. */
static void on_view_page(GObject *stack, GParamSpec *pspec, gpointer data) {
    GAction *a = g_action_map_lookup_action(G_ACTION_MAP(data), "view-2d");
    gboolean two = strcmp(gtk_stack_get_visible_child_name(GTK_STACK(stack)), "2d") == 0;
    if (a) g_simple_action_set_state(G_SIMPLE_ACTION(a), g_variant_new_boolean(two));
}

static void on_shortcuts_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    zg_search_close(w->search);
    zg_shortcuts_toggle(w->window);
}

/* The search ended its focus: the Settings page sends its own again, if
 * it shows. */
static void on_refocus_action(GSimpleAction *a, GVariant *v, gpointer data) {
    Window *w = get(data);
    zg_settings_panel_refocus(w->settings_panel);
}

/* Esc in the panel over the view hides it (an entry keeps its Esc). */
static gboolean on_panel_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Window *w = data;
    if (key != GDK_KEY_Escape || w->panel_mode != PANEL_OVER) return FALSE;
    GtkWidget *focus = gtk_window_get_focus(w->window);
    if (focus && (GTK_IS_EDITABLE(focus) || GTK_IS_TEXT_VIEW(focus) || gtk_widget_get_ancestor(focus, GTK_TYPE_POPOVER))) return FALSE;
    set_panel_mode(w, PANEL_HIDDEN);
    return TRUE;
}

/* The drawer over the view: the right part of the window, 460 points
 * wide (as the web app), or less in a narrow window. */
static gboolean on_body_child(GtkOverlay *overlay, GtkWidget *child, GdkRectangle *alloc, gpointer data) {
    Window *w = data;
    if (child != w->panel) return FALSE;
    int W = gtk_widget_get_width(GTK_WIDGET(overlay)), H = gtk_widget_get_height(GTK_WIDGET(overlay));
    int width = MIN(460, W * 92 / 100);
    int min = 0;
    gtk_widget_measure(child, GTK_ORIENTATION_HORIZONTAL, -1, &min, NULL, NULL, NULL);
    width = MAX(width, min);
    alloc->x = W - width;
    alloc->y = 0;
    alloc->width = width;
    alloc->height = H;
    return TRUE;
}

/* The width of the pinned panel, for the next start. */
static void on_paned_position(GObject *paned, GParamSpec *pspec, gpointer data) {
    Window *w = data;
    if (w->panel_mode != PANEL_PINNED || !gtk_widget_get_mapped(w->panel)) return;
    int width = gtk_widget_get_width(GTK_WIDGET(paned)) - gtk_paned_get_position(GTK_PANED(paned));
    if (width < 300) return;
    char buf[16];
    g_snprintf(buf, sizeof buf, "%d", width);
    zg_pref_set("panel_width", buf);
}

/* The keys of the whole window that no widget took: N shows or hides
 * the panel, and the Ctrl keys of the clipboard. A text field keeps its
 * keys. */
static gboolean on_window_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Window *w = data;
    GtkWidget *focus = gtk_window_get_focus(w->window);
    /* Ctrl+C, Ctrl+X, Ctrl+V, and Ctrl+D: the clipboard (view3d.c). */
    if (zg_view3d_clip_key(zg_preview_view3d(w->preview), key, mods, focus)) return TRUE;
    if (mods & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK)) return FALSE;
    if (focus && (GTK_IS_EDITABLE(focus) || GTK_IS_TEXT_VIEW(focus))) return FALSE;
    switch (key) {
    case GDK_KEY_n: case GDK_KEY_N:
        if (w->panel_mode == PANEL_HIDDEN) show_panel(w);
        else set_panel_mode(w, PANEL_HIDDEN);
        return TRUE;
    case GDK_KEY_question:
        zg_search_close(w->search);
        zg_shortcuts_toggle(w->window);
        return TRUE;
    case GDK_KEY_slash:
        /* / again closes the search (it stays open while the view moves). */
        if (zg_search_is_open(w->search)) zg_search_close(w->search);
        else zg_search_show(w->search, NULL, -1);
        return TRUE;
    case GDK_KEY_2:
    case GDK_KEY_KP_2: {
        /* 2: the 2D view, or the 3D view again. */
        GtkStack *stack = GTK_STACK(zg_preview_stack(w->preview));
        gtk_stack_set_visible_child_name(stack, strcmp(gtk_stack_get_visible_child_name(stack), "2d") == 0 ? "3d" : "2d");
        return TRUE;
    }
    case GDK_KEY_3:
    case GDK_KEY_KP_3:
        gtk_stack_set_visible_child_name(GTK_STACK(zg_preview_stack(w->preview)), "3d");
        return TRUE;
    case GDK_KEY_Escape:
        /* Esc closes the search also when the view has the focus, once the
         * keys of the view (a selection, the tape) are done. */
        if (!zg_search_is_open(w->search)) return FALSE;
        zg_search_close(w->search);
        return TRUE;
    default: return FALSE;
    }
}

/* ---- window ---- */

/* The labels of the printer menu: data 1 makes a label that shortens
 * with "…". */
static void on_name_setup(GtkSignalListItemFactory *f, GtkListItem *item, gpointer data) {
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    if (data) {
        gtk_label_set_wrap(GTK_LABEL(label), TRUE);
        gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD);
    }
    gtk_list_item_set_child(item, label);
}

static void on_name_bind(GtkSignalListItemFactory *f, GtkListItem *item, gpointer data) {
    GtkStringObject *s = gtk_list_item_get_item(item);
    gtk_label_set_text(GTK_LABEL(gtk_list_item_get_child(item)), s ? gtk_string_object_get_string(s) : "");
}

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

/* For tests: ZSLICE_PLATES=file;file;... adds a plate for each file and
 * loads the file on it, one each 1.5 s, then goes back to plate 1. */
static gboolean plates_step(gpointer data) {
    Window *w = data;
    static guint k = 0;
    char **files = g_strsplit(g_getenv("ZSLICE_PLATES"), ";", -1);
    guint n = g_strv_length(files);
    if (k < n) {
        char *bytes = NULL;
        gsize len = 0;
        if (g_file_get_contents(files[k], &bytes, &len, NULL)) {
            char *name = g_path_get_basename(files[k]);
            zg_model_plate_add(w->model);
            zg_model_load(w->model, name, bytes, len, NULL);
            g_free(name);
        }
        g_free(bytes);
        k++;
        g_strfreev(files);
        return G_SOURCE_CONTINUE;
    }
    g_strfreev(files);
    zg_model_plate_select(w->model, 0);
    g_message("plates: %zu plates", zs_set_count(zg_model_plate_set(w->model)));
    return G_SOURCE_REMOVE;
}

/* For development: ZSLICE_PLATE_TEST=file adds a plate, puts the model
 * file on it, adds an empty plate and removes it, goes to the plate before
 * and back with the keys of the plate bar, and removes the plate with the
 * file, one step each second. The log gives the plates of the set. */
static gboolean plate_test_step(gpointer data) {
    Window *w = data;
    static int step = 0;
    zs_set *set = zg_model_plate_set(w->model);
    switch (step++) {
    case 0: zg_model_plate_add(w->model); break;
    case 1: {
        char *bytes = NULL;
        gsize len = 0;
        const char *path = g_getenv("ZSLICE_PLATE_TEST");
        if (g_file_get_contents(path, &bytes, &len, NULL)) {
            char *name = g_path_get_basename(path);
            zg_model_load(w->model, name, bytes, len, NULL);
            g_free(name);
        }
        g_free(bytes);
        break;
    }
    case 2: case 3: break; /* the slices */
    case 4: zg_model_plate_add(w->model); break;
    case 5: g_action_group_activate_action(G_ACTION_GROUP(w->window), "remove-plate", NULL); break;
    case 6: zg_model_plate_select(w->model, 0); break;
    case 7: zg_model_plate_select(w->model, 1); break;
    case 8: zg_model_plate_remove(w->model, 1); break;
    default: return G_SOURCE_REMOVE;
    }
    size_t n = zs_set_count(set);
    for (size_t i = 0; i < n; i++) {
        zs_plate_info info;
        if (zs_set_plate_info(set, i, &info) != ZS_OK) continue;
        g_message("plate test %d: %s%zu %s, status %d, %zu parts, app state %d", step - 1, i == zs_set_active(set) ? "*" : " ", i + 1,
                  info.name, info.status, info.part_count, zs_app_state(zs_set_app(set, i)));
    }
    return G_SOURCE_CONTINUE;
}

/* For development: ZSLICE_UNDO_TEST=1 changes the infill density twice,
 * then undoes and redoes, moves part 0 and undoes the move, edits the wall
 * count three times with the focus on its editor (one step), goes to step
 * 1, and clears the history after it. It logs each value and the steps. */
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
    /* The edits of one setting while its editor has the focus: one step. */
    case 8: zg_model_history_set_focus(w->model, "project.wall_count");
            zg_model_set(w->model, "project.wall_count", "3", NULL); break;
    case 9: zg_model_set(w->model, "project.wall_count", "4", NULL); break;
    case 10: zg_model_set(w->model, "project.wall_count", "5", NULL); break;
    case 11: zg_model_history_set_focus(w->model, NULL); break;
    case 12: zg_model_history_goto(w->model, 1); break;
    case 13: zg_model_history_truncate(w->model, 1); break;
    default: return G_SOURCE_REMOVE;
    }
    {
        guint n = zg_model_history_count(w->model);
        g_message("undo test %d: step %u of %u", step - 1, zg_model_history_current(w->model), n);
        for (guint i = 1; i < n; i++) {
            char *changes = zg_model_history_changes(w->model, i);
            char *words = zg_model_history_describe(w->model, changes);
            g_strdelimit(words, "\n", ';');
            g_message("undo test %d:   %u %s", step - 1, i, words);
            g_free(words);
            g_free(changes);
        }
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
    if (w->refine_timer) g_source_remove(w->refine_timer);
    if (w->sum_pop) gtk_widget_unparent(w->sum_pop);
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
    char *saved = zg_pref_get("panel_width", "560");
    int panel = CLAMP(atoi(saved), 300, 2000);
    g_free(saved);
    if (width > panel + 240) gtk_paned_set_position(GTK_PANED(paned), width - panel);
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
    /* The file button: it opens models, at the start, before the name. */
    GtkWidget *open = gtk_button_new_from_icon_name("document-open-symbolic");
    gtk_widget_set_tooltip_text(open, "Open a model, or add models to this plate (Ctrl+O opens)");
    gtk_widget_set_focus_on_click(open, FALSE);
    g_signal_connect(open, "clicked", G_CALLBACK(on_open_clicked), w->window);

    w->export_button = gtk_button_new_with_label("Export G-code…");
    gtk_widget_add_css_class(w->export_button, "suggested-action");
    gtk_widget_set_tooltip_text(w->export_button, "Save the G-code (Ctrl+E)");
    g_signal_connect(w->export_button, "clicked", G_CALLBACK(on_export_clicked), w->window);

    /* The printer, and the send button with its menu. */
    w->printer_names = gtk_string_list_new(NULL);
    w->printer_dd = gtk_drop_down_new(G_LIST_MODEL(w->printer_names), NULL);
    /* The name on the button wraps in a narrow window. The list shows the
     * whole names. */
    GtkListItemFactory *short_names = gtk_signal_list_item_factory_new();
    g_signal_connect(short_names, "setup", G_CALLBACK(on_name_setup), GINT_TO_POINTER(1));
    g_signal_connect(short_names, "bind", G_CALLBACK(on_name_bind), NULL);
    GtkListItemFactory *names = gtk_signal_list_item_factory_new();
    g_signal_connect(names, "setup", G_CALLBACK(on_name_setup), GINT_TO_POINTER(0));
    g_signal_connect(names, "bind", G_CALLBACK(on_name_bind), NULL);
    gtk_drop_down_set_factory(GTK_DROP_DOWN(w->printer_dd), short_names);
    gtk_drop_down_set_list_factory(GTK_DROP_DOWN(w->printer_dd), names);
    g_object_unref(short_names);
    g_object_unref(names);
    gtk_widget_set_tooltip_text(w->printer_dd, "The printer: its machine settings, and where Send goes. From this list: the settings and the start and end G-code of the printer, or add a printer. Edit the connections in Preferences.");
    g_signal_connect(w->printer_dd, "notify::selected", G_CALLBACK(on_printer_dd), w);
    /* The setup of the print, as one group at the end: the printer, the
     * filament, and the quality. */
    GtkWidget *setup = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(setup, "linked");
    gtk_box_append(GTK_BOX(setup), w->printer_dd);
    gtk_box_append(GTK_BOX(setup), zg_filament_button_new(model));
    gtk_box_append(GTK_BOX(setup), zg_profile_menu_new(model, ZS_GROUP_FILAMENT));
    gtk_box_append(GTK_BOX(setup), zg_profile_menu_new(model, ZS_GROUP_PROJECT));
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
        {.name = "remove-plate", .activate = on_remove_plate_action},
        {.name = "smart-place", .activate = on_smart_place_action},
        {.name = "send-all", .activate = on_send_all_action},
        {.name = "export-all", .activate = on_export_all_action},
        {.name = "save-plate", .activate = on_save_plate_action},
        {.name = "clear-plate", .activate = on_clear_action},
        {.name = "undo", .activate = on_undo_action},
        {.name = "redo", .activate = on_redo_action},
        {.name = "panel", .activate = on_panel_action},
        {.name = "show-page", .activate = on_show_page_action, .parameter_type = "s"},
        {.name = "show-setting", .activate = on_show_setting_action, .parameter_type = "s"},
        {.name = "search", .activate = on_search_action, .parameter_type = "s"},
        {.name = "search-part", .activate = on_search_part_action, .parameter_type = "x"},
        {.name = "refocus", .activate = on_refocus_action},
        {.name = "shortcuts", .activate = on_shortcuts_action},
        {.name = "scale-tiny", .activate = on_scale_tiny_action, .parameter_type = "d"},
        {.name = "support-on", .activate = on_support_on_action},
        {.name = "print-details", .activate = on_print_details_action},
        {.name = "view-2d", .state = "false", .change_state = on_view_2d_change},
    };
    g_action_map_add_action_entries(G_ACTION_MAP(w->window), win_actions, G_N_ELEMENTS(win_actions), w->window);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_undo_changed), w);
    on_undo_changed(model, w);
    if (g_getenv("ZSLICE_UNDO_TEST")) g_timeout_add(1000, undo_test_step, w);
    if (g_getenv("ZSLICE_PLATE_TEST")) g_timeout_add(1000, plate_test_step, w);
    if (g_getenv("ZSLICE_PLATES")) g_timeout_add(1500, plates_step, w);
    if (g_getenv("ZSLICE_CURA_COMPARE")) g_timeout_add(1500, open_cura_compare_test, w);
    if (g_getenv("ZSLICE_PREFS")) g_timeout_add(1500, open_prefs_test, w);

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
    g_menu_append(menu, "Remove this plate", "win.remove-plate");
    g_menu_append(menu, "Compare with Cura\u2026", "win.compare-cura");
    GMenu *places = g_menu_new();
    g_menu_append(places, "Open a project\u2026", "win.show-page::project");
    g_menu_append(places, "Printers", "win.show-page::farm");
    g_menu_append(places, "History", "win.show-page::history");
    g_menu_append_section(menu, NULL, G_MENU_MODEL(places));
    g_object_unref(places);
    GMenu *view = g_menu_new();
    GMenuItem *view_2d = g_menu_item_new("2D view", "win.view-2d");
    g_menu_item_set_attribute(view_2d, "accel", "s", "2");
    g_menu_append_item(view, view_2d);
    g_object_unref(view_2d);
    g_menu_append_section(menu, NULL, G_MENU_MODEL(view));
    g_object_unref(view);
    GMenu *more = g_menu_new();
    g_menu_append_section(menu, NULL, G_MENU_MODEL(more));
    g_menu_append(more, "Keyboard shortcuts", "win.shortcuts");
    g_menu_append(more, "Preferences", "win.preferences");
    g_menu_append(more, "Licenses", "app.licenses");
    g_menu_append(more, "About zslice", "app.about");
    g_object_unref(more);
    GtkWidget *menu_button = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menu_button), "open-menu-symbolic");
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menu_button), G_MENU_MODEL(menu));
    /* F10 opens it. */
    gtk_menu_button_set_primary(GTK_MENU_BUTTON(menu_button), TRUE);
    gtk_widget_set_tooltip_text(menu_button, "Main menu (F10)");
    g_object_unref(menu);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), menu_button);
    /* The button of the drawer: all settings. */
    w->panel_toggle = gtk_toggle_button_new();
    gtk_button_set_icon_name(GTK_BUTTON(w->panel_toggle), "sidebar-show-right-symbolic");
    gtk_widget_set_tooltip_text(w->panel_toggle, "Show or hide all settings (N)");
    g_signal_connect(w->panel_toggle, "toggled", G_CALLBACK(on_panel_toggled), w);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), w->panel_toggle);
    /* The Printers page: it covers the view. */
    w->printers_button = gtk_toggle_button_new();
    gtk_button_set_icon_name(GTK_BUTTON(w->printers_button), "printer-symbolic");
    gtk_widget_set_tooltip_text(w->printers_button, "Printers: your printers, their jobs, and the plates to print");
    g_signal_connect(w->printers_button, "toggled", G_CALLBACK(on_printers_toggled), w);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), w->printers_button);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), setup);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), open);

    /* The name of the file, after the file button. */
    w->title = gtk_label_new("zslice");
    gtk_widget_add_css_class(w->title, "title");
    gtk_label_set_wrap(GTK_LABEL(w->title), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(w->title), PANGO_WRAP_WORD);
    gtk_label_set_max_width_chars(GTK_LABEL(w->title), 28);
    gtk_widget_set_margin_start(w->title, 6);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), w->title);

    /* Body: settings | preview. */
    w->preview = zg_preview_new(model);
    /* The check "2D view" of the main menu follows the view. */
    g_signal_connect(zg_preview_stack(w->preview), "notify::visible-child", G_CALLBACK(on_view_page), w->window);
    on_view_page(G_OBJECT(zg_preview_stack(w->preview)), NULL, w->window);
    /* The middle of the header bar: Search, and the legend of the colors
     * of the preview. */
    GtkWidget *view_bar = zg_preview_view_bar(w->preview);
    /* The search: its field (or its Search button, while it is undocked)
     * in the header, and its results over the view (added below). */
    w->search = zg_search_new(model);
    gtk_box_prepend(GTK_BOX(view_bar), zg_search_header(w->search));
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), view_bar);
    /* In a narrow window, the menus at the end keep their names, and the
     * view bar moves off the middle first. */
    for (GtkWidget *c = gtk_widget_get_parent(view_bar); c && c != header; c = gtk_widget_get_parent(c)) {
        if (GTK_IS_CENTER_BOX(c)) gtk_center_box_set_shrink_center_last(GTK_CENTER_BOX(c), FALSE);
    }
    gtk_window_set_titlebar(w->window, header);
    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    GtkWidget *settings = zg_settings_panel_new(model);
    w->settings_panel = settings;
    gtk_widget_set_vexpand(settings, TRUE);
    /* The print card: it floats at the bottom right of the view. */
    w->sum_box = zg_card_new();
    gtk_box_set_spacing(GTK_BOX(w->sum_box), 2);
    gtk_widget_add_css_class(w->sum_box, "zg-print-card");
    w->sum_time = gtk_label_new("—");
    gtk_widget_add_css_class(w->sum_time, "zg-summary-time");
    gtk_label_set_xalign(GTK_LABEL(w->sum_time), 0);
    w->sum_detail = gtk_label_new("");
    gtk_widget_add_css_class(w->sum_detail, "dim-label");
    gtk_label_set_xalign(GTK_LABEL(w->sum_detail), 0);
    w->sum_deck = gtk_label_new("");
    gtk_widget_add_css_class(w->sum_deck, "dim-label");
    gtk_widget_add_css_class(w->sum_deck, "caption");
    gtk_label_set_xalign(GTK_LABEL(w->sum_deck), 0);
    gtk_label_set_wrap(GTK_LABEL(w->sum_deck), TRUE);
    gtk_widget_set_visible(w->sum_deck, FALSE);
    w->facts = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(w->facts), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(w->facts), 3);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(w->facts), 3);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(w->facts), 3);
    gtk_widget_add_css_class(w->facts, "zg-facts");
    gtk_widget_set_margin_bottom(w->facts, 4);
    /* The buttons: print (with its menu: upload only, export), or export
     * with no printer, at the right of the head of the print. */
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_valign(actions, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(send_box, 150, -1);
    gtk_widget_set_hexpand(w->send_button, TRUE);
    gtk_widget_set_size_request(w->export_button, 150, -1);
    gtk_box_append(GTK_BOX(actions), send_box);
    gtk_box_append(GTK_BOX(actions), w->export_button);
    /* The state of the slice, and messages (an upload, an error). */
    w->status = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(w->status), 0);
    gtk_label_set_wrap(GTK_LABEL(w->status), TRUE);
    gtk_widget_add_css_class(w->status, "dim-label");
    gtk_widget_add_css_class(w->status, "caption");
    gtk_widget_add_css_class(w->status, "numeric");
    /* The hint: a wrapped text and its buttons. */
    w->hint = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(w->hint, "zg-hint");
    w->hint_label = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(w->hint_label), 0);
    gtk_label_set_wrap(GTK_LABEL(w->hint_label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(w->hint_label), PANGO_WRAP_WORD_CHAR);
    GtkWidget *hint_buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    w->hint_inches = gtk_button_new_with_label("Inches (\u00d725.4)");
    w->hint_meters = gtk_button_new_with_label("Meters (\u00d71000)");
    w->hint_support = gtk_button_new_with_label("Turn on support");
    gtk_actionable_set_detailed_action_name(GTK_ACTIONABLE(w->hint_inches), "win.scale-tiny(25.4)");
    gtk_actionable_set_detailed_action_name(GTK_ACTIONABLE(w->hint_meters), "win.scale-tiny(1000.0)");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(w->hint_support), "win.support-on");
    gtk_box_append(GTK_BOX(hint_buttons), w->hint_inches);
    gtk_box_append(GTK_BOX(hint_buttons), w->hint_meters);
    gtk_box_append(GTK_BOX(hint_buttons), w->hint_support);
    gtk_box_append(GTK_BOX(w->hint), w->hint_label);
    gtk_box_append(GTK_BOX(w->hint), hint_buttons);
    gtk_widget_set_visible(w->hint, FALSE);
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
    gtk_label_set_wrap(GTK_LABEL(w->printer_state), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(w->printer_state), PANGO_WRAP_WORD);
    gtk_widget_set_margin_top(w->printer_state, 6);
    gtk_widget_set_visible(w->printer_state, FALSE); /* until a printer answers */
    /* The head: the time, the plastic, and the badge. A click opens the
     * details: the main settings, the warnings, and the usual
     * refinements. */
    w->sum_more = gtk_button_new();
    gtk_widget_add_css_class(w->sum_more, "flat");
    gtk_widget_add_css_class(w->sum_more, "zg-sum-head");
    gtk_widget_set_tooltip_text(w->sum_more, "The details of the print");
    GtkWidget *head = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(head), 8);
    w->sum_badge = gtk_label_new("");
    gtk_widget_add_css_class(w->sum_badge, "zg-sum-badge");
    gtk_widget_set_halign(w->sum_badge, GTK_ALIGN_END);
    gtk_widget_set_valign(w->sum_badge, GTK_ALIGN_CENTER);
    gtk_widget_set_hexpand(w->sum_badge, TRUE);
    gtk_widget_set_visible(w->sum_badge, FALSE);
    gtk_grid_attach(GTK_GRID(head), w->sum_time, 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(head), w->sum_badge, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(head), w->sum_detail, 0, 1, 2, 1);
    gtk_button_set_child(GTK_BUTTON(w->sum_more), head);
    w->refine_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(w->refine_box, "zg-refine");
    gtk_widget_set_margin_top(w->refine_box, 8);
    gtk_widget_set_visible(w->refine_box, FALSE);
    GtkWidget *details = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_size_request(details, 320, -1);
    gtk_box_append(GTK_BOX(details), w->facts);
    gtk_box_append(GTK_BOX(details), w->status);
    gtk_box_append(GTK_BOX(details), w->sum_deck);
    gtk_box_append(GTK_BOX(details), w->hint);
    gtk_box_append(GTK_BOX(details), w->islands);
    gtk_box_append(GTK_BOX(details), w->printer_state);
    gtk_box_append(GTK_BOX(details), w->refine_box);
    w->sum_pop = gtk_popover_new();
    gtk_popover_set_child(GTK_POPOVER(w->sum_pop), details);
    gtk_popover_set_position(GTK_POPOVER(w->sum_pop), GTK_POS_TOP);
    gtk_widget_set_parent(w->sum_pop, w->sum_more);
    g_signal_connect_swapped(w->sum_more, "clicked", G_CALLBACK(gtk_popover_popup), w->sum_pop);
    /* The head and the buttons in a row, and the progress under them. */
    GtkWidget *sum_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_box_append(GTK_BOX(sum_row), w->sum_more);
    gtk_box_append(GTK_BOX(sum_row), actions);
    gtk_box_append(GTK_BOX(w->sum_box), sum_row);
    gtk_box_append(GTK_BOX(w->sum_box), w->progress);
    GtkWidget *panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(panel), settings);
    gtk_widget_add_css_class(panel, "zg-panel");
    w->panel = panel;
    /* Pin and close, at the end of the top row of the panel. */
    GtkWidget *panel_end = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    w->pin = gtk_toggle_button_new();
    gtk_button_set_icon_name(GTK_BUTTON(w->pin), "view-pin-symbolic");
    gtk_widget_add_css_class(w->pin, "flat");
    gtk_widget_set_tooltip_text(w->pin, "Pin: the panel beside the view, with a splitter. Off: the panel slides over the view.");
    g_signal_connect(w->pin, "toggled", G_CALLBACK(on_pin_toggled), w);
    GtkWidget *panel_close = gtk_button_new_from_icon_name("window-close-symbolic");
    gtk_widget_add_css_class(panel_close, "flat");
    gtk_widget_set_tooltip_text(panel_close, "Hide the panel (N)");
    g_signal_connect(panel_close, "clicked", G_CALLBACK(on_panel_close), w);
    gtk_box_append(GTK_BOX(panel_end), w->pin);
    gtk_box_append(GTK_BOX(panel_end), panel_close);
    zg_settings_panel_set_end(settings, panel_end);
    GtkEventController *panel_keys = gtk_event_controller_key_new();
    g_signal_connect(panel_keys, "key-pressed", G_CALLBACK(on_panel_key), w);
    gtk_widget_add_controller(panel, panel_keys);
    /* The model on the left, the settings on the right, as in other
     * slicers. */
    /* The preview, with the timeline of the history in its dock. */
    GtkWidget *left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(w->preview, TRUE);
    gtk_box_append(GTK_BOX(left), w->preview);
    w->timeline = zg_timeline_new(model);
    zg_preview_set_timeline(w->preview, w->timeline);
    /* The print card over the view, at its bottom right. */
    zg_preview_set_card(w->preview, w->sum_box);
    /* The card of a selected line, next to the click. */
    gtk_overlay_add_overlay(GTK_OVERLAY(w->preview), zg_line_card_new(model, w->preview));
    /* The card of a selected part, next to it. */
    gtk_overlay_add_overlay(GTK_OVERLAY(w->preview), zg_part_card_new(model, w->preview));
    gtk_overlay_add_overlay(GTK_OVERLAY(w->preview), zg_range_card_new(model, w->preview));
    /* The results of the search, over the view and the cards: hidden
     * until the field, /, or a fact opens them. */
    gtk_overlay_add_overlay(GTK_OVERLAY(w->preview), w->search);
    /* The Printers page, over the view and its cards. */
    w->farm_view = farm_view_new(w);
    gtk_overlay_add_overlay(GTK_OVERLAY(w->preview), w->farm_view);
    w->project_dialog = project_dialog_new(w);
    gtk_paned_set_start_child(GTK_PANED(paned), left);
    gtk_paned_set_end_child(GTK_PANED(paned), panel);
    w->paned = paned;
    gtk_paned_set_resize_end_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_shrink_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_shrink_end_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_wide_handle(GTK_PANED(paned), TRUE);
    /* The start width of the settings panel: the last two columns of the
     * settings browser. The user can drag it to 220. The position is from
     * the left, so it is set when the width of the window is known. */
    g_signal_connect(paned, "map", G_CALLBACK(on_paned_map), NULL);
    g_signal_connect(paned, "notify::position", G_CALLBACK(on_paned_position), w);
    gtk_widget_set_vexpand(paned, TRUE);

    /* The body: the paned, and the drawer over it. */
    w->body = gtk_overlay_new();
    gtk_overlay_set_child(GTK_OVERLAY(w->body), paned);
    g_signal_connect(w->body, "get-child-position", G_CALLBACK(on_body_child), w);
    gtk_window_set_child(w->window, w->body);
    /* The mode of the panel of the last session; hidden at the first
     * start. */
    char *mode = zg_pref_get("panel", "hidden");
    w->panel_mode = PANEL_PINNED;
    set_panel_mode(w, strcmp(mode, "pinned") == 0 ? PANEL_PINNED : strcmp(mode, "overlay") == 0 ? PANEL_OVER : PANEL_HIDDEN);
    g_free(mode);
    GtkEventController *win_keys = gtk_event_controller_key_new();
    g_signal_connect(win_keys, "key-pressed", G_CALLBACK(on_window_key), w);
    gtk_widget_add_controller(GTK_WIDGET(w->window), win_keys);
    /* The history: the changes of one setting are one step while its
     * editor keeps the focus. */
    g_signal_connect(w->window, "notify::focus-widget", G_CALLBACK(on_focus_widget), model);

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
