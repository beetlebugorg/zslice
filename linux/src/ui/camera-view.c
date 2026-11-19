/* camera-view.c: see camera-view.h.
 *
 * The MJPEG stream: libsoup sends the GET, and SoupMultipartInputStream
 * gives each part of the multipart/x-mixed-replace reply (RFC 2046). The
 * Bambu Lab camera: the JPEG frames of port 6000 in a thread, or RTSP over
 * TLS through GStreamer (rtspsrc, decodebin, appsink). See REFERENCES.md.
 *
 * Each start of a source has a number (gen). A callback of an older start
 * finds another number, and drops its frame.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "camera-view.h"

#include "../net/bambu-link.h"
#include "../net/key-header.h"

#include <libsoup/soup.h>
#include <string.h>
#ifdef ZG_HAVE_GST
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>
#endif

enum { SNAP_TILE_S = 5, SNAP_LARGE_S = 1, RETRY_S = 20, FIRST_S = 12 };

/* The largest picture of an MJPEG stream (as the JPEG frames of a Bambu
 * Lab printer, src/bambu.zig). */
#define ZG_CAMERA_MAX_FRAME (16u << 20)

typedef enum { SRC_NONE, SRC_HTTP, SRC_BAMBU } SourceKind;

typedef struct {
    gint refs;
    gboolean dead; /* the widget is gone */
    GtkWidget *root, *picture, *msg;
    gboolean large, active, playing, live;
    guint gen;
    SourceKind kind;
    /* HTTP. */
    char *stream, *snapshot, *api_key;
    gboolean printdeck;
    /* Bambu Lab: the printer, its address, its access code, and the hash
     * of its certificate ("" before the first connection). */
    char *id, *address, *code, *pin;
    int bambu_kind; /* zs_bambu_camera_kind: 0 not known, 1 RTSPS, 2 JPEG */
    int trying;     /* the kind of this start, 1 or 2 */
    GCancellable *cancel;
    guint timer, first;
    gboolean decoding;
    /* A frame of a thread is on its way to the main thread: the thread
     * drops the next ones (atomic). */
    gint pending;
    GByteArray *part; /* the part of the MJPEG stream that comes in */
#ifdef ZG_HAVE_GST
    GstElement *pipeline;
    guint bus_watch;
#endif
} Cam;

static Cam *cam_ref(Cam *c) {
    g_atomic_int_inc(&c->refs);
    return c;
}

static void cam_unref(Cam *c) {
    if (!g_atomic_int_dec_and_test(&c->refs)) return;
    g_free(c->stream);
    g_free(c->snapshot);
    g_free(c->api_key);
    g_free(c->id);
    g_free(c->address);
    g_free(c->code);
    g_free(c->pin);
    g_free(c);
}

static Cam *cam_of(GtkWidget *view) {
    return g_object_get_data(G_OBJECT(view), "zg-cam");
}

static SoupSession *session(void) {
    static SoupSession *s;
    if (!s) {
        s = soup_session_new();
        soup_session_set_timeout(s, 20);
        soup_session_set_user_agent(s, "zslice");
    }
    return s;
}

static void show_msg(Cam *c, const char *text) {
    gtk_label_set_text(GTK_LABEL(c->msg), text ? text : "");
    gtk_widget_set_visible(c->msg, text && text[0]);
}

static void stop(Cam *c);
static void start(Cam *c);

/* A frame for the picture, on the main thread. */
static void show_texture(Cam *c, GdkTexture *t) {
    gtk_picture_set_paintable(GTK_PICTURE(c->picture), GDK_PAINTABLE(t));
    if (!c->live) {
        /* For tests: which source gave the first frame. */
        if (g_getenv("ZSLICE_CAMERA_LOG"))
            g_message("camera: the first frame, %d x %d, from %s", gdk_texture_get_width(t), gdk_texture_get_height(t),
                      c->kind == SRC_HTTP ? "HTTP" : c->trying == 1 ? "RTSPS (port 322)" : "JPEG (port 6000)");
        c->live = TRUE;
        show_msg(c, NULL);
        gtk_widget_add_css_class(c->root, "cam-live");
    }
    if (c->first) g_source_remove(c->first);
    c->first = 0;
}

