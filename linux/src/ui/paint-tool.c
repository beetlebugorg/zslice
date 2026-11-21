/* paint-tool.c: see paint-tool.h.
 *
 * The session of the part comes from the cache of the meshes
 * (part-mesh.h). The tool keeps the gen of the mesh that the view has: a
 * new gen (the part moved or turned) gives the view the new mesh. The
 * text of the paint that the session has (`synced`) tells whether an undo
 * changed the paint of the part.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "paint-tool.h"

#include <math.h>
#include <string.h>

#include "filaments.h"
#include "paint-card.h"
#include "preview.h"

/* A region of the smart select: its id and its triangles. */
typedef struct {
    guint32 id;
    guint32 *tris;
    size_t n;
} Region;

struct ZgPaintTool {
    ZgModel *model;
    GtkWidget *area;
    zs_view *view;
    ZgPaintHost host;
    ZgPartMeshes *meshes;
    gboolean on, shown;
    /* The part, its filament (from 1), and the gen of the mesh that the
     * view has (0: none). */
    gint64 index;
    int base;
    guint gen;
    char *synced;
    ZgPaintMode mode;
    double size;
    int filament;
    Region *hover;
    GPtrArray *selection; /* Region */
    /* A press of the tool; a stroke of the brush, and the triangles that
     * it changed. A reload waits for the end of the press. */
    gboolean pressed, stroke, reload_wanted;
    long changed;
    /* The states for the view (with the lit bit). */
    guint8 *states;
    size_t states_cap;
    GtkWidget *card;
    gboolean test_started;
    /* The test hook: the time of the brush, of the states and pieces of
     * the session, and of the view (us). */
    gint64 us_brush, us_session, us_view;
};

static void upload(ZgPaintTool *t);
static void test_start(ZgPaintTool *t);

static void region_free(gpointer data) {
    Region *r = data;
    if (!r) return;
    g_free(r->tris);
    g_free(r);
}

static void toast(ZgPaintTool *t, const char *text) {
    for (GtkWidget *w = t->area; w; w = gtk_widget_get_parent(w))
        if (g_object_get_data(G_OBJECT(w), "zg-preview")) {
            zg_preview_note(w, text, 4000);
            return;
        }
}

/* The session of the part, while the view has its mesh. */
static zs_paint *session(ZgPaintTool *t) {
    if (!t->on || t->gen == 0) return NULL;
    const ZgPartMesh *e = zg_part_meshes_get(t->meshes, t->index);
    return e && e->gen == t->gen ? e->session : NULL;
}

/* The state of a filament number: the filament of the part is 0. */
static guint8 state_of(ZgPaintTool *t, int filament) {
    return filament == t->base ? 0 : (guint8)CLAMP(filament, 0, 127);
}

static void clear_selection(ZgPaintTool *t) {
    g_clear_pointer(&t->hover, region_free);
    g_ptr_array_set_size(t->selection, 0);
}

/* ---- the paint of the part ---- */

static char *paint_text(ZgModel *model, gint64 index) {
    size_t len = 0;
    zs_app *core = zg_model_core(model);
    if (zs_app_part_paint_get(core, (size_t)index, NULL, 0, &len) != ZS_OK) return NULL;
    char *buf = g_malloc(len + 1);
    if (zs_app_part_paint_get(core, (size_t)index, buf, len + 1, &len) != ZS_OK) {
        g_free(buf);
        return NULL;
    }
    buf[len] = 0;
    return buf;
}

/* The paint of the session to the part: one step of the history, and a
 * slice. */
static void commit(ZgPaintTool *t) {
    zs_paint *s = session(t);
    const char *text = NULL;
    size_t len = 0;
    if (!s || zs_paint_text(s, &text, &len) != ZS_OK) return;
    g_free(t->synced);
    t->synced = g_strndup(text ? text : "", len);
    if (!zg_model_part_paint_set(t->model, (size_t)t->index, t->synced, len)) toast(t, "The paint did not go to the part.");
}

/* The palette of the view: state 0 is the filament of the part, state k
 * filament k. */
