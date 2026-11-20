/* printer-link.c: see printer-link.h.
 *
 * The APIs: OctoPrint REST API (docs.octoprint.org, /api/printer,
 * /api/printerprofiles, /api/job, /api/files/local); Moonraker API
 * (moonraker.readthedocs.io, /printer/objects/query, /server/files/upload);
 * printdeck (../printdeck, deck/internal/octoapi); the App Keys flow of
 * OctoPrint (/plugin/appkeys/request). See REFERENCES.md.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "printer-link.h"

#include "key-header.h"
#include "signing.h"

#include <errno.h>
#include <fcntl.h>
#include <json-glib/json-glib.h>
#include <libsoup/soup.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static SoupSession *session(void) {
    static SoupSession *s;
    if (!s) {
        s = soup_session_new();
        soup_session_set_timeout(s, 15);
        soup_session_set_user_agent(s, "zslice");
    }
    return s;
}

void zg_printer_info_free(ZgPrinterInfo *info) {
    if (!info) return;
    g_free(info->state);
    g_free(info->material);
    g_free(info->spool);
    g_free(info->spool_id);
    g_free(info->spool_color);
    g_strfreev(info->spools);
    for (size_t i = 0; i < info->n_rolls; i++) {
        g_free(info->rolls[i].id);
        g_free(info->rolls[i].name);
        g_free(info->rolls[i].material);
        g_free(info->rolls[i].color);
    }
    g_free(info->rolls);
    g_free(info->job);
    zs_printer_status_free(info->core);
    g_free(info);
}

static char *join_url(const ZgPrinter *p, const char *path) {
    const char *base = p->url;
    size_t n = strlen(base);
    while (n > 0 && base[n - 1] == '/') n--;
    gboolean scheme = g_str_has_prefix(base, "http://") || g_str_has_prefix(base, "https://");
    return g_strdup_printf("%s%.*s%s", scheme ? "" : "http://", (int)n, base, path);
}

static SoupMessage *request(const ZgPrinter *p, const char *method, const char *path) {
    char *url = join_url(p, path);
    SoupMessage *msg = soup_message_new(method, url);
    g_free(url);
    zg_soup_add_key(msg, p->api_key);
    return msg;
}

/* ---- JSON helpers ---- */

static JsonNode *path_get(JsonNode *root, const char *dotted) {
    JsonNode *n = root;
    char **parts = g_strsplit(dotted, ".", -1);
    for (int i = 0; parts[i] && n; i++) {
        if (!JSON_NODE_HOLDS_OBJECT(n)) { n = NULL; break; }
        n = json_object_get_member(json_node_get_object(n), parts[i]);
    }
    g_strfreev(parts);
    return n;
}

static double num(JsonNode *root, const char *dotted) {
    JsonNode *n = path_get(root, dotted);
    return n && JSON_NODE_HOLDS_VALUE(n) && json_node_get_value_type(n) != G_TYPE_STRING ? json_node_get_double(n) : 0;
}

static char *str(JsonNode *root, const char *dotted) {
    JsonNode *n = path_get(root, dotted);
    if (!n || !JSON_NODE_HOLDS_VALUE(n) || json_node_get_value_type(n) != G_TYPE_STRING) return NULL;
    const char *s = json_node_get_string(n);
    return s && s[0] ? g_strdup(s) : NULL;
}

/* ---- query: a chain of GET requests ---- */

typedef struct {
    ZgPrinter p; /* a copy of the strings */
    GCancellable *cancel;
    ZgInfoFn fn;
    ZgCameraFn cam_fn; /* a read of the camera, in place of fn */
    gpointer data;
    ZgPrinterInfo *info;
    /* The requests (from the core), NULL at the end, and the status that
     * the core reads from the replies. */
    char **paths;
    int kind;
    zs_printer_status *status;
    int step;
} Query;

static void query_free(Query *q) {
    g_free(q->p.id);
    g_free(q->p.name);
    g_free(q->p.url);
    g_free(q->p.api_key);
    g_free(q->p.device);
    g_free(q->p.serial);
    if (q->cancel) g_object_unref(q->cancel);
    g_strfreev(q->paths);
    zs_printer_status_free(q->status);
    zg_printer_info_free(q->info);
    g_free(q);
}

static void query_next(Query *q);

static char *dup_or_null(const char *t) {
    return t && t[0] ? g_strdup(t) : NULL;
}

/* The status of the core (zs_printer_status) as the info of the app. */
static void fill_info(ZgPrinterInfo *in, const zs_printer_status *st) {
    zs_printer_info i;
    if (zs_printer_status_get(st, &i) != ZS_OK) return;
    g_free(in->state);
    in->state = dup_or_null(i.state);
    in->bed_x = i.bed_x;
    in->bed_y = i.bed_y;
    in->height = i.height;
    in->nozzle = i.nozzle;
    in->material = dup_or_null(i.material);
    in->diameter = i.diameter;
    in->spool = dup_or_null(i.spool.name);
    in->spool_id = dup_or_null(i.spool.id);
    in->spool_color = dup_or_null(i.spool.color);
    in->spool_left = i.spool.left;
    in->spool_price = i.spool_price;
    in->spool_full = i.spool_full;
    in->max_velocity = i.max_velocity;
    in->max_accel = i.max_accel;
    in->corner_velocity = i.corner_velocity;
    in->max_z_velocity = i.max_z_velocity;
    in->max_z_accel = i.max_z_accel;
    if (i.roll_count > 0) {
        in->spools = g_new0(char *, i.roll_count + 1);
        in->rolls = g_new0(ZgRoll, i.roll_count + 1);
        in->n_rolls = i.roll_count;
        for (size_t k = 0; k < i.roll_count; k++) {
            zs_printer_roll r;
            if (zs_printer_status_roll(st, k, &r) != ZS_OK) continue;
            in->rolls[k].id = dup_or_null(r.id);
            in->rolls[k].name = dup_or_null(r.name);
            in->rolls[k].material = dup_or_null(r.material);
            in->rolls[k].color = dup_or_null(r.color);
            in->rolls[k].left = r.left;
            in->spools[k] = r.material[0] ? g_strdup_printf("%s (%s)", r.name[0] ? r.name : "?", r.material) : g_strdup(r.name[0] ? r.name : "?");
        }
    }
    in->job = dup_or_null(i.job);
    in->progress = i.progress;
    in->time_left = i.time_left;
    in->layer = i.layer;
    in->layers = i.layers;
}