static gboolean retry(gpointer data) {
    Cam *c = data;
    c->timer = 0;
    if (!c->dead && c->active && !c->playing) start(c);
    return G_SOURCE_REMOVE;
}

/* The camera gave no picture: say why, and try again in RETRY_S. */
static void failed(Cam *c, const char *why) {
    if (c->dead) return;
    if (g_getenv("ZSLICE_CAMERA_LOG")) g_message("camera: no picture (%s)", why ? why : "");
#ifdef ZG_HAVE_GST
    /* A model that is not known: RTSPS first, then the JPEG port. */
    if (c->kind == SRC_BAMBU && c->bambu_kind == 0 && c->trying == 1 && !c->live) {
        stop(c);
        c->trying = 2;
        start(c);
        return;
    }
#endif
    stop(c);
    c->live = FALSE;
    gtk_widget_remove_css_class(c->root, "cam-live");
    gtk_picture_set_paintable(GTK_PICTURE(c->picture), NULL);
    show_msg(c, why);
    if (c->active) c->timer = g_timeout_add_seconds(RETRY_S, retry, c);
}

static gboolean on_first(gpointer data) {
    Cam *c = data;
    c->first = 0;
    if (!c->live) failed(c, "No picture came from the camera. The camera can be off, or out of reach.");
    return G_SOURCE_REMOVE;
}

/* ---- the JPEG decode, in a thread ---- */

typedef struct {
    Cam *c;
    guint gen;
    GBytes *jpeg;
    GdkTexture *texture;
} Decode;

static void decode_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancel) {
    Decode *d = data;
    d->texture = gdk_texture_new_from_bytes(d->jpeg, NULL);
    g_task_return_boolean(task, TRUE);
}

static void decode_free(gpointer data) {
    Decode *d = data;
    g_bytes_unref(d->jpeg);
    g_clear_object(&d->texture);
    cam_unref(d->c);
    g_free(d);
}

static void on_decoded(GObject *source, GAsyncResult *res, gpointer data) {
    Decode *d = g_task_get_task_data(G_TASK(res));
    Cam *c = d->c;
    c->decoding = FALSE;
    if (c->dead || d->gen != c->gen || !c->playing) return;
    if (d->texture) show_texture(c, d->texture);
}

/* Decodes a JPEG, unless the last one still decodes: then the frame is
 * dropped. */
static void decode(Cam *c, GBytes *jpeg) {
    if (c->decoding) return;
    c->decoding = TRUE;
    Decode *d = g_new0(Decode, 1);
    d->c = cam_ref(c);
    d->gen = c->gen;
    d->jpeg = g_bytes_ref(jpeg);
    GTask *t = g_task_new(NULL, NULL, on_decoded, NULL);
    g_task_set_task_data(t, d, decode_free);
    g_task_run_in_thread(t, decode_thread);
    g_object_unref(t);
}

/* ---- HTTP ---- */

typedef struct {
    Cam *c;
    guint gen;
    SoupMessage *msg;
    SoupMultipartInputStream *multi;
    GInputStream *in;
} Req;

static void req_free(Req *r) {
    g_clear_object(&r->msg);
    g_clear_object(&r->multi);
    g_clear_object(&r->in);
    cam_unref(r->c);
    g_free(r);
}

static gboolean req_stale(Req *r) {
    return r->c->dead || r->gen != r->c->gen || !r->c->playing;
}

static SoupMessage *get(Cam *c, const char *url) {
    SoupMessage *msg = soup_message_new("GET", url);
    zg_soup_add_key(msg, c->api_key);
    return msg;
}

static void next_part(Req *r);