static void colors(ZgPaintTool *t) {
    if (!t->view || !t->on) return;
    uint32_t rgb[32];
    rgb[0] = zg_filament_rgb24(t->model, t->base);
    for (int k = 1; k < 32; k++) rgb[k] = zg_filament_rgb24(t->model, k);
    zs_view_paint_colors(t->view, rgb, 32);
}

/* The lit bit on the states of the triangles of a region. */
static void light(ZgPaintTool *t, const Region *r, size_t n) {
    for (size_t i = 0; r && i < r->n; i++)
        if (r->tris[i] < n && t->states[r->tris[i]] != 255) t->states[r->tris[i]] |= 128;
}

/* The states of the triangles to the view, with the light of the region
 * under the pointer and of the selection, and the pieces of the split
 * triangles. */
static void upload(ZgPaintTool *t) {
    zs_paint *s = session(t);
    if (!s || !t->view) return;
    gint64 t0 = g_get_monotonic_time();
    const uint8_t *st = NULL;
    size_t n = zs_paint_states(s, &st);
    if (n > t->states_cap) {
        t->states = g_realloc(t->states, n);
        t->states_cap = n;
    }
    if (n > 0) memcpy(t->states, st, n);
    /* The region under the pointer lights only in the smart select. */
    if (t->mode == ZG_PAINT_SMART) light(t, t->hover, n);
    for (guint r = 0; r < t->selection->len; r++) light(t, g_ptr_array_index(t->selection, r), n);
    const float *leaves = NULL;
    size_t nl = zs_paint_leaves(s, &leaves);
    gint64 t1 = g_get_monotonic_time();
    zs_view_paint_states(t->view, t->states, n, leaves, nl);
    t->us_session += t1 - t0;
    t->us_view += g_get_monotonic_time() - t1;
    t->host.frame(t->host.data);
}

/* The mesh of the part to the view (again if the part moved), and the
 * paint of the part to the session if it changed (an undo). FALSE if the
 * part has no mesh. */
static gboolean sync_part(ZgPaintTool *t) {
    const ZgPartMesh *e = zg_part_meshes_get(t->meshes, t->index);
    if (!e || !t->view) return FALSE;
    if (e->gen != t->gen) {
        clear_selection(t);
        if (!zs_view_paint_mesh(t->view, e->verts, e->nv, e->faces, e->nf)) return FALSE;
        t->gen = e->gen;
        g_clear_pointer(&t->synced, g_free);
    }
    char *text = paint_text(t->model, t->index);
    if (!text) return FALSE;
    if (!t->synced || strcmp(text, t->synced) != 0) {
        zs_paint_set_text(e->session, text, strlen(text));
        g_free(t->synced);
        t->synced = text;
        /* The regions stay; their light follows the new paint. */
    } else {
        g_free(text);
    }
    t->base = zg_part_filament(t->model, t->index);
    colors(t);
    return TRUE;
}

/* ---- on and off ---- */

static void open_on(ZgPaintTool *t, gint64 index) {
    zs_app *core = zg_model_core(t->model);
    if (index < 0 || (size_t)index >= zs_app_part_count(core)) {
        toast(t, "Open a model to paint it.");
        return;
    }
    if (!t->view) return;
    t->index = index;
    t->gen = 0;
    clear_selection(t);
    if (!sync_part(t)) {
        t->gen = 0;
        zs_view_paint_mesh(t->view, NULL, 0, NULL, 0);
        toast(t, "The paint tool cannot open this part.");
        return;
    }
    /* Paint with another filament than the part's at first. */
    int count = (int)zs_app_filament_count(core);
    if (t->filament == t->base || t->filament > count || t->filament < 1) t->filament = count > 1 ? (t->base == 1 ? 2 : 1) : 1;
    upload(t);
    zg_paint_card_update(t->card);
}

static void close_tool(ZgPaintTool *t) {
    zg_paint_release(t);
    clear_selection(t);
    t->gen = 0;
    t->index = -1;
    g_clear_pointer(&t->synced, g_free);
    if (t->view) {
        zs_view_paint_mesh(t->view, NULL, 0, NULL, 0);
        t->host.frame(t->host.data);
    }
}

