/* label-tool.c: see label-tool.h.
 *
 * The tool keeps a copy of the labels of one part (zs_app_part_labels_get)
 * and reads them again after each slice, each undo or redo, and each
 * switch of the plate. A change of the selected label goes into the copy
 * at once: the decal and the card follow it. The change goes to the core
 * (zs_app_label_update) 400 ms after the last edit, or at the end of a
 * drag, so a drag, a turn with the wheel, or the keys of a word are one
 * step of the history. A read of the labels during that pause keeps the
 * label that waits.
 *
 * The outline of each label (zs_label_outline) is made again only when its
 * shapes change: a move or a turn changes only its frame, and the core view
 * keeps the fill of an outline that it had (zs_view_label_add).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "label-tool.h"

#include <math.h>
#include <string.h>

#include "filaments.h"
#include "float.h"
#include "label-card.h"
#include "preview.h"

/* The lift of the decal out of the surface, mm (as the core view). */
#define LIFT 0.05
/* The pause after the last change of a label before it goes to the
 * core. */
#define COMMIT_MS 400
/* The margin around the box of a label that still hits it, mm. */
#define HIT_MARGIN 1.0
/* The room for the handle around the box of a label on the screen,
 * points. */
#define HANDLE_ROOM 12.0

typedef struct {
    char *key; /* the JSON of the shapes */
    float *pts;
    uint32_t *ends;
    size_t n;
    double box[4];
} Outline;

struct ZgLabelTool {
    ZgModel *model;
    GtkWidget *area;
    zs_view *view;
    ZgLabelHost host;
    gboolean on, shown;
    /* The part of the labels, its filament (from 1), and the app of its
     * plate. */
    gint64 index;
    int base;
    zs_app *core;
    GPtrArray *labels; /* ZgLabel */
    gint64 sel;
    double curve;
    JsonObject *info;
    GHashTable *outlines; /* id -> Outline */
    GHashTable *sessions; /* part index -> zs_paint */
    /* A drag of a label: its id, the point of the press in its plane, the
     * label at the press, and the pointer of the press. */
    gboolean dragging, moved;
    guint32 drag_id;
    double drag_dx, drag_dy, press_x, press_y;
    ZgLabel *drag_start;
    /* A drag of the handle: the label at the press, the center of the
     * label and the pointer of the press on the screen. */
    gboolean scaling;
    ZgLabel *scale_start;
    double scale_c[2], scale_p[2], scale_d0;
    /* A free line that draws: its item and its points. */
    int drawing;
    GArray *drawn; /* double x, y */
    guint timer;
    gint64 pending;
    GtkWidget *card, *handle;
    gboolean test_started;
};

static void redraw(ZgLabelTool *t);
static void card_show(ZgLabelTool *t, const ZgLabel *l);
static void load_info(ZgLabelTool *t);
static void flush(ZgLabelTool *t);
static void test_start(ZgLabelTool *t);

static void outline_free(gpointer data) {
    Outline *o = data;
    g_free(o->key);
    g_free(o->pts);
    g_free(o->ends);
    g_free(o);
}

static gboolean live(ZgLabelTool *t) {
    return t->on && t->view;
}

static int scale_of(ZgLabelTool *t) {
    return gtk_widget_get_scale_factor(t->area);
}

static ZgLabel *label_by_id(ZgLabelTool *t, gint64 id) {
    for (guint i = 0; id >= 0 && i < t->labels->len; i++) {
        ZgLabel *l = g_ptr_array_index(t->labels, i);
        if (l->id == (guint32)id) return l;
    }
    return NULL;
}

const ZgLabel *zg_label_tool_label(ZgLabelTool *t) {
    return label_by_id(t, t->sel);
}

JsonObject *zg_label_tool_info(ZgLabelTool *t) {
    return t->info;
}

int zg_label_tool_base(ZgLabelTool *t) {
    return t->base;
}

double zg_label_tool_curve(ZgLabelTool *t) {
    return t->curve;
}

int zg_label_tool_drawing(ZgLabelTool *t) {
    return t->drawing;
}

/* A short note over the view. */
static void toast(ZgLabelTool *t, const char *text) {
    for (GtkWidget *w = t->area; w; w = gtk_widget_get_parent(w))
        if (g_object_get_data(G_OBJECT(w), "zg-preview")) {
            zg_preview_note(w, text, 4000);
            return;
        }
}

/* ---- the outlines and the decals ---- */

/* The outline of the shapes of a JSON (zs_label_outline), or NULL. */
static Outline *outline_of_json(const char *key) {
    const float *pts = NULL;
    const uint32_t *ends = NULL;
    size_t n = 0;
    if (zs_label_outline(key, strlen(key), &pts, &ends, &n) != ZS_OK) return NULL;
    Outline *o = g_new0(Outline, 1);
    size_t count = n > 0 ? ends[n - 1] : 0;
    o->n = n;
    o->ends = g_memdup2(ends, MAX(n, 1) * sizeof *ends);
    o->pts = g_memdup2(pts, MAX(2 * count, 1) * sizeof *pts);
    o->box[0] = o->box[1] = INFINITY;
    o->box[2] = o->box[3] = -INFINITY;
    for (size_t i = 0; i < count; i++) {
        o->box[0] = MIN(o->box[0], o->pts[2 * i]);
        o->box[1] = MIN(o->box[1], o->pts[2 * i + 1]);
        o->box[2] = MAX(o->box[2], o->pts[2 * i]);
        o->box[3] = MAX(o->box[3], o->pts[2 * i + 1]);
    }
    if (count == 0) o->box[0] = o->box[1] = o->box[2] = o->box[3] = 0;
    return o;
}

/* The outline of a label, made again only when its shapes change. */
static Outline *outline(ZgLabelTool *t, const ZgLabel *l) {
    char *key = zg_label_json(l, TRUE);
    Outline *have = g_hash_table_lookup(t->outlines, GUINT_TO_POINTER(l->id));
    if (have && strcmp(have->key, key) == 0) {
        g_free(key);
        return have;
    }
    Outline *o = outline_of_json(key);
    if (!o) {
        g_free(key);
        return have;
    }
    o->key = key;
    g_hash_table_replace(t->outlines, GUINT_TO_POINTER(l->id), o);
    return o;
}

static guint32 filament_rgb(ZgLabelTool *t, int filament) {
    char *c = zg_model_filament_get(t->model, (size_t)MAX(filament - 1, 0), "filament.color");
    if (!c || !c[0]) {
        g_free(c);
        c = zg_model_filament_get(t->model, 0, "filament.color");
    }
    double rgb[3];
    zg_filament_rgb(c, rgb);
    g_free(c);
    return ((guint32)lround(rgb[0] * 255) << 16) | ((guint32)lround(rgb[1] * 255) << 8) | (guint32)lround(rgb[2] * 255);
}

