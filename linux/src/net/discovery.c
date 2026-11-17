/* discovery.c: see discovery.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "discovery.h"

#include <gio/gio.h>
#include <libsoup/soup.h>
#include <sys/socket.h>

#define SEARCH_MS 6000

struct ZgDiscovery {
    zs_discovery *core;
    ZgDiscoveryFn changed;
    gpointer data;
    GSocket *sock;     /* our own port: the unicast answers */
    GSocket *group;    /* port 5353 in the group, or NULL */
    GSource *sock_src, *group_src;
    guint resend[2];
    guint stop;
    guint follow;      /* a query with the next questions, soon */
    size_t asked;      /* the printers that got an HTTP request */
    SoupSession *http;
    GCancellable *cancel;
    gboolean running;
};

static void notify(ZgDiscovery *d) {
    if (d->changed) d->changed(d, d->data);
}

/* ---- HTTP: the kind and the bed of a new printer ---- */

typedef struct {
    ZgDiscovery *d;
    size_t index;
    int what;
} Ask;

static void on_http(GObject *source, GAsyncResult *res, gpointer data) {
    Ask *a = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
        g_error_free(error);
        g_free(a);
        return;
    }
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    if (body && msg && soup_message_get_status(msg) == SOUP_STATUS_OK) {
        gsize len = 0;
        const char *text = g_bytes_get_data(body, &len);
        if (zs_discovery_reply(a->d->core, a->index, a->what, text, len) == 1) notify(a->d);
    }
    if (body) g_bytes_unref(body);
    g_clear_error(&error);
    g_free(a);
}

static void ask(ZgDiscovery *d, size_t i) {
    zs_found_printer p;
    if (zs_discovery_get(d->core, i, &p) != ZS_OK) return;
    const char *path = p.kind == ZS_FOUND_MOONRAKER ? "/printer/objects/query?toolhead" : "/api/version";
    char *url = g_strconcat(p.url, path, NULL);
    SoupMessage *msg = soup_message_new("GET", url);
    g_free(url);
    if (!msg) return;
    Ask *a = g_new0(Ask, 1);
    a->d = d;
    a->index = i;
    a->what = p.kind == ZS_FOUND_MOONRAKER ? ZS_FOUND_REPLY_TOOLHEAD : ZS_FOUND_REPLY_VERSION;
    soup_session_send_and_read_async(d->http, msg, G_PRIORITY_DEFAULT, d->cancel, on_http, a);
    g_object_unref(msg);
}

/* ---- UDP ---- */

static void send_query(ZgDiscovery *d);

static gboolean on_follow(gpointer data) {
    ZgDiscovery *d = data;
    d->follow = 0;
    send_query(d);
    return G_SOURCE_REMOVE;
}

static gboolean on_packet(GSocket *sock, GIOCondition cond, gpointer data) {
    ZgDiscovery *d = data;
    guint8 buf[9000];
    gboolean changed = FALSE;
    for (;;) {
        GError *error = NULL;
        gssize n = g_socket_receive(sock, (gchar *)buf, sizeof buf, NULL, &error);
        if (n < 0) {
            g_clear_error(&error);
            break;
        }
        if (zs_discovery_feed(d->core, buf, (size_t)n) == 1) changed = TRUE;
    }
    if (changed) {
        size_t count = zs_discovery_count(d->core);
        for (; d->asked < count; d->asked++) ask(d, d->asked);
        /* The next questions (SRV, TXT, A), after the other answers of
         * this round. */
        if (!d->follow) d->follow = g_timeout_add(150, on_follow, d);
        notify(d);
    }
    return G_SOURCE_CONTINUE;
}

static void send_query(ZgDiscovery *d) {
    const uint8_t *q = NULL;
    size_t len = 0;
    zs_discovery_query(d->core, &q, &len);
    GInetAddress *group = g_inet_address_new_from_string("224.0.0.251");
    GSocketAddress *to = g_inet_socket_address_new(group, 5353);
    GSocket *socks[2] = {d->group, d->sock};
    for (int i = 0; i < 2; i++) {
        GError *error = NULL;
        if (socks[i] && g_socket_send_to(socks[i], to, (const gchar *)q, len, NULL, &error) < 0) {
            g_message("zslice: the printer search could not send: %s", error->message);
            g_error_free(error);
        }
    }
    g_object_unref(to);
    g_object_unref(group);
}

static gboolean on_resend(gpointer data) {
    ZgDiscovery *d = data;
    send_query(d);
    for (int i = 0; i < 2; i++) {
        if (d->resend[i] == g_source_get_id(g_main_current_source())) d->resend[i] = 0;
    }
    return G_SOURCE_REMOVE;
}

