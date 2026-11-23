/* bambu-link.c: see bambu-link.h.
 *
 * A thread of its own runs the MQTT client with blocking reads. The core
 * makes the packets and reads them (zs_mqtt_*, src/mqtt.zig): this file
 * moves the bytes. It sends CONNECT, SUBSCRIBE, PINGREQ (each 30 s, to
 * keep the connection), and DISCONNECT. It sends no PUBLISH. Each report
 * goes to the main thread, which feeds the core. The topic and the fields
 * follow the LAN mode documents of Bambu Lab printers (see docs/references/bambu-studio.md).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "bambu-link.h"

#include <string.h>

enum { KEEPALIVE_S = 60, PING_S = 30, READ_TIMEOUT_S = 5 };

struct ZgBambuWatch {
    gint refs;
    GCancellable *cancel;
    char *address, *serial, *code;
    /* The printer (for a new pin), and its pin: "" until the first
     * connection. The thread only, after the start. */
    char *id, *pin;
    ZgBambuFn fn;
    gpointer data;
    gboolean stopped;
    /* The key of the gate: "address:port". */
    char *gate;
    /* The main thread only. */
    zs_printer_status *status;
    guint timer;
    gboolean dirty, shown;
    char *error;
};

static void watch_unref(ZgBambuWatch *w) {
    if (!g_atomic_int_dec_and_test(&w->refs)) return;
    g_object_unref(w->cancel);
    g_free(w->gate);
    g_free(w->address);
    g_free(w->serial);
    g_free(w->code);
    g_free(w->id);
    g_free(w->pin);
    zs_printer_status_free(w->status);
    g_free(w->error);
    g_free(w);
}

/* ---- one connection for each address ----
 *
 * A printer in LAN mode can have a small limit on clients. A gate lets one
 * watch connect to an address. The wait after a refusal or a drop is in
 * the gate, so a new watch keeps it. */
enum { RETRY_S = 15 };

typedef struct {
    gboolean busy;
    gint64 next; /* monotonic time of the next try, us */
    char *report; /* the words of the last report of the open link */
} Gate;

static GMutex gate_lock;
static GHashTable *gates;

static void gate_free(gpointer data) {
    Gate *g = data;
    g_free(g->report);
    g_free(g);
}

/* With gate_lock. */
static Gate *gate_of(const char *key) {
    if (!gates) gates = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, gate_free);
    Gate *g = g_hash_table_lookup(gates, key);
    if (!g) {
        g = g_new0(Gate, 1);
        g_hash_table_insert(gates, g_strdup(key), g);
    }
    return g;
}

static char *host_of(const char *url) {
    const char *a = url;
    if (strstr(a, "://")) a = strstr(a, "://") + 3;
    return g_strndup(a, strcspn(a, "/:"));
}

int zg_bambu_port(const char *name, int port) {
    char *var = g_strdup_printf("ZSLICE_BAMBU_%s_PORT", name);
    const char *v = g_getenv(var);
    g_free(var);
    int n = v ? atoi(v) : 0;
    return n > 0 && n < 65536 ? n : port;
}

char *zg_cert_hash(GTlsCertificate *cert) {
    GByteArray *der = NULL;
    if (cert) g_object_get(cert, "certificate", &der, NULL);
    if (!der) return NULL;
    char *hash = g_compute_checksum_for_data(G_CHECKSUM_SHA256, der->data, der->len);
    g_byte_array_unref(der);
    return hash;
}

/* The pin of one connection, and the hash that the printer showed. */
typedef struct {
    const char *pin;
    char *seen;
} PinCheck;

/* The certificate of the printer is self-signed, so the checks of GIO
 * fail, and GIO asks here. The pin decides. */
static gboolean accept_pinned(GTlsConnection *conn, GTlsCertificate *cert, GTlsCertificateFlags errors, gpointer data) {
    PinCheck *pc = data;
    g_free(pc->seen);
    pc->seen = zg_cert_hash(cert);
    if (!pc->seen) return FALSE;
    return !pc->pin || !pc->pin[0] || g_ascii_strcasecmp(pc->pin, pc->seen) == 0;
}