/* The decals of the labels of the part to the core view. */
static void redraw(ZgLabelTool *t) {
    if (!t->view) return;
    zs_view_labels_clear(t->view);
    for (guint i = 0; t->on && i < t->labels->len; i++) {
        ZgLabel *l = g_ptr_array_index(t->labels, i);
        Outline *o = outline(t, l);
        if (!o || o->n == 0) continue;
        double frame[9];
        memcpy(frame, l->origin, sizeof l->origin);
        memcpy(frame + 3, l->normal, sizeof l->normal);
        memcpy(frame + 6, l->right, sizeof l->right);
        zs_view_label_add(t->view, frame, o->pts, o->ends, o->n, filament_rgb(t, l->filament), l->id == (guint32)t->sel);
    }
    t->host.frame(t->host.data);
}

/* ---- the picks ---- */

static gboolean ray(ZgLabelTool *t, double x, double y, float r[6], double o[3], double d[3]) {
    int s = scale_of(t);
    if (!t->view || !zs_view_ray(t->view, (float)(x * s), (float)(y * s), r)) return FALSE;
    for (int k = 0; k < 3; k++) {
        o[k] = r[k];
        d[k] = r[3 + k];
    }
    return TRUE;
}

/* The paint session of the mesh of part `index`, for the pick. */
static zs_paint *session(ZgLabelTool *t, gint64 index) {
    zs_app *core = zg_model_core(t->model);
    if (index < 0) return NULL;
    zs_paint *have = g_hash_table_lookup(t->sessions, GINT_TO_POINTER((int)index));
    if (have) return have;
    const float *verts = NULL;
    const uint32_t *faces = NULL;
    size_t nv = 0, nf = 0;
    zs_paint *s = NULL;
    if (zs_app_part_mesh(core, (size_t)index, &verts, &nv, &faces, &nf) != ZS_OK || nf == 0) return NULL;
    if (zs_paint_new(verts, nv, faces, nf, &s) != ZS_OK) return NULL;
    g_hash_table_insert(t->sessions, GINT_TO_POINTER((int)index), s);
    return s;
}

static void free_sessions(ZgLabelTool *t) {
    g_hash_table_remove_all(t->sessions);
}

/* The frame of a label at x, y on the mesh of part `index`: out as
 * zs_label_place. */
static gboolean place_at(ZgLabelTool *t, gint64 index, double x, double y, double out[10]) {
    float r[6];
    double o[3], d[3];
    zs_paint *s = session(t, index);
    return s && ray(t, x, y, r, o, d) && zs_label_place(s, r, 5, out) == 1;
}

/* The label under x, y (the selected label first), and the point in its
 * plane. */
static ZgLabel *label_at(ZgLabelTool *t, double x, double y, double *lx, double *ly) {
    float r[6];
    double o[3], d[3];
    if (!live(t) || !ray(t, x, y, r, o, d)) return NULL;
    for (int pass = 0; pass < 2; pass++) {
        for (guint i = 0; i < t->labels->len; i++) {
            ZgLabel *l = g_ptr_array_index(t->labels, i);
            if ((pass == 0) != (l->id == (guint32)t->sel)) continue;
            Outline *ol = outline(t, l);
            double p[3], px, py;
            if (!ol || !zg_label_plane_hit(l, o, d, p, &px, &py)) continue;
            if (px >= ol->box[0] - HIT_MARGIN && px <= ol->box[2] + HIT_MARGIN && py >= ol->box[1] - HIT_MARGIN && py <= ol->box[3] + HIT_MARGIN) {
                if (lx) *lx = px;
                if (ly) *ly = py;
                return l;
            }
        }
    }
    return NULL;
}

/* A point of the plane of a label on the screen (points of the view). */
static gboolean screen_of(ZgLabelTool *t, const ZgLabel *l, double x, double y, double out[2]) {
    double p[3];
    float qx, qy;
    zg_label_to_bed(l, x, y, LIFT, p);
    if (!t->view || !zs_view_pixel_of(t->view, p[0], p[1], p[2], &qx, &qy)) return FALSE;
    int s = scale_of(t);
    out[0] = qx / s;
    out[1] = qy / s;
    return TRUE;
}

/* The box of the selected label on the screen, with the room of its
 * handle. FALSE if it does not show. */
static gboolean screen_box(ZgLabelTool *t, double box[4]) {
    const ZgLabel *l = zg_label_tool_label(t);
    Outline *o = l ? outline(t, l) : NULL;
    if (!o) return FALSE;
    box[0] = box[1] = INFINITY;
    box[2] = box[3] = -INFINITY;
    for (int k = 0; k < 4; k++) {
        double q[2];
        if (!screen_of(t, l, k & 1 ? o->box[2] + HIT_MARGIN : o->box[0] - HIT_MARGIN, k & 2 ? o->box[3] + HIT_MARGIN : o->box[1] - HIT_MARGIN, q))
            continue;
        box[0] = MIN(box[0], q[0]);
        box[1] = MIN(box[1], q[1]);
        box[2] = MAX(box[2], q[0]);
        box[3] = MAX(box[3], q[1]);
    }
    if (!(box[0] <= box[2])) return FALSE;
    box[0] -= HANDLE_ROOM;
    box[1] -= HANDLE_ROOM;
    box[2] += HANDLE_ROOM;
    box[3] += HANDLE_ROOM;
    return TRUE;
}

static gboolean screen_center(ZgLabelTool *t, double c[2]) {
    const ZgLabel *l = zg_label_tool_label(t);
    Outline *o = l ? outline(t, l) : NULL;
    return o && screen_of(t, l, (o->box[0] + o->box[2]) / 2, (o->box[1] + o->box[3]) / 2, c);
}

/* ---- the labels of the core ---- */

static char *labels_json(zs_app *core, gint64 index) {
    size_t cap = 4096, len = 0;
    char *buf = g_malloc(cap);
    for (int tries = 0; tries < 2; tries++) {
        if (zs_app_part_labels_get(core, (size_t)index, buf, cap, &len) != ZS_OK) {
            g_free(buf);
            return NULL;
        }
        if (len < cap) return buf;
        cap = len + 1;
        buf = g_realloc(buf, cap);
    }
    g_free(buf);
    return NULL;
}

/* The filament of part `index` (from 1): its own, or the plate's. */
static int part_filament(ZgLabelTool *t, gint64 index) {
    char *own = zg_model_part_setting(t->model, (size_t)index, "project.filament");
    char *v = own ? own : zg_model_get(t->model, "project.filament");
    int f = atoi(v ? v : "1");
    g_free(v);
    return f > 0 ? f : 1;
}

void zg_label_tool_select(ZgLabelTool *t, gint64 id);

/* The labels of part `index` from the core. id: the label to select (-1:
 * keep the selection if the label is still there). */
static void load(ZgLabelTool *t, gint64 index, gint64 id) {
    zs_app *core = zg_model_core(t->model);
    if (index < 0 || (size_t)index >= zs_app_part_count(core)) {
        t->index = -1;
        g_ptr_array_set_size(t->labels, 0);
        zg_label_tool_select(t, -1);
        redraw(t);
        return;
    }
    if (index != t->index) zg_label_tool_select(t, -1);
    char *json = labels_json(core, index);
    GPtrArray *list = json ? zg_labels_parse(json, -1) : NULL;
    g_free(json);
    if (!list) list = g_ptr_array_new_with_free_func((GDestroyNotify)zg_label_free);
    /* A change that waits for its pause keeps its values. */
    ZgLabel *keep = index == t->index && t->pending >= 0 ? label_by_id(t, t->pending) : NULL;
    for (guint i = 0; keep && i < list->len; i++) {
        ZgLabel *l = g_ptr_array_index(list, i);
        if (l->id != keep->id) continue;
        g_ptr_array_index(list, i) = zg_label_copy(keep);
        zg_label_free(l);
    }
    g_ptr_array_unref(t->labels);
    t->labels = list;
    t->index = index;
    t->core = core;
    t->base = part_filament(t, index);
    if (id >= 0) zg_label_tool_select(t, id);
    else if (!zg_label_tool_label(t)) zg_label_tool_select(t, -1);
    else card_show(t, zg_label_tool_label(t));
    redraw(t);
}