static void on_part_read(GObject *source, GAsyncResult *res, gpointer data) {
    Req *r = data;
    GError *e = NULL;
    GBytes *b = g_input_stream_read_bytes_finish(G_INPUT_STREAM(source), res, &e);
    if (req_stale(r)) {
        if (b) g_bytes_unref(b);
        g_clear_error(&e);
        req_free(r);
        return;
    }
    if (!b) {
        failed(r->c, "The stream of the camera stopped.");
        g_clear_error(&e);
        req_free(r);
        return;
    }
    gsize n = g_bytes_get_size(b);
    if (n > 0 && r->c->part->len + n > ZG_CAMERA_MAX_FRAME) {
        /* A part with no end: a camera (or a device at its address) that
         * sends without end would fill the memory. */
        g_bytes_unref(b);
        failed(r->c, "The camera sent a picture larger than 16 MB.");
        req_free(r);
        return;
    }
    if (n > 0) {
        g_byte_array_append(r->c->part, g_bytes_get_data(b, NULL), (guint)n);
        g_bytes_unref(b);
        g_input_stream_read_bytes_async(r->in, 65536, G_PRIORITY_DEFAULT, r->c->cancel, on_part_read, r);
        return;
    }
    g_bytes_unref(b);
    /* The end of a part: one JPEG. */
    GBytes *jpeg = g_bytes_new(r->c->part->data, r->c->part->len);
    g_byte_array_set_size(r->c->part, 0);
    if (g_bytes_get_size(jpeg) > 0) decode(r->c, jpeg);
    g_bytes_unref(jpeg);
    g_clear_object(&r->in);
    next_part(r);
}

static void on_next_part(GObject *source, GAsyncResult *res, gpointer data) {
    Req *r = data;
    GError *e = NULL;
    GInputStream *part = soup_multipart_input_stream_next_part_finish(SOUP_MULTIPART_INPUT_STREAM(source), res, &e);
    if (req_stale(r)) {
        g_clear_object(&part);
        g_clear_error(&e);
        req_free(r);
        return;
    }
    if (!part) {
        failed(r->c, "The stream of the camera stopped.");
        g_clear_error(&e);
        req_free(r);
        return;
    }
    r->in = part;
    g_byte_array_set_size(r->c->part, 0);
    g_input_stream_read_bytes_async(r->in, 65536, G_PRIORITY_DEFAULT, r->c->cancel, on_part_read, r);
}

static void next_part(Req *r) {
    soup_multipart_input_stream_next_part_async(r->multi, G_PRIORITY_DEFAULT, r->c->cancel, on_next_part, r);
}

static const char *status_text(guint status) {
    if (status == 401 || status == 403) return "The printer refused the API key for the camera.";
    if (status == 404) return "The printer has no camera at this address.";
    if (status == 503) return "The camera is off, or busy.";
    return "The camera gave no picture.";
}

static void on_stream(GObject *source, GAsyncResult *res, gpointer data) {
    Req *r = data;
    GError *e = NULL;
    GInputStream *in = soup_session_send_finish(SOUP_SESSION(source), res, &e);
    if (req_stale(r)) {
        g_clear_object(&in);
        g_clear_error(&e);
        req_free(r);
        return;
    }
    if (!in) {
        char *m = g_strdup_printf("The camera did not answer (%s). The printer can be off, or out of reach.", e ? e->message : "no reason");
        failed(r->c, m);
        g_free(m);
        g_clear_error(&e);
        req_free(r);
        return;
    }
    guint status = soup_message_get_status(r->msg);
    if (status < 200 || status >= 300) {
        failed(r->c, status_text(status));
        g_object_unref(in);
        req_free(r);
        return;
    }
    r->multi = soup_multipart_input_stream_new(r->msg, in);
    g_object_unref(in);
    next_part(r);
}

static void snap(Cam *c);

static gboolean on_snap_timer(gpointer data) {
    Cam *c = data;
    c->timer = 0;
    if (c->playing) snap(c);
    return G_SOURCE_REMOVE;
}