static void show_card(ZgPaintTool *t) {
    gtk_widget_set_visible(t->card, t->on && t->shown);
}

/* The part to paint: the selected part, or else the first part. */
static gint64 wanted_part(ZgPaintTool *t) {
    gint64 part = zg_model_selected_part(t->model);
    if (part >= 0) return part;
    return zs_app_part_count(zg_model_core(t->model)) >= 1 ? 0 : -1;
}

static void on_tool_changed(ZgModel *model, gpointer data) {
    ZgPaintTool *t = data;
    gboolean on = zg_model_tool(model) == ZG_TOOL_PAINT;
    if (on == t->on) return;
    if (!on) {
        close_tool(t);
        t->on = FALSE;
        show_card(t);
        return;
    }
    t->on = TRUE;
    show_card(t);
    open_on(t, wanted_part(t));
    t->host.focus(t->host.data);
}

/* After a slice, an undo or a redo, or another plate: the mesh and the
 * paint of the part again. */
static void reload(ZgPaintTool *t) {
    if (!t->on) return;
    if (t->pressed) {
        t->reload_wanted = TRUE;
        return;
    }
    t->reload_wanted = FALSE;
    zg_part_meshes_check(t->meshes);
    zs_app *core = zg_model_core(t->model);
    if (t->index < 0 || (size_t)t->index >= zs_app_part_count(core)) {
        close_tool(t);
        open_on(t, wanted_part(t));
        return;
    }
    if (!sync_part(t)) {
        close_tool(t);
        return;
    }
    upload(t);
    zg_paint_card_update(t->card);
}

static void on_maybe_changed(ZgModel *model, gpointer data) {
    reload(data);
}

static void on_core_event(ZgModel *model, int event, double progress, int status, gpointer data) {
    ZgPaintTool *t = data;
    if (event != ZS_EVENT_SLICED) return;
    reload(t);
    test_start(t);
}

/* Another part selected (Ctrl and a click): paint that part. */
static void on_part_selected(ZgModel *model, gint64 part, gpointer data) {
    ZgPaintTool *t = data;
    if (!t->on || part < 0 || part == t->index) return;
    zg_paint_release(t);
    open_on(t, part);
}

/* A new color or a new list of filaments: the palette and the chips. */
static void on_filaments(ZgModel *model, gpointer data) {
    ZgPaintTool *t = data;
    if (!t->on) return;
    t->base = zg_part_filament(t->model, t->index);
    colors(t);
    upload(t);
    zg_paint_card_update(t->card);
}

/* ---- the picks ---- */

/* The triangle under x, y and the point of the surface there, or -1. */
static gint64 hit(ZgPaintTool *t, double x, double y, float p[3]) {
    zs_paint *s = session(t);
    float r[6];
    int scale = gtk_widget_get_scale_factor(t->area);
    uint32_t tri = 0;
    float d = 0;
    if (!s || !t->view || !zs_view_ray(t->view, (float)(x * scale), (float)(y * scale), r) || zs_paint_hit(s, r, &tri, &d) != 1) return -1;
    for (int k = 0; k < 3; k++) p[k] = r[k] + r[3 + k] * d;
    return tri;
}

/* The region of the smart select of a triangle. A region with the id of
 * `same` gives NULL and *is_same: a hover over one region costs a
 * lookup. */
static Region *region_of(ZgPaintTool *t, guint32 tri, const Region *same, gboolean *is_same) {
    zs_paint *s = session(t);
    const uint32_t *list = NULL;
    size_t n = 0;
    uint32_t id = 0;
    if (is_same) *is_same = FALSE;
    if (!s || zs_paint_region(s, tri, &list, &n, &id) != ZS_OK) return NULL;
    if (same && same->id == id) {
        if (is_same) *is_same = TRUE;
        return NULL;
    }
    Region *r = g_new0(Region, 1);
    r->id = id;
    r->n = n;
    r->tris = g_memdup2(list, MAX(n, 1) * sizeof *list);
    return r;
}

static long fill(ZgPaintTool *t, const guint32 *tris, size_t n, guint8 state) {
    zs_paint *s = session(t);
    if (!s || n == 0) return 0;
    int c = zs_paint_fill(s, tris, n, state);
    return c > 0 ? c : 0;
}

