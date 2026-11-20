/* deck-target-test.c: a send to a deck that drives more printers must
 * reach the printer that the user picked (src/net/printer-link.c).
 *
 * A fake deck on 127.0.0.1 lists two printers: "TAZ" at its own address,
 * and "X2D" at /printers/x2d. It counts the uploads at each path. A send
 * of a printer named X2D with the address of the deck itself must fail
 * with no upload; the same printer at /printers/x2d must upload there.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "../src/net/printer-link.h"

#include <libsoup/soup.h>

#include <string.h>

static char *base;
static int root_uploads, x2d_uploads;
static gboolean saw_wrapped; /* an upload of x.gcode.3mf with the wrapped bytes */

static void handle(SoupServer *server, SoupServerMessage *msg, const char *path, GHashTable *query, gpointer data) {
    (void)server;
    (void)query;
    (void)data;
    if (strcmp(path, "/slicer/printer.json") == 0) {
        static const char json[] = "{\"name\":\"Deck\",\"kind\":\"printdeck\",\"printers\":["
                                   "{\"id\":\"taz\",\"name\":\"TAZ\",\"url\":\"\"},"
                                   "{\"id\":\"x2d\",\"name\":\"X2D\",\"url\":\"/printers/x2d\"}]}";
        soup_server_message_set_status(msg, 200, NULL);
        soup_server_message_set_response(msg, "application/json", SOUP_MEMORY_STATIC, json, strlen(json));
        return;
    }
    if (strcmp(path, "/api/files/local") == 0) root_uploads++;
    if (strcmp(path, "/printers/x2d/api/files/local") == 0) {
        x2d_uploads++;
        SoupMessageBody *b = soup_server_message_get_request_body(msg);
        GBytes *all = soup_message_body_flatten(b);
        gsize n = 0;
        const char *d = g_bytes_get_data(all, &n);
        if (g_strstr_len(d, (gssize)n, "x.gcode.3mf") && g_strstr_len(d, (gssize)n, "WRAPPED-G-CODE")) saw_wrapped = TRUE;
        g_bytes_unref(all);
    }
    /* The answer of an upload: the stored file. */
    static const char stored[] = "{\"done\":true,\"files\":{\"local\":{\"name\":\"a.gcode\"}}}";
    soup_server_message_set_status(msg, 201, NULL);
    soup_server_message_set_response(msg, "application/json", SOUP_MEMORY_STATIC, stored, strlen(stored));
}

typedef struct {
    gboolean done, ok;
} Result;

static void on_done(gboolean ok, const char *message, gpointer data) {
    Result *r = data;
    (void)message;
    r->ok = ok;
    r->done = TRUE;
}

static GBytes *wrap(GBytes *signed_gcode, gpointer data) {
    (void)data;
    /* The signed G-code must arrive here: it starts with the G-code. */
    gsize n = 0;
    const char *g = g_bytes_get_data(signed_gcode, &n);
    if (n < 4 || memcmp(g, "G28\n", 4) != 0) return NULL;
    return g_bytes_new_static("WRAPPED-G-CODE", 14);
}

static gboolean send_to(const char *name, const char *url) {
    ZgPrinter p = {0};
    p.id = (char *)"t";
    p.name = (char *)name;
    p.kind = ZG_LINK_PRINTDECK;
    p.url = (char *)url;
    p.api_key = (char *)"k";
    Result r = {0};
    GBytes *g = g_bytes_new_static("G28\n", 4);
    zg_link_send(&p, "a.gcode", g, FALSE, NULL, NULL, on_done, &r);
    while (!r.done) g_main_context_iteration(NULL, TRUE);
    g_bytes_unref(g);
    return r.ok;
}

int main(void) {
    char *dir = g_dir_make_tmp("zslice-deck-XXXXXX", NULL);
    g_setenv("XDG_CONFIG_HOME", dir, TRUE);
    GError *error = NULL;
    SoupServer *server = soup_server_new(NULL, NULL);
    soup_server_add_handler(server, NULL, handle, NULL, NULL);
    if (!soup_server_listen_local(server, 0, SOUP_SERVER_LISTEN_IPV4_ONLY, &error)) g_error("listen: %s", error->message);
    GSList *uris = soup_server_get_uris(server);
    base = g_strdup_printf("http://127.0.0.1:%d", g_uri_get_port(uris->data));
    g_slist_free_full(uris, (GDestroyNotify)g_uri_unref);

    /* The X2D with the address of the deck itself (its first printer). */
    if (send_to("X2D", base) || root_uploads != 0) g_error("the X2D at the deck address must not upload");
    /* The X2D at its path. */
    char *x2d = g_strconcat(base, "/printers/x2d", NULL);
    if (!send_to("X2D", x2d) || x2d_uploads != 1) g_error("the X2D at /printers/x2d must upload there");
    /* The TAZ at the deck address. */
    if (!send_to("TAZ", base) || root_uploads != 1) g_error("the TAZ at the deck address must upload");
    /* The queue case: a longer name of the X2D, and an unknown name, at the
     * address of the deck. */
    if (send_to("Bambu Lab X2D", base)) g_error("Bambu Lab X2D at the deck address must fail");
    if (send_to("Printdeck", base)) g_error("an unknown name at the deck address must fail");
    if (!send_to("TAZ Workhorse", base) || root_uploads != 2) g_error("TAZ Workhorse at the deck address must upload");
    /* A path that the deck does not have. */
    char *gone = g_strconcat(base, "/printers/gone", NULL);
    if (send_to("Mine", gone)) g_error("a path that the deck does not have must fail");
    /* A wrapped send: the file goes out as the wrap made it. */
    {
        ZgPrinter p = {0};
        p.id = (char *)"t";
        p.name = (char *)"X2D";
        p.kind = ZG_LINK_PRINTDECK;
        p.url = x2d;
        p.api_key = (char *)"k";
        Result r = {0};
        GBytes *g = g_bytes_new_static("G28\n", 4);
        zg_link_send_wrapped(&p, "x.gcode.3mf", g, wrap, NULL, FALSE, NULL, NULL, on_done, &r);
        while (!r.done) g_main_context_iteration(NULL, TRUE);
        g_bytes_unref(g);
        if (!r.ok || !saw_wrapped) g_error("a wrapped send must upload the wrapped file");
    }
    g_print("ok\n");
    g_free(x2d);
    g_free(gone);
    g_object_unref(server);
    return 0;
}