/* After a slice, an undo, or another plate: the labels again, and a new
 * mesh for the pick (the part can be at another place). */
static void reload(ZgLabelTool *t) {
    if (!t->on || t->dragging || t->scaling) return;
    free_sessions(t);
    if (t->core != zg_model_core(t->model)) {
        /* Another plate: its labels are on other parts. */
        t->pending = -1;
        t->index = -1;
    }
    if (t->index >= 0) load(t, t->index, -1);
    else {
        g_ptr_array_set_size(t->labels, 0);
        zg_label_tool_select(t, -1);
        redraw(t);
    }
    load_info(t);
}

static void load_info(ZgLabelTool *t) {
    const ZgLabel *l = zg_label_tool_label(t);
    if (t->info) json_object_unref(t->info);
    t->info = NULL;
    if (!l) return;
    size_t cap = 2048, len = 0;
    char *buf = g_malloc(cap);
    int rc = zs_app_label_info(zg_model_core(t->model), (size_t)t->index, l->id, buf, cap, &len);
    if (rc == ZS_OK && len >= cap) {
        cap = len + 1;
        buf = g_realloc(buf, cap);
        rc = zs_app_label_info(zg_model_core(t->model), (size_t)t->index, l->id, buf, cap, &len);
    }
    if (rc == ZS_OK) {
        JsonParser *p = json_parser_new();
        if (json_parser_load_from_data(p, buf, (gssize)len, NULL) && JSON_NODE_HOLDS_OBJECT(json_parser_get_root(p)))
            t->info = json_object_ref(json_node_get_object(json_parser_get_root(p)));
        g_object_unref(p);
    }
    g_free(buf);
    zg_label_card_info(t->card, t->info);
}

/* ---- the selection ---- */

/* The card of label l (NULL: none), while the tool and the view show. */
static void card_show(ZgLabelTool *t, const ZgLabel *l) {
    zg_label_card_show(t->card, t->on && t->shown ? l : NULL);
}

static void show_handle(ZgLabelTool *t) {
    gtk_widget_set_visible(t->handle, t->shown && zg_label_tool_label(t) != NULL);
}

void zg_label_tool_select(ZgLabelTool *t, gint64 id) {
    if (id != t->sel) {
        flush(t);
        t->drawing = -1;
    }
    t->sel = id;
    const ZgLabel *l = zg_label_tool_label(t);
    if (!l) {
        t->sel = -1;
        if (t->info) json_object_unref(t->info);
        t->info = NULL;
        t->curve = 0;
        card_show(t, NULL);
        show_handle(t);
        redraw(t);
        return;
    }
    card_show(t, t->shown ? l : NULL);
    show_handle(t);
    redraw(t);
    load_info(t);
    zg_label_tool_place(t);
}

/* ---- the changes ---- */

static gboolean on_commit_timer(gpointer data) {
    ZgLabelTool *t = data;
    t->timer = 0;
    flush(t);
    return G_SOURCE_REMOVE;
}

/* The selected label becomes `next` (the tool owns it): the decal and the
 * card at once, and the core after a pause (commit: at once). FALSE for a
 * bad shape: the label stays. */
static gboolean change(ZgLabelTool *t, ZgLabel *next, gboolean commit) {
    ZgLabel *l = label_by_id(t, t->sel);
    if (!l) {
        zg_label_free(next);
        return FALSE;
    }
    char *a = zg_label_json(l, TRUE), *b = zg_label_json(next, TRUE);
    gboolean same = strcmp(a, b) == 0;
    Outline *check = same ? NULL : outline_of_json(b);
    g_free(a);
    g_free(b);
    if (!same && !check) {
        zg_label_free(next);
        return FALSE;
    }
    if (check) outline_free(check);
    next->id = l->id;
    for (guint i = 0; i < t->labels->len; i++)
        if (g_ptr_array_index(t->labels, i) == l) {
            g_ptr_array_index(t->labels, i) = next;
            zg_label_free(l);
            break;
        }
    redraw(t);
    card_show(t, next);
    if (t->timer) g_source_remove(t->timer);
    t->timer = 0;
    t->pending = next->id;
    /* A drag sends the label at its end (one step of the history). */
    if (commit) flush(t);
    else if (!t->dragging && !t->scaling) t->timer = g_timeout_add(COMMIT_MS, on_commit_timer, t);
    return TRUE;
}

/* A copy of the selected label to change, with its own items. */
static ZgLabel *edit_copy(ZgLabelTool *t) {
    const ZgLabel *l = zg_label_tool_label(t);
    if (!l) return NULL;
    ZgLabel *c = zg_label_copy(l);
    zg_label_own_items(c);
    return c;
}

/* Sends the change that waits to the core. */
static void flush(ZgLabelTool *t) {
    if (t->timer) g_source_remove(t->timer);
    t->timer = 0;
    gint64 id = t->pending;
    t->pending = -1;
    ZgLabel *l = label_by_id(t, id);
    if (!l || t->index < 0) return;
    char *json = zg_label_json(l, FALSE);
    if (!zg_model_label_update(t->model, (size_t)t->index, l->id, json)) toast(t, "The label did not change: a value is out of range.");
    g_free(json);
    load_info(t);
}

gboolean zg_label_tool_edit_number(ZgLabelTool *t, guint item, const char *field, double v) {
    ZgLabel *c = edit_copy(t);
    JsonObject *it = c ? zg_label_item(c, item) : NULL;
    if (!it || !isfinite(v)) {
        zg_label_free(c);
        return FALSE;
    }
    if (strcmp(field, "count") == 0) json_object_set_int_member(it, field, (gint64)lround(v));
    else json_object_set_double_member(it, field, v);
    return change(t, c, FALSE);
}

gboolean zg_label_tool_edit_text(ZgLabelTool *t, guint item, const char *text) {
    ZgLabel *c = edit_copy(t);
    JsonObject *it = c ? zg_label_item(c, item) : NULL;
    if (!it) {
        zg_label_free(c);
        return FALSE;
    }
    json_object_set_string_member(it, "text", text);
    return change(t, c, FALSE);
}

gboolean zg_label_tool_edit_flag(ZgLabelTool *t, guint item, const char *field, gboolean on) {
    ZgLabel *c = edit_copy(t);
    JsonObject *it = c ? zg_label_item(c, item) : NULL;
    if (!it) {
        zg_label_free(c);
        return FALSE;
    }
    json_object_set_boolean_member(it, field, on);
    return change(t, c, FALSE);
}