/* One step of the brush at a point of the surface. */
static void dab(ZgPaintTool *t, const float p[3]) {
    zs_paint *s = session(t);
    if (!s) return;
    gint64 t0 = g_get_monotonic_time();
    int n = zs_paint_brush(s, p[0], p[1], p[2], (float)t->size, state_of(t, t->filament), (float)MAX(0.1, t->size / 6));
    t->us_brush += g_get_monotonic_time() - t0;
    if (n > 0) {
        t->changed += n;
        upload(t);
    }
}

/* ---- the pointer ---- */

gboolean zg_paint_press(ZgPaintTool *t, double x, double y, gboolean shift) {
    if (!t->on || !t->view) return FALSE;
    t->host.focus(t->host.data);
    t->pressed = TRUE;
    float p[3];
    gint64 tri = hit(t, x, y, p);
    if (t->mode == ZG_PAINT_SMART) {
        Region *r = tri >= 0 ? region_of(t, (guint32)tri, NULL, NULL) : NULL;
        if (!r) {
            if (!shift) g_ptr_array_set_size(t->selection, 0);
            upload(t);
            return TRUE;
        }
        gboolean have = FALSE;
        for (guint i = 0; i < t->selection->len; i++) have = have || ((Region *)g_ptr_array_index(t->selection, i))->id == r->id;
        if (!shift) g_ptr_array_set_size(t->selection, 0);
        long changed = fill(t, r->tris, r->n, state_of(t, t->filament));
        if (shift && have) region_free(r);
        else g_ptr_array_add(t->selection, r);
        if (changed > 0) commit(t);
        upload(t);
        return TRUE;
    }
    t->stroke = TRUE;
    t->changed = 0;
    if (tri >= 0) dab(t, p);
    return TRUE;
}

void zg_paint_drag(ZgPaintTool *t, double x, double y) {
    if (!t->stroke) return;
    float p[3];
    if (hit(t, x, y, p) >= 0) dab(t, p);
}

void zg_paint_release(ZgPaintTool *t) {
    if (!t->pressed) return;
    t->pressed = FALSE;
    if (t->stroke) {
        t->stroke = FALSE;
        if (t->changed > 0) commit(t);
        t->changed = 0;
    }
    if (t->reload_wanted) reload(t);
}

gboolean zg_paint_pressed(ZgPaintTool *t) {
    return t->pressed;
}

void zg_paint_hover(ZgPaintTool *t, double x, double y) {
    if (!t->on || t->mode != ZG_PAINT_SMART || t->pressed) return;
    float p[3];
    gint64 tri = hit(t, x, y, p);
    gboolean same = FALSE;
    Region *r = tri >= 0 ? region_of(t, (guint32)tri, t->hover, &same) : NULL;
    if (same || (!r && !t->hover)) return;
    region_free(t->hover);
    t->hover = r;
    upload(t);
}

gboolean zg_paint_key(ZgPaintTool *t, guint key) {
    if (!t->on) return FALSE;
    if (key != GDK_KEY_Escape) return FALSE;
    zg_model_set_tool(t->model, ZG_TOOL_SELECT);
    return TRUE;
}

/* ---- the card ---- */

ZgPaintMode zg_paint_tool_mode(ZgPaintTool *t) {
    return t->mode;
}

void zg_paint_tool_set_mode(ZgPaintTool *t, ZgPaintMode mode) {
    t->mode = mode;
    g_clear_pointer(&t->hover, region_free);
    upload(t);
    zg_paint_card_update(t->card);
}

double zg_paint_tool_size(ZgPaintTool *t) {
    return t->size;
}

void zg_paint_tool_set_size(ZgPaintTool *t, double mm) {
    if (isfinite(mm)) t->size = CLAMP(mm, 0.3, 10);
}

int zg_paint_tool_filament(ZgPaintTool *t) {
    return t->filament;
}

int zg_paint_tool_base(ZgPaintTool *t) {
    return t->base;
}

