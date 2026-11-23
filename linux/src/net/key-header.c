/* key-header.c: see key-header.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "key-header.h"

#include <string.h>

/* The origin of a URI: "scheme://host:port". */
static char *origin_of(GUri *u) {
    if (!u) return g_strdup("");
    const char *scheme = g_uri_get_scheme(u);
    const char *host = g_uri_get_host(u);
    int port = g_uri_get_port(u);
    if (port < 0) port = scheme && g_ascii_strcasecmp(scheme, "https") == 0 ? 443 : 80;
    char *lower_scheme = g_ascii_strdown(scheme ? scheme : "", -1);
    char *lower_host = g_ascii_strdown(host ? host : "", -1);
    char *o = g_strdup_printf("%s://%s:%d", lower_scheme, lower_host, port);
    g_free(lower_scheme);
    g_free(lower_host);
    return o;
}

static char *origin_of_text(const char *text) {
    char *clean = g_strstrip(g_strdup(text ? text : ""));
    char *full = strstr(clean, "://") ? g_strdup(clean) : g_strconcat("http://", clean, NULL);
    GUri *u = clean[0] ? g_uri_parse(full, G_URI_FLAGS_NONE, NULL) : NULL;
    char *o = u && g_uri_get_host(u) && g_uri_get_host(u)[0] ? origin_of(u) : NULL;
    if (u) g_uri_unref(u);
    g_free(full);
    g_free(clean);
    return o;
}

gboolean zg_same_origin(const char *a, const char *b) {
    char *x = origin_of_text(a), *y = origin_of_text(b);
    gboolean same = x && y && strcmp(x, y) == 0;
    g_free(x);
    g_free(y);
    return same;
}

/* A redirect: the request goes out again, to its new URI. */
static void on_restarted(SoupMessage *msg, gpointer data) {
    const char *origin = data;
    char *now = origin_of(soup_message_get_uri(msg));
    if (strcmp(now, origin) != 0) soup_message_headers_remove(soup_message_get_request_headers(msg), ZG_KEY_HEADER);
    g_free(now);
}

static void free_origin(gpointer data, GClosure *closure) {
    (void)closure;
    g_free(data);
}

void zg_soup_add_key(SoupMessage *msg, const char *key) {
    if (!msg || !key || !key[0]) return;
    soup_message_headers_replace(soup_message_get_request_headers(msg), ZG_KEY_HEADER, key);
    g_signal_connect_data(msg, "restarted", G_CALLBACK(on_restarted), origin_of(soup_message_get_uri(msg)), free_origin, 0);
}