static void on_event(GSocketClient *client, GSocketClientEvent event, GSocketConnectable *to, GIOStream *conn, gpointer data) {
    if (event == G_SOCKET_CLIENT_TLS_HANDSHAKING && G_IS_TLS_CLIENT_CONNECTION(conn))
        g_signal_connect(conn, "accept-certificate", G_CALLBACK(accept_pinned), data);
}

GIOStream *zg_bambu_connect(const char *address, int port, const char *pin, char **seen, GCancellable *cancel,
                            GError **error) {
    PinCheck pc = {.pin = pin, .seen = NULL};
    GSocketClient *c = g_socket_client_new();
    g_socket_client_set_tls(c, TRUE);
    g_socket_client_set_timeout(c, 10);
    g_signal_connect(c, "event", G_CALLBACK(on_event), &pc);
    GError *e = NULL;
    GSocketConnection *conn = g_socket_client_connect_to_host(c, address, (guint16)port, cancel, &e);
    g_object_unref(c);
    if (!conn && pc.seen && pin && pin[0] && g_ascii_strcasecmp(pin, pc.seen) != 0) {
        g_clear_error(&e);
        g_set_error_literal(&e, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                            "The certificate of the printer is not the one that zslice trusts. A device on the network "
                            "can claim to be the printer, so zslice sent no access code. If the printer was reset, "
                            "read its serial number again in Settings to trust it.");
    }
    if (e) g_propagate_error(error, e);
    if (seen) *seen = pc.seen;
    else g_free(pc.seen);
    return conn ? G_IO_STREAM(conn) : NULL;
}

/* ---- the packets (the core: zs_mqtt_*) ---- */

static gboolean write_packet(GOutputStream *out, uint8_t *p, size_t n, GCancellable *cancel, GError **error) {
    gboolean ok = g_output_stream_write_all(out, p, n, NULL, cancel, error);
    zs_buffer_free(p, n);
    return ok;
}

/* Reads what comes into the reader. *idle: READ_TIMEOUT_S with no byte. */
static gboolean read_more(GInputStream *in, zs_mqtt_reader *r, gboolean *idle, GCancellable *cancel, GError **error) {
    guint8 buf[16384];
    GError *e = NULL;
    *idle = FALSE;
    gssize n = g_input_stream_read(in, buf, sizeof buf, cancel, &e);
    if (n < 0 && g_error_matches(e, G_IO_ERROR, G_IO_ERROR_TIMED_OUT)) {
        *idle = TRUE;
        g_error_free(e);
        return TRUE;
    }
    if (n <= 0) {
        if (e) g_propagate_error(error, e);
        else g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_CLOSED, "The printer closed the connection.");
        return FALSE;
    }
    return zs_mqtt_reader_feed(r, buf, (size_t)n) == ZS_OK;
}

/* ---- the main thread ---- */

typedef struct {
    ZgBambuWatch *w;
    GBytes *payload; /* a report, or NULL */
    char *error;
} Post;

static gboolean flush(gpointer data) {
    ZgBambuWatch *w = data;
    w->timer = 0;
    if (w->stopped) return G_SOURCE_REMOVE;
    if (w->error) w->fn(NULL, w->error, w->data);
    else if (w->dirty) w->fn(w->status, NULL, w->data);
    w->dirty = FALSE;
    w->shown = TRUE;
    return G_SOURCE_REMOVE;
}

static gboolean on_post(gpointer data) {
    Post *p = data;
    ZgBambuWatch *w = p->w;
    if (!w->stopped) {
        if (p->payload) {
            gsize len = 0;
            const char *text = g_bytes_get_data(p->payload, &len);
            zs_printer_status_feed(w->status, 4, "report", text, len);
            w->dirty = TRUE;
            zs_printer_info in;
            if (zs_printer_status_get(w->status, &in) == ZS_OK) {
                g_mutex_lock(&gate_lock);
                Gate *g = gate_of(w->gate);
                if (g->busy) {
                    g_free(g->report);
                    g->report = g_strdup_printf("Connected. The printer reports%s%s%s%s.", in.state[0] ? ": " : "", in.state, in.job[0] ? ", " : "", in.job);
                }
                g_mutex_unlock(&gate_lock);
            }
            g_clear_pointer(&w->error, g_free);
        } else {
            g_free(w->error);
            w->error = g_strdup(p->error);
        }
        /* At most one call of fn each second; an error at once. */
        if (p->error) {
            if (w->timer) g_source_remove(w->timer);
            w->timer = 0;
            flush(w);
        } else if (!w->timer) {
            /* The first report shows at once. */
            w->timer = g_timeout_add(w->shown ? 1000 : 50, flush, w);
        }
    }
    if (p->payload) g_bytes_unref(p->payload);
    g_free(p->error);
    watch_unref(w);
    g_free(p);
    return G_SOURCE_REMOVE;
}