/* The end of a query: the info, the camera, or an error. */
static void query_fail(Query *q, const char *error) {
    if (q->cam_fn) q->cam_fn(NULL, NULL, error, q->data);
    else q->fn(NULL, error, q->data);
}

static void on_query_reply(GObject *source, GAsyncResult *res, gpointer data) {
    Query *q = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    const char *path = q->paths[q->step];
    if (!body) {
        query_fail(q, error->message);
        g_error_free(error);
        query_free(q);
        return;
    }
    guint status = soup_message_get_status(msg);
    if (status == 401 || status == 403) {
        query_fail(q, "The printer did not accept the API key.");
        g_bytes_unref(body);
        query_free(q);
        return;
    }
    if (status >= 200 && status < 300) {
        gsize len = 0;
        const char *text = g_bytes_get_data(body, &len);
        zs_printer_status_feed(q->status, q->kind, path, text, len);
    } else if (q->step == 0) {
        char *m = g_strdup_printf("The printer answered %u %s.", status, soup_message_get_reason_phrase(msg));
        query_fail(q, m);
        g_free(m);
        g_bytes_unref(body);
        query_free(q);
        return;
    }
    g_bytes_unref(body);
    q->step++;
    query_next(q);
}

/* An address of the camera, absolute: a relative one is on the printer. */
static char *camera_url(const ZgPrinter *p, const char *u) {
    if (!u || !u[0]) return NULL;
    if (strstr(u, "://")) return g_strdup(u);
    char *base = join_url(p, "/");
    GUri *b = g_uri_parse(base, G_URI_FLAGS_ENCODED, NULL);
    g_free(base);
    if (!b) return NULL;
    GUri *r = g_uri_parse_relative(b, u, G_URI_FLAGS_ENCODED, NULL);
    g_uri_unref(b);
    if (!r) return NULL;
    char *out = g_uri_to_string(r);
    g_uri_unref(r);
    return out;
}

static void query_next(Query *q) {
    if (!q->paths[q->step] && q->cam_fn) {
        zs_printer_camera cam = {0};
        char *stream = NULL, *snapshot = NULL;
        if (zs_printer_status_camera(q->status, &cam) == ZS_OK) {
            stream = camera_url(&q->p, cam.stream);
            snapshot = camera_url(&q->p, cam.snapshot);
        }
        q->cam_fn(stream, snapshot, NULL, q->data);
        g_free(stream);
        g_free(snapshot);
        query_free(q);
        return;
    }
    if (!q->paths[q->step]) {
        fill_info(q->info, q->status);
        /* The info keeps the status of the core. */
        q->info->core = q->status;
        q->status = NULL;
        ZgPrinterInfo *info = q->info;
        q->info = NULL;
        q->fn(info, NULL, q->data);
        query_free(q);
        return;
    }
    SoupMessage *msg = request(&q->p, "GET", q->paths[q->step]);
    if (!msg) {
        query_fail(q, "The address is not valid.");
        query_free(q);
        return;
    }
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, q->cancel, on_query_reply, q);
    g_object_unref(msg);
}

static Query *query_new(const ZgPrinter *p, GCancellable *cancel) {
    Query *q = g_new0(Query, 1);
    q->p = *p;
    q->p.id = g_strdup(p->id);
    q->p.name = g_strdup(p->name);
    q->p.url = g_strdup(p->url);
    q->p.api_key = g_strdup(p->api_key);
    q->p.device = g_strdup(p->device);
    q->p.serial = g_strdup(p->serial);
    q->p.tls_pin = NULL; /* not used: the pin is in the printer list */
    q->cancel = cancel ? g_object_ref(cancel) : NULL;
    q->info = g_new0(ZgPrinterInfo, 1);
    q->info->time_left = -1;
    return q;
}

void zg_link_query(const ZgPrinter *p, GCancellable *cancel, ZgInfoFn fn, gpointer data) {
    switch (p->kind) {
    case ZG_LINK_NONE:
        fn(NULL, "This printer has no connection.", data);
        return;
    case ZG_LINK_BAMBU:
        /* A Bambu Lab printer reports over MQTT (bambu-link.h). */
        fn(NULL, "A Bambu Lab printer gives its status on the Printers page.", data);
        return;
    case ZG_LINK_USB: {
        /* A serial port has no API: only check that it opens. */
        int fd = p->device[0] ? open(p->device, O_RDWR | O_NOCTTY | O_NONBLOCK) : -1;
        if (fd < 0) {
            char *m = g_strdup_printf("The port %s does not open: %s", p->device[0] ? p->device : "(none)", g_strerror(errno));
            fn(NULL, m, data);
            g_free(m);
            return;
        }
        close(fd);
        ZgPrinterInfo *info = g_new0(ZgPrinterInfo, 1);
        info->state = g_strdup("Port opens");
        info->time_left = -1;
        fn(info, NULL, data);
        return;
    }
    default:
        break;
    }
    if (!p->url[0]) {
        fn(NULL, "Set the address of the printer.", data);
        return;
    }
    Query *q = query_new(p, cancel);
    q->fn = fn;
    q->data = data;
    /* The kinds of the core: 1 OctoPrint, 2 printdeck, 3 Moonraker. */
    q->kind = p->kind == ZG_LINK_MOONRAKER ? 3 : p->kind == ZG_LINK_PRINTDECK ? 2 : 1;
    q->paths = g_strsplit(zs_printer_status_paths(q->kind), "\n", -1);
    q->status = zs_printer_status_new();
    query_next(q);
}

void zg_link_camera(const ZgPrinter *p, GCancellable *cancel, ZgCameraFn fn, gpointer data) {
    int kind = p->kind == ZG_LINK_MOONRAKER ? 3 : p->kind == ZG_LINK_PRINTDECK ? 2 : p->kind == ZG_LINK_OCTOPRINT ? 1 : 0;
    if (!kind || !p->url[0]) {
        fn(NULL, NULL, "This printer gives no camera over HTTP.", data);
        return;
    }
    Query *q = query_new(p, cancel);
    q->cam_fn = fn;
    q->data = data;
    q->kind = kind;
    q->paths = g_strsplit(zs_printer_camera_paths(kind), "\n", -1);
    q->status = zs_printer_status_new();
    query_next(q);
}

