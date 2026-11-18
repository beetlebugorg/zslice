/* shortcuts.c: see shortcuts.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "shortcuts.h"

#include <string.h>

typedef struct {
    const char *keys, *what;
} Key;

typedef struct {
    const char *group;
    Key keys[28];
} Group;

/* The keys of the GTK app. "A, B": two keys for the same thing. A note in
 * parentheses says when the key works. */
static const Group SHORTCUTS[] = {
    {"General", {
        {"?", "Show this sheet of the keyboard shortcuts"},
        {"/", "Search the settings and the actions, and change a setting in the results"},
        {"N", "Show or hide the panel: all settings, the selected line, the history, and the project"},
        {"Ctrl+O", "Add models to the plate"},
        {"Ctrl+E", "Export the G-code"},
        {"Ctrl+S", "Save the project: all plates in one 3MF file"},
        {"Ctrl+Z", "Undo"},
        {"Ctrl+Shift+Z, Ctrl+Y", "Redo"},
        {"Ctrl+,", "Preferences: the printers and the app"},
        {"Alt+Left", "Back to the place before in the panel"},
        {"Esc", "Close a menu, the search, a card, or the panel over the view; then clear the measure, then the selection"},
        {"Menu key, Shift+F10", "The menu of the view"},
        {"Ctrl+Q", "Quit"},
        {NULL, NULL}}},
    {"Plates", {
        {"]", "The next plate: make it active"},
        {"[", "The plate before: make it active"},
        {"F", "Show the active plate"},
        {"Home", "The start view (the view shows the active plate only)"},
        {NULL, NULL}}},
    {"Tools", {
        {"V", "Select: a click selects a line"},
        {"M", "Move: a drag moves a part, the wheel turns it 15°"},
        {"R", "Turn: drag a ring of the selected part to turn it about X, Y, or Z"},
        {"T", "Measure: two clicks measure between two points"},
        {"S", "Support: click points on the part to draw a support area, and drag the points of an area"},
        {"Enter (Support tool)", "Close the area that you draw (also: click its first point)"},
        {"Backspace (Support tool)", "Remove the last point of the area that you draw"},
        {"Delete (Support tool)", "Delete the selected support area"},
        {"Esc (Support tool)", "Stop the area that you draw, then clear the selected area"},
        {"G", "Gaps: show the gaps of the top layer"},
        {"Ctrl+click, Ctrl+drag, Ctrl+wheel", "Select, move, and turn a part with any tool"},
        {"Tab, Shift+Tab", "Select the next part, or the part before"},
        {"Left, Right, Up, Down (a part)", "Move the selected part 1 mm (with Shift: 10 mm)"},
        {"Left, Right (Turn tool)", "Turn the selected part on the bed, 15° (with Shift: 5°)"},
        {"Up, Down (Turn tool)", "Tilt the selected part about X, 15° (with Shift: 5°)"},
        {"Page Up, Page Down (Turn tool)", "Tilt the selected part about Y, 15° (with Shift: 5°)"},
        {"[, ] (a part)", "Turn the selected part 15° on the bed (with Shift: 1°)"},
        {"D", "Duplicate the selected part"},
        {"Delete (a selected line)", "Take the line out of the print: an edit, kept across slices"},
        {"Delete", "Remove the selected part"},
        {"Shift+click", "Add a line to the selection"},
        {"Shift (measure, support)", "No snap"},
        {NULL, NULL}}},
    {"Layers", {
        {"Up, K", "The top layer one up (with a selected line: the nearest line one layer up)"},
        {"Down, J", "The top layer one down (with a selected line: the nearest line one layer down)"},
        {"Page Up, Page Down", "10 layers up or down"},
        {"Shift+Up, Shift+Down", "Move the bottom of the layer range"},
        {"C", "Show the layers up to the selected line"},
        {"Shift+C", "Show all layers"},
        {NULL, NULL}}},
    {"Lines and the nozzle", {
        {"Left, H", "The segment before the selected one (no selection: the nozzle back 2 % of the layer)"},
        {"Right, L", "The next segment (no selection: the nozzle on 2 % of the layer)"},
        {"Shift+Left, Shift+Right", "The line before, or the next line"},
        {NULL, NULL}}},
    {"Search", {
        {"Up, Down", "Go through the results"},
        {"Left, Right", "Change the value of the result: a step, or the next choice"},
        {"Space, Enter", "Turn a switch, or run an action"},
        {"V", "The eye of the result: show only the lines of its setting, or all lines again"},
        {"Tab", "Go into the controls of the result"},
        {"Esc", "Leave a control, then close the search"},
        {NULL, NULL}}},
    {"Settings", {
        {"Up, Down (an entry)", "Step a number by one unit of its last decimal place (Shift: 10 steps, Ctrl: a tenth)"},
        {"Enter", "Use the value of an entry"},
        {NULL, NULL}}},
    {"History", {
        {"Up, Down (History tab)", "The next step, or the step before"},
        {"Space (History tab)", "Back to the step shown before"},
        {"Left, Right (timeline)", "The step before, or the next step"},
        {NULL, NULL}}},
    {"Mouse and touchpad", {
        {"Left drag", "Orbit"},
        {"Middle or right drag", "Pan (on a touchpad: two fingers pressed down and a drag)"},
        {"Wheel, light two-finger swipe, pinch", "Zoom toward the pointer"},
        {"Double-click on a side of a part", "Turn the view to face that side"},
        {"Double-click elsewhere", "Reset the view"},
        {"Right click", "The menu of the view"},
        {NULL, NULL}}},
};