gboolean zg_label_tool_edit_at(ZgLabelTool *t, guint item, double x, double y) {
    ZgLabel *c = edit_copy(t);
    JsonObject *it = c ? zg_label_item(c, item) : NULL;
    if (!it || !isfinite(x) || !isfinite(y)) {
        zg_label_free(c);
        return FALSE;
    }
    JsonArray *a = json_array_sized_new(2);
    json_array_add_double_element(a, x);
    json_array_add_double_element(a, y);
    json_object_set_array_member(it, "at", a);
    return change(t, c, FALSE);
}

static void replace_item(ZgLabel *c, guint item, JsonObject *it) {
    JsonArray *a = json_array_new();
    for (guint i = 0; i < zg_label_item_count(c); i++) {
        if (i == item) json_array_add_object_element(a, it);
        else json_array_add_object_element(a, json_object_ref(zg_label_item(c, i)));
    }
    json_array_unref(c->items);
    c->items = a;
}

void zg_label_tool_set_shape(ZgLabelTool *t, guint item, const char *kind) {
    ZgLabel *c = edit_copy(t);
    JsonObject *it = c ? zg_label_item(c, item) : NULL;
    if (!it) {
        zg_label_free(c);
        return;
    }
    replace_item(c, item, zg_label_change_shape(it, kind));
    if (t->drawing == (int)item) t->drawing = -1;
    change(t, c, TRUE);
}

/* A new item in the label: under the items that are there (ticks and
 * rings go around the center, under the text). */
void zg_label_tool_add_item(ZgLabelTool *t, const char *kind) {
    const ZgLabel *l = zg_label_tool_label(t);
    if (!l) return;
    Outline *o = outline(t, l);
    double size = 5;
    for (guint i = 0; i < zg_label_item_count(l); i++) {
        JsonObject *it = zg_label_item(l, i);
        if (strcmp(zg_label_item_kind(it), "text") == 0) {
            size = zg_label_item_number(it, "size", 5);
            break;
        }
    }
    JsonObject *it = zg_label_new_item(kind, size);
    double at_y = NAN;
    if (strcmp(kind, "ticks") == 0 || strcmp(kind, "ring") == 0) {
        double r = strcmp(kind, "ticks") == 0 ? zg_label_item_number(it, "radius", 0) + zg_label_item_number(it, "length_end", 0)
                                              : zg_label_item_number(it, "outer", 0);
        at_y = (o ? o->box[1] : 0) - r - 1;
    } else if (o && zg_label_item_count(l) > 0) {
        at_y = o->box[1] - size;
    }
    if (!isnan(at_y)) {
        JsonArray *a = json_array_sized_new(2);
        json_array_add_double_element(a, 0);
        json_array_add_double_element(a, at_y);
        json_object_set_array_member(it, "at", a);
    }
    ZgLabel *c = edit_copy(t);
    json_array_add_object_element(c->items, it);
    change(t, c, TRUE);
}

void zg_label_tool_remove_item(ZgLabelTool *t, guint item) {
    const ZgLabel *l = zg_label_tool_label(t);
    if (!l || zg_label_item_count(l) <= 1 || item >= zg_label_item_count(l)) return;
    ZgLabel *c = edit_copy(t);
    json_array_remove_element(c->items, item);
    if (t->drawing == (int)item) t->drawing = -1;
    else if (t->drawing > (int)item) t->drawing--;
    change(t, c, TRUE);
}

void zg_label_tool_set_angle(ZgLabelTool *t, double deg) {
    ZgLabel *c = edit_copy(t);
    if (!c) return;
    zg_label_set_angle(c, deg);
    change(t, c, FALSE);
}

static void turn(ZgLabelTool *t, double deg) {
    ZgLabel *c = edit_copy(t);
    if (!c) return;
    zg_label_turn(c, deg);
    change(t, c, FALSE);
}

void zg_label_tool_set_filament(ZgLabelTool *t, int filament) {
    ZgLabel *c = edit_copy(t);
    if (!c) return;
    c->filament = filament;
    change(t, c, TRUE);
}

void zg_label_tool_add_filament(ZgLabelTool *t) {
    gint64 i = zg_model_filament_add(t->model);
    if (i >= 0) zg_label_tool_set_filament(t, (int)i + 1);
    const ZgLabel *l = zg_label_tool_label(t);
    if (l) card_show(t, l);
}

void zg_label_tool_set_depth(ZgLabelTool *t, double mm) {
    ZgLabel *c = edit_copy(t);
    if (!c) return;
    c->depth = CLAMP(mm, 0, 10);
    change(t, c, TRUE);
}

void zg_label_tool_remove(ZgLabelTool *t) {
    const ZgLabel *l = zg_label_tool_label(t);
    if (!l || t->index < 0) return;
    if (t->timer) g_source_remove(t->timer);
    t->timer = 0;
    t->pending = -1;
    guint32 id = l->id;
    zg_model_label_remove(t->model, (size_t)t->index, id);
    g_hash_table_remove(t->outlines, GUINT_TO_POINTER(id));
    t->sel = -1;
    load(t, t->index, -1);
}

void zg_label_tool_draw_points(ZgLabelTool *t, int item) {
    t->drawing = item;
    g_array_set_size(t->drawn, 0);
    if (item < 0) flush(t);
    const ZgLabel *l = zg_label_tool_label(t);
    if (l) card_show(t, l);
}

/* A point of a free line at x, y: into the item that draws. */
static void draw_point(ZgLabelTool *t, double x, double y) {
    const ZgLabel *l = zg_label_tool_label(t);
    JsonObject *it = l ? zg_label_item(l, (guint)t->drawing) : NULL;
    float r[6];
    double o[3], d[3], p[3], hx, hy;
    if (!it || strcmp(zg_label_item_kind(it), "polyline") != 0 || !ray(t, x, y, r, o, d) || !zg_label_plane_hit(l, o, d, p, &hx, &hy)) return;
    double at[2] = {0, 0};
    if (json_object_has_member(it, "at")) {
        JsonArray *a = json_object_get_array_member(it, "at");
        if (a && json_array_get_length(a) == 2) {
            at[0] = json_array_get_double_element(a, 0);
            at[1] = json_array_get_double_element(a, 1);
        }
    }
    double ang = -zg_label_item_number(it, "angle", 0) * G_PI / 180, px = hx - at[0], py = hy - at[1];
    double q[2] = {px * cos(ang) - py * sin(ang), px * sin(ang) + py * cos(ang)};
    g_array_append_vals(t->drawn, q, 2);
    guint n = t->drawn->len / 2;
    if (n < 2) return;
    ZgLabel *c = edit_copy(t);
    JsonObject *ci = zg_label_item(c, (guint)t->drawing);
    JsonArray *pts = json_array_new();
    for (guint k = 0; k < n; k++) {
        JsonArray *pt = json_array_sized_new(2);
        json_array_add_double_element(pt, g_array_index(t->drawn, double, 2 * k));
        json_array_add_double_element(pt, g_array_index(t->drawn, double, 2 * k + 1));
        json_array_add_array_element(pts, pt);
    }
    json_object_set_array_member(ci, "points", pts);
    change(t, c, FALSE);
}

/* ---- a new label ---- */

