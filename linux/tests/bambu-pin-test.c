/* bambu-pin-test.c: zg_bambu_connect trusts the first certificate of a
 * printer, and refuses another one later (src/net/bambu-link.c).
 *
 * A TLS server on 127.0.0.1 plays the printer, with a certificate that
 * openssl makes in a new temporary folder. With no openssl, the test is
 * skipped (exit code 77).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "../src/net/bambu-link.h"

#include <glib/gstdio.h>
#include <string.h>

static GTlsCertificate *server_cert;
static GMutex lock;

static gboolean on_incoming(GSocketService *service, GSocketConnection *conn, GObject *source, gpointer data) {
    g_mutex_lock(&lock);
    GTlsCertificate *cert = g_object_ref(server_cert);
    g_mutex_unlock(&lock);
    GIOStream *tls = g_tls_server_connection_new(G_IO_STREAM(conn), cert, NULL);
    g_object_unref(cert);
    if (tls) {
        /* A failed handshake (the client refused the certificate) is fine. */
        g_tls_connection_handshake(G_TLS_CONNECTION(tls), NULL, NULL);
        g_io_stream_close(tls, NULL, NULL);
        g_object_unref(tls);
    }
    return TRUE;
}

static GTlsCertificate *make_cert(const char *dir, const char *name) {
    char *key = g_strdup_printf("%s/%s.key", dir, name);
    char *crt = g_strdup_printf("%s/%s.crt", dir, name);
    char *subject = g_strdup_printf("/CN=01P00A0000000%s", name);
    const char *argv[] = {"openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                          "-keyout", key, "-out", crt, "-days", "2", "-subj", subject, NULL};
    int status = 1;
    GTlsCertificate *cert = NULL;
    if (g_spawn_sync(NULL, (char **)argv, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
                     NULL, NULL, NULL, NULL, &status, NULL) &&
        g_spawn_check_wait_status(status, NULL))
        cert = g_tls_certificate_new_from_files(crt, key, NULL);
    g_unlink(key);
    g_unlink(crt);
    g_free(key);
    g_free(crt);
    g_free(subject);
    return cert;
}

static gpointer serve(gpointer data) {
    GMainContext *ctx = data;
    g_main_context_push_thread_default(ctx);
    GMainLoop *loop = g_main_loop_new(ctx, FALSE);
    g_main_loop_run(loop);
    return NULL;
}

int main(void) {
    char *dir = g_dir_make_tmp("zslice-pin-XXXXXX", NULL);
    g_assert_nonnull(dir);
    GTlsCertificate *a = make_cert(dir, "a");
    GTlsCertificate *b = make_cert(dir, "b");
    g_rmdir(dir);
    g_free(dir);
    if (!a || !b) {
        g_print("skip: no openssl or no TLS backend\n");
        return 77;
    }
    char *hash_a = zg_cert_hash(a);
    char *hash_b = zg_cert_hash(b);
    g_assert_cmpstr(hash_a, !=, hash_b);
    g_assert_cmpuint(strlen(hash_a), ==, 64);

    server_cert = g_object_ref(a);
    GMainContext *ctx = g_main_context_new();
    g_main_context_push_thread_default(ctx);
    GSocketService *service = g_threaded_socket_service_new(4);
    g_signal_connect(service, "run", G_CALLBACK(on_incoming), NULL);
    GInetAddress *lo = g_inet_address_new_loopback(G_SOCKET_FAMILY_IPV4);
    GSocketAddress *any = g_inet_socket_address_new(lo, 0);
    GSocketAddress *bound = NULL;
    GError *e = NULL;
    g_assert_true(g_socket_listener_add_address(G_SOCKET_LISTENER(service), any, G_SOCKET_TYPE_STREAM, G_SOCKET_PROTOCOL_TCP,
                                                NULL, &bound, &e));
    int port = g_inet_socket_address_get_port(G_INET_SOCKET_ADDRESS(bound));
    g_socket_service_start(service);
    g_main_context_pop_thread_default(ctx);
    g_thread_new("server", serve, ctx);

    /* The first connection: no pin, any certificate, and its hash. */
    char *seen = NULL;
    GIOStream *io = zg_bambu_connect("127.0.0.1", port, NULL, &seen, NULL, &e);
    g_assert_no_error(e);
    g_assert_nonnull(io);
    g_assert_cmpstr(seen, ==, hash_a);
    g_object_unref(io);
    g_clear_pointer(&seen, g_free);

    /* The pin of the same certificate. */
    io = zg_bambu_connect("127.0.0.1", port, hash_a, &seen, NULL, &e);
    g_assert_no_error(e);
    g_assert_nonnull(io);
    g_object_unref(io);
    g_clear_pointer(&seen, g_free);

    /* Another device at the address: no connection, so no access code. */
    g_mutex_lock(&lock);
    g_object_unref(server_cert);
    server_cert = g_object_ref(b);
    g_mutex_unlock(&lock);
    io = zg_bambu_connect("127.0.0.1", port, hash_a, &seen, NULL, &e);
    g_assert_null(io);
    g_assert_error(e, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED);
    g_assert_cmpstr(seen, ==, hash_b);
    g_clear_error(&e);
    g_clear_pointer(&seen, g_free);
    g_print("ok\n");
    return 0;
}
