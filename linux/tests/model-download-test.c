/* model-download-test.c: the download of a zslice:// link
 * (src/net/model-download.c) refuses a name that resolves to a local
 * address, before it connects.
 *
 * A stub resolver takes the place of the default one: "lan.example.com"
 * gives 192.168.1.20, "mixed.example.com" gives a public address and
 * 127.0.0.1, and "nas.example.com" gives fd00::5. Each download must end
 * with the "local network" error. The test sends no packet: the stub
 * answers each lookup, and a refused name gets no connection.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "../src/net/model-download.h"

#include <string.h>

/* ---- a stub resolver ---- */

typedef GResolver StubResolver;
typedef GResolverClass StubResolverClass;
G_DEFINE_TYPE(StubResolver, stub_resolver, G_TYPE_RESOLVER)

static int lookups;

static GList *stub_lookup(GResolver *r, const char *host, GCancellable *cancel, GError **error) {
    lookups++;
    const char *const *addresses = NULL;
    static const char *const lan[] = {"192.168.1.20", NULL};
    static const char *const mixed[] = {"93.184.216.34", "127.0.0.1", NULL};
    static const char *const nas[] = {"fd00::5", NULL};
    if (strcmp(host, "lan.example.com") == 0) addresses = lan;
    if (strcmp(host, "mixed.example.com") == 0) addresses = mixed;
    if (strcmp(host, "nas.example.com") == 0) addresses = nas;
    if (!addresses) {
        g_set_error_literal(error, G_RESOLVER_ERROR, G_RESOLVER_ERROR_NOT_FOUND, "no such name");
        return NULL;
    }
    GList *list = NULL;
    for (int i = 0; addresses[i]; i++) list = g_list_append(list, g_inet_address_new_from_string(addresses[i]));
    return list;
}

static GList *stub_lookup_flags(GResolver *r, const char *host, GResolverNameLookupFlags flags, GCancellable *cancel,
                                GError **error) {
    return stub_lookup(r, host, cancel, error);
}

static void stub_resolver_class_init(StubResolverClass *k) {
    k->lookup_by_name = stub_lookup;
    k->lookup_by_name_with_flags = stub_lookup_flags;
}

static void stub_resolver_init(StubResolver *r) {}

/* ---- the test ---- */

typedef struct {
    GMainLoop *loop;
    GBytes *bytes;
    GError *error;
} Result;

static void on_done(GObject *source, GAsyncResult *res, gpointer data) {
    Result *r = data;
    r->bytes = zg_model_download_finish(res, NULL, &r->error);
    g_main_loop_quit(r->loop);
}

static int failures;

static void check(gboolean ok, const char *what) {
    if (!ok) {
        failures++;
        g_printerr("FAIL: %s\n", what);
    }
}

static void download_refused(const char *link_text, const char *expect) {
    zs_link link;
    check(zs_link_check(link_text, &link) == ZS_LINK_OK, link_text);
    Result r = {g_main_loop_new(NULL, FALSE), NULL, NULL};
    zg_model_download(&link, NULL, NULL, on_done, &r);
    g_main_loop_run(r.loop);
    check(r.bytes == NULL, "no bytes");
    check(r.error && strstr(r.error->message, expect), expect);
    if (r.error) g_print("%s: %s\n", link.host, r.error->message);
    g_clear_error(&r.error);
    if (r.bytes) g_bytes_unref(r.bytes);
    g_main_loop_unref(r.loop);
}

int main(void) {
    GResolver *stub = g_object_new(stub_resolver_get_type(), NULL);
    g_resolver_set_default(stub);

    download_refused("zslice://open?file=https%3A%2F%2Flan.example.com%2Fa.stl", "local network");
    download_refused("zslice://open?file=https://mixed.example.com/a.stl", "local network");
    download_refused("zslice://open?file=https://nas.example.com/b.3mf", "local network");
    download_refused("zslice://open?file=https://gone.example.com/b.3mf", "does not resolve");
    check(lookups == 4, "one lookup for each link");

    check(g_str_has_prefix(zs_import_user_agent(), "zslice/"), "the User-Agent");

    GError *error = NULL;
    check(!zg_model_download_check_host("lan.example.com", NULL, &error), "the check of a host");
    g_clear_error(&error);

    /* A cancel before the start ends the download. */
    zs_link link;
    zs_link_check("zslice://open?file=https://lan.example.com/a.stl", &link);
    GCancellable *cancel = g_cancellable_new();
    g_cancellable_cancel(cancel);
    Result r = {g_main_loop_new(NULL, FALSE), NULL, NULL};
    zg_model_download(&link, cancel, NULL, on_done, &r);
    g_main_loop_run(r.loop);
    check(r.bytes == NULL && r.error, "a cancel");
    g_clear_error(&r.error);
    g_main_loop_unref(r.loop);
    g_object_unref(cancel);

    g_object_unref(stub);
    if (failures) g_printerr("%d failed\n", failures);
    return failures ? 1 : 0;
}