static void add_at(ZgLabelTool *t, double x, double y) {
    gint64 part = t->host.part_at(t->host.data, x, y);
    if (part < 0) {
        zg_label_tool_select(t, -1);
        return;
    }
    if (part != t->index) load(t, part, -1);
    double at[10];
    if (!place_at(t, part, x, y, at)) {
        toast(t, "Click a face of the part to put a label there.");
        return;
    }
    ZgLabel *l = zg_label_new();
    memcpy(l->origin, at, sizeof l->origin);
    memcpy(l->normal, at + 3, sizeof l->normal);
    memcpy(l->right, at + 6, sizeof l->right);
    l->filament = zg_label_next_filament(t->base, (int)zs_app_filament_count(zg_model_core(t->model)));
    json_array_add_object_element(l->items, zg_label_new_item("text", 5));
    char *json = zg_label_json(l, FALSE);
    zg_label_free(l);
    flush(t);
    gint64 id = zg_model_label_add(t->model, (size_t)part, json);
    g_free(json);
    if (id < 0) {
        toast(t, "The label does not fit here.");
        return;
    }
    t->curve = at[9];
    load(t, part, id);
    zg_label_card_curve(t->card, t->curve);
    /* The text field gets the keys at once. */
    zg_label_card_focus_text(t->card);
}

/* ---- the pointer ---- */

gboolean zg_label_press(ZgLabelTool *t, double x, double y) {
    if (!live(t) || t->drawing >= 0) return FALSE;
    /* The keys go back to the view (Delete removes the label). */
    t->host.focus(t->host.data);
    double lx, ly;
    ZgLabel *l = label_at(t, x, y, &lx, &ly);
    if (!l) return FALSE;
    guint32 id = l->id;
    if ((gint64)id != t->sel) zg_label_tool_select(t, id);
    flush(t);
    l = label_by_id(t, id);
    if (!l) return FALSE;
    t->dragging = TRUE;
    t->moved = FALSE;
    t->drag_id = id;
    t->drag_dx = lx;
    t->drag_dy = ly;
    t->press_x = x;
    t->press_y = y;
    zg_label_free(t->drag_start);
    t->drag_start = zg_label_copy(l);
    /* The mesh for the pick, before the first move. */
    session(t, t->index);
    return TRUE;
}

/* The selected label under the pointer while it drags: on the surface,
 * or in its plane with Shift. */
static void move_to(ZgLabelTool *t, double x, double y, gboolean keep_plane) {
    const ZgLabel *s = t->drag_start;
    if (!s) return;
    if (keep_plane) {
        float r[6];
        double o[3], d[3], p[3], hx, hy, up[3];
        if (!ray(t, x, y, r, o, d) || !zg_label_plane_hit(s, o, d, p, &hx, &hy)) return;
        zg_label_up(s, up);
        ZgLabel *c = edit_copy(t);
        if (!c) return;
        for (int k = 0; k < 3; k++) c->origin[k] = p[k] - t->drag_dx * s->right[k] - t->drag_dy * up[k];
        memcpy(c->normal, s->normal, sizeof c->normal);
        memcpy(c->right, s->right, sizeof c->right);
        change(t, c, FALSE);
        return;
    }
    double at[10];
    if (!place_at(t, t->index, x, y, at)) return;
    ZgLabel *c = edit_copy(t);
    if (!c) return;
    zg_label_move(c, at, at + 3);
    double up[3];
    zg_label_up(c, up);
    for (int k = 0; k < 3; k++) c->origin[k] -= t->drag_dx * c->right[k] + t->drag_dy * up[k];
    change(t, c, FALSE);
    if (fabs(at[9] - t->curve) > 1e-6) {
        t->curve = at[9];
        zg_label_card_curve(t->card, t->curve);
    }
}

void zg_label_drag(ZgLabelTool *t, double x, double y, gboolean shift) {
    if (!t->dragging) return;
    if (!t->moved && hypot(x - t->press_x, y - t->press_y) < 3) return;
    t->moved = TRUE;
    move_to(t, x, y, shift);
}

void zg_label_release(ZgLabelTool *t) {
    if (!t->dragging) return;
    t->dragging = FALSE;
    g_clear_pointer(&t->drag_start, zg_label_free);
    if (t->moved) flush(t);
    t->moved = FALSE;
}

gboolean zg_label_dragging(ZgLabelTool *t) {
    return t->dragging;
}

void zg_label_click(ZgLabelTool *t, double x, double y) {
    if (!live(t)) return;
    t->host.focus(t->host.data);
    if (t->drawing >= 0) {
        draw_point(t, x, y);
        return;
    }
    ZgLabel *l = label_at(t, x, y, NULL, NULL);
    if (l) {
        if ((gint64)l->id != t->sel) zg_label_tool_select(t, l->id);
        return;
    }
    add_at(t, x, y);
}

gboolean zg_label_wheel(ZgLabelTool *t, double x, double y, double dy, gboolean shift) {
    if (!live(t) || t->sel < 0) return FALSE;
    ZgLabel *l = label_at(t, x, y, NULL, NULL);
    if (!l || (gint64)l->id != t->sel) return FALSE;
    if (dy != 0) turn(t, (dy < 0 ? 1 : -1) * (shift ? 15 : 1));
    return TRUE;
}

gboolean zg_label_key(ZgLabelTool *t, guint key) {
    if (!t->on) return FALSE;
    switch (key) {
    case GDK_KEY_Delete:
    case GDK_KEY_KP_Delete:
    case GDK_KEY_BackSpace:
        if (t->sel < 0) return FALSE;
        zg_label_tool_remove(t);
        return TRUE;
    case GDK_KEY_Escape:
        if (t->drawing >= 0) zg_label_tool_draw_points(t, -1);
        else if (t->sel >= 0) zg_label_tool_select(t, -1);
        else zg_model_set_tool(t->model, ZG_TOOL_SELECT);
        return TRUE;
    default: return FALSE;
    }
}

const char *zg_label_cursor(ZgLabelTool *t, double x, double y) {
    if (t->drawing < 0 && label_at(t, x, y, NULL, NULL)) return "grab";
    return "crosshair";
}

/* ---- the handle at the corner: a drag scales the label ---- */

static void draw_handle(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    cairo_rectangle(cr, 1.5, 1.5, w - 3, h - 3);
    cairo_set_source_rgb(cr, 0xf5 / 255.0, 0xc2 / 255.0, 0x11 / 255.0);
    cairo_fill_preserve(cr);
    cairo_set_source_rgb(cr, 0x1b / 255.0, 0x1b / 255.0, 0x1d / 255.0);
    cairo_set_line_width(cr, 1.5);
    cairo_stroke(cr);
}

static void on_handle_begin(GtkGestureDrag *g, double x, double y, gpointer data) {
    ZgLabelTool *t = data;
    const ZgLabel *l = zg_label_tool_label(t);
    double c[2];
    graphene_point_t p;
    if (!l || !screen_center(t, c) || !gtk_widget_compute_point(t->handle, t->area, &GRAPHENE_POINT_INIT((float)x, (float)y), &p)) {
        gtk_gesture_set_state(GTK_GESTURE(g), GTK_EVENT_SEQUENCE_DENIED);
        return;
    }
    flush(t);
    t->scaling = TRUE;
    zg_label_free(t->scale_start);
    t->scale_start = zg_label_copy(l);
    t->scale_c[0] = c[0];
    t->scale_c[1] = c[1];
    t->scale_p[0] = p.x;
    t->scale_p[1] = p.y;
    t->scale_d0 = MAX(4, hypot(p.x - c[0], p.y - c[1]));
}