void zg_paint_tool_set_filament(ZgPaintTool *t, int filament) {
    if (filament < 1) return;
    t->filament = filament;
    /* The selection gets the new filament. */
    long changed = 0;
    for (guint i = 0; i < t->selection->len; i++) {
        Region *r = g_ptr_array_index(t->selection, i);
        changed += fill(t, r->tris, r->n, state_of(t, filament));
    }
    if (changed > 0) commit(t);
    upload(t);
    zg_paint_card_update(t->card);
}

void zg_paint_tool_add_filament(ZgPaintTool *t) {
    gint64 i = zg_model_filament_add(t->model);
    if (i < 0) {
        toast(t, "The plate has the most filaments it can have.");
        return;
    }
    colors(t);
    zg_paint_tool_set_filament(t, (int)i + 1);
}

void zg_paint_tool_clear(ZgPaintTool *t) {
    const ZgPartMesh *e = zg_part_meshes_get(t->meshes, t->index);
    if (!e || !session(t)) return;
    guint32 *all = g_new(guint32, e->nf);
    for (size_t i = 0; i < e->nf; i++) all[i] = (guint32)i;
    if (fill(t, all, e->nf, 0) > 0) commit(t);
    g_free(all);
    g_ptr_array_set_size(t->selection, 0);
    upload(t);
}

/* ---- the life of the tool ---- */

ZgPaintTool *zg_paint_tool_new(ZgModel *model, GtkWidget *area, ZgPaintHost host, ZgPartMeshes *meshes) {
    ZgPaintTool *t = g_new0(ZgPaintTool, 1);
    t->model = model;
    t->area = area;
    t->host = host;
    t->meshes = meshes;
    t->index = -1;
    t->mode = ZG_PAINT_SMART;
    t->size = 2;
    t->filament = 2;
    t->base = 1;
    t->selection = g_ptr_array_new_with_free_func(region_free);
    t->card = g_object_ref_sink(zg_paint_card_new(model, t));
    g_signal_connect(model, "tool-changed", G_CALLBACK(on_tool_changed), t);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_maybe_changed), t);
    g_signal_connect(model, "plates-changed", G_CALLBACK(on_maybe_changed), t);
    g_signal_connect(model, "core-event", G_CALLBACK(on_core_event), t);
    g_signal_connect(model, "part-selected", G_CALLBACK(on_part_selected), t);
    g_signal_connect(model, "filaments-changed", G_CALLBACK(on_filaments), t);
    return t;
}

void zg_paint_tool_free(ZgPaintTool *t) {
    if (!t) return;
    g_signal_handlers_disconnect_by_data(t->model, t);
    region_free(t->hover);
    g_ptr_array_unref(t->selection);
    g_free(t->states);
    g_free(t->synced);
    g_object_unref(t->card);
    g_free(t);
}

void zg_paint_tool_set_view(ZgPaintTool *t, zs_view *view) {
    t->view = view;
    if (t->on && view && t->gen == 0) open_on(t, wanted_part(t));
    if (view && zs_app_state(zg_model_core(t->model)) == ZS_STATE_DONE) test_start(t);
}

void zg_paint_tool_set_shown(ZgPaintTool *t, gboolean shown) {
    t->shown = shown;
    show_card(t);
}

GtkWidget *zg_paint_tool_card(ZgPaintTool *t) {
    return t->card;
}

/* ---- the test hook ----
 *
 * ZSLICE_PAINT_DO=steps: picks the Paint tool 1 s after the first slice,
 * then runs one step each 700 ms, as the mouse and the keys do. Steps,
 * with ';' between them: "smart" or "brush" (the mode), "size mm",
 * "filament n" (a chip), "addfilament" (the + chip), "orbit dx dy",
 * "zoom f", "look nx ny nz d" (the camera looks at the middle of part 0
 * from the direction n, d mm away), "click x y" and "sclick x y" (a
 * press and a release at a point of the view; s: with Shift), "clickw x
 * y z" (the same at the pixel of a point of the bed frame, mm), "hover x
 * y", "stroke x0 y0 x1 y1" (a drag of the brush from one point of the
 * view to the other), "rect x0 y0 x1 y1 step" (one drag of the brush
 * along the rows of the rectangle, `step` points apart),
 * "clear" (Remove all paint), "undo", "redo", "key Name", "check" (the
 * issues of kind ZS_ISSUE_COLOR in the log, and the Check list opens),
 * "partcard" (the Move tool selects part 0, and its card shows), "paint"
 * (the Paint tool again), "wait" (no step), "slice" (waits for the end of
 * the slice), "shot N" (logs "paint test: shot N" and waits 3 s, for a
 * screenshot from outside). x, y are points of the 3D view. The log gives
 * the paint, the selection, the card, and the history after each step. */