/* ---- the certificate of an https printer ---- */

/* The SHA-256 hash (hex) of the certificate, and the start of its
 * validity. NULL with no certificate. */
static char *cert_pin(SoupMessage *msg, gint64 *since) {
    GTlsCertificate *cert = msg ? soup_message_get_tls_peer_certificate(msg) : NULL;
    if (!cert) return NULL;
    GByteArray *der = NULL;
    g_object_get(cert, "certificate", &der, NULL);
    if (!der) return NULL;
    char *pin = g_compute_checksum_for_data(G_CHECKSUM_SHA256, der->data, der->len);
    g_byte_array_unref(der);
    GDateTime *t = g_tls_certificate_get_not_valid_before(cert);
    *since = t ? g_date_time_to_unix(t) : 0;
    if (t) g_date_time_unref(t);
    return pin;
}

static void set_pin(ZgPrinter *p, const char *pin, gint64 since) {
    g_free(p->tls_pin);
    p->tls_pin = g_strdup(pin);
    p->tls_since = since;
    zg_printers_save();
}

/* Checks the certificate of a reply of the printer `id` against its pin.
 * libsoup has checked the chain and the name already. The first https
 * reply sets the pin. A certificate for the same name with a later start
 * (a renewal: the deck gets a new one every 60 days) replaces it. Any
 * other change returns FALSE and the warning in `message`. */
static gboolean pin_check(const char *id, SoupMessage *msg, char **message) {
    ZgPrinter *p = id ? zg_printers_find(id) : NULL;
    gint64 since = 0;
    char *pin = p ? cert_pin(msg, &since) : NULL;
    if (!pin) return TRUE;
    gboolean ok = TRUE;
    if (!p->tls_pin || !p->tls_pin[0] || (since > p->tls_since && strcmp(pin, p->tls_pin) != 0)) {
        set_pin(p, pin, since);
    } else if (strcmp(pin, p->tls_pin) != 0) {
        ok = FALSE;
        *message = g_strdup_printf("The certificate of %s changed to an older or another one. A device on the network can claim to be the printer. "
                                   "The file did not go out. If you set up the printer again, press Get a key in its settings to trust it again.", p->name);
    }
    g_free(pin);
    return ok;
}

/* ---- send over the network ---- */

typedef struct {
    ZgDoneFn done;
    gpointer data;
    char *id; /* the printer, for the pin */
    ZgLinkKind kind;
} Send;

static void on_sent(GObject *source, GAsyncResult *res, gpointer data) {
    Send *s = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    char *warning = NULL;
    if (!body) {
        s->done(FALSE, error->message, s->data);
        g_error_free(error);
    } else if (!pin_check(s->id, msg, &warning)) {
        /* A new connection with another certificate after the check of
         * zg_link_send: the file went out. */
        char *m = g_strdup_printf("%s (The file went to the printer before this check.)", warning);
        s->done(FALSE, m, s->data);
        g_free(m);
        g_free(warning);
        g_bytes_unref(body);
    } else {
        guint status = soup_message_get_status(msg);
        /* An upload of OctoPrint and printdeck answers JSON with the stored
         * file (files.local, or done). Another 2xx answer (a web page, a
         * proxy) stored nothing: a send once said "sent", and no file came
         * to the deck. */
        gboolean stored = TRUE;
        if (status >= 200 && status < 300 && s->kind != ZG_LINK_MOONRAKER) {
            JsonParser *parser = json_parser_new();
            gsize len = 0;
            const char *text = g_bytes_get_data(body, &len);
            stored = FALSE;
            if (json_parser_load_from_data(parser, text, (gssize)len, NULL)) {
                JsonNode *root = json_parser_get_root(parser);
                JsonNode *done = path_get(root, "done");
                stored = path_get(root, "files.local") != NULL || (done && JSON_NODE_HOLDS_VALUE(done) && json_node_get_value_type(done) == G_TYPE_BOOLEAN && json_node_get_boolean(done));
            }
            g_object_unref(parser);
        }
        if (status >= 200 && status < 300 && stored) {
            s->done(TRUE, NULL, s->data);
        } else if (status >= 200 && status < 300) {
            char *m = g_strdup_printf("The printer answered %u, but not with a stored file. The file may not be on the printer: check its address in Preferences › Printers.", status);
            s->done(FALSE, m, s->data);
            g_free(m);
        } else {
            /* The OctoPrint API has the reason in {"error": "..."}. */
            char *reason = NULL;
            JsonParser *parser = json_parser_new();
            gsize len = 0;
            const char *text = g_bytes_get_data(body, &len);
            if (json_parser_load_from_data(parser, text, (gssize)len, NULL)) reason = str(json_parser_get_root(parser), "error");
            g_object_unref(parser);
            char *m = g_strdup_printf("The printer answered %u: %s", status, reason ? reason : soup_message_get_reason_phrase(msg));
            s->done(FALSE, m, s->data);
            g_free(m);
            g_free(reason);
        }
        g_bytes_unref(body);
    }
    g_free(s->id);
    g_free(s);
}

static void send_serial(const ZgPrinter *p, GBytes *gcode, GCancellable *cancel, ZgProgressFn progress,
                        ZgDoneFn done, gpointer data);

/* ---- the estimate of a printdeck printer ---- */

typedef struct {
    ZgPrinter *printer; /* a copy of the fields that the request uses */
    GBytes *gcode;
    GCancellable *cancel;
    ZgEstimateFn fn;
    gpointer data;
} Estimate;

static void estimate_free(Estimate *e) {
    g_free(e->printer->url);
    g_free(e->printer->api_key);
    g_free(e->printer);
    if (e->gcode) g_bytes_unref(e->gcode);
    if (e->cancel) g_object_unref(e->cancel);
    g_free(e);
}

/* On a worker thread: the G-code with gzip (a file of some MB goes down
 * to a few hundred kB). */
