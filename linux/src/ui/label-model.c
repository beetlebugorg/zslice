/* label-model.c: see label-model.h.
 *
 * The items stay JSON objects, so a field that the card does not show
 * (the alignment, the spacing, a round end) goes back to the core as it
 * came. The ids, the filament, and the count of ticks are integers in the
 * JSON of the core, so they go out as integers.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "label-model.h"

#include <math.h>
#include <string.h>

const char *const zg_label_kinds[ZG_LABEL_KINDS] = {"text", "line", "bar", "ring", "ticks", "polyline"};
const char *const zg_label_kind_names[ZG_LABEL_KINDS] = {"Text", "Line", "Bar", "Ring", "Ticks", "Free"};

static const ZgLabelField TEXT_FIELDS[] = {
    {"size", "Size", "mm", 0.5, 200, 0.1, "The height of the capitals"},
    {"weight", "Weight", "mm", 0, 0.3, 0.01, "Makes each stroke wider: small text prints better, small holes close"},
};
static const ZgLabelField LINE_FIELDS[] = {
    {"length", "Length", "mm", 0.1, 500, 0.1, NULL},
    {"width", "Width", "mm", 0.1, 100, 0.1, NULL},
};
static const ZgLabelField BAR_FIELDS[] = {
    {"width", "Width", "mm", 0.1, 500, 0.1, NULL},
    {"height", "Height", "mm", 0.1, 500, 0.1, NULL},
    {"radius", "Corners", "mm", 0, 100, 0.1, "The radius of the corners"},
};
static const ZgLabelField RING_FIELDS[] = {
    {"outer", "Outer radius", "mm", 0.1, 250, 0.1, NULL},
    {"inner", "Inner radius", "mm", 0, 250, 0.1, "0 makes a disk"},
};
static const ZgLabelField TICKS_FIELDS[] = {
    {"count", "Count", "", 1, 360, 1, "The number of ticks"},
    {"radius", "Radius", "mm", 0, 250, 0.1, "The distance from the center to the inner end of each tick"},
    {"length", "First length", "mm", 0.1, 100, 0.1, "The length of the first tick"},
    {"length_end", "Last length", "mm", 0, 100, 0.1, "The length of the last tick (0: the same as the first). The ticks between grow evenly."},
    {"width", "Width", "mm", 0.1, 20, 0.05, "The width of each tick"},
    {"start", "Start", "°", -360, 360, 1, "The angle of the first tick (0: to the right, 90: up)"},
    {"sweep", "Sweep", "°", -360, 360, 1, "The angle from the first tick to the last (negative: clockwise)"},
};
static const ZgLabelField POLY_FIELDS[] = {
    {"width", "Width", "mm", 0, 100, 0.1, "The width of the line (0 with Filled)"},
};

const ZgLabelField *zg_label_fields(const char *kind, size_t *n) {
    static const struct {
        const char *kind;
        const ZgLabelField *f;
        size_t n;
    } all[] = {
        {"text", TEXT_FIELDS, G_N_ELEMENTS(TEXT_FIELDS)},   {"line", LINE_FIELDS, G_N_ELEMENTS(LINE_FIELDS)},
        {"bar", BAR_FIELDS, G_N_ELEMENTS(BAR_FIELDS)},      {"ring", RING_FIELDS, G_N_ELEMENTS(RING_FIELDS)},
        {"ticks", TICKS_FIELDS, G_N_ELEMENTS(TICKS_FIELDS)}, {"polyline", POLY_FIELDS, G_N_ELEMENTS(POLY_FIELDS)},
    };
    for (size_t i = 0; i < G_N_ELEMENTS(all); i++)
        if (g_strcmp0(kind, all[i].kind) == 0) {
            *n = all[i].n;
            return all[i].f;
        }
    *n = 0;
    return NULL;
}

/* The fields of each kind that are lengths: a scale changes them. */
static const char *const *length_fields(const char *kind) {
    static const char *const text[] = {"size", "spacing", NULL};
    static const char *const line[] = {"length", "width", NULL};
    static const char *const bar[] = {"width", "height", "radius", NULL};
    static const char *const ring[] = {"outer", "inner", NULL};
    static const char *const ticks[] = {"radius", "length", "length_end", "width", NULL};
    static const char *const poly[] = {"width", NULL};
    static const char *const none[] = {NULL};
    if (g_strcmp0(kind, "text") == 0) return text;
    if (g_strcmp0(kind, "line") == 0) return line;
    if (g_strcmp0(kind, "bar") == 0) return bar;
    if (g_strcmp0(kind, "ring") == 0) return ring;
    if (g_strcmp0(kind, "ticks") == 0) return ticks;
    if (g_strcmp0(kind, "polyline") == 0) return poly;
    return none;
}