static void scale_to(ZgLabelTool *t, double x, double y) {
    if (!t->scaling || !t->scale_start) return;
    double k = MAX(0.05, hypot(x - t->scale_c[0], y - t->scale_c[1]) / t->scale_d0);
    ZgLabel *c = zg_label_copy(t->scale_start);
    zg_label_scale(c, k);
    change(t, c, FALSE);
}

static void on_handle_update(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    ZgLabelTool *t = data;
    scale_to(t, t->scale_p[0] + dx, t->scale_p[1] + dy);
}

static void scale_end(ZgLabelTool *t) {
    if (!t->scaling) return;
    t->scaling = FALSE;
    g_clear_pointer(&t->scale_start, zg_label_free);
    flush(t);
}

static void on_handle_end(GtkGestureDrag *g, double dx, double dy, gpointer data) {
    scale_end(data);
}

/* After each frame: the handle at the upper right corner of the label,
 * and the card beside the label. */
void zg_label_tool_place(ZgLabelTool *t) {
    if (!t->on || t->sel < 0 || !t->shown) return;
    const ZgLabel *l = zg_label_tool_label(t);
    Outline *o = l ? outline(t, l) : NULL;
    double q[2];
    gboolean at = o && screen_of(t, l, o->box[2] + 0.5, o->box[3] + 0.5, q);
    gtk_widget_set_visible(t->handle, at);
    if (at) {
        double ox, oy;
        if (!zg_float_get(t->handle, &ox, &oy) || fabs(ox - (q[0] - 7)) > 0.25 || fabs(oy - (q[1] - 7)) > 0.25) zg_float_place(t->handle, q[0] - 7, q[1] - 7);
    }
    GtkWidget *host = gtk_widget_get_parent(t->card);
    double box[4];
    if (host) zg_label_card_place(t->card, host, screen_box(t, box) ? box : NULL);
}

/* ---- the tool on and off ---- */

static void close_tool(ZgLabelTool *t) {
    flush(t);
    zg_label_release(t);
    scale_end(t);
    free_sessions(t);
    g_ptr_array_set_size(t->labels, 0);
    g_hash_table_remove_all(t->outlines);
    t->index = -1;
    t->drawing = -1;
    zg_label_tool_select(t, -1);
    if (t->view) {
        zs_view_labels_clear(t->view);
        t->host.frame(t->host.data);
    }
}

static void on_tool_changed(ZgModel *model, gpointer data) {
    ZgLabelTool *t = data;
    gboolean on = zg_model_tool(model) == ZG_TOOL_LABEL;
    if (on == t->on) return;
    if (!on) {
        close_tool(t);
        t->on = FALSE;
        return;
    }
    t->on = TRUE;
    t->core = zg_model_core(model);
    gint64 part = zg_model_selected_part(model);
    if (part >= 0) load(t, part, -1);
    toast(t, "Click a face of a part to put a label there. Drag a label to move it; the wheel turns it.");
    t->host.focus(t->host.data);
}

/* An undo, a redo, or a switch of the plate: the labels of the core
 * again. */
static void on_maybe_changed(ZgModel *model, gpointer data) {
    reload(data);
}

static void on_core_event(ZgModel *model, int event, double progress, int status, gpointer data) {
    ZgLabelTool *t = data;
    if (event == ZS_EVENT_SLICED) {
        reload(t);
        test_start(t);
    }
}

/* A new color of a filament: the decals again. */
static void on_filaments(ZgModel *model, gpointer data) {
    ZgLabelTool *t = data;
    if (!t->on) return;
    redraw(t);
    const ZgLabel *l = zg_label_tool_label(t);
    if (l) card_show(t, l);
}

void zg_label_tool_open(ZgLabelTool *t, gint64 part, guint32 id) {
    if (zg_model_tool(t->model) != ZG_TOOL_LABEL) zg_model_set_tool(t->model, ZG_TOOL_LABEL);
    load(t, part, id);
}

ZgLabelTool *zg_label_tool_new(ZgModel *model, GtkWidget *area, ZgLabelHost host) {
    ZgLabelTool *t = g_new0(ZgLabelTool, 1);
    t->model = model;
    t->area = area;
    t->host = host;
    t->index = -1;
    t->sel = -1;
    t->pending = -1;
    t->drawing = -1;
    t->labels = g_ptr_array_new_with_free_func((GDestroyNotify)zg_label_free);
    t->outlines = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, outline_free);
    t->sessions = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, (GDestroyNotify)zs_paint_free);
    t->drawn = g_array_new(FALSE, FALSE, sizeof(double));
    t->card = g_object_ref_sink(zg_label_card_new(model, t));
    t->handle = g_object_ref_sink(gtk_drawing_area_new());
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(t->handle), 14);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(t->handle), 14);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(t->handle), draw_handle, NULL, NULL);
    gtk_widget_set_cursor_from_name(t->handle, "nesw-resize");
    gtk_widget_set_tooltip_text(t->handle, "Drag to make the label larger or smaller");
    gtk_widget_set_halign(t->handle, GTK_ALIGN_START);
    gtk_widget_set_valign(t->handle, GTK_ALIGN_START);
    GtkGesture *drag = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag), GDK_BUTTON_PRIMARY);
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_handle_begin), t);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_handle_update), t);
    g_signal_connect(drag, "drag-end", G_CALLBACK(on_handle_end), t);
    gtk_widget_add_controller(t->handle, GTK_EVENT_CONTROLLER(drag));
    gtk_widget_set_visible(t->handle, FALSE);
    g_signal_connect(model, "tool-changed", G_CALLBACK(on_tool_changed), t);
    g_signal_connect(model, "undo-changed", G_CALLBACK(on_maybe_changed), t);
    g_signal_connect(model, "plates-changed", G_CALLBACK(on_maybe_changed), t);
    g_signal_connect(model, "core-event", G_CALLBACK(on_core_event), t);
    g_signal_connect(model, "filaments-changed", G_CALLBACK(on_filaments), t);
    return t;
}

void zg_label_tool_free(ZgLabelTool *t) {
    if (!t) return;
    g_signal_handlers_disconnect_by_data(t->model, t);
    if (t->timer) g_source_remove(t->timer);
    g_hash_table_destroy(t->sessions);
    g_hash_table_destroy(t->outlines);
    g_ptr_array_unref(t->labels);
    g_array_free(t->drawn, TRUE);
    zg_label_free(t->drag_start);
    zg_label_free(t->scale_start);
    if (t->info) json_object_unref(t->info);
    g_object_unref(t->card);
    g_object_unref(t->handle);
    g_free(t);
}

void zg_label_tool_set_view(ZgLabelTool *t, zs_view *view) {
    t->view = view;
    if (t->on) redraw(t);
    if (view && zs_app_state(zg_model_core(t->model)) == ZS_STATE_DONE) test_start(t);
}