static void gzip_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancel) {
    GBytes *in = data;
    GZlibCompressor *z = g_zlib_compressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP, 6);
    GOutputStream *mem = g_memory_output_stream_new_resizable();
    GOutputStream *out = g_converter_output_stream_new(mem, G_CONVERTER(z));
    gsize len = 0;
    const void *p = g_bytes_get_data(in, &len);
    GError *error = NULL;
    if (!g_output_stream_write_all(out, p, len, NULL, cancel, &error) || !g_output_stream_close(out, cancel, &error)) {
        g_task_return_error(task, error);
    } else {
        g_task_return_pointer(task, g_memory_output_stream_steal_as_bytes(G_MEMORY_OUTPUT_STREAM(mem)), (GDestroyNotify)g_bytes_unref);
    }
    g_object_unref(out);
    g_object_unref(mem);
    g_object_unref(z);
}

static void on_estimate_reply(GObject *source, GAsyncResult *res, gpointer data) {
    Estimate *e = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    if (!body) {
        if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) e->fn(NULL, error->message, e->data);
        g_error_free(error);
        estimate_free(e);
        return;
    }
    guint status = msg ? soup_message_get_status(msg) : 0;
    JsonParser *parser = json_parser_new();
    gsize len = 0;
    const char *text = g_bytes_get_data(body, &len);
    if (status == 200 && json_parser_load_from_data(parser, text, (gssize)len, NULL)) {
        JsonNode *root = json_parser_get_root(parser);
        ZgEstimate est = {.moves = num(root, "moves"), .prep = num(root, "prep"), .total = num(root, "total"),
                          .plan_prints = (int)num(root, "plan_prints")};
        e->fn(est.total > 0 ? &est : NULL, est.total > 0 ? NULL : "no estimate", e->data);
    } else {
        char *m = g_strdup_printf("The printer answered %u", status);
        e->fn(NULL, m, e->data);
        g_free(m);
    }
    g_object_unref(parser);
    g_bytes_unref(body);
    estimate_free(e);
}

static void on_gzipped(GObject *source, GAsyncResult *res, gpointer data) {
    Estimate *e = data;
    GError *error = NULL;
    GBytes *zipped = g_task_propagate_pointer(G_TASK(res), &error);
    if (!zipped) {
        if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) e->fn(NULL, error->message, e->data);
        g_error_free(error);
        estimate_free(e);
        return;
    }
    SoupMessage *msg = request(e->printer, "POST", "/api/plugin/printdeck/estimate");
    if (!msg) {
        g_bytes_unref(zipped);
        e->fn(NULL, "The address of the printer is not valid.", e->data);
        estimate_free(e);
        return;
    }
    soup_message_headers_append(soup_message_get_request_headers(msg), "Content-Encoding", "gzip");
    soup_message_set_request_body_from_bytes(msg, "text/plain", zipped);
    g_bytes_unref(zipped);
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_LOW, e->cancel, on_estimate_reply, e);
    g_object_unref(msg);
}

void zg_link_estimate(const ZgPrinter *p, GBytes *gcode, GCancellable *cancel, ZgEstimateFn fn, gpointer data) {
    if (p->kind != ZG_LINK_PRINTDECK || !p->url || !p->url[0]) {
        fn(NULL, "no estimates", data);
        return;
    }
    Estimate *e = g_new0(Estimate, 1);
    e->printer = g_new0(ZgPrinter, 1);
    e->printer->kind = p->kind;
    e->printer->url = g_strdup(p->url);
    e->printer->api_key = g_strdup(p->api_key ? p->api_key : "");
    e->gcode = g_bytes_ref(gcode);
    e->cancel = cancel ? g_object_ref(cancel) : NULL;
    e->fn = fn;
    e->data = data;
    GTask *task = g_task_new(NULL, cancel, on_gzipped, e);
    g_task_set_task_data(task, g_bytes_ref(gcode), (GDestroyNotify)g_bytes_unref);
    g_task_run_in_thread(task, (GTaskThreadFunc)gzip_thread);
    g_object_unref(task);
}

/* ---- an API key from the printer (App Keys) ---- */

typedef struct {
    char *base; /* the URL of /plugin/appkeys/request */
    char *id;   /* the printer, for the pin */
    char *token;
    gint64 t0;
    guint timer;
    GCancellable *cancel;
    ZgWaitFn wait;
    ZgKeyFn done;
    gpointer data;
} KeyRequest;

/* The printer keeps a request for 2 minutes. */
enum { KEY_WAIT_S = 125 };

static void key_free(KeyRequest *k) {
    if (k->timer) g_source_remove(k->timer);
    g_free(k->base);
    g_free(k->id);
    g_free(k->token);
    g_clear_object(&k->cancel);
    g_free(k);
}

static void key_end(KeyRequest *k, gboolean ok, const char *key, const char *message) {
    if (!g_cancellable_is_cancelled(k->cancel)) k->done(ok, key, message, k->data);
    key_free(k);
}

/* The member `name` of a JSON object in `body`, or NULL. Free with g_free. */
static char *json_member(GBytes *body, const char *name) {
    gsize len = 0;
    const char *text = g_bytes_get_data(body, &len);
    JsonParser *parser = json_parser_new();
    char *out = NULL;
    if (json_parser_load_from_data(parser, text, (gssize)len, NULL)) out = str(json_parser_get_root(parser), name);
    g_object_unref(parser);
    return out;
}

static gboolean key_poll(gpointer data);

