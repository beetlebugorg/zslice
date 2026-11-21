/* label-model-test.c: the model of a label of the Label tool
 * (src/ui/label-model.c): its JSON, its frame, and its shapes, as
 * web/app/test-node.mjs tests the model of label.js.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "../src/ui/label-model.h"

#include <math.h>
#include <string.h>

#define NEAR(a, b) g_assert_cmpfloat_with_epsilon((a), (b), 1e-9)

static const char *volume =
    "[{\"id\":7,\"name\":\"\",\"origin\":[30,0,12],\"normal\":[0,-1,0],\"right\":[1,0,0],\"filament\":2,\"depth\":0,"
    "\"stretch\":[1,1],\"items\":[{\"kind\":\"text\",\"text\":\"VOLUME\",\"size\":5,\"at\":[0,9],\"alignment\":\"left\"},"
    "{\"kind\":\"ticks\",\"count\":11,\"radius\":7,\"length\":1.5,\"length_end\":3,\"width\":0.6}]},"
    "{\"id\":8,\"origin\":[1,2],\"normal\":[0,0,1],\"right\":[1,0,0],\"items\":[]}]";

static void test_parse_and_write(void) {
    GPtrArray *list = zg_labels_parse(volume, -1);
    g_assert_nonnull(list);
    /* The second label has a bad origin: it is left out. */
    g_assert_cmpuint(list->len, ==, 1);
    ZgLabel *l = g_ptr_array_index(list, 0);
    g_assert_cmpuint(l->id, ==, 7);
    g_assert_cmpint(l->filament, ==, 2);
    g_assert_true(l->has_stretch);
    g_assert_cmpuint(zg_label_item_count(l), ==, 2);
    g_assert_cmpstr(zg_label_item_kind(zg_label_item(l, 1)), ==, "ticks");
    char *title = zg_label_title(l);
    g_assert_cmpstr(title, ==, "“VOLUME”");
    g_free(title);
    /* A round trip keeps each value, and the fields that the card does
     * not show (the alignment). The id, the filament, and the count stay
     * integers. */
    char *json = zg_label_json(l, FALSE);
    g_assert_nonnull(strstr(json, "\"alignment\":\"left\""));
    g_assert_nonnull(strstr(json, "\"id\":7"));
    g_assert_nonnull(strstr(json, "\"filament\":2"));
    g_assert_nonnull(strstr(json, "\"count\":11"));
    GPtrArray *again = zg_labels_parse(json, -1);
    g_assert_cmpuint(again->len, ==, 1);
    ZgLabel *m = g_ptr_array_index(again, 0);
    NEAR(m->origin[0], 30);
    NEAR(m->normal[1], -1);
    char *json2 = zg_label_json(m, FALSE);
    g_assert_cmpstr(json, ==, json2);
    /* The shapes only: no frame. */
    char *shapes = zg_label_json(l, TRUE);
    g_assert_null(strstr(shapes, "origin"));
    g_assert_nonnull(strstr(shapes, "\"stretch\""));
    g_free(json);
    g_free(json2);
    g_free(shapes);
    g_ptr_array_unref(again);
    g_ptr_array_unref(list);
    g_assert_null(zg_labels_parse("{nope", -1));
}

static void test_items(void) {
    JsonObject *t = zg_label_new_item("text", 5);
    NEAR(zg_label_item_size(t), 5);
    JsonObject *ticks = zg_label_new_item("ticks", 5);
    g_assert_cmpint(json_object_get_int_member(ticks, "count"), ==, 11);
    /* Outer diameter: 2 (radius 8 + longest tick 3). */
    NEAR(zg_label_item_size(ticks), 22);
    /* Text 5 mm to a ring: a ring of about that size, at the same place. */
    json_object_set_array_member(t, "at", json_array_new());
    json_array_add_double_element(json_object_get_array_member(t, "at"), 2);
    json_array_add_double_element(json_object_get_array_member(t, "at"), -3);
    JsonObject *ring = zg_label_change_shape(t, "ring");
    g_assert_cmpstr(zg_label_item_kind(ring), ==, "ring");
    NEAR(zg_label_item_number(ring, "outer", 0), 5);
    NEAR(json_array_get_double_element(json_object_get_array_member(ring, "at"), 1), -3);
    JsonObject *free_line = zg_label_new_item("polyline", 2);
    NEAR(zg_label_item_size(free_line), 8);
    json_object_unref(t);
    json_object_unref(ticks);
    json_object_unref(ring);
    json_object_unref(free_line);
}