typedef struct {
    GtkWindow *window;
    GtkWidget *filter, *body;
} Sheet;

static GtkWindow *open_sheet;

/* The keys of a shortcut as key caps: "Ctrl+Shift+Z, Ctrl+Y". */
static GtkWidget *keys_box(const char *text) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 3);
    char **alts = g_strsplit(text, ", ", -1);
    for (int i = 0; alts[i]; i++) {
        if (i > 0) {
            GtkWidget *or = gtk_label_new("or");
            gtk_widget_add_css_class(or, "dim-label");
            gtk_widget_add_css_class(or, "caption");
            gtk_box_append(GTK_BOX(box), or);
        }
        /* A note at the end: "(a part)". */
        char *note = strstr(alts[i], " (");
        if (note) *note = 0;
        /* "+" alone is a key; "Ctrl+," splits at the first "+". */
        const char *p = alts[i];
        gboolean first = TRUE;
        while (*p) {
            const char *plus = strchr(p + 1, '+');
            char *key = plus ? g_strndup(p, (gsize)(plus - p)) : g_strdup(p);
            if (!first) {
                GtkWidget *l = gtk_label_new("+");
                gtk_widget_add_css_class(l, "dim-label");
                gtk_box_append(GTK_BOX(box), l);
            }
            GtkWidget *cap = gtk_label_new(key);
            gtk_widget_add_css_class(cap, "zg-keycap");
            gtk_box_append(GTK_BOX(box), cap);
            g_free(key);
            first = FALSE;
            p = plus ? plus + 1 : p + strlen(p);
        }
        if (note) {
            GtkWidget *n = gtk_label_new(note + 1);
            gtk_widget_add_css_class(n, "dim-label");
            gtk_widget_add_css_class(n, "caption");
            gtk_box_append(GTK_BOX(box), n);
        }
    }
    g_strfreev(alts);
    return box;
}

static gboolean matches(const char *q, const char *a, const char *b, const char *c) {
    if (!q[0]) return TRUE;
    gboolean ok = FALSE;
    const char *texts[] = {a, b, c};
    for (int i = 0; i < 3 && !ok; i++) {
        char *low = g_utf8_strdown(texts[i], -1);
        ok = strstr(low, q) != NULL;
        g_free(low);
    }
    return ok;
}