static void on_key_poll(GObject *source, GAsyncResult *res, gpointer data) {
    KeyRequest *k = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    if (!body) {
        key_end(k, FALSE, NULL, error->message);
        g_error_free(error);
        return;
    }
    guint status = msg ? soup_message_get_status(msg) : 0;
    if (status == 202) {
        /* The user has not decided yet. */
        g_bytes_unref(body);
        if ((g_get_monotonic_time() - k->t0) / G_USEC_PER_SEC >= KEY_WAIT_S) {
            key_end(k, FALSE, NULL, "No answer on the printer in 2 minutes.");
            return;
        }
        k->timer = g_timeout_add_seconds(1, key_poll, k);
        return;
    }
    if (status == 404) {
        g_bytes_unref(body);
        key_end(k, FALSE, NULL, "The printer did not allow it (Deny), or the request waited too long.");
        return;
    }
    if (status != 200) {
        g_bytes_unref(body);
        char *m = g_strdup_printf("The printer answered %u.", status);
        key_end(k, FALSE, NULL, m);
        g_free(m);
        return;
    }
    char *key = json_member(body, "api_key");
    char *trusted = json_member(body, "trusted_key");
    g_bytes_unref(body);
    /* A pairing trusts the certificate of now. */
    gint64 since = 0;
    char *pin = cert_pin(msg, &since);
    ZgPrinter *p = k->id ? zg_printers_find(k->id) : NULL;
    if (pin && p) set_pin(p, pin, since);
    g_free(pin);
    if (key && key[0] && trusted)
        key_end(k, TRUE, key, "The printer gave zslice a key, and trusts the prints that zslice signs.");
    else if (key && key[0]) key_end(k, TRUE, key, "The printer gave zslice a key.");
    else key_end(k, FALSE, NULL, "The printer gave no key.");
    g_free(key);
    g_free(trusted);
}

static gboolean key_poll(gpointer data) {
    KeyRequest *k = data;
    k->timer = 0;
    if (g_cancellable_is_cancelled(k->cancel)) {
        key_free(k);
        return G_SOURCE_REMOVE;
    }
    k->wait((int)((g_get_monotonic_time() - k->t0) / G_USEC_PER_SEC), k->data);
    char *escaped = g_uri_escape_string(k->token, NULL, FALSE);
    char *url = g_strdup_printf("%s/%s", k->base, escaped);
    g_free(escaped);
    SoupMessage *msg = soup_message_new("GET", url);
    g_free(url);
    if (!msg) {
        key_end(k, FALSE, NULL, "The address of the printer is not valid.");
        return G_SOURCE_REMOVE;
    }
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, k->cancel, on_key_poll, k);
    g_object_unref(msg);
    return G_SOURCE_REMOVE;
}

static void on_key_token(GObject *source, GAsyncResult *res, gpointer data) {
    KeyRequest *k = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    if (!body) {
        key_end(k, FALSE, NULL, error->message);
        g_error_free(error);
        return;
    }
    guint status = msg ? soup_message_get_status(msg) : 0;
    if (status == 404) {
        g_bytes_unref(body);
        key_end(k, FALSE, NULL, "The printer does not give keys to apps (App Keys is off or missing).");
        return;
    }
    if (status < 200 || status >= 300) {
        g_bytes_unref(body);
        char *m = g_strdup_printf("The printer answered %u.", status);
        key_end(k, FALSE, NULL, m);
        g_free(m);
        return;
    }
    k->token = json_member(body, "app_token");
    g_bytes_unref(body);
    if (!k->token || !k->token[0]) {
        key_end(k, FALSE, NULL, "The printer gave no request token.");
        return;
    }
    k->t0 = g_get_monotonic_time();
    k->wait(0, k->data);
    k->timer = g_timeout_add_seconds(1, key_poll, k);
}

void zg_link_request_key(const ZgPrinter *p, GCancellable *cancel, ZgWaitFn wait, ZgKeyFn done, gpointer data) {
    if (!p->url || !p->url[0]) {
        done(FALSE, NULL, "No address.", data);
        return;
    }
    if (p->kind == ZG_LINK_MOONRAKER) {
        done(FALSE, NULL, "Moonraker gives no API keys this way: it needs none, or the key of its config.", data);
        return;
    }
    KeyRequest *k = g_new0(KeyRequest, 1);
    k->base = join_url(p, "/plugin/appkeys/request");
    k->id = g_strdup(p->id);
    k->cancel = cancel ? g_object_ref(cancel) : g_cancellable_new();
    k->wait = wait;
    k->done = done;
    k->data = data;
    SoupMessage *msg = soup_message_new("POST", k->base);
    if (!msg) {
        key_end(k, FALSE, NULL, "The address of the printer is not valid.");
        return;
    }
    /* printdeck: the public key of the signatures too. The deck trusts it
     * after "Allow". */
    JsonBuilder *jb = json_builder_new();
    json_builder_begin_object(jb);
    json_builder_set_member_name(jb, "app");
    json_builder_add_string_value(jb, "zslice");
    const char *pub = p->kind == ZG_LINK_PRINTDECK ? zg_signing_public_key() : NULL;
    if (pub) {
        json_builder_set_member_name(jb, "public_key");
        json_builder_add_string_value(jb, pub);
    }
    json_builder_end_object(jb);
    JsonNode *root = json_builder_get_root(jb);
    char *text = json_to_string(root, FALSE);
    json_node_unref(root);
    g_object_unref(jb);
    GBytes *bytes = g_bytes_new_take(text, strlen(text));
    soup_message_set_request_body_from_bytes(msg, "application/json", bytes);
    g_bytes_unref(bytes);
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, k->cancel, on_key_token, k);
    g_object_unref(msg);
}

/* A send that waits for the check of the certificate. */
typedef struct {
    ZgPrinter p; /* a copy of the strings that the send uses */
    char *filename;
    GBytes *gcode;
    gboolean print;
    GCancellable *cancel;
    ZgDoneFn done;
    gpointer data;
} Upload;

static void upload_free(Upload *u) {
    g_free(u->p.id);
    g_free(u->p.name);
    g_free(u->p.url);
    g_free(u->p.api_key);
    g_free(u->filename);
    g_bytes_unref(u->gcode);
    g_clear_object(&u->cancel);
    g_free(u);
}

static void upload_now(Upload *u) {
    const ZgPrinter *p = &u->p;
    SoupMultipart *mp = soup_multipart_new(SOUP_FORM_MIME_TYPE_MULTIPART);
    soup_multipart_append_form_file(mp, "file", u->filename, "application/octet-stream", u->gcode);
    soup_multipart_append_form_string(mp, "print", u->print ? "true" : "false");
    const char *path = p->kind == ZG_LINK_MOONRAKER ? "/server/files/upload" : "/api/files/local";
    char *url = join_url(p, path);
    SoupMessage *msg = soup_message_new_from_multipart(url, mp);
    g_free(url);
    soup_multipart_free(mp);
    zg_soup_add_key(msg, p->api_key);
    Send *s = g_new0(Send, 1);
    s->done = u->done;
    s->data = u->data;
    s->id = g_strdup(p->id);
    s->kind = p->kind;
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, u->cancel, on_sent, s);
    g_object_unref(msg);
    upload_free(u);
}