void zg_label_tool_set_shown(ZgLabelTool *t, gboolean shown) {
    t->shown = shown;
    const ZgLabel *l = zg_label_tool_label(t);
    card_show(t, shown && t->on ? l : NULL);
    show_handle(t);
}

GtkWidget *zg_label_tool_card(ZgLabelTool *t) {
    return t->card;
}

GtkWidget *zg_label_tool_handle(ZgLabelTool *t) {
    return t->handle;
}

/* ---- the test hook ----
 *
 * ZSLICE_LABEL_DO=steps: picks the Label tool 1 s after the first slice,
 * then runs one step each 700 ms, as the mouse and the keys do. Steps,
 * with ';' between them: "orbit dx dy" (turn the view), "zoom f" (zoom
 * toward the middle of the view), "click x y" (a click at a point of the
 * view), "clickw x y z" (a click at the pixel of a point of the bed frame,
 * mm), "drag dx dy" (drag the selected label from its center by dx, dy
 * points; "sdrag": with Shift), "wheel n" (n steps of the wheel over the
 * selected label; "swheel": with Shift), "scale k" (drag the handle to k
 * times its distance from the center), "text T" (the text of item 0;
 * '_' is a space), "set i field value" (a field of item i), "shape i kind",
 * "add kind", "filament n", "depth mm", "turn deg", "key Name", "undo",
 * "redo", "wait" (no step), "look nx ny nz d" (the camera looks at the
 * middle of the front face of part 0 from the direction n, d mm away),
 * "face dx dz" (a click on the front face
 * (-Y) of part 0, dx and dz mm from its middle), "addfilament", "info"
 * (the facts again), "check" (the issues of kind ZS_ISSUE_LABEL in the
 * log, and the Check list opens), "partcard" (the Move tool selects
 * part 0, and its card shows), "partlabel" (a click on the first label of
 * the part card), "draw i" (clicks add points to the free line of item
 * i; -1 stops), "reload" (the labels from the core again, as after a
 * slice), "esc" (the card closes, then the tool), "shot N"
 * (logs "label test: shot N" and waits 3 s, for a screenshot from
 * outside). x, y are points of the 3D view. The log gives
 * the labels, the selection, the card, and the history after each
 * step. */

typedef struct {
    ZgLabelTool *t;
    char **steps;
    guint i;
} TestRun;

/* The first widget under w with the data `key`, or NULL. */
static GtkWidget *find_with_data(GtkWidget *w, const char *key) {
    if (g_object_get_data(G_OBJECT(w), key) && gtk_widget_get_visible(w)) return w;
    for (GtkWidget *c = gtk_widget_get_first_child(w); c; c = gtk_widget_get_next_sibling(c)) {
        GtkWidget *found = find_with_data(c, key);
        if (found) return found;
    }
    return NULL;
}

static void test_log(ZgLabelTool *t, const char *step) {
    GString *s = g_string_new(NULL);
    g_string_append_printf(s, "label test: %s: part %" G_GINT64_FORMAT ", %u labels", step, t->index, t->labels->len);
    for (guint i = 0; i < t->labels->len; i++) {
        ZgLabel *l = g_ptr_array_index(t->labels, i);
        char *title = zg_label_title(l);
        double c[2] = {0, 0};
        gboolean on_screen = l->id == (guint32)t->sel && screen_center(t, c);
        g_string_append_printf(s, " [%u %s, %u items, filament %d, at %.2f %.2f %.2f, normal %.2f %.2f %.2f, turn %.1f%s", l->id, title,
                               zg_label_item_count(l), l->filament, l->origin[0], l->origin[1], l->origin[2], l->normal[0], l->normal[1],
                               l->normal[2], zg_label_angle(l), l->id == (guint32)t->sel ? ", selected" : "");
        if (on_screen) g_string_append_printf(s, ", center %.0f,%.0f", c[0], c[1]);
        JsonObject *it = zg_label_item(l, 0);
        if (it) g_string_append_printf(s, ", size %.2f", zg_label_item_size(it));
        g_string_append(s, "]");
        g_free(title);
    }
    if (t->info) {
        g_string_append_printf(s, ", info: %s changes %.0f (estimate %.0f), %.0f min, %.1f g, thinnest %.2f",
                               json_object_get_boolean_member_with_default(t->info, "sliced", FALSE) ? "sliced" : "not sliced",
                               json_object_get_double_member_with_default(t->info, "changes", -1),
                               json_object_get_double_member_with_default(t->info, "estimate_changes", -1),
                               json_object_get_double_member_with_default(t->info, "minutes", -1),
                               json_object_get_double_member_with_default(t->info, "grams", -1),
                               json_object_get_double_member_with_default(t->info, "thinnest", -1));
    }
    zs_stats st = {0};
    zs_app *core = zg_model_core(t->model);
    gboolean done = zs_app_state(core) == ZS_STATE_DONE && zs_app_stats(core, &st) == ZS_OK;
    g_string_append_printf(s, ", curve %.0f°, drawing %d, card %s, pending %" G_GINT64_FORMAT ", history %u of %u, %s", t->curve, t->drawing, gtk_widget_get_visible(t->card) ? "shown" : "hidden", t->pending, zg_model_history_current(t->model) + 1, zg_model_history_count(t->model), done ? "sliced" : "slicing");
    if (done) g_string_append_printf(s, " %.2f g", st.filament_g);
    g_message("%s", s->str);
    g_string_free(s, TRUE);
}