static void on_snapshot(GObject *source, GAsyncResult *res, gpointer data) {
    Req *r = data;
    GError *e = NULL;
    GBytes *b = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &e);
    if (req_stale(r)) {
        if (b) g_bytes_unref(b);
        g_clear_error(&e);
        req_free(r);
        return;
    }
    guint status = soup_message_get_status(r->msg);
    if (!b || status < 200 || status >= 300) {
        failed(r->c, !b ? "The camera did not answer. The printer can be off, or out of reach." : status_text(status));
        if (b) g_bytes_unref(b);
        g_clear_error(&e);
        req_free(r);
        return;
    }
    decode(r->c, b);
    g_bytes_unref(b);
    Cam *c = r->c;
    c->timer = g_timeout_add_seconds(c->large ? SNAP_LARGE_S : SNAP_TILE_S, on_snap_timer, c);
    req_free(r);
}

static void snap(Cam *c) {
    SoupMessage *msg = get(c, c->snapshot);
    if (!msg) {
        failed(c, "The address of the camera is not valid.");
        return;
    }
    Req *r = g_new0(Req, 1);
    r->c = cam_ref(c);
    r->gen = c->gen;
    r->msg = msg;
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_LOW, c->cancel, on_snapshot, r);
}

static void start_http(Cam *c) {
    if (c->stream && c->stream[0]) {
        GUri *u = g_uri_parse(c->stream, G_URI_FLAGS_ENCODED, NULL);
        char *url = NULL;
        if (u && c->printdeck) {
            /* printdeck: a small picture at a low rate for a tile, the
             * whole picture at 10 frames a second for the large view. */
            const char *q = g_uri_get_query(u);
            char *extra = g_strdup_printf("%s%s%s", q && q[0] ? q : "", q && q[0] ? "&" : "", c->large ? "fps=10" : "w=480&fps=4");
            GUri *v = g_uri_build(G_URI_FLAGS_ENCODED, g_uri_get_scheme(u), g_uri_get_userinfo(u), g_uri_get_host(u), g_uri_get_port(u),
                                  g_uri_get_path(u), extra, NULL);
            url = g_uri_to_string(v);
            g_uri_unref(v);
            g_free(extra);
        }
        if (u) g_uri_unref(u);
        SoupMessage *msg = get(c, url ? url : c->stream);
        g_free(url);
        if (!msg) {
            failed(c, "The address of the camera is not valid.");
            return;
        }
        Req *r = g_new0(Req, 1);
        r->c = cam_ref(c);
        r->gen = c->gen;
        r->msg = msg;
        soup_session_send_async(session(), msg, G_PRIORITY_LOW, c->cancel, on_stream, r);
    } else {
        snap(c);
    }
}

/* ---- Bambu Lab: the JPEG frames of port 6000 ---- */

typedef struct {
    Cam *c;
    guint gen;
    GdkTexture *texture;
    char *error;
} Frame;

static gboolean on_frame(gpointer data) {
    Frame *f = data;
    Cam *c = f->c;
    if (f->texture) g_atomic_int_set(&c->pending, 0);
    if (!c->dead && f->gen == c->gen && c->playing) {
        if (f->texture) show_texture(c, f->texture);
        else failed(c, f->error);
    }
    g_clear_object(&f->texture);
    g_free(f->error);
    cam_unref(c);
    g_free(f);
    return G_SOURCE_REMOVE;
}

/* Posts a frame (or an error) to the main thread, unless the last one is
 * still on its way. */
static void post_frame(Cam *c, guint gen, GdkTexture *t, const char *error) {
    if (t && !g_atomic_int_compare_and_exchange(&c->pending, 0, 1)) return;
    Frame *f = g_new0(Frame, 1);
    f->c = cam_ref(c);
    f->gen = gen;
    f->texture = t ? g_object_ref(t) : NULL;
    f->error = g_strdup(error);
    g_idle_add(on_frame, f);
}

typedef struct {
    Cam *c;
    guint gen;
    char *id, *address, *code, *pin;
    GCancellable *cancel;
    int fps_ms;
} JpegRun;