static void on_pin_reply(GObject *source, GAsyncResult *res, gpointer data) {
    Upload *u = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    char *warning = NULL;
    if (!body) {
        u->done(FALSE, error->message, u->data);
        g_error_free(error);
        upload_free(u);
        return;
    }
    g_bytes_unref(body);
    if (!pin_check(u->p.id, msg, &warning)) {
        u->done(FALSE, warning, u->data);
        g_free(warning);
        upload_free(u);
        return;
    }
    upload_now(u);
}

/* The upload, after the checks: on https, a small request first for the
 * check of the certificate before the file goes out. */
static void send_start(Upload *u) {
    const ZgPrinter *p = &u->p;
    char *url = join_url(p, "");
    gboolean https = g_str_has_prefix(url, "https://");
    g_free(url);
    if (!https) {
        upload_now(u);
        return;
    }
    SoupMessage *msg = request(p, "GET", p->kind == ZG_LINK_MOONRAKER ? "/server/info" : "/api/version");
    if (!msg) {
        u->done(FALSE, "The address of the printer is not valid.", u->data);
        upload_free(u);
        return;
    }
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, u->cancel, on_pin_reply, u);
    g_object_unref(msg);
}

/* The path of a deck printer in `url` ("/printers/<id>", or "" for the
 * deck itself), and the length of the root before it. */
static const char *deck_path(const char *url, size_t *root_len) {
    const char *at = strstr(url, "/printers/");
    size_t n = strlen(url);
    while (n > 0 && url[n - 1] == '/') n--;
    if (!at || (size_t)(at - url) >= n) {
        *root_len = n;
        return "";
    }
    *root_len = (size_t)(at - url);
    return at;
}

/* TRUE when the words of one name are all in the other ("Bambu Lab X2D"
 * and "X2D"), with no case. */
static gboolean names_one(const char *a, const char *b) {
    if (!a || !b) return FALSE;
    char *x = g_utf8_casefold(a, -1), *y = g_utf8_casefold(b, -1);
    char **wa = g_regex_split_simple("[^a-z0-9]+", x, 0, 0);
    char **wb = g_regex_split_simple("[^a-z0-9]+", y, 0, 0);
    gboolean a_in_b = TRUE, b_in_a = TRUE, any_a = FALSE, any_b = FALSE;
    for (char **w = wa; *w; w++) {
        if (!**w) continue;
        any_a = TRUE;
        if (!g_strv_contains((const char *const *)wb, *w)) a_in_b = FALSE;
    }
    for (char **w = wb; *w; w++) {
        if (!**w) continue;
        any_b = TRUE;
        if (!g_strv_contains((const char *const *)wa, *w)) b_in_a = FALSE;
    }
    g_strfreev(wa);
    g_strfreev(wb);
    g_free(x);
    g_free(y);
    return any_a && any_b && (a_in_b || b_in_a);
}

static gboolean names_printer(const ZgDeckPrinter *d, const char *name) {
    return names_one(d->name, name) || names_one(d->label, name);
}

static gboolean same_name(const char *a, const char *b) {
    if (!a || !b) return FALSE;
    char *x = g_utf8_casefold(a, -1);
    char *y = g_utf8_casefold(b, -1);
    g_strstrip(x);
    g_strstrip(y);
    gboolean eq = g_strcmp0(x, y) == 0;
    g_free(x);
    g_free(y);
    return eq;
}

/* The answer of the deck list for a send: on a deck of more printers, the
 * address must be one of its printers, and the user's printer must not
 * have the name of another one. A print once went to the first printer of
 * a deck (its own address) in place of the one that the user picked. A
 * deck with no list cannot be checked: the send goes on. */
static void on_deck_check(GPtrArray *list, const char *error, gpointer data) {
    (void)error;
    Upload *u = data;
    if (!list || list->len < 2) {
        send_start(u);
        return;
    }
    size_t root_len = 0;
    char *path = g_strdup(deck_path(u->p.url, &root_len));
    size_t pl = strlen(path);
    while (pl > 0 && path[pl - 1] == '/') path[--pl] = 0;
    const ZgDeckPrinter *at = NULL, *other = NULL;
    for (guint i = 0; i < list->len; i++) {
        const ZgDeckPrinter *d = g_ptr_array_index(list, i);
        if (g_strcmp0(d->path, path) == 0) at = d;
    }
    for (guint i = 0; i < list->len; i++) {
        const ZgDeckPrinter *d = g_ptr_array_index(list, i);
        if (d != at && names_printer(d, u->p.name)) other = d;
    }
    char *why = NULL;
    if (!at) {
        why = g_strdup_printf("The deck has no printer at %s. Nothing was sent. Add the printer again from the deck.", path[0] ? path : "its own address");
    } else if (other && !names_printer(at, u->p.name)) {
        why = g_strdup_printf("%s is at %s on the deck, but the address of this printer leads to %s. Nothing was sent. Add %s again from the deck.", u->p.name, other->path, at->name, u->p.name);
    } else if (!path[0] && !names_printer(at, u->p.name) && !same_name(at->name, u->p.name)) {
        /* The address of the deck itself leads to its first printer: with
         * more printers on the deck, that must be the user's printer for
         * sure. A print for the X2D went to the TAZ this way. */
        why = g_strdup_printf("The address of %s is the deck itself, which prints on %s. zslice cannot tell that %s is %s. Nothing was sent. Add the printer again from the deck, and pick it from the list of the deck.", u->p.name, at->name, u->p.name, at->name);
    }
    g_free(path);
    if (why) {
        u->done(FALSE, why, u->data);
        g_free(why);
        upload_free(u);
        return;
    }
    send_start(u);
}

static void deck_check(Upload *u) {
    size_t root_len = 0;
    deck_path(u->p.url, &root_len);
    ZgPrinter root = u->p;
    root.url = g_strndup(u->p.url, root_len);
    zg_link_deck_printers(&root, u->cancel, on_deck_check, u);
    g_free(root.url);
}