static void post(ZgBambuWatch *w, GBytes *payload, const char *error) {
    Post *p = g_new0(Post, 1);
    g_atomic_int_inc(&w->refs);
    p->w = w;
    p->payload = payload ? g_bytes_ref(payload) : NULL;
    p->error = g_strdup(error);
    g_idle_add(on_post, p);
}

typedef struct {
    char *id, *pin;
} PinPost;

/* The first connection to a printer with no pin: the printer keeps the
 * hash of its certificate (trust on first use). */
static gboolean on_pin(gpointer data) {
    PinPost *pp = data;
    ZgPrinter *p = zg_printers_find(pp->id);
    if (p && p->kind == ZG_LINK_BAMBU && !p->tls_pin[0]) {
        g_free(p->tls_pin);
        p->tls_pin = g_strdup(pp->pin);
        zg_printers_save();
    }
    g_free(pp->id);
    g_free(pp->pin);
    g_free(pp);
    return G_SOURCE_REMOVE;
}

void zg_bambu_trust_first(const char *id, const char *pin) {
    if (!id || !pin || !pin[0]) return;
    PinPost *pp = g_new0(PinPost, 1);
    pp->id = g_strdup(id);
    pp->pin = g_strdup(pin);
    g_idle_add(on_pin, pp);
}

/* ---- the thread ---- */

static const char *connack_text(guint8 rc) {
    switch (rc) {
    case 4:
    case 5:
        return "The printer refused the access code. Check the code on the screen of the printer (Settings › LAN Only Mode).";
    default:
        return "The printer refused the connection.";
    }
}

/* Waits for the gate of the address. FALSE: the watch stopped. */
static gboolean gate_enter(ZgBambuWatch *w) {
    gboolean told = FALSE;
    while (!g_cancellable_is_cancelled(w->cancel)) {
        g_mutex_lock(&gate_lock);
        Gate *g = gate_of(w->gate);
        gboolean free_now = !g->busy && g_get_monotonic_time() >= g->next;
        gboolean other = g->busy;
        if (free_now) g->busy = TRUE;
        g_mutex_unlock(&gate_lock);
        if (free_now) return TRUE;
        if (other && !told) {
            told = TRUE;
            post(w, NULL, "Another connection to this address is open. This entry waits for it to end.");
        }
        g_usleep(100000);
    }
    return FALSE;
}

/* `failed`: a refusal or a drop, so the next try waits. */
static void gate_leave(ZgBambuWatch *w, gboolean failed) {
    g_mutex_lock(&gate_lock);
    Gate *g = gate_of(w->gate);
    g->busy = FALSE;
    g_clear_pointer(&g->report, g_free);
    if (failed) g->next = g_get_monotonic_time() + RETRY_S * G_USEC_PER_SEC;
    g_mutex_unlock(&gate_lock);
}

char *zg_bambu_link_report(const ZgPrinter *p) {
    char *host = host_of(p->url);
    char *key = g_strdup_printf("%s:%d", host, zg_bambu_port("MQTT", 8883));
    char *text = NULL;
    g_mutex_lock(&gate_lock);
    Gate *g = gates ? g_hash_table_lookup(gates, key) : NULL;
    gint64 left = g ? g->next - g_get_monotonic_time() : 0;
    if (g && g->busy) text = g_strdup(g->report ? g->report : "A connection to this printer is starting. Try again in a moment.");
    else if (left > 0) text = g_strdup_printf("The printer refused or dropped the last connection. The next try is in %d s.", (int)(left / G_USEC_PER_SEC) + 1);
    g_mutex_unlock(&gate_lock);
    g_free(key);
    g_free(host);
    return text;
}

