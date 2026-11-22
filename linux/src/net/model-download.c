/* model-download.c: see model-download.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "model-download.h"

#include <libsoup/soup.h>
#include "zslice-app.h"
#include <string.h>

typedef struct {
    zs_link link;
    ZgDownloadProgress progress;
    gpointer progress_data;
    GMainContext *context;
    /* A request of an import (zg_net_request): the POST body, or NULL for
     * a GET; and the largest answer. */
    gboolean request;
    char *body;
    guint64 limit;
    /* Set by the check of a connection. */
    gboolean local_peer;
    GCancellable *inner;
} Job;

typedef struct {
    ZgDownloadProgress fn;
    gpointer data;
    double fraction;
} Progress;

typedef struct {
    GBytes *bytes;
    char *name;
} Done;

static void done_free(gpointer p) {
    Done *d = p;
    if (d->bytes) g_bytes_unref(d->bytes);
    g_free(d->name);
    g_free(d);
}

static void job_free(gpointer p) {
    Job *j = p;
    if (j->context) g_main_context_unref(j->context);
    g_clear_object(&j->inner);
    g_free(j->body);
    g_free(j);
}

static void fail_with(GError **error, int result) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, zs_link_message(result));
}

static gboolean address_public(GInetAddress *a) {
    return zs_link_address_public(g_inet_address_to_bytes(a), g_inet_address_get_native_size(a)) != 0;
}

gboolean zg_model_download_check_host(const char *host, GCancellable *cancel, GError **error) {
    GResolver *resolver = g_resolver_get_default();
    GList *list = g_resolver_lookup_by_name(resolver, host, cancel, error);
    g_object_unref(resolver);
    if (!list) {
        if (error && *error && !g_error_matches(*error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
            g_clear_error(error);
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "The name of the site does not resolve.");
        }
        return FALSE;
    }
    gboolean ok = TRUE;
    for (GList *l = list; l; l = l->next)
        if (!address_public(l->data)) ok = FALSE;
    g_resolver_free_addresses(list);
    if (!ok) fail_with(error, ZS_LINK_LOCAL_ADDRESS);
    return ok;
}

static void peer_check(Job *j, GIOStream *stream) {
    if (G_IS_TLS_CONNECTION(stream)) {
        GIOStream *base = NULL;
        g_object_get(stream, "base-io-stream", &base, NULL);
        if (base) {
            peer_check(j, base);
            g_object_unref(base);
        }
        return;
    }
    if (!G_IS_SOCKET_CONNECTION(stream)) return;
    GSocketAddress *sa = g_socket_connection_get_remote_address(G_SOCKET_CONNECTION(stream), NULL);
    gboolean ok = sa && G_IS_INET_SOCKET_ADDRESS(sa) && address_public(g_inet_socket_address_get_address(G_INET_SOCKET_ADDRESS(sa)));
    g_clear_object(&sa);
    if (!ok) {
        j->local_peer = TRUE;
        g_cancellable_cancel(j->inner);
    }
}

/* Each new connection: its peer must be public, before the TLS handshake
 * and before any byte of the request. */
static void on_network_event(SoupMessage *m, GSocketClientEvent event, GIOStream *stream, gpointer data) {
    if (event == G_SOCKET_CLIENT_CONNECTED || event == G_SOCKET_CLIENT_TLS_HANDSHAKING) peer_check(data, stream);
}

static gboolean progress_main(gpointer data) {
    Progress *p = data;
    p->fn(p->fraction, p->data);
    g_free(p);
    return G_SOURCE_REMOVE;
}

static void post_progress(Job *j, double fraction) {
    if (!j->progress) return;
    Progress *p = g_new(Progress, 1);
    p->fn = j->progress;
    p->data = j->progress_data;
    p->fraction = fraction;
    g_main_context_invoke(j->context, progress_main, p);
}

static void forward_cancel(GCancellable *outer, gpointer inner) {
    g_cancellable_cancel(inner);
}