static gpointer jpeg_thread(gpointer data) {
    JpegRun *j = data;
    GError *e = NULL;
    char *seen = NULL;
    GIOStream *io = zg_bambu_connect(j->address, zg_bambu_port("JPEG", 6000), j->pin, &seen, j->cancel, &e);
    if (io && !j->pin[0]) zg_bambu_trust_first(j->id, seen);
    g_free(seen);
    guint8 auth[80];
    if (io && zs_bambu_camera_auth(j->code, auth) == ZS_OK &&
        g_output_stream_write_all(g_io_stream_get_output_stream(io), auth, sizeof auth, NULL, j->cancel, &e)) {
        GInputStream *in = g_io_stream_get_input_stream(io);
        /* The core cuts the stream into frames (zs_bambu_jpeg_reader). */
        zs_bambu_jpeg_reader *r = zs_bambu_jpeg_reader_new();
        gint64 shown = 0;
        guint8 *buf = g_malloc(65536);
        while (r && !g_cancellable_is_cancelled(j->cancel)) {
            gssize n = g_input_stream_read(in, buf, 65536, j->cancel, &e);
            if (n <= 0) break;
            zs_bambu_jpeg_reader_feed(r, buf, (size_t)n);
            const uint8_t *jp = NULL;
            size_t len = 0;
            int got;
            while ((got = zs_bambu_jpeg_reader_next(r, &jp, &len)) == 1) {
                /* A tile shows a few frames a second: the others are read
                 * and dropped. */
                gint64 now = g_get_monotonic_time();
                if (now - shown < (gint64)j->fps_ms * 1000 || g_atomic_int_get(&j->c->pending)) continue;
                GBytes *jpeg = g_bytes_new(jp, len);
                GdkTexture *t = gdk_texture_new_from_bytes(jpeg, NULL);
                g_bytes_unref(jpeg);
                if (t) {
                    post_frame(j->c, j->gen, t, NULL);
                    g_object_unref(t);
                    shown = now;
                }
            }
            if (got < 0) {
                if (!e) e = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "a frame with a wrong size");
                break;
            }
        }
        g_free(buf);
        if (r) zs_bambu_jpeg_reader_free(r);
    }
    if (!g_cancellable_is_cancelled(j->cancel)) {
        char *m = g_strdup_printf("The camera did not answer (%s). The printer must be in LAN mode, with the right access code.",
                                  e ? e->message : "the stream ended");
        post_frame(j->c, j->gen, NULL, m);
        g_free(m);
    }
    g_clear_error(&e);
    g_clear_object(&io);
    g_object_unref(j->cancel);
    g_free(j->id);
    g_free(j->address);
    g_free(j->code);
    g_free(j->pin);
    cam_unref(j->c);
    g_free(j);
    return NULL;
}

static void start_jpeg(Cam *c) {
    JpegRun *j = g_new0(JpegRun, 1);
    j->c = cam_ref(c);
    j->gen = c->gen;
    j->id = g_strdup(c->id);
    j->address = g_strdup(c->address);
    j->code = g_strdup(c->code);
    j->pin = g_strdup(c->pin);
    j->cancel = g_object_ref(c->cancel);
    j->fps_ms = c->large ? 0 : 250;
    g_thread_unref(g_thread_new("zslice-bambu-cam", jpeg_thread, j));
}

/* ---- Bambu Lab: RTSP over TLS through GStreamer ---- */

#ifdef ZG_HAVE_GST
typedef struct {
    Cam *c;
    guint gen;
} Sink;

static void sink_free(gpointer data, GClosure *closure) {
    Sink *s = data;
    cam_unref(s->c);
    g_free(s);
}