static gpointer run(gpointer data) {
    ZgBambuWatch *w = data;
    GError *error = NULL;
    int port = zg_bambu_port("MQTT", 8883);
    gboolean holding = FALSE;
    GIOStream *io = NULL;
    zs_mqtt_reader *r = NULL;
    while (!g_cancellable_is_cancelled(w->cancel)) {
        if (!gate_enter(w)) break;
        holding = TRUE;
        g_clear_error(&error);
        g_clear_pointer(&r, zs_mqtt_reader_free);
        r = zs_mqtt_reader_new();
        char *seen = NULL;
        io = zg_bambu_connect(w->address, port, w->pin, &seen, w->cancel, &error);
        if (io && seen && !w->pin[0]) {
            /* The first connection: the next ones need this certificate. */
            g_free(w->pin);
            w->pin = g_strdup(seen);
            zg_bambu_trust_first(w->id, seen);
        }
        g_free(seen);
        if (!io) goto retry;
        GSocket *sock = g_socket_connection_get_socket(G_SOCKET_CONNECTION(io));
        g_socket_set_timeout(sock, READ_TIMEOUT_S);
        GInputStream *in = g_io_stream_get_input_stream(io);
        GOutputStream *out = g_io_stream_get_output_stream(io);
        uint8_t *p = NULL;
        size_t n = 0;
        char *id = g_strdup_printf("zslice-%08x", g_random_int());
        int rc = zs_mqtt_connect_packet(id, "bblp", w->code, KEEPALIVE_S, &p, &n);
        g_free(id);
        if (rc != ZS_OK || !write_packet(out, p, n, w->cancel, &error)) goto retry;
        gboolean subscribed = FALSE, idle = FALSE;
        gint64 last = g_get_monotonic_time();
        int idles = 0;
        while (!g_cancellable_is_cancelled(w->cancel)) {
            zs_mqtt_packet pk;
            int got;
            while ((got = zs_mqtt_reader_next(r, &pk)) == 1) {
                if (pk.kind == 2) {
                    if (pk.return_code != 0) {
                        post(w, NULL, connack_text((guint8)pk.return_code));
                        /* A wrong code stays wrong: no retry. */
                        g_clear_object(&io);
                        goto done;
                    }
                    /* SUBSCRIBE to the report topic, QoS 0. */
                    char *topic = g_strdup_printf("device/%s/report", w->serial);
                    rc = zs_mqtt_subscribe_packet(topic, 1, &p, &n);
                    g_free(topic);
                    if (rc != ZS_OK || !write_packet(out, p, n, w->cancel, &error)) goto retry;
                    subscribed = TRUE;
                } else if (pk.kind == 3 && pk.payload) {
                    GBytes *payload = g_bytes_new(pk.payload, pk.payload_len);
                    post(w, payload, NULL);
                    g_bytes_unref(payload);
                }
            }
            if (got < 0) {
                g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_FAILED, "The printer did not answer as an MQTT broker.");
                goto retry;
            }
            if (!read_more(in, r, &idle, w->cancel, &error)) goto retry;
            if (idle && !subscribed && ++idles >= 3) {
                g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "no answer to the login");
                goto retry;
            }
            if (subscribed && g_get_monotonic_time() - last > PING_S * G_USEC_PER_SEC) {
                static const guint8 ping[2] = {0xC0, 0};
                if (!g_output_stream_write_all(out, ping, 2, NULL, w->cancel, &error)) goto retry;
                last = g_get_monotonic_time();
            }
        }
        {
            static const guint8 bye[2] = {0xE0, 0};
            g_output_stream_write_all(out, bye, 2, NULL, NULL, NULL);
        }
        g_clear_object(&io);
        gate_leave(w, FALSE);
        holding = FALSE;
        break;
    retry:
        g_clear_object(&io);
        gate_leave(w, !g_cancellable_is_cancelled(w->cancel));
        holding = FALSE;
        if (g_cancellable_is_cancelled(w->cancel)) break;
        {
            char *m = g_strdup_printf("The printer did not answer (%s). Check that it is on, in LAN mode, and at this address.",
                                      error ? error->message : "no reason");
            post(w, NULL, m);
            g_free(m);
        }
        /* The gate holds the next try for RETRY_S. */
    }
done:
    if (holding) gate_leave(w, TRUE);
    g_clear_pointer(&r, zs_mqtt_reader_free);
    g_clear_error(&error);
    watch_unref(w);
    return NULL;
}