static gboolean test_step(gpointer data) {
    TestRun *r = data;
    ZgLabelTool *t = r->t;
    if (!r->steps[r->i]) {
        test_log(t, "end");
        g_strfreev(r->steps);
        g_free(r);
        return G_SOURCE_REMOVE;
    }
    char *step = g_strstrip(g_strdup(r->steps[r->i++]));
    char **f = g_strsplit(step, " ", 5);
    guint n = g_strv_length(f);
    double a = n > 1 ? g_ascii_strtod(f[1], NULL) : 0, b = n > 2 ? g_ascii_strtod(f[2], NULL) : 0;
    double c[2];
    if (n == 3 && strcmp(f[0], "orbit") == 0 && t->view) {
        zs_view_orbit(t->view, (float)a, (float)b);
        t->host.frame(t->host.data);
    } else if (n == 2 && strcmp(f[0], "zoom") == 0 && t->view) {
        zs_view_zoom(t->view, (float)a);
        t->host.frame(t->host.data);
    } else if (n == 5 && strcmp(f[0], "look") == 0 && t->view) {
        zs_part part;
        if (zs_app_part_get(zg_model_core(t->model), 0, &part) == ZS_OK) {
            zs_view_look_at(t->view, (float)part.x, (float)(part.y - part.size_y / 2), (float)(part.size_z / 2), (float)a, (float)b,
                            (float)g_ascii_strtod(f[3], NULL), (float)g_ascii_strtod(f[4], NULL));
            for (int k = 0; k < 200 && zs_view_animate(t->view, 0.05); k++) {}
            t->host.frame(t->host.data);
        }
    } else if (n == 3 && strcmp(f[0], "click") == 0) {
        zg_label_click(t, a, b);
    } else if (n == 4 && strcmp(f[0], "clickw") == 0 && t->view) {
        float qx, qy;
        int s = scale_of(t);
        if (zs_view_pixel_of(t->view, a, b, g_ascii_strtod(f[3], NULL), &qx, &qy)) zg_label_click(t, qx / s, qy / s);
        else g_message("label test: the point is not in the view");
    } else if (n == 3 && (strcmp(f[0], "drag") == 0 || strcmp(f[0], "sdrag") == 0)) {
        if (screen_center(t, c) && zg_label_press(t, c[0], c[1])) {
            /* The time of a move: the pick, the label, and the decal. */
            gint64 t0 = g_get_monotonic_time();
            for (int k = 1; k <= 10; k++) {
                zg_label_drag(t, c[0] + a * k / 10, c[1] + b * k / 10, f[0][0] == 's');
                if (t->view) zs_view_draw(t->view);
            }
            g_message("label test: a move and its frame, %.2f ms", (g_get_monotonic_time() - t0) / 10000.0);
            zg_label_release(t);
        } else {
            g_message("label test: no label to drag");
        }
    } else if (n == 2 && (strcmp(f[0], "wheel") == 0 || strcmp(f[0], "swheel") == 0)) {
        if (!screen_center(t, c)) g_message("label test: no label for the wheel");
        for (int k = 0; k < (int)fabs(a); k++) zg_label_wheel(t, c[0], c[1], a > 0 ? -1 : 1, f[0][0] == 's');
    } else if (n == 2 && strcmp(f[0], "scale") == 0) {
        const ZgLabel *l = zg_label_tool_label(t);
        Outline *o = l ? outline(t, l) : NULL;
        double q[2];
        if (o && screen_center(t, c) && screen_of(t, l, o->box[2] + 0.5, o->box[3] + 0.5, q)) {
            flush(t);
            t->scaling = TRUE;
            t->scale_start = zg_label_copy(l);
            t->scale_c[0] = c[0];
            t->scale_c[1] = c[1];
            t->scale_d0 = MAX(4, hypot(q[0] - c[0], q[1] - c[1]));
            for (int k = 1; k <= 10; k++) {
                double kk = 1 + (a - 1) * k / 10;
                scale_to(t, c[0] + (q[0] - c[0]) * kk, c[1] + (q[1] - c[1]) * kk);
            }
            scale_end(t);
        } else {
            g_message("label test: no handle");
        }
    } else if (n >= 2 && strcmp(f[0], "text") == 0) {
        char *text = g_strjoinv(" ", f + 1);
        g_strdelimit(text, "_", ' ');
        /* As after a click on the view: the text field shows the text. */
        t->host.focus(t->host.data);
        zg_label_tool_edit_text(t, 0, text);
        card_show(t, zg_label_tool_label(t));
        g_free(text);
    } else if (n == 4 && strcmp(f[0], "set") == 0) {
        if (!zg_label_tool_edit_number(t, (guint)a, f[2], g_ascii_strtod(f[3], NULL))) g_message("label test: a bad value");
    } else if (n == 3 && strcmp(f[0], "shape") == 0) {
        zg_label_tool_set_shape(t, (guint)a, f[2]);
    } else if (n == 2 && strcmp(f[0], "add") == 0) {
        zg_label_tool_add_item(t, f[1]);
    } else if (n == 2 && strcmp(f[0], "filament") == 0) {
        zg_label_tool_set_filament(t, (int)a);
    } else if (n == 2 && strcmp(f[0], "depth") == 0) {
        zg_label_tool_set_depth(t, a);
    } else if (n == 2 && strcmp(f[0], "turn") == 0) {
        zg_label_tool_set_angle(t, a);
    } else if (n == 2 && strcmp(f[0], "key") == 0) {
        if (!zg_label_key(t, gdk_keyval_from_name(f[1]))) g_message("label test: the tool did not use the key %s", f[1]);
    } else if (n == 1 && strcmp(f[0], "undo") == 0) {
        zg_model_undo(t->model);
    } else if (n == 1 && strcmp(f[0], "redo") == 0) {
        zg_model_redo(t->model);
    } else if (n == 1 && strcmp(f[0], "wait") == 0) {
    } else if (n == 3 && strcmp(f[0], "face") == 0 && t->view) {
        zs_part part;
        float qx, qy;
        int s = scale_of(t);
        if (zs_app_part_get(zg_model_core(t->model), 0, &part) == ZS_OK &&
            zs_view_pixel_of(t->view, part.x + a, part.y - part.size_y / 2, part.size_z / 2 + b, &qx, &qy))
            zg_label_click(t, qx / s, qy / s);
        else
            g_message("label test: no front face");
    } else if (n == 1 && strcmp(f[0], "addfilament") == 0) {
        zg_label_tool_add_filament(t);
    } else if (n == 1 && strcmp(f[0], "info") == 0) {
        load_info(t);
    } else if (n == 1 && strcmp(f[0], "check") == 0) {
        const zs_issue *issues = NULL;
        size_t count = 0;
        const char *text = NULL;
        int rc = zs_app_checks(zg_model_core(t->model), &issues, &count, &text);
        for (size_t k = 0; rc == ZS_OK && k < count; k++)
            if (issues[k].kind == ZS_ISSUE_LABEL)
                g_message("label test: a label issue at layer %u: %.*s", (unsigned)issues[k].layer, (int)issues[k].text_len, text + issues[k].text_start);
        gtk_widget_activate_action(t->area, "preview.check", NULL);
    } else if (n == 1 && strcmp(f[0], "reload") == 0) {
        reload(t);
    } else if (n == 2 && strcmp(f[0], "draw") == 0) {
        zg_label_tool_draw_points(t, (int)a);
    } else if (n == 1 && strcmp(f[0], "partcard") == 0) {
        zg_model_set_tool(t->model, ZG_TOOL_MOVE);
        zg_model_select_part(t->model, 0);
    } else if (n == 1 && strcmp(f[0], "partlabel") == 0) {
        GtkWidget *root = GTK_WIDGET(gtk_widget_get_root(t->area));
        GtkWidget *b = root ? find_with_data(root, "zg-label") : NULL;
        if (b) g_signal_emit_by_name(b, "clicked");
        else g_message("label test: no label on the part card");
    } else if (n == 1 && strcmp(f[0], "esc") == 0) {
        zg_label_key(t, GDK_KEY_Escape);
    } else if (n == 2 && strcmp(f[0], "shot") == 0) {
        test_log(t, step);
        g_message("label test: shot %s", f[1]);
        g_strfreev(f);
        g_free(step);
        g_timeout_add(3000, test_step, r);
        return G_SOURCE_REMOVE;
    } else {
        g_message("label test: a bad step: %s", step);
    }
    test_log(t, step);
    g_strfreev(f);
    g_free(step);
    g_timeout_add(700, test_step, r);
    return G_SOURCE_REMOVE;
}

static void test_start(ZgLabelTool *t) {
    const char *steps = g_getenv("ZSLICE_LABEL_DO");
    if (!steps || t->test_started || !t->view) return;
    t->test_started = TRUE;
    zg_model_set_tool(t->model, ZG_TOOL_LABEL);
    TestRun *r = g_new0(TestRun, 1);
    r->t = t;
    r->steps = g_strsplit(steps, ";", -1);
    g_timeout_add(1000, test_step, r);
}