/* ---- vectors ---- */

static double dot3(const double *a, const double *b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

static void cross3(const double *a, const double *b, double *out) {
    double c[3] = {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
    memcpy(out, c, sizeof c);
}

static gboolean unit3(double *a) {
    double l = sqrt(dot3(a, a));
    if (!(l > 1e-9)) return FALSE;
    for (int k = 0; k < 3; k++) a[k] /= l;
    return TRUE;
}

/* ---- the label ---- */

ZgLabel *zg_label_new(void) {
    ZgLabel *l = g_new0(ZgLabel, 1);
    l->name = g_strdup("");
    l->normal[2] = 1;
    l->right[0] = 1;
    l->filament = 1;
    l->items = json_array_new();
    return l;
}

ZgLabel *zg_label_copy(const ZgLabel *l) {
    ZgLabel *c = g_memdup2(l, sizeof *l);
    c->name = g_strdup(l->name);
    c->items = json_array_ref(l->items);
    return c;
}

void zg_label_free(ZgLabel *l) {
    if (!l) return;
    g_free(l->name);
    if (l->items) json_array_unref(l->items);
    g_free(l);
}

static gboolean vec_of(JsonObject *o, const char *name, double *out, guint n) {
    if (!json_object_has_member(o, name)) return FALSE;
    JsonNode *node = json_object_get_member(o, name);
    if (!JSON_NODE_HOLDS_ARRAY(node)) return FALSE;
    JsonArray *a = json_node_get_array(node);
    if (json_array_get_length(a) != n) return FALSE;
    for (guint k = 0; k < n; k++) {
        JsonNode *e = json_array_get_element(a, k);
        if (json_node_get_value_type(e) != G_TYPE_DOUBLE && json_node_get_value_type(e) != G_TYPE_INT64) return FALSE;
        out[k] = json_node_get_double(e);
        if (!isfinite(out[k])) return FALSE;
    }
    return TRUE;
}

static double num_of(JsonObject *o, const char *name, double fallback) {
    if (!o || !json_object_has_member(o, name)) return fallback;
    JsonNode *n = json_object_get_member(o, name);
    GType t = JSON_NODE_HOLDS_VALUE(n) ? json_node_get_value_type(n) : G_TYPE_INVALID;
    if (t != G_TYPE_DOUBLE && t != G_TYPE_INT64) return fallback;
    double v = json_node_get_double(n);
    return isfinite(v) ? v : fallback;
}

static ZgLabel *label_of(JsonObject *o) {
    ZgLabel *l = zg_label_new();
    l->id = (guint32)num_of(o, "id", 0);
    l->filament = (int)num_of(o, "filament", 1);
    l->depth = num_of(o, "depth", 0);
    if (json_object_has_member(o, "name") && JSON_NODE_HOLDS_VALUE(json_object_get_member(o, "name"))) {
        g_free(l->name);
        l->name = g_strdup(json_object_get_string_member(o, "name"));
        if (!l->name) l->name = g_strdup("");
    }
    l->has_stretch = vec_of(o, "stretch", l->stretch, 2);
    if (!vec_of(o, "origin", l->origin, 3) || !vec_of(o, "normal", l->normal, 3) || !vec_of(o, "right", l->right, 3) || !unit3(l->normal) ||
        !unit3(l->right)) {
        zg_label_free(l);
        return NULL;
    }
    if (json_object_has_member(o, "items") && JSON_NODE_HOLDS_ARRAY(json_object_get_member(o, "items"))) {
        json_array_unref(l->items);
        l->items = json_array_ref(json_object_get_array_member(o, "items"));
    }
    return l;
}

GPtrArray *zg_labels_parse(const char *json, gssize len) {
    JsonParser *p = json_parser_new();
    if (!json_parser_load_from_data(p, json, len, NULL)) {
        g_object_unref(p);
        return NULL;
    }
    GPtrArray *out = g_ptr_array_new_with_free_func((GDestroyNotify)zg_label_free);
    JsonNode *root = json_parser_get_root(p);
    if (root && JSON_NODE_HOLDS_ARRAY(root)) {
        JsonArray *a = json_node_get_array(root);
        for (guint i = 0; i < json_array_get_length(a); i++) {
            JsonNode *e = json_array_get_element(a, i);
            ZgLabel *l = JSON_NODE_HOLDS_OBJECT(e) ? label_of(json_node_get_object(e)) : NULL;
            if (l) g_ptr_array_add(out, l);
        }
    } else if (root && JSON_NODE_HOLDS_OBJECT(root)) {
        ZgLabel *l = label_of(json_node_get_object(root));
        if (l) g_ptr_array_add(out, l);
    } else {
        g_ptr_array_unref(out);
        out = NULL;
    }
    g_object_unref(p);
    return out;
}

static JsonArray *vec_array(const double *v, guint n) {
    JsonArray *a = json_array_sized_new(n);
    for (guint k = 0; k < n; k++) json_array_add_double_element(a, v[k]);
    return a;
}

char *zg_label_json(const ZgLabel *l, gboolean shapes_only) {
    JsonObject *o = json_object_new();
    if (!shapes_only) {
        json_object_set_int_member(o, "id", l->id);
        if (l->name && l->name[0]) json_object_set_string_member(o, "name", l->name);
        json_object_set_array_member(o, "origin", vec_array(l->origin, 3));
        json_object_set_array_member(o, "normal", vec_array(l->normal, 3));
        json_object_set_array_member(o, "right", vec_array(l->right, 3));
        json_object_set_int_member(o, "filament", l->filament);
        json_object_set_double_member(o, "depth", l->depth);
    }
    if (l->has_stretch) json_object_set_array_member(o, "stretch", vec_array(l->stretch, 2));
    json_object_set_array_member(o, "items", json_array_ref(l->items));
    JsonNode *root = json_node_new(JSON_NODE_OBJECT);
    json_node_take_object(root, o);
    char *text = json_to_string(root, FALSE);
    json_node_unref(root);
    return text;
}

/* ---- the items ---- */

guint zg_label_item_count(const ZgLabel *l) {
    return l && l->items ? json_array_get_length(l->items) : 0;
}

JsonObject *zg_label_item(const ZgLabel *l, guint i) {
    if (i >= zg_label_item_count(l)) return NULL;
    JsonNode *n = json_array_get_element(l->items, i);
    return JSON_NODE_HOLDS_OBJECT(n) ? json_node_get_object(n) : NULL;
}

const char *zg_label_item_kind(JsonObject *it) {
    if (!it || !json_object_has_member(it, "kind")) return "";
    const char *k = json_object_get_string_member(it, "kind");
    return k ? k : "";
}

double zg_label_item_number(JsonObject *it, const char *field, double fallback) {
    return num_of(it, field, fallback);
}

static void set_point(JsonObject *o, const char *name, double x, double y) {
    JsonArray *a = json_array_sized_new(2);
    json_array_add_double_element(a, x);
    json_array_add_double_element(a, y);
    json_object_set_array_member(o, name, a);
}

JsonObject *zg_label_new_item(const char *kind, double size) {
    JsonObject *o = json_object_new();
    json_object_set_string_member(o, "kind", kind);
    if (strcmp(kind, "text") == 0) {
        json_object_set_string_member(o, "text", "LABEL");
        json_object_set_double_member(o, "size", size);
    } else if (strcmp(kind, "line") == 0) {
        json_object_set_double_member(o, "length", 4 * size);
        json_object_set_double_member(o, "width", 1);
    } else if (strcmp(kind, "bar") == 0) {
        json_object_set_double_member(o, "width", 4 * size);
        json_object_set_double_member(o, "height", MAX(1, 0.4 * size));
        json_object_set_double_member(o, "radius", 0);
    } else if (strcmp(kind, "ring") == 0) {
        json_object_set_double_member(o, "outer", size);
        json_object_set_double_member(o, "inner", MAX(0, size - 1));
    } else if (strcmp(kind, "ticks") == 0) {
        json_object_set_int_member(o, "count", 11);
        json_object_set_double_member(o, "radius", 1.6 * size);
        json_object_set_double_member(o, "length", 0.3 * size);
        json_object_set_double_member(o, "length_end", 0.6 * size);
        json_object_set_double_member(o, "width", 0.8);
        json_object_set_double_member(o, "start", 225);
        json_object_set_double_member(o, "sweep", -270);
    } else {
        json_object_set_string_member(o, "kind", "polyline");
        JsonArray *pts = json_array_new();
        const double p[3][2] = {{-2 * size, -size / 2}, {0, size / 2}, {2 * size, -size / 2}};
        for (int k = 0; k < 3; k++) {
            JsonArray *q = json_array_sized_new(2);
            json_array_add_double_element(q, p[k][0]);
            json_array_add_double_element(q, p[k][1]);
            json_array_add_array_element(pts, q);
        }
        json_object_set_array_member(o, "points", pts);
        json_object_set_double_member(o, "width", 1);
        json_object_set_boolean_member(o, "closed", FALSE);
        json_object_set_boolean_member(o, "filled", FALSE);
    }
    return o;
}

double zg_label_item_size(JsonObject *it) {
    const char *k = zg_label_item_kind(it);
    if (strcmp(k, "text") == 0) return num_of(it, "size", 0);
    if (strcmp(k, "line") == 0) return num_of(it, "length", 0);
    if (strcmp(k, "bar") == 0) return num_of(it, "width", 0);
    if (strcmp(k, "ring") == 0) return 2 * num_of(it, "outer", 0);
    if (strcmp(k, "ticks") == 0) return 2 * (num_of(it, "radius", 0) + MAX(num_of(it, "length", 0), num_of(it, "length_end", 0)));
    if (strcmp(k, "polyline") == 0 && json_object_has_member(it, "points")) {
        JsonArray *a = json_object_get_array_member(it, "points");
        double lo = INFINITY, hi = -INFINITY;
        for (guint i = 0; a && i < json_array_get_length(a); i++) {
            JsonArray *q = json_array_get_array_element(a, i);
            if (!q || json_array_get_length(q) < 2) continue;
            double x = json_array_get_double_element(q, 0);
            lo = MIN(lo, x);
            hi = MAX(hi, x);
        }
        return hi >= lo ? hi - lo : 0;
    }
    return 0;
}

/* A deep copy (json_node_copy shares the members of an object). */
static JsonObject *copy_object(JsonObject *o) {
    JsonNode *n = json_node_new(JSON_NODE_OBJECT);
    json_node_set_object(n, o);
    char *text = json_to_string(n, FALSE);
    json_node_unref(n);
    JsonNode *c = json_from_string(text, NULL);
    g_free(text);
    JsonObject *out = c && JSON_NODE_HOLDS_OBJECT(c) ? json_object_ref(json_node_get_object(c)) : json_object_new();
    if (c) json_node_unref(c);
    return out;
}

JsonObject *zg_label_change_shape(JsonObject *it, const char *kind) {
    const char *now = zg_label_item_kind(it);
    if (strcmp(now, kind) == 0) return copy_object(it);
    double div = strcmp(now, "text") == 0 ? 1 : strcmp(now, "ring") == 0 ? 2 : 4;
    JsonObject *out = zg_label_new_item(kind, MAX(0.5, zg_label_item_size(it) / div));
    double at[2];
    if (vec_of(it, "at", at, 2)) set_point(out, "at", at[0], at[1]);
    double angle = num_of(it, "angle", 0);
    if (angle != 0) json_object_set_double_member(out, "angle", angle);
    return out;
}

void zg_label_own_items(ZgLabel *l) {
    JsonArray *a = json_array_new();
    for (guint i = 0; i < zg_label_item_count(l); i++) {
        JsonObject *it = zg_label_item(l, i);
        if (it) json_array_add_object_element(a, copy_object(it));
    }
    json_array_unref(l->items);
    l->items = a;
}

void zg_label_scale(ZgLabel *l, double k) {
    zg_label_own_items(l);
    for (guint i = 0; i < zg_label_item_count(l); i++) {
        JsonObject *it = zg_label_item(l, i);
        for (const char *const *f = length_fields(zg_label_item_kind(it)); *f; f++)
            if (json_object_has_member(it, *f)) json_object_set_double_member(it, *f, num_of(it, *f, 0) * k);
        double at[2];
        if (vec_of(it, "at", at, 2)) set_point(it, "at", at[0] * k, at[1] * k);
        if (json_object_has_member(it, "points") && JSON_NODE_HOLDS_ARRAY(json_object_get_member(it, "points"))) {
            JsonArray *a = json_object_get_array_member(it, "points");
            JsonArray *b = json_array_new();
            for (guint j = 0; j < json_array_get_length(a); j++) {
                JsonArray *q = json_array_get_array_element(a, j);
                JsonArray *r = json_array_sized_new(2);
                json_array_add_double_element(r, json_array_get_double_element(q, 0) * k);
                json_array_add_double_element(r, json_array_get_double_element(q, 1) * k);
                json_array_add_array_element(b, r);
            }
            json_object_set_array_member(it, "points", b);
        }
    }
}

char *zg_label_title(const ZgLabel *l) {
    if (l->name && l->name[0]) return g_strdup(l->name);
    for (guint i = 0; i < zg_label_item_count(l); i++) {
        JsonObject *it = zg_label_item(l, i);
        if (strcmp(zg_label_item_kind(it), "text") != 0) continue;
        const char *t = json_object_has_member(it, "text") ? json_object_get_string_member(it, "text") : NULL;
        char *s = g_strstrip(g_strdup(t ? t : ""));
        if (s[0]) {
            char *out = g_strdup_printf("“%s”", s);
            g_free(s);
            return out;
        }
        g_free(s);
    }
    GString *out = g_string_new(NULL);
    gboolean seen[ZG_LABEL_KINDS] = {FALSE};
    for (guint i = 0; i < zg_label_item_count(l); i++) {
        const char *k = zg_label_item_kind(zg_label_item(l, i));
        for (int j = 0; j < ZG_LABEL_KINDS; j++) {
            if (strcmp(k, zg_label_kinds[j]) != 0 || seen[j]) continue;
            seen[j] = TRUE;
            if (out->len) g_string_append(out, " and ");
            g_string_append(out, zg_label_kind_names[j]);
        }
    }
    if (!out->len) g_string_append(out, "Empty label");
    return g_string_free(out, FALSE);
}

/* ---- the frame ---- */

void zg_label_up(const ZgLabel *l, double up[3]) {
    cross3(l->normal, l->right, up);
}

void zg_label_level_right(const double n[3], double out[3]) {
    if (fabs(n[2]) <= 0.7) {
        double r[3] = {-n[1], n[0], 0};
        if (unit3(r)) {
            memcpy(out, r, sizeof r);
            return;
        }
        out[0] = 1;
        out[1] = out[2] = 0;
        return;
    }
    double r[3] = {1 - n[0] * n[0], -n[0] * n[1], -n[0] * n[2]};
    if (unit3(r)) {
        memcpy(out, r, sizeof r);
        return;
    }
    double s[3] = {-n[1] * n[0], 1 - n[1] * n[1], -n[1] * n[2]};
    unit3(s);
    memcpy(out, s, sizeof s);
}

double zg_label_angle(const ZgLabel *l) {
    double ref[3], ref_up[3];
    zg_label_level_right(l->normal, ref);
    cross3(l->normal, ref, ref_up);
    return atan2(dot3(l->right, ref_up), dot3(l->right, ref)) * 180 / G_PI;
}

void zg_label_set_angle(ZgLabel *l, double deg) {
    double a = deg * G_PI / 180, ref[3], ref_up[3];
    zg_label_level_right(l->normal, ref);
    cross3(l->normal, ref, ref_up);
    double r[3];
    for (int k = 0; k < 3; k++) r[k] = ref[k] * cos(a) + ref_up[k] * sin(a);
    if (unit3(r)) memcpy(l->right, r, sizeof r);
}

void zg_label_turn(ZgLabel *l, double deg) {
    double a = deg * G_PI / 180, up[3], r[3];
    zg_label_up(l, up);
    for (int k = 0; k < 3; k++) r[k] = l->right[k] * cos(a) + up[k] * sin(a);
    if (unit3(r)) memcpy(l->right, r, sizeof r);
}

void zg_label_move(ZgLabel *l, const double origin[3], const double normal[3]) {
    double n[3] = {normal[0], normal[1], normal[2]};
    if (!unit3(n)) memcpy(n, l->normal, sizeof n);
    double d = dot3(l->right, n);
    double r[3] = {l->right[0] - d * n[0], l->right[1] - d * n[1], l->right[2] - d * n[2]};
    if (!unit3(r)) zg_label_level_right(n, r);
    memcpy(l->origin, origin, sizeof l->origin);
    memcpy(l->normal, n, sizeof n);
    memcpy(l->right, r, sizeof r);
}

gboolean zg_label_plane_hit(const ZgLabel *l, const double o[3], const double d[3], double p[3], double *x, double *y) {
    double den = dot3(d, l->normal);
    if (fabs(den) < 1e-9) return FALSE;
    double to[3] = {l->origin[0] - o[0], l->origin[1] - o[1], l->origin[2] - o[2]};
    double t = dot3(to, l->normal) / den;
    if (!(t > 0)) return FALSE;
    double up[3], v[3];
    zg_label_up(l, up);
    for (int k = 0; k < 3; k++) {
        p[k] = o[k] + d[k] * t;
        v[k] = p[k] - l->origin[k];
    }
    *x = dot3(v, l->right);
    *y = dot3(v, up);
    return TRUE;
}

void zg_label_to_bed(const ZgLabel *l, double x, double y, double lift, double out[3]) {
    double up[3];
    zg_label_up(l, up);
    for (int k = 0; k < 3; k++) out[k] = l->origin[k] + x * l->right[k] + y * up[k] + lift * l->normal[k];
}

int zg_label_next_filament(int base, int count) {
    if (count <= 1) return 1;
    if (base + 1 <= count) return base + 1;
    return base == 1 ? 2 : 1;
}