ZgBambuWatch *zg_bambu_watch(const ZgPrinter *p, ZgBambuFn fn, gpointer data) {
    const char *why = !p->url[0] ? "Set the IP address of the printer."
                    : !p->serial[0] ? "Set the serial number of the printer."
                    : !p->api_key[0] ? "Set the access code of the printer."
                                     : NULL;
    if (why) {
        fn(NULL, why, data);
        return NULL;
    }
    ZgBambuWatch *w = g_new0(ZgBambuWatch, 1);
    w->refs = 2; /* the caller and the thread */
    w->cancel = g_cancellable_new();
    /* An address with a scheme or a port: the host only. */
    w->address = host_of(p->url);
    w->gate = g_strdup_printf("%s:%d", w->address, zg_bambu_port("MQTT", 8883));
    w->serial = g_strstrip(g_strdup(p->serial));
    w->code = g_strstrip(g_strdup(p->api_key));
    w->id = g_strdup(p->id);
    w->pin = g_strdup(p->tls_pin ? p->tls_pin : "");
    w->fn = fn;
    w->data = data;
    w->status = zs_printer_status_new();
    GThread *t = g_thread_new("zslice-bambu", run, w);
    g_thread_unref(t);
    return w;
}

void zg_bambu_watch_stop(ZgBambuWatch *w) {
    if (!w) return;
    w->stopped = TRUE;
    if (w->timer) g_source_remove(w->timer);
    w->timer = 0;
    g_cancellable_cancel(w->cancel);
    watch_unref(w);
}

/* ---- the serial number from the certificate ---- */

static void serial_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancel) {
    const char *address = data;
    GError *e = NULL;
    char *pin = NULL;
    /* No pin: the user reads the serial number to trust this printer. */
    GIOStream *io = zg_bambu_connect(address, zg_bambu_port("MQTT", 8883), NULL, &pin, cancel, &e);
    if (!io) {
        g_free(pin);
        g_task_return_error(task, e);
        return;
    }
    char *serial = NULL;
    GTlsCertificate *cert = G_IS_TCP_WRAPPER_CONNECTION(io) ? g_tls_connection_get_peer_certificate(G_TLS_CONNECTION(g_tcp_wrapper_connection_get_base_io_stream(G_TCP_WRAPPER_CONNECTION(io)))) : NULL;
    if (cert) {
        char *dn = g_tls_certificate_get_subject_name(cert);
        /* "CN=20P5AJ670602796" or "...,CN=<serial>,...". */
        const char *cn = dn ? strstr(dn, "CN=") : NULL;
        if (cn) serial = g_strndup(cn + 3, strcspn(cn + 3, ",+/"));
        g_free(dn);
    }
    g_io_stream_close(io, NULL, NULL);
    g_object_unref(io);
    /* The serial number goes in an MQTT topic and a file name: letters and
     * digits only. */
    gboolean ok = serial && serial[0] && pin;
    for (const char *s = serial; ok && *s; s++) ok = g_ascii_isalnum(*s);
    if (ok) {
        char **pair = g_new0(char *, 3);
        pair[0] = serial;
        pair[1] = pin;
        g_task_return_pointer(task, pair, (GDestroyNotify)g_strfreev);
    } else {
        g_free(serial);
        g_free(pin);
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_FAILED, "The certificate of the printer has no serial number.");
    }
}

void zg_bambu_read_serial(const char *address, GCancellable *cancel, GAsyncReadyCallback done, gpointer data) {
    const char *a = address;
    if (strstr(a, "://")) a = strstr(a, "://") + 3;
    GTask *t = g_task_new(NULL, cancel, done, data);
    g_task_set_task_data(t, g_strndup(a, strcspn(a, "/:")), g_free);
    g_task_run_in_thread(t, serial_thread);
    g_object_unref(t);
}

char *zg_bambu_read_serial_finish(GAsyncResult *res, char **pin, GError **error) {
    char **pair = g_task_propagate_pointer(G_TASK(res), error);
    if (!pair) {
        if (pin) *pin = NULL;
        return NULL;
    }
    char *serial = pair[0];
    if (pin) *pin = pair[1];
    else g_free(pair[1]);
    g_free(pair);
    return serial;
}