static GstFlowReturn on_sample(GstAppSink *appsink, gpointer data) {
    Sink *s = data;
    GstSample *sample = gst_app_sink_pull_sample(appsink);
    if (!sample) return GST_FLOW_EOS;
    if (!g_atomic_int_get(&s->c->pending)) {
        GstVideoInfo info;
        GstBuffer *buf = gst_sample_get_buffer(sample);
        GstMapInfo map;
        if (gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) && gst_buffer_map(buf, &map, GST_MAP_READ)) {
            gsize stride = (gsize)GST_VIDEO_INFO_PLANE_STRIDE(&info, 0);
            gsize h = (gsize)GST_VIDEO_INFO_HEIGHT(&info);
            if (map.size >= stride * h) {
                GBytes *b = g_bytes_new(map.data, stride * h);
                GdkTexture *t = gdk_memory_texture_new(GST_VIDEO_INFO_WIDTH(&info), (int)h, GDK_MEMORY_R8G8B8A8, b, stride);
                post_frame(s->c, s->gen, t, NULL);
                g_object_unref(t);
                g_bytes_unref(b);
            }
            gst_buffer_unmap(buf, &map);
        }
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

static gboolean on_bus(GstBus *bus, GstMessage *m, gpointer data) {
    Cam *c = data;
    if (GST_MESSAGE_TYPE(m) == GST_MESSAGE_ERROR || GST_MESSAGE_TYPE(m) == GST_MESSAGE_EOS) {
        GError *e = NULL;
        if (GST_MESSAGE_TYPE(m) == GST_MESSAGE_ERROR) gst_message_parse_error(m, &e, NULL);
        char *msg = g_strdup_printf("The camera did not answer (%s). The printer must be in LAN mode, with LAN Only Liveview on, and the right access code.",
                                    e ? e->message : "the stream ended");
        c->bus_watch = 0;
        failed(c, msg);
        g_free(msg);
        g_clear_error(&e);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

typedef struct {
    char *id, *pin;
} RtspPin;

static void rtsp_pin_free(gpointer data, GClosure *closure) {
    RtspPin *rp = data;
    g_free(rp->id);
    g_free(rp->pin);
    g_free(rp);
}

/* The self-signed certificate of the printer fails the checks of GIO, so
 * rtspsrc asks here, before it sends the access code. The pin decides, as
 * in zg_bambu_connect. A streaming thread. */
static gboolean on_rtsp_cert(GstElement *src, GTlsConnection *conn, GTlsCertificate *cert, GTlsCertificateFlags errors,
                             gpointer data) {
    RtspPin *rp = data;
    char *seen = zg_cert_hash(cert);
    gboolean ok = seen && (!rp->pin[0] || g_ascii_strcasecmp(seen, rp->pin) == 0);
    if (ok && !rp->pin[0]) zg_bambu_trust_first(rp->id, seen);
    g_free(seen);
    return ok;
}

static void start_rtsps(Cam *c) {
    static gboolean inited;
    if (!inited) {
        gst_init(NULL, NULL);
        inited = TRUE;
    }
    /* The video of a tile: 640 wide at 5 frames a second; the large view:
     * all frames. rtspsrc checks the certificate (tls-validation-flags of
     * its default) and asks on_rtsp_cert. */
    char *pipe = g_strdup_printf(
        "rtspsrc name=src protocols=tcp latency=300 ! decodebin ! videoconvert ! videoscale ! "
        "%s video/x-raw,format=RGBA%s ! appsink name=sink max-buffers=1 drop=true sync=false",
        c->large ? "" : "videorate drop-only=true max-rate=5 !", c->large ? "" : ",width=640,pixel-aspect-ratio=1/1");
    GError *e = NULL;
    GstElement *p = gst_parse_launch(pipe, &e);
    g_free(pipe);
    if (!p || e) {
        char *m = g_strdup_printf("GStreamer cannot play the camera (%s).", e ? e->message : "no pipeline");
        failed(c, m);
        g_free(m);
        g_clear_error(&e);
        if (p) gst_object_unref(p);
        return;
    }
    GstElement *src = gst_bin_get_by_name(GST_BIN(p), "src");
    char *url = g_strdup_printf("rtsps://%s:%d/streaming/live/1", c->address, zg_bambu_port("RTSPS", 322));
    g_object_set(src, "location", url, "user-id", "bblp", "user-pw", c->code, NULL);
    g_free(url);
    RtspPin *rp = g_new0(RtspPin, 1);
    rp->id = g_strdup(c->id);
    rp->pin = g_strdup(c->pin ? c->pin : "");
    g_signal_connect_data(src, "accept-certificate", G_CALLBACK(on_rtsp_cert), rp, rtsp_pin_free, 0);
    gst_object_unref(src);
    GstElement *sink = gst_bin_get_by_name(GST_BIN(p), "sink");
    Sink *s = g_new0(Sink, 1);
    s->c = cam_ref(c);
    s->gen = c->gen;
    g_object_set(sink, "emit-signals", TRUE, NULL);
    g_signal_connect_data(sink, "new-sample", G_CALLBACK(on_sample), s, sink_free, 0);
    gst_object_unref(sink);
    GstBus *bus = gst_element_get_bus(p);
    c->bus_watch = gst_bus_add_watch(bus, on_bus, c);
    gst_object_unref(bus);
    c->pipeline = p;
    gst_element_set_state(p, GST_STATE_PLAYING);
}
#endif

/* ---- start and stop ---- */

static void start(Cam *c) {
    if (c->playing || c->kind == SRC_NONE) return;
    c->playing = TRUE;
    c->gen++;
    c->cancel = g_cancellable_new();
    if (!c->live) show_msg(c, "Connecting…");
    if (c->first) g_source_remove(c->first);
    c->first = g_timeout_add_seconds(FIRST_S, on_first, c);
    if (c->kind == SRC_HTTP) {
        start_http(c);
        return;
    }
    if (c->trying == 0) c->trying = c->bambu_kind == 2 ? 2 : 1;
#ifdef ZG_HAVE_GST
    if (c->trying == 1) {
        start_rtsps(c);
        return;
    }
#else
    if (c->trying == 1 && c->bambu_kind == 1) {
        failed(c, "This build of zslice has no GStreamer: it cannot play the RTSP camera of this printer.");
        return;
    }
#endif
    start_jpeg(c);
}

static void stop(Cam *c) {
    if (c->timer) g_source_remove(c->timer);
    c->timer = 0;
    if (c->first) g_source_remove(c->first);
    c->first = 0;
    if (!c->playing) return;
    c->playing = FALSE;
    c->gen++;
    if (c->cancel) g_cancellable_cancel(c->cancel);
    g_clear_object(&c->cancel);
    c->decoding = FALSE;
#ifdef ZG_HAVE_GST
    if (c->bus_watch) g_source_remove(c->bus_watch);
    c->bus_watch = 0;
    if (c->pipeline) {
        gst_element_set_state(c->pipeline, GST_STATE_NULL);
        gst_object_unref(c->pipeline);
        c->pipeline = NULL;
    }
#endif
}

static void update(Cam *c) {
    gboolean want = c->active && gtk_widget_get_mapped(c->root) && c->kind != SRC_NONE;
    if (want && !c->playing && !c->timer) start(c);
    else if (!want && c->playing) stop(c);
    else if (!want && c->timer) {
        g_source_remove(c->timer);
        c->timer = 0;
    }
}

static void on_map(GtkWidget *w, gpointer data) {
    update(data);
}

static void on_unmap(GtkWidget *w, gpointer data) {
    update(data);
}

static void on_destroy(gpointer data) {
    Cam *c = data;
    stop(c);
    c->dead = TRUE;
    if (c->part) g_byte_array_unref(c->part);
    c->part = NULL;
    cam_unref(c);
}

GtkWidget *zg_camera_view_new(gboolean large) {
    Cam *c = g_new0(Cam, 1);
    c->refs = 1;
    c->large = large;
    c->part = g_byte_array_new();
    c->root = gtk_overlay_new();
    gtk_widget_add_css_class(c->root, "camera");
    c->picture = gtk_picture_new();
    gtk_picture_set_content_fit(GTK_PICTURE(c->picture), GTK_CONTENT_FIT_CONTAIN);
    gtk_picture_set_can_shrink(GTK_PICTURE(c->picture), TRUE);
    gtk_widget_set_hexpand(c->picture, TRUE);
    gtk_widget_set_vexpand(c->picture, TRUE);
    gtk_overlay_set_child(GTK_OVERLAY(c->root), c->picture);
    c->msg = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(c->msg), TRUE);
    gtk_label_set_justify(GTK_LABEL(c->msg), GTK_JUSTIFY_CENTER);
    gtk_widget_add_css_class(c->msg, "camera-msg");
    gtk_widget_set_margin_start(c->msg, 10);
    gtk_widget_set_margin_end(c->msg, 10);
    gtk_overlay_add_overlay(GTK_OVERLAY(c->root), c->msg);
    g_object_set_data_full(G_OBJECT(c->root), "zg-cam", c, on_destroy);
    g_signal_connect(c->root, "map", G_CALLBACK(on_map), c);
    g_signal_connect(c->root, "unmap", G_CALLBACK(on_unmap), c);
    show_msg(c, "No camera");
    if (large) return c->root;
    /* A tile has a fixed height: a scrolled window with no scroll bars
     * gives the picture its size, whatever the size of the frames. */
    GtkWidget *frame = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(frame), GTK_POLICY_EXTERNAL, GTK_POLICY_EXTERNAL);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(frame), 200);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(frame), 200);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(frame), c->root);
    gtk_widget_add_css_class(frame, "camera");
    /* The view is the frame: the state goes with it. */
    g_object_set_data(G_OBJECT(frame), "zg-cam", c);
    return frame;
}