void zg_link_send_wrapped(const ZgPrinter *p, const char *filename, GBytes *gcode, ZgWrapFn wrap, gpointer wrap_data,
                          gboolean print, GCancellable *cancel, ZgProgressFn progress, ZgDoneFn done, gpointer data) {
    if (p->kind == ZG_LINK_NONE) {
        done(FALSE, "This printer has no connection.", data);
        return;
    }
    if (p->kind == ZG_LINK_USB) {
        send_serial(p, gcode, cancel, progress, done, data);
        return;
    }
    if (p->kind == ZG_LINK_BAMBU) {
        /* The Linux app reads a Bambu Lab printer, and sends it nothing. */
        done(FALSE, "The Linux app cannot send prints to a Bambu Lab printer yet. Export the G-code, or use Bambu Studio or the macOS app.", data);
        return;
    }
    Upload *u = g_new0(Upload, 1);
    u->p.id = g_strdup(p->id);
    u->p.kind = p->kind;
    u->p.url = g_strdup(p->url);
    u->p.api_key = g_strdup(p->api_key);
    u->filename = g_strdup(filename);
    /* Each file that goes out has the signature of this install. */
    u->gcode = zg_sign_gcode(gcode);
    if (wrap) {
        GBytes *w = wrap(u->gcode, wrap_data);
        if (!w) {
            done(FALSE, "zslice could not make the .gcode.3mf file of the plate.", data);
            upload_free(u);
            return;
        }
        g_bytes_unref(u->gcode);
        u->gcode = w;
    }
    u->print = print;
    u->cancel = cancel ? g_object_ref(cancel) : NULL;
    u->done = done;
    u->data = data;
    u->p.name = g_strdup(p->name);
    /* A deck that drives more printers: first the check that the address
     * leads to the printer that the user picked. */
    if (p->kind == ZG_LINK_PRINTDECK) {
        deck_check(u);
        return;
    }
    send_start(u);
}

void zg_link_send(const ZgPrinter *p, const char *filename, GBytes *gcode, gboolean print, GCancellable *cancel,
                  ZgProgressFn progress, ZgDoneFn done, gpointer data) {
    zg_link_send_wrapped(p, filename, gcode, NULL, NULL, print, cancel, progress, done, data);
}

/* ---- USB: a serial port ---- */

typedef struct {
    char *device;
    int baud;
    GBytes *gcode;
    GCancellable *cancel;
    ZgProgressFn progress;
    ZgDoneFn done;
    gpointer data;
    /* The result, for the main thread. */
    gboolean ok;
    char *message;
    double fraction;
} Serial;

static speed_t baud_of(int baud) {
    switch (baud) {
    case 9600: return B9600;
    case 19200: return B19200;
    case 38400: return B38400;
    case 57600: return B57600;
    case 115200: return B115200;
    case 230400: return B230400;
#ifdef B250000
    case 250000: return B250000;
#endif
    case 460800: return B460800;
    case 500000: return B500000;
    case 1000000: return B1000000;
    default: return B115200;
    }
}

static gboolean report_progress(gpointer data) {
    Serial *s = data;
    if (s->progress) s->progress(s->fraction, s->data);
    return G_SOURCE_REMOVE;
}

static gboolean report_done(gpointer data) {
    Serial *s = data;
    s->done(s->ok, s->message, s->data);
    g_free(s->device);
    g_free(s->message);
    g_bytes_unref(s->gcode);
    if (s->cancel) g_object_unref(s->cancel);
    g_free(s);
    return G_SOURCE_REMOVE;
}

/* Reads until a line starts with "ok", or an error. The printer sends
 * other lines too (temperatures, echo). */
static gboolean wait_ok(int fd, GCancellable *cancel, char **error) {
    char line[256];
    size_t n = 0;
    gint64 deadline = g_get_monotonic_time() + 600 * G_USEC_PER_SEC; /* a long move or a heat-up */
    while (g_get_monotonic_time() < deadline) {
        if (cancel && g_cancellable_is_cancelled(cancel)) return FALSE;
        char c;
        ssize_t r = read(fd, &c, 1);
        if (r < 0 && errno != EAGAIN && errno != EINTR) {
            *error = g_strdup_printf("The port stopped: %s", g_strerror(errno));
            return FALSE;
        }
        if (r <= 0) {
            g_usleep(1000);
            continue;
        }
        if (c == '\n' || c == '\r') {
            line[n] = 0;
            if (g_str_has_prefix(line, "ok")) return TRUE;
            if (g_str_has_prefix(line, "Error") || g_str_has_prefix(line, "!!")) {
                *error = g_strdup_printf("The printer said: %s", line);
                return FALSE;
            }
            n = 0;
        } else if (n + 1 < sizeof line) {
            line[n++] = c;
        }
    }
    *error = g_strdup("The printer did not answer.");
    return FALSE;
}

static gpointer serial_thread(gpointer data) {
    Serial *s = data;
    int fd = open(s->device, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        s->message = g_strdup_printf("The port %s does not open: %s", s->device, g_strerror(errno));
        g_idle_add(report_done, s);
        return NULL;
    }
    struct termios t;
    tcgetattr(fd, &t);
    cfmakeraw(&t);
    cfsetispeed(&t, baud_of(s->baud));
    cfsetospeed(&t, baud_of(s->baud));
    t.c_cflag |= CLOCAL | CREAD;
    tcsetattr(fd, TCSANOW, &t);
    /* Most boards reset when the port opens: wait, and drop their start
     * text. */
    g_usleep(2 * G_USEC_PER_SEC);
    tcflush(fd, TCIOFLUSH);

    gsize len = 0;
    const char *text = g_bytes_get_data(s->gcode, &len);
    gsize pos = 0;
    gint64 last_report = 0;
    char *error = NULL;
    while (pos < len) {
        if (s->cancel && g_cancellable_is_cancelled(s->cancel)) {
            error = g_strdup("Canceled.");
            break;
        }
        const char *nl = memchr(text + pos, '\n', len - pos);
        gsize end = nl ? (gsize)(nl - text) : len;
        /* The command without the comment and the spaces. */
        gsize cut = end;
        const char *semi = memchr(text + pos, ';', end - pos);
        if (semi) cut = (gsize)(semi - text);
        while (cut > pos && (text[cut - 1] == ' ' || text[cut - 1] == '\r')) cut--;
        gsize start = pos;
        while (start < cut && text[start] == ' ') start++;
        pos = end + 1;
        if (cut <= start) continue;
        if (write(fd, text + start, cut - start) < 0 || write(fd, "\n", 1) < 0) {
            error = g_strdup_printf("The port stopped: %s", g_strerror(errno));
            break;
        }
        if (!wait_ok(fd, s->cancel, &error)) {
            if (!error) error = g_strdup("Canceled.");
            break;
        }
        gint64 now = g_get_monotonic_time();
        if (now - last_report > 250000) {
            last_report = now;
            s->fraction = (double)pos / (double)len;
            g_idle_add(report_progress, s);
        }
    }
    close(fd);
    s->ok = error == NULL;
    s->message = error;
    g_idle_add(report_done, s);
    return NULL;
}