static void fill(Sheet *s) {
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(s->body))) gtk_box_remove(GTK_BOX(s->body), child);
    char *q = g_utf8_strdown(gtk_editable_get_text(GTK_EDITABLE(s->filter)), -1);
    g_strstrip(q);
    gboolean any = FALSE;
    /* One table: the keys of all groups line up. */
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 16);
    gtk_box_append(GTK_BOX(s->body), grid);
    int row = 0;
    for (size_t g = 0; g < G_N_ELEMENTS(SHORTCUTS); g++) {
        gboolean head_done = FALSE;
        for (const Key *k = SHORTCUTS[g].keys; k->keys; k++) {
            if (!matches(q, k->keys, k->what, SHORTCUTS[g].group)) continue;
            if (!head_done) {
                GtkWidget *head = gtk_label_new(SHORTCUTS[g].group);
                gtk_label_set_xalign(GTK_LABEL(head), 0);
                gtk_widget_add_css_class(head, "zg-keys-group");
                gtk_grid_attach(GTK_GRID(grid), head, 0, row++, 2, 1);
                head_done = TRUE;
            }
            GtkWidget *keys = keys_box(k->keys);
            gtk_widget_set_valign(keys, GTK_ALIGN_START);
            GtkWidget *what = gtk_label_new(k->what);
            gtk_label_set_xalign(GTK_LABEL(what), 0);
            gtk_label_set_wrap(GTK_LABEL(what), TRUE);
            gtk_label_set_max_width_chars(GTK_LABEL(what), 60);
            gtk_widget_set_hexpand(what, TRUE);
            gtk_grid_attach(GTK_GRID(grid), keys, 0, row, 1, 1);
            gtk_grid_attach(GTK_GRID(grid), what, 1, row++, 1, 1);
            any = TRUE;
        }
    }
    if (!any) {
        GtkWidget *none = gtk_label_new("No shortcut matches.");
        gtk_widget_add_css_class(none, "dim-label");
        gtk_box_append(GTK_BOX(s->body), none);
    }
    g_free(q);
}

static void on_filter(GtkEditable *e, gpointer data) {
    fill(data);
}

static gboolean on_key(GtkEventControllerKey *c, guint key, guint code, GdkModifierType mods, gpointer data) {
    Sheet *s = data;
    if (key == GDK_KEY_Escape) {
        gtk_window_close(s->window);
        return TRUE;
    }
    return FALSE;
}

static void on_destroy(GtkWidget *w, gpointer data) {
    open_sheet = NULL;
    g_free(data);
}

void zg_shortcuts_toggle(GtkWindow *parent) {
    if (open_sheet) {
        gtk_window_close(open_sheet);
        return;
    }
    Sheet *s = g_new0(Sheet, 1);
    s->window = GTK_WINDOW(gtk_window_new());
    open_sheet = s->window;
    gtk_window_set_title(s->window, "Keyboard shortcuts");
    gtk_window_set_transient_for(s->window, parent);
    gtk_window_set_modal(s->window, TRUE);
    gtk_window_set_default_size(s->window, 760, 640);
    GtkWidget *header = gtk_header_bar_new();
    s->filter = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(s->filter), "Filter");
    gtk_widget_set_size_request(s->filter, 260, -1);
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), s->filter);
    GtkWidget *title = gtk_label_new("Keyboard shortcuts");
    gtk_widget_add_css_class(title, "title");
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), title);
    gtk_window_set_titlebar(s->window, header);
    s->body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_margin_start(s->body, 20);
    gtk_widget_set_margin_end(s->body, 20);
    gtk_widget_set_margin_top(s->body, 12);
    gtk_widget_set_margin_bottom(s->body, 20);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), s->body);
    gtk_window_set_child(s->window, scroll);
    g_signal_connect(s->filter, "search-changed", G_CALLBACK(on_filter), s);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), s);
    gtk_widget_add_controller(GTK_WIDGET(s->window), keys);
    g_signal_connect(s->window, "destroy", G_CALLBACK(on_destroy), s);
    fill(s);
    gtk_window_present(s->window);
    gtk_widget_grab_focus(s->filter);
}
