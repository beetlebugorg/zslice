/* bambu-gate-test.c: one connection for each Bambu Lab address, a wait
 * that survives a new watch (src/net/bambu-link.c), and no overwrite of an
 * app.ini that did not read (src/prefs/printers.c).
 *
 * A TCP server on 127.0.0.1 counts the connections. It holds them open, or
 * closes them at once. Uses a new temporary config folder.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "../src/net/bambu-link.h"

#include <glib/gstdio.h>
#include <string.h>

static gint connections;
static gint close_now;
static GMutex held_lock;
static GPtrArray *held;

static gboolean on_incoming(GSocketService *service, GSocketConnection *conn, GObject *source, gpointer data) {
    g_atomic_int_inc(&connections);
    if (g_atomic_int_get(&close_now)) {
        g_io_stream_close(G_IO_STREAM(conn), NULL, NULL);
        return TRUE;
    }
    g_mutex_lock(&held_lock);
    g_ptr_array_add(held, g_object_ref(conn));
    g_mutex_unlock(&held_lock);
    return TRUE;
}

static void on_status(const zs_printer_status *st, const char *error, gpointer data) {}

static void spin(guint ms) {
    gint64 end = g_get_monotonic_time() + ms * 1000;
    while (g_get_monotonic_time() < end) {
        g_main_context_iteration(NULL, FALSE);
        g_usleep(5000);
    }
}

static void test_gate(const ZgPrinter *p) {
    /* One watch connects, and a second one to the address waits. */
    ZgBambuWatch *a = zg_bambu_watch(p, on_status, NULL);
    spin(400);
    g_assert_cmpint(g_atomic_int_get(&connections), ==, 1);
    ZgBambuWatch *b = zg_bambu_watch(p, on_status, NULL);
    spin(600);
    g_assert_cmpint(g_atomic_int_get(&connections), ==, 1);
    char *report = zg_bambu_link_report(p);
    g_assert_nonnull(report);
    g_free(report);
    /* The first stops with no failure: the second connects. */
    zg_bambu_watch_stop(a);
    spin(600);
    g_assert_cmpint(g_atomic_int_get(&connections), ==, 2);
    zg_bambu_watch_stop(b);
    spin(300);

    /* A drop starts the wait, and a new watch keeps it. */
    g_atomic_int_set(&close_now, 1);
    ZgBambuWatch *c = zg_bambu_watch(p, on_status, NULL);
    spin(500);
    g_assert_cmpint(g_atomic_int_get(&connections), ==, 3);
    zg_bambu_watch_stop(c);
    spin(200);
    ZgBambuWatch *d = zg_bambu_watch(p, on_status, NULL);
    spin(800);
    g_assert_cmpint(g_atomic_int_get(&connections), ==, 3);
    report = zg_bambu_link_report(p);
    g_assert_nonnull(report);
    g_assert_nonnull(strstr(report, "next try"));
    g_free(report);
    zg_bambu_watch_stop(d);
    spin(200);
}

static void test_bad_ini(const char *dir) {
    char *cfg = g_build_filename(dir, "zslice", NULL);
    g_mkdir_with_parents(cfg, 0700);
    char *ini = g_build_filename(cfg, "app.ini", NULL);
    static const char bad[] = "[printer printer-1\nthis line does not parse\n";
    g_assert_true(g_file_set_contents(ini, bad, -1, NULL));
    zg_printers_load();
    g_assert_true(zg_printers_read_failed());
    g_assert_false(zg_printers_first_start());
    zg_printers_save();
    char *now = NULL;
    g_assert_true(g_file_get_contents(ini, &now, NULL, NULL));
    g_assert_cmpstr(now, ==, bad);
    g_free(now);
    g_unlink(ini);
    zg_printers_load();
    g_assert_false(zg_printers_read_failed());
    g_free(ini);
    g_free(cfg);
}

int main(void) {
    char *dir = g_dir_make_tmp("zslice-gate-XXXXXX", NULL);
    g_assert_nonnull(dir);
    g_setenv("XDG_CONFIG_HOME", dir, TRUE);
    test_bad_ini(dir);

    held = g_ptr_array_new_with_free_func(g_object_unref);
    GSocketService *service = g_socket_service_new();
    guint16 port = g_socket_listener_add_any_inet_port(G_SOCKET_LISTENER(service), NULL, NULL);
    g_assert_cmpuint(port, >, 0);
    g_signal_connect(service, "incoming", G_CALLBACK(on_incoming), NULL);
    g_socket_service_start(service);
    char *text = g_strdup_printf("%u", port);
    g_setenv("ZSLICE_BAMBU_MQTT_PORT", text, TRUE);
    g_free(text);

    ZgPrinter *p = zg_printers_add("Gate test");
    p->kind = ZG_LINK_BAMBU;
    g_free(p->url);
    p->url = g_strdup("127.0.0.1");
    g_free(p->serial);
    p->serial = g_strdup("01P00A000000000");
    g_free(p->api_key);
    p->api_key = g_strdup("12345678");
    test_gate(p);

    g_socket_service_stop(service);
    g_object_unref(service);
    g_ptr_array_unref(held);
    char *argv[] = {"rm", "-rf", dir, NULL};
    g_spawn_sync(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, NULL, NULL, NULL);
    g_free(dir);
    g_print("ok\n");
    return 0;
}