static void reset(Cam *c) {
    stop(c);
    c->live = FALSE;
    c->trying = 0;
    gtk_widget_remove_css_class(c->root, "cam-live");
    gtk_picture_set_paintable(GTK_PICTURE(c->picture), NULL);
}

void zg_camera_view_set_http(GtkWidget *view, const char *stream, const char *snapshot, const char *api_key, gboolean printdeck) {
    Cam *c = cam_of(view);
    reset(c);
    g_free(c->stream);
    g_free(c->snapshot);
    g_free(c->api_key);
    c->stream = g_strdup(stream);
    c->snapshot = g_strdup(snapshot);
    c->api_key = g_strdup(api_key);
    c->printdeck = printdeck;
    c->kind = (stream && stream[0]) || (snapshot && snapshot[0]) ? SRC_HTTP : SRC_NONE;
    show_msg(c, c->kind == SRC_NONE ? "No camera" : "Connecting…");
    update(c);
}

void zg_camera_view_set_bambu(GtkWidget *view, const ZgPrinter *p, const char *model_id) {
    Cam *c = cam_of(view);
    reset(c);
    g_free(c->id);
    g_free(c->address);
    g_free(c->code);
    g_free(c->pin);
    const char *a = p->url;
    if (strstr(a, "://")) a = strstr(a, "://") + 3;
    c->id = g_strdup(p->id);
    c->address = g_strndup(a, strcspn(a, "/:"));
    c->code = g_strstrip(g_strdup(p->api_key));
    c->pin = g_strdup(p->tls_pin ? p->tls_pin : "");
    c->bambu_kind = model_id ? zs_bambu_camera_kind(model_id) : 0;
    c->kind = c->address[0] && c->code[0] ? SRC_BAMBU : SRC_NONE;
    show_msg(c, c->kind == SRC_NONE ? "Set the address and the access code to see the camera." : "Connecting…");
    update(c);
}

void zg_camera_view_set_none(GtkWidget *view, const char *message) {
    Cam *c = cam_of(view);
    reset(c);
    c->kind = SRC_NONE;
    show_msg(c, message);
}

void zg_camera_view_set_active(GtkWidget *view, gboolean active) {
    Cam *c = cam_of(view);
    if (c->active == active) return;
    c->active = active;
    update(c);
}

gboolean zg_camera_view_has_source(GtkWidget *view) {
    return cam_of(view)->kind != SRC_NONE;
}