static void close_sockets(ZgDiscovery *d) {
    for (int i = 0; i < 2; i++) {
        if (d->resend[i]) g_source_remove(d->resend[i]);
        d->resend[i] = 0;
    }
    if (d->stop) g_source_remove(d->stop);
    d->stop = 0;
    if (d->follow) g_source_remove(d->follow);
    d->follow = 0;
    if (d->sock_src) {
        g_source_destroy(d->sock_src);
        g_source_unref(d->sock_src);
        d->sock_src = NULL;
    }
    if (d->group_src) {
        g_source_destroy(d->group_src);
        g_source_unref(d->group_src);
        d->group_src = NULL;
    }
    if (d->sock) g_socket_close(d->sock, NULL);
    if (d->group) g_socket_close(d->group, NULL);
    g_clear_object(&d->sock);
    g_clear_object(&d->group);
}

static gboolean on_stop(gpointer data) {
    ZgDiscovery *d = data;
    d->stop = 0;
    close_sockets(d);
    d->running = FALSE;
    notify(d);
    return G_SOURCE_REMOVE;
}

static GSource *watch(ZgDiscovery *d, GSocket *s) {
    GSource *src = g_socket_create_source(s, G_IO_IN, NULL);
    g_source_set_callback(src, (GSourceFunc)(void (*)(void))on_packet, d, NULL);
    g_source_attach(src, NULL);
    return src;
}

static GSocket *open_socket(guint16 port, gboolean group) {
    GError *error = NULL;
    GSocket *s = g_socket_new(G_SOCKET_FAMILY_IPV4, G_SOCKET_TYPE_DATAGRAM, G_SOCKET_PROTOCOL_UDP, &error);
    if (!s) {
        g_message("zslice: no socket for the printer search: %s", error->message);
        g_error_free(error);
        return NULL;
    }
    g_socket_set_blocking(s, FALSE);
    if (group) {
        /* Share port 5353 with the mDNS service of the system. */
        g_socket_set_option(s, SOL_SOCKET, SO_REUSEADDR, 1, NULL);
#ifdef SO_REUSEPORT
        g_socket_set_option(s, SOL_SOCKET, SO_REUSEPORT, 1, NULL);
#endif
    }
    GInetAddress *any = g_inet_address_new_any(G_SOCKET_FAMILY_IPV4);
    GSocketAddress *addr = g_inet_socket_address_new(any, port);
    gboolean ok = g_socket_bind(s, addr, TRUE, &error);
    g_object_unref(addr);
    if (ok && group) {
        GInetAddress *g = g_inet_address_new_from_string("224.0.0.251");
        ok = g_socket_join_multicast_group(s, g, FALSE, NULL, &error);
        g_object_unref(g);
    }
    g_object_unref(any);
    if (!ok) {
        /* Port 5353 is optional: the unicast answers come to our port. */
        if (!group) g_message("zslice: the printer search could not open a socket: %s", error->message);
        g_clear_error(&error);
        g_object_unref(s);
        return NULL;
    }
    return s;
}

void zg_discovery_restart(ZgDiscovery *d) {
    close_sockets(d);
    d->sock = open_socket(0, FALSE);
    d->group = open_socket(5353, TRUE);
    if (d->sock) d->sock_src = watch(d, d->sock);
    if (d->group) d->group_src = watch(d, d->group);
    d->running = d->sock != NULL;
    if (!d->running) {
        notify(d);
        return;
    }
    send_query(d);
    d->resend[0] = g_timeout_add(1000, on_resend, d);
    d->resend[1] = g_timeout_add(3000, on_resend, d);
    d->stop = g_timeout_add(SEARCH_MS, on_stop, d);
    notify(d);
}

ZgDiscovery *zg_discovery_new(ZgDiscoveryFn changed, gpointer data) {
    ZgDiscovery *d = g_new0(ZgDiscovery, 1);
    if (zs_discovery_new(&d->core) != ZS_OK) {
        g_free(d);
        return NULL;
    }
    d->changed = changed;
    d->data = data;
    d->http = soup_session_new_with_options("timeout", 4, NULL);
    d->cancel = g_cancellable_new();
    zg_discovery_restart(d);
    return d;
}

void zg_discovery_free(ZgDiscovery *d) {
    if (!d) return;
    d->changed = NULL;
    g_cancellable_cancel(d->cancel);
    close_sockets(d);
    g_clear_object(&d->cancel);
    g_clear_object(&d->http);
    zs_discovery_free(d->core);
    g_free(d);
}

gboolean zg_discovery_running(const ZgDiscovery *d) {
    return d && d->running;
}

const zs_discovery *zg_discovery_list(const ZgDiscovery *d) {
    return d ? d->core : NULL;
}