typedef struct {
    ZgPaintTool *t;
    char **steps;
    guint i;
    gint64 wait_start;
} TestRun;

static void test_log(ZgPaintTool *t, const char *step) {
    zs_app *core = zg_model_core(t->model);
    uint32_t used = 0;
    if (t->index >= 0) zs_app_part_paint_used(core, (size_t)t->index, &used);
    size_t painted = 0, split = 0, n = 0, nl = 0;
    zs_paint *s = session(t);
    if (s) {
        const uint8_t *st = NULL;
        n = zs_paint_states(s, &st);
        for (size_t i = 0; i < n; i++) {
            painted += st[i] != 0;
            split += st[i] == 255;
        }
        nl = zs_paint_leaves(s, NULL);
    }
    zs_stats stats = {0};
    gboolean done = zs_app_state(core) == ZS_STATE_DONE && zs_app_stats(core, &stats) == ZS_OK;
    GString *g = g_string_new(NULL);
    g_string_append_printf(g, "paint test: %s: tool %s, part %" G_GINT64_FORMAT ", %s, size %.1f, filament %d, base %d, %zu of %zu triangles painted (%zu split, %zu pieces), used 0x%x, selection %u, hover %s, card %s, history %u of %u, %s",
                           step, t->on ? "on" : "off", t->index, t->mode == ZG_PAINT_SMART ? "smart" : "brush", t->size, t->filament, t->base,
                           painted, n, split, nl, used, t->selection->len, t->hover ? "yes" : "no", gtk_widget_get_visible(t->card) ? "shown" : "hidden",
                           zg_model_history_current(t->model) + 1, zg_model_history_count(t->model), done ? "sliced" : "slicing");
    if (done) {
        g_string_append_printf(g, " %.2f g", stats.filament_g);
        double grams[16] = {0};
        uint32_t changes = 0;
        double flush = 0;
        if (zs_app_filament_stats(core, grams, 16, &changes, &flush) == ZS_OK) {
            g_string_append_printf(g, ", %u changes, grams", changes);
            for (size_t k = 0; k < MIN(zs_app_filament_count(core), 16); k++) g_string_append_printf(g, " %.2f", grams[k]);
        }
    }
    g_message("%s", g->str);
    g_string_free(g, TRUE);
}

/* A press, the moves through the n points of `pts` (x, y pairs), and the
 * release of the left button, as view3d.c sends them. The moves are 3
 * points apart. */
static void test_path(ZgPaintTool *t, const double *pts, int n, gboolean shift) {
    if (!zg_paint_press(t, pts[0], pts[1], shift)) {
        g_message("paint test: the tool did not take the press");
        return;
    }
    gint64 t0 = g_get_monotonic_time(), draw = 0;
    t->us_brush = t->us_session = t->us_view = 0;
    int steps = 0;
    for (int j = 1; j < n; j++) {
        double x0 = pts[2 * j - 2], y0 = pts[2 * j - 1], x1 = pts[2 * j], y1 = pts[2 * j + 1];
        int m = MAX(1, (int)(hypot(x1 - x0, y1 - y0) / 3));
        for (int k = 1; k <= m; k++, steps++) {
            zg_paint_drag(t, x0 + (x1 - x0) * k / m, y0 + (y1 - y0) * k / m);
            gint64 d0 = g_get_monotonic_time();
            if (t->view) zs_view_draw(t->view);
            draw += g_get_monotonic_time() - d0;
        }
    }
    if (steps > 0)
        g_message("paint test: a step of the brush and its frame, %.2f ms (brush %.2f, session %.2f, view %.2f, draw %.2f)",
                  (g_get_monotonic_time() - t0) / 1000.0 / steps, t->us_brush / 1000.0 / steps, t->us_session / 1000.0 / steps,
                  t->us_view / 1000.0 / steps, draw / 1000.0 / steps);
    zg_paint_release(t);
}