static void test_scale_copy(void) {
    GPtrArray *list = zg_labels_parse(volume, -1);
    ZgLabel *l = g_ptr_array_index(list, 0);
    ZgLabel *c = zg_label_copy(l);
    zg_label_scale(c, 2);
    /* The copy scales; the label it came from keeps its sizes. */
    NEAR(zg_label_item_number(zg_label_item(c, 0), "size", 0), 10);
    NEAR(zg_label_item_number(zg_label_item(l, 0), "size", 0), 5);
    NEAR(json_array_get_double_element(json_object_get_array_member(zg_label_item(c, 0), "at"), 1), 18);
    NEAR(zg_label_item_number(zg_label_item(c, 1), "length_end", 0), 6);
    g_assert_cmpint(json_object_get_int_member(zg_label_item(c, 1), "count"), ==, 11);
    zg_label_free(c);
    g_ptr_array_unref(list);
}

static void test_frame(void) {
    GPtrArray *list = zg_labels_parse(volume, -1);
    ZgLabel *l = g_ptr_array_index(list, 0);
    /* On the face -Y, level is +X: the turn is 0. */
    NEAR(zg_label_angle(l), 0);
    zg_label_turn(l, 30);
    g_assert_cmpfloat_with_epsilon(zg_label_angle(l), 30, 1e-6);
    zg_label_set_angle(l, -45);
    g_assert_cmpfloat_with_epsilon(zg_label_angle(l), -45, 1e-6);
    zg_label_set_angle(l, 0);
    double up[3];
    zg_label_up(l, up);
    g_assert_cmpfloat_with_epsilon(up[2], 1, 1e-9);
    /* A move to the face +X: the right goes into the new plane. */
    const double o[3] = {40, 5, 12}, n[3] = {1, 0, 0};
    zg_label_move(l, o, n);
    g_assert_cmpfloat_with_epsilon(fabs(l->right[0]), 0, 1e-9);
    NEAR(l->origin[1], 5);
    /* A ray from in front of the face hits its plane. */
    const double ro[3] = {100, 6, 13}, rd[3] = {-1, 0, 0};
    double p[3], x, y;
    g_assert_true(zg_label_plane_hit(l, ro, rd, p, &x, &y));
    NEAR(p[0], 40);
    double back[3];
    zg_label_to_bed(l, x, y, 0, back);
    g_assert_cmpfloat_with_epsilon(back[1], 6, 1e-9);
    g_assert_cmpfloat_with_epsilon(back[2], 13, 1e-9);
    /* A ray along the plane misses it. */
    const double along[3] = {0, 1, 0};
    g_assert_false(zg_label_plane_hit(l, ro, along, p, &x, &y));
    /* On a top face, the level right is +X. */
    const double top[3] = {0, 0, 1};
    double r[3];
    zg_label_level_right(top, r);
    NEAR(r[0], 1);
    g_ptr_array_unref(list);
}

static void test_filament(void) {
    g_assert_cmpint(zg_label_next_filament(1, 1), ==, 1);
    g_assert_cmpint(zg_label_next_filament(1, 3), ==, 2);
    g_assert_cmpint(zg_label_next_filament(3, 3), ==, 1);
    g_assert_cmpint(zg_label_next_filament(1, 2), ==, 2);
    g_assert_cmpint(zg_label_next_filament(2, 2), ==, 1);
}

static void test_fields(void) {
    size_t n = 0;
    const ZgLabelField *f = zg_label_fields("ticks", &n);
    g_assert_cmpuint(n, ==, 7);
    g_assert_cmpstr(f[0].field, ==, "count");
    g_assert_null(zg_label_fields("nope", &n));
    for (int k = 0; k < ZG_LABEL_KINDS; k++) {
        JsonObject *it = zg_label_new_item(zg_label_kinds[k], 5);
        g_assert_cmpstr(zg_label_item_kind(it), ==, zg_label_kinds[k]);
        g_assert_nonnull(zg_label_fields(zg_label_kinds[k], &n));
        json_object_unref(it);
    }
}

int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/label/parse-and-write", test_parse_and_write);
    g_test_add_func("/label/items", test_items);
    g_test_add_func("/label/scale-copy", test_scale_copy);
    g_test_add_func("/label/frame", test_frame);
    g_test_add_func("/label/filament", test_filament);
    g_test_add_func("/label/fields", test_fields);
    return g_test_run();
}
