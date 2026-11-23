#define _GNU_SOURCE
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
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
    char *message;
} Result;

static void on_done(gboolean ok, const char *message, gpointer data) {
    Result *r = data;
    g_free(r->message);
    r->message = g_strdup(message);
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

/* An upload to a USB printer must not reach the port: it would start a
 * print. The device does not exist, so nothing can open. */
static void usb_upload_sends_nothing(void) {
    ZgPrinter p = {0};
    p.id = (char *)"usb";
    p.name = (char *)"USB";
    p.kind = ZG_LINK_USB;
    p.device = (char *)"/nonexistent/zslice-test-port";
    p.baud = 115200;
    Result r = {0};
    GBytes *g = g_bytes_new_static("G28\n", 4);
    zg_link_send(&p, "a.gcode", g, FALSE, NULL, NULL, on_done, &r);
    while (!r.done) g_main_context_iteration(NULL, TRUE);
    g_bytes_unref(g);
    g_assert_false(r.ok);
    g_assert_nonnull(r.message);
    g_assert_nonnull(strstr(r.message, "Nothing was sent"));
    g_free(r.message);
}

/* A status query must not open the port: an open can restart the board. */
static void on_usb_info(ZgPrinterInfo *info, const char *error, gpointer data) {
    (void)error;
    *(gboolean *)data = info != NULL;
    if (info) zg_printer_info_free(info);
}

static void usb_query_opens_nothing(void) {
    ZgPrinter p = {0};
    p.id = (char *)"usb";
    p.name = (char *)"USB";
    p.kind = ZG_LINK_USB;
    p.device = (char *)"/nonexistent/zslice-test-port";
    gboolean got = FALSE;
    zg_link_query(&p, NULL, on_usb_info, &got);
    g_assert_true(got);
}

/* A printer on a pseudo terminal: it answers "ok" to each line, keeps the
 * text, and asks for a Stop after five lines. */
typedef struct {
    int fd;
    GCancellable *cancel;
    GString *got;
    GMutex lock;
    gboolean end;
} FakePrinter;

static gpointer fake_printer(gpointer data) {
    FakePrinter *f = data;
    int lines = 0;
    for (;;) {
        g_mutex_lock(&f->lock);
        gboolean end = f->end;
        g_mutex_unlock(&f->lock);
        if (end) return NULL;
        struct pollfd w = {f->fd, POLLIN, 0};
        if (poll(&w, 1, 20) <= 0 || !(w.revents & POLLIN)) continue;
        char c;
        if (read(f->fd, &c, 1) != 1) continue;
        g_mutex_lock(&f->lock);
        g_string_append_c(f->got, c);
        g_mutex_unlock(&f->lock);
        if (c != '\n') continue;
        if (write(f->fd, "ok\n", 3) != 3) return NULL;
        if (++lines == 5) g_cancellable_cancel(f->cancel);
    }
}

static void usb_stop_turns_off_heat(int nozzles, const char *first, const char *const *want, const char *refuse) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    g_assert_cmpint(master, >=, 0);
    g_assert_cmpint(grantpt(master), ==, 0);
    g_assert_cmpint(unlockpt(master), ==, 0);
    char *name = g_strdup(ptsname(master));
    int keep = open(name, O_RDWR | O_NOCTTY);
    g_assert_cmpint(keep, >=, 0);
    struct termios t;
    tcgetattr(keep, &t);
    cfmakeraw(&t);
    tcsetattr(keep, TCSANOW, &t);
    FakePrinter f = {.fd = master, .cancel = g_cancellable_new(), .got = g_string_new(NULL)};
    g_mutex_init(&f.lock);
    GThread *th = g_thread_new("fake-printer", fake_printer, &f);
    GString *code = g_string_new(first);
    for (int i = 0; i < 2000; i++) g_string_append_printf(code, "G1 X%d\n", i % 100);
    GBytes *g = g_string_free_to_bytes(code);
    ZgPrinter p = {0};
    p.id = (char *)"usb";
    p.name = (char *)"USB";
    p.kind = ZG_LINK_USB;
    p.device = name;
    p.baud = 115200;
    p.nozzles = nozzles;
    Result r = {0};
    zg_link_send(&p, "a.gcode", g, TRUE, f.cancel, NULL, on_done, &r);
    while (!r.done) g_main_context_iteration(NULL, TRUE);
    g_mutex_lock(&f.lock);
    f.end = TRUE;
    for (; *want; want++) g_assert_nonnull(strstr(f.got->str, *want));
    if (refuse) g_assert_null(strstr(f.got->str, refuse));
    g_assert_nonnull(strstr(f.got->str, "M140 S0\n"));
    g_assert_nonnull(strstr(f.got->str, "M107\n"));
    g_assert_null(strstr(strstr(f.got->str, "M140 S0\n"), "G1"));
    g_mutex_unlock(&f.lock);
    g_thread_join(th);
    g_assert_false(r.ok);
    g_assert_nonnull(strstr(r.message, "heaters and the fan are off"));
    g_free(r.message);
    g_bytes_unref(g);
    g_string_free(f.got, TRUE);
    g_object_unref(f.cancel);
    g_mutex_clear(&f.lock);
    close(keep);
    close(master);
    g_free(name);
}

int main(void) {
    usb_upload_sends_nothing();
    usb_query_opens_nothing();
    {
        const char *const one[] = {"M104 S0\n", NULL};
        const char *const two[] = {"M104 T0 S0\n", "M104 T1 S0\n", NULL};
        usb_stop_turns_off_heat(1, "", one, "M104 T");
        usb_stop_turns_off_heat(2, "", two, "M104 S0\n");
        /* The machine says one nozzle, and the file selects T1. */
        usb_stop_turns_off_heat(1, "T1\n", two, "M104 S0\n");
        /* A tool past nine, and a nozzle heated by number with no T line. */
        const char *const eleven[] = {"M104 T0 S0\n", "M104 T11 S0\n", NULL};
        usb_stop_turns_off_heat(1, "T11\n", eleven, "M104 T12");
        usb_stop_turns_off_heat(1, "M109 T1 S200\n", two, "M104 S0\n");
        usb_stop_turns_off_heat(1, "M104 S200 T1\n", two, "M104 S0\n");
        /* Words with no space, and a T word of three digits. */
        usb_stop_turns_off_heat(1, "M104T1S200\n", two, "M104 S0\n");
        usb_stop_turns_off_heat(1, "M104 S200T1\n", two, "M104 S0\n");
        const char *const last[] = {"M104 T0 S0\n", "M104 T15 S0\n", NULL};
        usb_stop_turns_off_heat(1, "M109 T123 S200\n", last, "M104 T16");
        /* Words that only look like a tool. */
        usb_stop_turns_off_heat(1, "TEST\n", one, "M104 T");
        usb_stop_turns_off_heat(1, "M104 TEST S200\n", one, "M104 T0 S0");
        usb_stop_turns_off_heat(1, "M104 XT1 S200\n", one, "M104 T0 S0");
        usb_stop_turns_off_heat(1, "M1040 T1\n", one, "M104 T0 S0");
        usb_stop_turns_off_heat(1, "M117 T1 ready\n", one, "M104 T0 S0");
    }
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
