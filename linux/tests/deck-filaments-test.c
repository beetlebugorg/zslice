/* deck-filaments-test.c: the nozzle codes and the loaded filaments of a
 * printdeck printer (src/net/deck-filaments.c).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "../src/net/deck-filaments.h"

#include <string.h>

static void check_code(const char *code, const char *type, const char *flow) {
    const char *t = NULL, *f = NULL;
    gboolean ok = zg_nozzle_of_code(code, &t, &f);
    if (!type) {
        if (ok) g_error("%s: a nozzle, expected none", code);
        return;
    }
    if (!ok || strcmp(t, type) != 0 || strcmp(f, flow) != 0)
        g_error("%s: %s %s, expected %s %s", code, ok ? t : "-", ok ? f : "-", type, flow);
}

static void test_codes(void) {
    check_code("HS01", "hardened_steel", "standard");
    check_code("HH01", "hardened_steel", "high_flow");
    check_code("SS", "stainless_steel", "standard");
    check_code("TH02", "tungsten_carbide", "high_flow");
    check_code(" hs01 ", "hardened_steel", "standard");
    check_code("XS01", NULL, NULL);
    check_code("HX01", NULL, NULL);
    check_code("HS0A", NULL, NULL);
    check_code("H", NULL, NULL);
    check_code("", NULL, NULL);
    check_code(NULL, NULL, NULL);
}

static const char *deck =
    "{\"filaments\": ["
    "{\"slot\": \"A1\", \"material\": \"pla\", \"color\": \"#FF0000\", \"nozzle\": \"main\"},"
    "{\"slot\": \"A2\", \"material\": \"PETG\", \"color\": \"red\", \"nozzle\": \"main\"},"
    "{\"slot\": \"Ext\", \"material\": \"TPU\", \"color\": \"#00ff00\", \"nozzle\": \"aux\"},"
    "{\"slot\": \"A3\", \"material\": \"\"}],"
    "\"nozzles\": [{\"type\": \"??\"}, {\"type\": \"HH01\"}]}";

static void test_one_nozzle(void) {
    char *error = NULL;
    ZgDeckFilaments *d = zg_deck_filaments_parse(deck, -1, FALSE, "X2D", &error);
    g_assert_nonnull(d);
    g_assert_cmpuint(d->use->len, ==, 2);
    g_assert_cmpuint(d->left_out->len, ==, 1);
    ZgSpool *a = g_ptr_array_index(d->use, 0), *b = g_ptr_array_index(d->use, 1);
    g_assert_cmpstr(a->material, ==, "PLA");
    g_assert_cmpstr(a->color, ==, "#ff0000");
    g_assert_null(b->color);
    g_assert_cmpstr(d->nozzle_type, ==, "hardened_steel");
    g_assert_cmpstr(d->nozzle_flow, ==, "high_flow");
    char *m = zg_deck_filaments_message(d, FALSE, "X2D");
    g_assert_cmpstr(m, ==, "2 filaments from X2D: A1 PLA, A2 PETG. Not used: Ext TPU (the second nozzle: pick the printer profile of X2D, "
                           "with two nozzles). Nozzles: hardened steel, high flow.");
    g_free(m);
    zg_deck_filaments_free(d);
}

static void test_two_nozzles(void) {
    char *error = NULL;
    ZgDeckFilaments *d = zg_deck_filaments_parse(deck, -1, TRUE, "X2D", &error);
    g_assert_nonnull(d);
    g_assert_cmpuint(d->use->len, ==, 3);
    g_assert_cmpuint(d->left_out->len, ==, 0);
    ZgSpool *c = g_ptr_array_index(d->use, 2);
    g_assert_true(c->aux);
    char *m = zg_deck_filaments_message(d, TRUE, "X2D");
    g_assert_cmpstr(m, ==, "3 filaments from X2D: A1 PLA, A2 PETG, Ext TPU (2nd nozzle). Nozzles: hardened steel, high flow.");
    g_free(m);
    zg_deck_filaments_free(d);
}

static void test_errors(void) {
    char *error = NULL;
    g_assert_null(zg_deck_filaments_parse("{\"filaments\": []}", -1, FALSE, "P1S", &error));
    g_assert_cmpstr(error, ==, "The printer tells no loaded filaments. Update the deck, or load a spool.");
    g_clear_pointer(&error, g_free);
    g_assert_null(zg_deck_filaments_parse("{\"filaments\": [{\"material\": \"PLA\", \"nozzle\": \"aux\"}]}", -1, FALSE, "P1S", &error));
    g_assert_true(g_str_has_prefix(error, "The spools of P1S feed its second nozzle only."));
    g_clear_pointer(&error, g_free);
    g_assert_null(zg_deck_filaments_parse("not json", -1, FALSE, "P1S", &error));
    g_assert_nonnull(error);
    g_clear_pointer(&error, g_free);
    /* 16 filaments at most, and a spool with no slot is a "roll". */
    GString *many = g_string_new("{\"filaments\": [");
    for (int i = 0; i < 20; i++) g_string_append_printf(many, "%s{\"material\": \"PLA\"}", i ? "," : "");
    g_string_append(many, "]}");
    ZgDeckFilaments *d = zg_deck_filaments_parse(many->str, -1, FALSE, "P1S", &error);
    g_assert_nonnull(d);
    g_assert_cmpuint(d->use->len, ==, 16);
    g_assert_null(d->nozzle_type);
    char *m = zg_deck_filaments_message(d, FALSE, "P1S");
    g_assert_true(g_str_has_prefix(m, "16 filaments from P1S: roll PLA, roll PLA"));
    g_free(m);
    zg_deck_filaments_free(d);
    g_string_free(many, TRUE);
}

int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/deck-filaments/codes", test_codes);
    g_test_add_func("/deck-filaments/one-nozzle", test_one_nozzle);
    g_test_add_func("/deck-filaments/two-nozzles", test_two_nozzles);
    g_test_add_func("/deck-filaments/errors", test_errors);
    return g_test_run();
}
