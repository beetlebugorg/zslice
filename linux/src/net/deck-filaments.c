/* deck-filaments.c: see deck-filaments.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "deck-filaments.h"

#include <json-glib/json-glib.h>
#include <string.h>

/* The most filaments of a plate (src/app/filament_slots.zig). */
enum { MAX_FILAMENTS = 16 };

static void spool_free(gpointer data) {
    ZgSpool *s = data;
    g_free(s->slot);
    g_free(s->material);
    g_free(s->color);
    g_free(s);
}

void zg_deck_filaments_free(ZgDeckFilaments *d) {
    if (!d) return;
    g_ptr_array_unref(d->use);
    g_ptr_array_unref(d->left_out);
    g_free(d);
}

gboolean zg_nozzle_of_code(const char *code, const char **type, const char **flow) {
    if (!code) return FALSE;
    while (g_ascii_isspace(*code)) code++;
    size_t n = strlen(code);
    while (n > 0 && g_ascii_isspace(code[n - 1])) n--;
    if (n < 2) return FALSE;
    for (size_t i = 2; i < n; i++)
        if (!g_ascii_isdigit(code[i])) return FALSE;
    const char *t;
    switch (g_ascii_toupper(code[0])) {
    case 'H': t = "hardened_steel"; break;
    case 'S': t = "stainless_steel"; break;
    case 'T': t = "tungsten_carbide"; break;
    default: return FALSE;
    }
    char f = g_ascii_toupper(code[1]);
    if (f != 'S' && f != 'H') return FALSE;
    if (type) *type = t;
    if (flow) *flow = f == 'H' ? "high_flow" : "standard";
    return TRUE;
}

/* A string member of a JSON object, or NULL. */
static const char *member(JsonObject *o, const char *name) {
    JsonNode *n = json_object_get_member(o, name);
    if (!n || !JSON_NODE_HOLDS_VALUE(n) || json_node_get_value_type(n) != G_TYPE_STRING) return NULL;
    return json_node_get_string(n);
}

static gboolean is_color(const char *s) {
    if (!s || s[0] != '#' || strlen(s) != 7) return FALSE;
    for (int i = 1; i < 7; i++)
        if (!g_ascii_isxdigit(s[i])) return FALSE;
    return TRUE;
}

ZgDeckFilaments *zg_deck_filaments_parse(const char *json, gssize len, gboolean two_nozzles, const char *printer, char **error) {
    JsonParser *parser = json_parser_new();
    if (!json_parser_load_from_data(parser, json, len, NULL) || !JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser))) {
        g_object_unref(parser);
        *error = g_strdup("The deck sent no valid answer.");
        return NULL;
    }
    JsonObject *root = json_node_get_object(json_parser_get_root(parser));
    ZgDeckFilaments *d = g_new0(ZgDeckFilaments, 1);
    d->use = g_ptr_array_new_with_free_func(spool_free);
    d->left_out = g_ptr_array_new_with_free_func(spool_free);
    guint loaded = 0;
    JsonNode *list = json_object_get_member(root, "filaments");
    if (list && JSON_NODE_HOLDS_ARRAY(list)) {
        JsonArray *a = json_node_get_array(list);
        for (guint i = 0; i < json_array_get_length(a); i++) {
            JsonNode *e = json_array_get_element(a, i);
            if (!JSON_NODE_HOLDS_OBJECT(e)) continue;
            JsonObject *o = json_node_get_object(e);
            const char *material = member(o, "material");
            if (!material || !material[0]) continue;
            loaded++;
            ZgSpool *s = g_new0(ZgSpool, 1);
            const char *slot = member(o, "slot");
            s->slot = slot && slot[0] ? g_strdup(slot) : NULL;
            s->material = g_ascii_strup(material, -1);
            const char *color = member(o, "color");
            s->color = is_color(color) ? g_ascii_strdown(color, -1) : NULL;
            s->aux = g_strcmp0(member(o, "nozzle"), "aux") == 0;
            /* A spool of the second nozzle needs a printer with two
             * nozzles in the settings. Else the change asks for it in
             * the main nozzle. */
            if (s->aux && !two_nozzles) g_ptr_array_add(d->left_out, s);
            else if (d->use->len < MAX_FILAMENTS) g_ptr_array_add(d->use, s);
            else spool_free(s);
        }
    }
    JsonNode *nozzles = json_object_get_member(root, "nozzles");
    if (nozzles && JSON_NODE_HOLDS_ARRAY(nozzles)) {
        JsonArray *a = json_node_get_array(nozzles);
        for (guint i = 0; i < json_array_get_length(a) && !d->nozzle_type; i++) {
            JsonNode *e = json_array_get_element(a, i);
            if (JSON_NODE_HOLDS_OBJECT(e)) zg_nozzle_of_code(member(json_node_get_object(e), "type"), &d->nozzle_type, &d->nozzle_flow);
        }
    }
    g_object_unref(parser);
    if (loaded == 0) {
        *error = g_strdup("The printer tells no loaded filaments. Update the deck, or load a spool.");
        zg_deck_filaments_free(d);
        return NULL;
    }
    if (d->use->len == 0) {
        *error = g_strdup_printf("The spools of %s feed its second nozzle only. Pick the printer profile of %s (two nozzles), or load a spool in the AMS.",
                                 printer, printer);
        zg_deck_filaments_free(d);
        return NULL;
    }
    return d;
}

/* "slot material" for each spool, with commas. */
static void append_spools(GString *s, GPtrArray *list, const char *no_slot, gboolean mark_aux) {
    for (guint i = 0; i < list->len; i++) {
        ZgSpool *sp = g_ptr_array_index(list, i);
        if (i > 0) g_string_append(s, ", ");
        g_string_append_printf(s, "%s %s%s", sp->slot ? sp->slot : no_slot, sp->material, mark_aux && sp->aux ? " (2nd nozzle)" : "");
    }
}

static void append_words(GString *s, const char *name) {
    for (const char *c = name; *c; c++) g_string_append_c(s, *c == '_' ? ' ' : *c);
}

char *zg_deck_filaments_message(const ZgDeckFilaments *d, gboolean two_nozzles, const char *printer) {
    GString *s = g_string_new(NULL);
    g_string_append_printf(s, "%u %s from %s: ", d->use->len, d->use->len == 1 ? "filament" : "filaments", printer);
    append_spools(s, d->use, "roll", two_nozzles);
    g_string_append_c(s, '.');
    if (d->left_out->len > 0) {
        g_string_append(s, " Not used: ");
        append_spools(s, d->left_out, "spool", FALSE);
        g_string_append_printf(s, " (the second nozzle: pick the printer profile of %s, with two nozzles).", printer);
    }
    if (d->nozzle_type) {
        g_string_append(s, " Nozzles: ");
        append_words(s, d->nozzle_type);
        g_string_append(s, ", ");
        append_words(s, d->nozzle_flow);
        g_string_append_c(s, '.');
    }
    return g_string_free(s, FALSE);
}

gboolean zg_material_is_plain(const char *material) {
    if (!material) return FALSE;
    size_t n = strlen(material);
    if (n == 0 || n > 32) return FALSE;
    for (size_t i = 0; i < n; i++) {
        char c = material[i];
        if (!g_ascii_isalnum(c) && c != '+' && c != '-' && c != '_' && c != ' ') return FALSE;
    }
    return TRUE;
}
