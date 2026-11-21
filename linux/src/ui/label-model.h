/* label-model.h: the model of a label of the Label tool (as the top of
 * web/app/label.js): its JSON, its frame, and its shapes. It needs no
 * core and no widget, so linux/tests/label-model-test.c tests it alone.
 *
 * A label is a 2D shape on the surface of a part (include/zslice-app.h,
 * "the labels of a part"). Its frame is an origin, a normal (out of the
 * part), and a right (the +x axis of the shape); up = normal x right is
 * its +y axis. Its items are the shapes, as JSON objects with a "kind"
 * (text, line, bar, ring, ticks, polyline) and the fields of that kind.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <json-glib/json-glib.h>

/* The face curves more than this (degrees) under a label: the label
 * stretches, and the card says so. */
#define ZG_LABEL_CURVE_LIMIT 60.0
#define ZG_LABEL_CURVE_TEXT "The face curves too much here; the label stretches."

typedef struct {
    guint32 id;
    char *name;
    double origin[3], normal[3], right[3];
    int filament; /* from 1 */
    double depth; /* mm; 0: one line width */
    gboolean has_stretch;
    double stretch[2];
    JsonArray *items; /* the shapes (a reference) */
} ZgLabel;

/* The kinds of the shapes, in the order of the chips of the card, and
 * their names there. */
#define ZG_LABEL_KINDS 6
extern const char *const zg_label_kinds[ZG_LABEL_KINDS];
extern const char *const zg_label_kind_names[ZG_LABEL_KINDS];

/* The number fields of each kind: the field, its name on the card, its
 * unit, its range and step, and a tip. */
typedef struct {
    const char *field, *name, *unit;
    double min, max, step;
    const char *tip;
} ZgLabelField;
/* The fields of `kind`; n gets their count. */
const ZgLabelField *zg_label_fields(const char *kind, size_t *n);

ZgLabel *zg_label_new(void);
ZgLabel *zg_label_copy(const ZgLabel *l);
void zg_label_free(ZgLabel *l);

/* The labels of a JSON array (zs_app_part_labels_get), or of one label
 * (an object). NULL for bad JSON. A label with a bad frame is left out. */
GPtrArray *zg_labels_parse(const char *json, gssize len);
/* The JSON of a label: the whole label (for zs_app_label_add and
 * zs_app_label_update), or with `shapes_only` its items and its stretch
 * only (for zs_label_outline, and as the key of an outline). */
char *zg_label_json(const ZgLabel *l, gboolean shapes_only);

/* Item i, or NULL. */
JsonObject *zg_label_item(const ZgLabel *l, guint i);
guint zg_label_item_count(const ZgLabel *l);
const char *zg_label_item_kind(JsonObject *it);
double zg_label_item_number(JsonObject *it, const char *field, double fallback);
/* A new item of a kind; size is the size of the label (the cap height of
 * its text), mm. */
JsonObject *zg_label_new_item(const char *kind, double size);
/* An item of another kind at the same place, with about the same size. */
JsonObject *zg_label_change_shape(JsonObject *it, const char *kind);
/* The size of an item for the card (mm): the cap height of a text, the
 * length of a line, the width of a bar, the diameter of a ring, the
 * outer diameter of the ticks, the width of a free line. */
double zg_label_item_size(JsonObject *it);
/* Replaces the items with copies (the label owns its own items after
 * this; an edit of a copy leaves the original alone). */
void zg_label_own_items(ZgLabel *l);
/* Scales all items of the label by k: their lengths, places, points. */
void zg_label_scale(ZgLabel *l, double k);

/* The words of a label for a list: its name, its text in quotes, or the
 * names of its shapes ("Line and Ticks"). Free with g_free. */
char *zg_label_title(const ZgLabel *l);

/* up = normal x right. */
void zg_label_up(const ZgLabel *l, double up[3]);
/* The right of a label with a turn of 0 at the normal n: level on a side
 * face (|n.z| <= 0.7), else the X axis of the bed in the plane. */
void zg_label_level_right(const double n[3], double out[3]);
/* The turn of the label in its plane from its level right, degrees. */
double zg_label_angle(const ZgLabel *l);
void zg_label_set_angle(ZgLabel *l, double deg);
/* Turns the label by deg about its normal (counterclockwise from the
 * front). */
void zg_label_turn(ZgLabel *l, double deg);
/* Puts the label at a new point and normal of the surface; its right
 * keeps its direction, put into the new plane. */
void zg_label_move(ZgLabel *l, const double origin[3], const double normal[3]);
/* The point of the plane of the label on a ray (o, d): p in the frame of
 * the bed, and x, y along right and up. FALSE if the ray misses it. */
gboolean zg_label_plane_hit(const ZgLabel *l, const double o[3], const double d[3], double p[3], double *x, double *y);
/* A point (x, y) of the plane in the frame of the bed, lift mm out of the
 * surface. */
void zg_label_to_bed(const ZgLabel *l, double x, double y, double lift, double out[3]);

/* The filament of a new label on a part in filament base (from 1), with
 * count filaments on the plate: the filament after it, else the first
 * other one; 1 with one filament. */
int zg_label_next_filament(int base, int count);
