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
    if (msg && p->api_key[0]) soup_message_headers_append(soup_message_get_request_headers(msg), "X-Api-Key", p->api_key);
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

static void on_query_reply(GObject *source, GAsyncResult *res, gpointer data) {
    Query *q = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    const char *path = q->paths[q->step];
    if (!body) {
        q->fn(NULL, error->message, q->data);
        g_error_free(error);
        query_free(q);
        return;
    }
    guint status = soup_message_get_status(msg);
    if (status == 401 || status == 403) {
        q->fn(NULL, "The printer did not accept the API key.", q->data);
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
        q->fn(NULL, m, q->data);
        g_free(m);
        g_bytes_unref(body);
        query_free(q);
        return;
    }
    g_bytes_unref(body);
    q->step++;
    query_next(q);
}

static void query_next(Query *q) {
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
        q->fn(NULL, "The address is not valid.", q->data);
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

/* ---- send over the network ---- */

typedef struct {
    ZgDoneFn done;
    gpointer data;
} Send;

static void on_sent(GObject *source, GAsyncResult *res, gpointer data) {
    Send *s = data;
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    if (!body) {
        s->done(FALSE, error->message, s->data);
        g_error_free(error);
    } else {
        guint status = soup_message_get_status(msg);
        if (status >= 200 && status < 300) {
            s->done(TRUE, NULL, s->data);
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
    g_bytes_unref(body);
    if (key && key[0]) key_end(k, TRUE, key, "The printer gave zslice a key.");
    else key_end(k, FALSE, NULL, "The printer gave no key.");
    g_free(key);
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
    k->cancel = cancel ? g_object_ref(cancel) : g_cancellable_new();
    k->wait = wait;
    k->done = done;
    k->data = data;
    SoupMessage *msg = soup_message_new("POST", k->base);
    if (!msg) {
        key_end(k, FALSE, NULL, "The address of the printer is not valid.");
        return;
    }
    static const char body[] = "{\"app\":\"zslice\"}";
    GBytes *bytes = g_bytes_new_static(body, sizeof body - 1);
    soup_message_set_request_body_from_bytes(msg, "application/json", bytes);
    g_bytes_unref(bytes);
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, k->cancel, on_key_token, k);
    g_object_unref(msg);
}

void zg_link_send(const ZgPrinter *p, const char *filename, GBytes *gcode, gboolean print, GCancellable *cancel,
                  ZgProgressFn progress, ZgDoneFn done, gpointer data) {
    if (p->kind == ZG_LINK_NONE) {
        done(FALSE, "This printer has no connection.", data);
        return;
    }
    if (p->kind == ZG_LINK_USB) {
        send_serial(p, gcode, cancel, progress, done, data);
        return;
    }
    SoupMultipart *mp = soup_multipart_new(SOUP_FORM_MIME_TYPE_MULTIPART);
    soup_multipart_append_form_file(mp, "file", filename, "application/octet-stream", gcode);
    soup_multipart_append_form_string(mp, "print", print ? "true" : "false");
    const char *path = p->kind == ZG_LINK_MOONRAKER ? "/server/files/upload" : "/api/files/local";
    char *url = join_url(p, path);
    SoupMessage *msg = soup_message_new_from_multipart(url, mp);
    g_free(url);
    soup_multipart_free(mp);
    if (p->api_key[0]) soup_message_headers_append(soup_message_get_request_headers(msg), "X-Api-Key", p->api_key);
    Send *s = g_new0(Send, 1);
    s->done = done;
    s->data = data;
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, cancel, on_sent, s);
    g_object_unref(msg);
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