/* One request. A redirect returns NULL with *redirected TRUE. */
static GBytes *fetch_once(Job *j, SoupSession *session, gboolean *redirected, GError **error) {
    *redirected = FALSE;
    GUri *uri = g_uri_parse(j->link.url, G_URI_FLAGS_ENCODED | G_URI_FLAGS_PARSE_RELAXED, NULL);
    if (!uri) {
        fail_with(error, ZS_LINK_NOT_PUBLIC);
        return NULL;
    }
    SoupMessage *m = soup_message_new_from_uri(j->body ? "POST" : "GET", uri);
    g_uri_unref(uri);
    soup_message_set_flags(m, SOUP_MESSAGE_NO_REDIRECT);
    soup_message_headers_replace(soup_message_get_request_headers(m), "Accept", j->body ? "application/json" : "*/*");
    if (j->body) {
        GBytes *body = g_bytes_new(j->body, strlen(j->body));
        soup_message_set_request_body_from_bytes(m, "application/json", body);
        g_bytes_unref(body);
    }
    g_signal_connect(m, "network-event", G_CALLBACK(on_network_event), j);
    GError *e = NULL;
    GInputStream *in = soup_session_send(session, m, j->inner, &e);
    if (!in) {
        if (j->local_peer) {
            g_clear_error(&e);
            fail_with(error, ZS_LINK_LOCAL_ADDRESS);
        } else if (g_error_matches(e, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
            g_propagate_error(error, e);
        } else if (e->domain == G_TLS_ERROR) {
            g_clear_error(&e);
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "The certificate of the site is not valid.");
        } else {
            g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "The download failed: %s", e->message);
            g_clear_error(&e);
        }
        g_object_unref(m);
        return NULL;
    }
    GBytes *result = NULL;
    guint status = soup_message_get_status(m);
    SoupMessageHeaders *head = soup_message_get_response_headers(m);
    if (j->body && status >= 300 && status < 400) {
        /* A POST to an API follows no redirect. */
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "The site answered with error %u.", status);
        goto out;
    }
    if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
        const char *location = soup_message_headers_get_one(head, "Location");
        if (!location || !*location)
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "The site sent a redirect with no address.");
        else if (zs_link_redirect(location, &j->link) != ZS_LINK_OK)
            fail_with(error, ZS_LINK_BAD_REDIRECT);
        else
            *redirected = TRUE;
        goto out;
    }
    if (status < 200 || status >= 300) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "The site answered with error %u.", status);
        goto out;
    }
    gint64 total = soup_message_headers_get_encoding(head) == SOUP_ENCODING_CONTENT_LENGTH
                       ? soup_message_headers_get_content_length(head)
                       : -1;
    guint64 limit = j->request ? j->limit : ZS_LINK_MAX_BYTES;
    if (j->request) {
        if (total > 0 && (guint64)total > limit) {
            fail_with(error, ZS_LINK_TOO_LARGE);
            goto out;
        }
    } else {
        int rc = zs_link_check_reply(soup_message_headers_get_one(head, "Content-Type"), total);
        if (rc == ZS_LINK_OK) rc = zs_link_file_name(soup_message_headers_get_one(head, "Content-Disposition"), &j->link);
        if (rc != ZS_LINK_OK) {
            fail_with(error, rc);
            goto out;
        }
    }
    GByteArray *data = g_byte_array_sized_new(total > 0 ? (guint)total : 1 << 20);
    guint8 *buffer = g_malloc(256 * 1024);
    int last = -1;
    for (;;) {
        gssize got = g_input_stream_read(in, buffer, 256 * 1024, j->inner, &e);
        if (got < 0) {
            if (j->local_peer) {
                g_clear_error(&e);
                fail_with(error, ZS_LINK_LOCAL_ADDRESS);
            } else {
                g_propagate_error(error, e);
            }
            break;
        }
        if (got == 0) {
            result = g_byte_array_free_to_bytes(data);
            data = NULL;
            break;
        }
        if (data->len + (guint64)got > limit) {
            if (j->request)
                g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "The answer of the site is too large.");
            else
                fail_with(error, ZS_LINK_TOO_LARGE);
            break;
        }
        g_byte_array_append(data, buffer, (guint)got);
        if (total > 0) {
            int percent = (int)(100.0 * data->len / total);
            if (percent != last) {
                last = percent;
                post_progress(j, data->len / (double)total);
            }
        }
    }
    g_free(buffer);
    if (data) g_byte_array_unref(data);