static void send_serial(const ZgPrinter *p, GBytes *gcode, GCancellable *cancel, ZgProgressFn progress,
                        ZgDoneFn done, gpointer data) {
    if (!p->device[0]) {
        done(FALSE, "Set the serial port of the printer.", data);
        return;
    }
    Serial *s = g_new0(Serial, 1);
    s->device = g_strdup(p->device);
    s->baud = p->baud;
    s->gcode = g_bytes_ref(gcode);
    s->cancel = cancel ? g_object_ref(cancel) : NULL;
    s->progress = progress;
    s->done = done;
    s->data = data;
    g_thread_unref(g_thread_new("zslice-usb", serial_thread, s));
}

char **zg_link_serial_ports(void) {
    GPtrArray *out = g_ptr_array_new();
    /* The names by id first: they stay the same after a replug. */
    GDir *dir = g_dir_open("/dev/serial/by-id", 0, NULL);
    if (dir) {
        const char *name;
        while ((name = g_dir_read_name(dir))) g_ptr_array_add(out, g_build_filename("/dev/serial/by-id", name, NULL));
        g_dir_close(dir);
    }
    dir = g_dir_open("/dev", 0, NULL);
    if (dir) {
        const char *name;
        while ((name = g_dir_read_name(dir))) {
            if (g_str_has_prefix(name, "ttyUSB") || g_str_has_prefix(name, "ttyACM")) {
                g_ptr_array_add(out, g_build_filename("/dev", name, NULL));
            }
        }
        g_dir_close(dir);
    }
    g_ptr_array_add(out, NULL);
    return (char **)g_ptr_array_free(out, FALSE);
}

/* ---- the printers of a deck ---- */

typedef struct {
    ZgDeckFn fn;
    gpointer data;
} DeckQuery;

static void deck_printer_free(gpointer data) {
    ZgDeckPrinter *d = data;
    g_free(d->id);
    g_free(d->name);
    g_free(d->label);
    g_free(d->color);
    g_free(d->kind);
    g_free(d->path);
    g_free(d);
}

static void on_deck_reply(GObject *source, GAsyncResult *res, gpointer data) {
    DeckQuery *q = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    guint status = body ? soup_message_get_status(msg) : 0;
    if (!body) {
        q->fn(NULL, error->message, q->data);
    } else if (status == 401 || status == 403) {
        q->fn(NULL, "The deck refused the key.", q->data);
    } else if (status < 200 || status >= 300) {
        char *m = g_strdup_printf("The deck answered %u.", status);
        q->fn(NULL, m, q->data);
        g_free(m);
    } else {
        GPtrArray *out = g_ptr_array_new_with_free_func(deck_printer_free);
        JsonParser *parser = json_parser_new();
        gsize len = 0;
        const char *text = g_bytes_get_data(body, &len);
        if (json_parser_load_from_data(parser, text, (gssize)len, NULL)) {
            JsonNode *list = path_get(json_parser_get_root(parser), "printers");
            if (list && JSON_NODE_HOLDS_ARRAY(list)) {
                JsonArray *a = json_node_get_array(list);
                for (guint i = 0; i < json_array_get_length(a); i++) {
                    JsonNode *e = json_array_get_element(a, i);
                    ZgDeckPrinter *d = g_new0(ZgDeckPrinter, 1);
                    d->id = str(e, "id");
                    d->name = str(e, "name");
                    d->label = str(e, "label");
                    d->color = str(e, "color");
                    d->kind = str(e, "kind");
                    d->path = str(e, "url");
                    if (!d->path) d->path = g_strdup("");
                    if (d->name) g_ptr_array_add(out, d);
                    else deck_printer_free(d);
                }
            }
        }
        g_object_unref(parser);
        q->fn(out, NULL, q->data);
        g_ptr_array_unref(out);
    }
    if (body) g_bytes_unref(body);
    g_clear_error(&error);
    g_free(q);
}

void zg_link_deck_printers(const ZgPrinter *p, GCancellable *cancel, ZgDeckFn fn, gpointer data) {
    SoupMessage *msg = p->url[0] ? request(p, "GET", "/slicer/printer.json") : NULL;
    if (!msg) {
        fn(NULL, "The address is not valid.", data);
        return;
    }
    DeckQuery *q = g_new0(DeckQuery, 1);
    q->fn = fn;
    q->data = data;
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, cancel, on_deck_reply, q);
    g_object_unref(msg);
}


gboolean zg_link_wants_3mf(const zs_app *app, const ZgPrinter *p) {
    if (!app || !p || p->kind != ZG_LINK_PRINTDECK) return FALSE;
    char model[128] = "";
    if (zs_app_setting_get(app, "machine.model", model, sizeof model, NULL) != ZS_OK) return FALSE;
    return g_str_has_prefix(model, "bambu-lab");
}

GBytes *zg_link_bambu_wrap(GBytes *signed_gcode, gpointer data) {
    gsize len = 0;
    const uint8_t *g = g_bytes_get_data(signed_gcode, &len);
    uint8_t *out = NULL;
    size_t out_len = 0;
    if (zs_app_bambu_file_gcode(data, g, len, NULL, &out, &out_len) != ZS_OK || !out) return NULL;
    GBytes *b = g_bytes_new(out, out_len);
    zs_buffer_free(out, out_len);
    return b;
}