static void test_stroke(ZgPaintTool *t, double x0, double y0, double x1, double y1, gboolean shift) {
    double pts[4] = {x0, y0, x1, y1};
    test_path(t, pts, x0 == x1 && y0 == y1 ? 1 : 2, shift);
}

static gboolean test_step(gpointer data);

static gboolean test_wait_slice(gpointer data) {
    TestRun *r = data;
    zs_app *core = zg_model_core(r->t->model);
    if (zs_app_state(core) != ZS_STATE_DONE) return G_SOURCE_CONTINUE;
    g_message("paint test: the slice ended %.1f s after the step", (g_get_monotonic_time() - r->wait_start) / 1e6);
    g_timeout_add(300, test_step, r);
    return G_SOURCE_REMOVE;
}

static gboolean test_step(gpointer data) {
    TestRun *r = data;
    ZgPaintTool *t = r->t;
    if (!r->steps[r->i]) {
        test_log(t, "end");
        g_strfreev(r->steps);
        g_free(r);
        return G_SOURCE_REMOVE;
    }
    char *step = g_strstrip(g_strdup(r->steps[r->i++]));
    char **f = g_strsplit(step, " ", 6);
    guint n = g_strv_length(f);
    double v[5] = {0};
    for (guint k = 1; k < n && k <= 5; k++) v[k - 1] = g_ascii_strtod(f[k], NULL);
    int scale = gtk_widget_get_scale_factor(t->area);
    if (n == 1 && strcmp(f[0], "smart") == 0) {
        zg_paint_tool_set_mode(t, ZG_PAINT_SMART);
    } else if (n == 1 && strcmp(f[0], "brush") == 0) {
        zg_paint_tool_set_mode(t, ZG_PAINT_BRUSH);
    } else if (n == 2 && strcmp(f[0], "size") == 0) {
        zg_paint_tool_set_size(t, v[0]);
        zg_paint_card_update(t->card);
    } else if (n == 2 && strcmp(f[0], "filament") == 0) {
        zg_paint_tool_set_filament(t, (int)v[0]);
    } else if (n == 1 && strcmp(f[0], "addfilament") == 0) {
        zg_paint_tool_add_filament(t);
    } else if (n == 3 && strcmp(f[0], "orbit") == 0 && t->view) {
        zs_view_orbit(t->view, (float)v[0], (float)v[1]);
        t->host.frame(t->host.data);
    } else if (n == 2 && strcmp(f[0], "zoom") == 0 && t->view) {
        zs_view_zoom(t->view, (float)v[0]);
        t->host.frame(t->host.data);
    } else if (n == 5 && strcmp(f[0], "look") == 0 && t->view) {
        zs_part part;
        if (zs_app_part_get(zg_model_core(t->model), 0, &part) == ZS_OK) {
            zs_view_look_at(t->view, (float)part.x, (float)part.y, (float)(part.size_z / 2), (float)v[0], (float)v[1], (float)v[2], (float)v[3]);
            for (int k = 0; k < 200 && zs_view_animate(t->view, 0.05); k++) {}
            t->host.frame(t->host.data);
        }
    } else if (n == 3 && (strcmp(f[0], "click") == 0 || strcmp(f[0], "sclick") == 0)) {
        test_stroke(t, v[0], v[1], v[0], v[1], f[0][0] == 's');
    } else if (n == 4 && strcmp(f[0], "clickw") == 0 && t->view) {
        float qx, qy;
        if (zs_view_pixel_of(t->view, v[0], v[1], v[2], &qx, &qy)) test_stroke(t, qx / scale, qy / scale, qx / scale, qy / scale, FALSE);
        else g_message("paint test: the point is not in the view");
    } else if (n == 3 && strcmp(f[0], "hover") == 0) {
        float p[3];
        gint64 tri = hit(t, v[0], v[1], p);
        g_message("paint test: triangle %" G_GINT64_FORMAT " at %.2f %.2f %.2f", tri, p[0], p[1], p[2]);
        zg_paint_hover(t, v[0], v[1]);
    } else if (n == 5 && strcmp(f[0], "stroke") == 0) {
        test_stroke(t, v[0], v[1], v[2], v[3], FALSE);
    } else if (n == 6 && strcmp(f[0], "rect") == 0) {
        /* One stroke along the rows, left to right, then right to left. */
        double stepy = MAX(1, g_ascii_strtod(f[5], NULL));
        GArray *pts = g_array_new(FALSE, FALSE, sizeof(double));
        int row = 0;
        for (double y = v[1]; y <= v[3] + 1e-9; y += stepy, row++) {
            double a[4] = {row % 2 ? v[2] : v[0], y, row % 2 ? v[0] : v[2], y};
            g_array_append_vals(pts, a, 4);
        }
        test_path(t, (double *)pts->data, (int)pts->len / 2, FALSE);
        g_array_free(pts, TRUE);
    } else if (n == 1 && strcmp(f[0], "clear") == 0) {
        zg_paint_tool_clear(t);
    } else if (n == 1 && strcmp(f[0], "undo") == 0) {
        zg_model_undo(t->model);
    } else if (n == 1 && strcmp(f[0], "redo") == 0) {
        zg_model_redo(t->model);
    } else if (n == 2 && strcmp(f[0], "key") == 0) {
        if (!zg_paint_key(t, gdk_keyval_from_name(f[1]))) g_message("paint test: the tool did not use the key %s", f[1]);
    } else if (n == 1 && strcmp(f[0], "check") == 0) {
        const zs_issue *issues = NULL;
        size_t count = 0;
        const char *text = NULL;
        int rc = zs_app_checks(zg_model_core(t->model), &issues, &count, &text);
        size_t colors_n = 0;
        for (size_t k = 0; rc == ZS_OK && k < count; k++)
            if (issues[k].kind == ZS_ISSUE_COLOR) {
                if (colors_n++ < 5) g_message("paint test: a color issue at layer %u: %.*s", (unsigned)issues[k].layer, (int)issues[k].text_len, text + issues[k].text_start);
            }
        g_message("paint test: %zu color issues of %zu (rc %d)", colors_n, count, rc);
        gtk_widget_activate_action(t->area, "preview.check", NULL);
    } else if (n == 1 && strcmp(f[0], "partcard") == 0) {
        zg_model_set_tool(t->model, ZG_TOOL_MOVE);
        zg_model_select_part(t->model, 0);
    } else if (n == 1 && strcmp(f[0], "paint") == 0) {
        zg_model_set_tool(t->model, ZG_TOOL_PAINT);
    } else if (n == 1 && strcmp(f[0], "wait") == 0) {
    } else if (n == 1 && strcmp(f[0], "slice") == 0) {
        test_log(t, step);
        g_strfreev(f);
        g_free(step);
        r->wait_start = g_get_monotonic_time();
        g_timeout_add(200, test_wait_slice, r);
        return G_SOURCE_REMOVE;
    } else if (n == 2 && strcmp(f[0], "shot") == 0) {
        test_log(t, step);
        g_message("paint test: shot %s", f[1]);
        g_strfreev(f);
        g_free(step);
        g_timeout_add(3000, test_step, r);
        return G_SOURCE_REMOVE;
    } else {
        g_message("paint test: a bad step: %s", step);
    }
    test_log(t, step);
    g_strfreev(f);
    g_free(step);
    g_timeout_add(700, test_step, r);
    return G_SOURCE_REMOVE;
}

static void test_start(ZgPaintTool *t) {
    const char *steps = g_getenv("ZSLICE_PAINT_DO");
    if (!steps || t->test_started || !t->view) return;
    t->test_started = TRUE;
    zg_model_set_tool(t->model, ZG_TOOL_PAINT);
    TestRun *r = g_new0(TestRun, 1);
    r->t = t;
    r->steps = g_strsplit(steps, ";", -1);
    g_timeout_add(1000, test_step, r);
}
