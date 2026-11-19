/* key-header-test.c: a redirect to another origin must not carry the API
 * key (src/net/key-header.c).
 *
 * Two servers on 127.0.0.1: the "printer" answers /same with a redirect
 * to its own /ok, and /away with a redirect to /ok of the "other" server.
 * Each server records the key that each request brings.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "../src/net/key-header.h"

#include <string.h>

typedef struct {
    SoupServer *server;
    char *base; /* "http://127.0.0.1:<port>" */
    char *last_key; /* the key of the last request to /ok, or "" */
    int hits;
} Host;

static Host printer, other;

static void handle(SoupServer *server, SoupServerMessage *msg, const char *path, GHashTable *query, gpointer data) {
    Host *h = data;
    if (strcmp(path, "/ok") == 0) {
        const char *k = soup_message_headers_get_one(soup_server_message_get_request_headers(msg), ZG_KEY_HEADER);
        g_free(h->last_key);
        h->last_key = g_strdup(k ? k : "");
        h->hits++;
        soup_server_message_set_status(msg, 200, NULL);
        soup_server_message_set_response(msg, "text/plain", SOUP_MEMORY_STATIC, "ok", 2);
        return;
    }
    char *to = strcmp(path, "/same") == 0 ? g_strconcat(printer.base, "/ok", NULL) : g_strconcat(other.base, "/ok", NULL);
    soup_server_message_set_redirect(msg, 302, to);
    g_free(to);
}

static void start(Host *h) {
    GError *error = NULL;
    h->server = soup_server_new(NULL, NULL);
    soup_server_add_handler(h->server, NULL, handle, h, NULL);
    if (!soup_server_listen_local(h->server, 0, SOUP_SERVER_LISTEN_IPV4_ONLY, &error)) g_error("listen: %s", error->message);
    GSList *uris = soup_server_get_uris(h->server);
    GUri *u = uris->data;
    h->base = g_strdup_printf("http://127.0.0.1:%d", g_uri_get_port(u));
    g_slist_free_full(uris, (GDestroyNotify)g_uri_unref);
    h->last_key = g_strdup("");
}

/* Sends GET <printer>/<path> with the key, and waits for the answer. */
static guint fetch(const char *path) {
    SoupSession *s = soup_session_new();
    char *url = g_strconcat(printer.base, path, NULL);
    SoupMessage *msg = soup_message_new("GET", url);
    g_free(url);
    zg_soup_add_key(msg, "secret-key");
    GBytes *body = soup_session_send_and_read(s, msg, NULL, NULL);
    guint status = soup_message_get_status(msg);
    if (body) g_bytes_unref(body);
    g_object_unref(msg);
    g_object_unref(s);
    return status;
}

/* The servers run in a thread of their own: the sends below block. */
static GMutex lock;
static GCond ready;
static gboolean up;

static gpointer serve(gpointer data) {
    GMainContext *ctx = g_main_context_new();
    g_main_context_push_thread_default(ctx);
    start(&printer);
    start(&other);
    g_mutex_lock(&lock);
    up = TRUE;
    g_cond_signal(&ready);
    g_mutex_unlock(&lock);
    GMainLoop *loop = g_main_loop_new(ctx, FALSE);
    g_main_loop_run(loop);
    return NULL;
}

int main(void) {
    g_thread_new("servers", serve, NULL);
    g_mutex_lock(&lock);
    while (!up) g_cond_wait(&ready, &lock);
    g_mutex_unlock(&lock);
    /* A redirect on the same origin keeps the key. */
    g_assert_cmpuint(fetch("/same"), ==, 200);
    g_assert_cmpint(printer.hits, ==, 1);
    g_assert_cmpstr(printer.last_key, ==, "secret-key");
    /* A redirect to another origin (another port) loses the key. */
    g_assert_cmpuint(fetch("/away"), ==, 200);
    g_assert_cmpint(other.hits, ==, 1);
    g_assert_cmpstr(other.last_key, ==, "");
    /* No key: no header. */
    SoupMessage *m = soup_message_new("GET", printer.base);
    zg_soup_add_key(m, "");
    g_assert_null(soup_message_headers_get_one(soup_message_get_request_headers(m), ZG_KEY_HEADER));
    g_object_unref(m);
    g_print("ok\n");
    return 0;
}