out:
    g_input_stream_close(in, NULL, NULL);
    g_object_unref(in);
    g_object_unref(m);
    return result;
}

static void download_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancel) {
    Job *j = data;
    SoupSession *session = soup_session_new_with_options("user-agent", zs_import_user_agent(), "timeout", 30, "max-conns-per-host", 2, NULL);
    /* No proxy: the check of the peer needs the real address. */
    soup_session_set_proxy_resolver(session, NULL);
    /* No cookie jar, no cache, and no credentials: a new session has none,
     * and nothing answers its "authenticate" signal. */
    gulong forward = cancel ? g_cancellable_connect(cancel, G_CALLBACK(forward_cancel), j->inner, NULL) : 0;
    GError *error = NULL;
    GBytes *bytes = NULL;
    for (int hop = 0; hop <= ZS_LINK_MAX_REDIRECTS; hop++) {
        if (!zg_model_download_check_host(j->link.host, j->inner, &error)) break;
        gboolean redirected = FALSE;
        bytes = fetch_once(j, session, &redirected, &error);
        if (!redirected) break;
        if (hop == ZS_LINK_MAX_REDIRECTS) fail_with(&error, ZS_LINK_TOO_MANY_REDIRECTS);
    }
    if (cancel) g_cancellable_disconnect(cancel, forward);
    g_object_unref(session);
    if (bytes && !j->request && zs_project_file_is(g_bytes_get_data(bytes, NULL), g_bytes_get_size(bytes))) {
        g_bytes_unref(bytes);
        bytes = NULL;
        fail_with(&error, ZS_LINK_PROJECT);
    }
    if (!bytes) {
        if (!error && j->request)
            g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_FAILED, "The site did not answer.");
        if (!error) fail_with(&error, ZS_LINK_NOT_A_MODEL);
        g_task_return_error(task, error);
        return;
    }
    Done *d = g_new0(Done, 1);
    d->bytes = bytes;
    d->name = g_strdup(j->link.name);
    g_task_return_pointer(task, d, done_free);
}

void zg_model_download(const zs_link *link, GCancellable *cancel, ZgDownloadProgress progress, GAsyncReadyCallback done,
                       gpointer data) {
    Job *j = g_new0(Job, 1);
    j->link = *link;
    j->progress = progress;
    j->progress_data = data;
    j->context = g_main_context_ref_thread_default();
    j->inner = g_cancellable_new();
    GTask *task = g_task_new(NULL, cancel, done, data);
    g_task_set_task_data(task, j, job_free);
    g_task_set_return_on_cancel(task, FALSE);
    g_task_run_in_thread(task, download_thread);
    g_object_unref(task);
}

GBytes *zg_model_download_finish(GAsyncResult *result, char **name, GError **error) {
    Done *d = g_task_propagate_pointer(G_TASK(result), error);
    if (!d) return NULL;
    GBytes *bytes = d->bytes;
    d->bytes = NULL;
    if (name) *name = g_strdup(d->name);
    done_free(d);
    return bytes;
}

void zg_net_request(const zs_link *link, const char *body, guint64 limit, GCancellable *cancel, GAsyncReadyCallback done,
                    gpointer data) {
    Job *j = g_new0(Job, 1);
    j->link = *link;
    j->request = TRUE;
    j->body = g_strdup(body);
    j->limit = limit;
    j->context = g_main_context_ref_thread_default();
    j->inner = g_cancellable_new();
    GTask *task = g_task_new(NULL, cancel, done, data);
    g_task_set_task_data(task, j, job_free);
    g_task_set_return_on_cancel(task, FALSE);
    g_task_run_in_thread(task, download_thread);
    g_object_unref(task);
}

GBytes *zg_net_request_finish(GAsyncResult *result, GError **error) {
    return zg_model_download_finish(result, NULL, error);
}
