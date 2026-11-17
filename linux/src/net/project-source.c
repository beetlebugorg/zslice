/* project-source.c: see project-source.h.
 *
 * The GitHub REST API (docs.github.com/rest: repos, commits, git/trees)
 * and the Git LFS pointer format (github.com/git-lfs/git-lfs, docs/spec.md).
 * The same requests as web/app/project.js. See REFERENCES.md.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "project-source.h"

#include <json-glib/json-glib.h>
#include <libsoup/soup.h>
#include <string.h>

static SoupSession *session(void) {
    static SoupSession *s;
    if (!s) {
        s = soup_session_new();
        soup_session_set_timeout(s, 30);
        /* GitHub needs a User-Agent. */
        soup_session_set_user_agent(s, "zslice");
    }
    return s;
}

static ZgSource *source_new(ZgSourceKind kind) {
    ZgSource *src = g_atomic_rc_box_new0(ZgSource);
    src->kind = kind;
    src->cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_bytes_unref);
    return src;
}

ZgSource *zg_source_folder_new(const char *path) {
    ZgSource *src = source_new(ZG_SOURCE_FOLDER);
    src->path = g_strdup(path);
    return src;
}

ZgSource *zg_source_ref(ZgSource *src) {
    return g_atomic_rc_box_acquire(src);
}

static void source_clear(gpointer data) {
    ZgSource *src = data;
    g_free(src->path);
    g_free(src->owner);
    g_free(src->repo);
    g_free(src->sha);
    if (src->paths) g_hash_table_unref(src->paths);
    g_hash_table_unref(src->cache);
}

void zg_source_unref(ZgSource *src) {
    if (src) g_atomic_rc_box_release_full(src, source_clear);
}

gboolean zg_source_has(ZgSource *src, const char *path) {
    if (src->kind == ZG_SOURCE_GITHUB) return g_hash_table_contains(src->paths, path);
    char *full = g_build_filename(src->path, path, NULL);
    gboolean has = g_file_test(full, G_FILE_TEST_IS_REGULAR);
    g_free(full);
    return has;
}

/* ---- parse ---- */

static gboolean name_ok(const char *s, size_t n) {
    if (n == 0) return FALSE;
    for (size_t i = 0; i < n; i++)
        if (!g_ascii_isalnum(s[i]) && s[i] != '_' && s[i] != '.' && s[i] != '-') return FALSE;
    return TRUE;
}

gboolean zg_github_parse(const char *text, char **owner, char **repo, char **ref) {
    char *t = g_strstrip(g_strdup(text));
    char *p = t;
    if (g_str_has_suffix(p, ".git")) p[strlen(p) - 4] = 0;
    if (g_str_has_prefix(p, "https://")) p += 8;
    else if (g_str_has_prefix(p, "http://")) p += 7;
    if (g_str_has_prefix(p, "www.")) p += 4;
    if (g_str_has_prefix(p, "github.com/")) p += strlen("github.com/");
    size_t n = strlen(p);
    while (n > 0 && p[n - 1] == '/') p[--n] = 0;
    const char *slash = strchr(p, '/');
    gboolean ok = FALSE;
    if (slash && name_ok(p, (size_t)(slash - p))) {
        const char *r = slash + 1;
        const char *tree = strstr(r, "/tree/");
        const char *end = tree ? tree : r + strlen(r);
        if (name_ok(r, (size_t)(end - r)) && (!tree || tree[6])) {
            *owner = g_strndup(p, (size_t)(slash - p));
            *repo = g_strndup(r, (size_t)(end - r));
            *ref = g_strdup(tree ? tree + 6 : "");
            ok = TRUE;
        }
    }
    g_free(t);
    return ok;
}

/* ---- GitHub: open ---- */

typedef struct {
    char *owner, *repo, *ref;
    GCancellable *cancel;
    ZgSourceOpened done;
    gpointer data;
} OpenJob;

static void open_job_free(OpenJob *j) {
    g_free(j->owner);
    g_free(j->repo);
    g_free(j->ref);
    g_clear_object(&j->cancel);
    g_free(j);
}

static void open_fail(OpenJob *j, const char *error) {
    j->done(NULL, error, j->data);
    open_job_free(j);
}

typedef void (*JsonStep)(OpenJob *j, JsonNode *root);

typedef struct {
    OpenJob *job;
    JsonStep next;
} ApiCall;

static void on_api(GObject *source, GAsyncResult *res, gpointer data) {
    ApiCall *call = data;
    OpenJob *j = call->job;
    JsonStep next = call->next;
    g_free(call);
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    if (!body) {
        char *text = g_strdup_printf("GitHub did not answer: %s", error->message);
        g_error_free(error);
        open_fail(j, text);
        g_free(text);
        return;
    }
    guint status = soup_message_get_status(msg);
    if (status == 404) {
        char *text = j->ref && j->ref[0] ? g_strdup_printf("GitHub has no public repository %s/%s with %s.", j->owner, j->repo, j->ref)
                                         : g_strdup_printf("GitHub has no public repository %s/%s.", j->owner, j->repo);
        open_fail(j, text);
        g_free(text);
    } else if (status == 403 || status == 429) {
        open_fail(j, "GitHub refused the request (the limit of requests with no login is 60 an hour). Try again later.");
    } else if (status < 200 || status >= 300) {
        char *text = g_strdup_printf("GitHub answered %u.", status);
        open_fail(j, text);
        g_free(text);
    } else {
        JsonParser *parser = json_parser_new();
        gsize len = 0;
        const char *d = g_bytes_get_data(body, &len);
        if (json_parser_load_from_data(parser, d, (gssize)len, NULL) && JSON_NODE_HOLDS_OBJECT(json_parser_get_root(parser)))
            next(j, json_parser_get_root(parser));
        else
            open_fail(j, "GitHub answered with no valid JSON.");
        g_object_unref(parser);
    }
    g_bytes_unref(body);
}

static void api_get(OpenJob *j, const char *path, JsonStep next) {
    char *url = g_strdup_printf("https://api.github.com/repos/%s/%s%s", j->owner, j->repo, path);
    SoupMessage *msg = soup_message_new("GET", url);
    g_free(url);
    if (!msg) {
        open_fail(j, "The address of the repository is not valid.");
        return;
    }
    soup_message_headers_append(soup_message_get_request_headers(msg), "Accept", "application/vnd.github+json");
    ApiCall *call = g_new0(ApiCall, 1);
    call->job = j;
    call->next = next;
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, j->cancel, on_api, call);
    g_object_unref(msg);
}

static void on_tree(OpenJob *j, JsonNode *root) {
    JsonObject *o = json_node_get_object(root);
    JsonArray *tree = json_object_has_member(o, "tree") ? json_object_get_array_member(o, "tree") : NULL;
    if (!tree) {
        open_fail(j, "GitHub answered with no list of files.");
        return;
    }
    ZgSource *src = source_new(ZG_SOURCE_GITHUB);
    src->owner = g_strdup(j->owner);
    src->repo = g_strdup(j->repo);
    src->sha = g_strdup(json_object_get_string_member_with_default(o, "sha", j->ref));
    src->paths = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (guint i = 0; i < json_array_get_length(tree); i++) {
        JsonObject *e = json_array_get_object_element(tree, i);
        if (!e || g_strcmp0(json_object_get_string_member_with_default(e, "type", ""), "blob") != 0) continue;
        const char *path = json_object_get_string_member_with_default(e, "path", NULL);
        if (path) g_hash_table_add(src->paths, g_strdup(path));
    }
    j->done(src, NULL, j->data);
    open_job_free(j);
}

static void get_tree(OpenJob *j, const char *sha) {
    char *path = g_strdup_printf("/git/trees/%s?recursive=1", sha);
    api_get(j, path, on_tree);
    g_free(path);
}

static void on_commit(OpenJob *j, JsonNode *root) {
    const char *sha = json_object_get_string_member_with_default(json_node_get_object(root), "sha", NULL);
    if (!sha) {
        open_fail(j, "GitHub answered with no commit.");
        return;
    }
    char *s = g_strdup(sha);
    get_tree(j, s);
    g_free(s);
}

static void get_commit(OpenJob *j, const char *branch) {
    char *esc = g_uri_escape_string(branch, NULL, FALSE);
    char *path = g_strdup_printf("/commits/%s", esc);
    api_get(j, path, on_commit);
    g_free(path);
    g_free(esc);
}

static void on_repo(OpenJob *j, JsonNode *root) {
    const char *branch = json_object_get_string_member_with_default(json_node_get_object(root), "default_branch", NULL);
    if (!branch) {
        open_fail(j, "GitHub answered with no default branch.");
        return;
    }
    char *b = g_strdup(branch);
    get_commit(j, b);
    g_free(b);
}

void zg_source_github_open(const char *owner, const char *repo, const char *ref, const char *sha, GCancellable *cancel,
                           ZgSourceOpened done, gpointer data) {
    OpenJob *j = g_new0(OpenJob, 1);
    j->owner = g_strdup(owner);
    j->repo = g_strdup(repo);
    j->ref = g_strdup(ref ? ref : "");
    j->cancel = cancel ? g_object_ref(cancel) : NULL;
    j->done = done;
    j->data = data;
    if (sha && sha[0]) get_tree(j, sha);
    else if (j->ref[0]) get_commit(j, j->ref);
    else api_get(j, "", on_repo);
}

/* ---- read ---- */

typedef struct {
    ZgSource *src;
    GHashTable *files; /* path -> GBytes */
    guint total, done;
    char *error;
    gboolean finished;
    GCancellable *cancel;
    ZgSourceProgress progress;
    ZgSourceRead callback;
    gpointer data;
} ReadJob;

static void read_finish(ReadJob *r) {
    if (r->error) {
        g_hash_table_unref(r->files);
        r->callback(NULL, r->error, r->data);
    } else {
        r->callback(r->files, NULL, r->data);
    }
    g_free(r->error);
    g_clear_object(&r->cancel);
    zg_source_unref(r->src);
    g_free(r);
}

/* The paths to read: the files, then the files under each folder. */
static GPtrArray *wanted(ZgSource *src, const char *const *paths, const char *const *folders) {
    GPtrArray *list = g_ptr_array_new_with_free_func(g_free);
    GHashTable *seen = g_hash_table_new(g_str_hash, g_str_equal);
    for (size_t i = 0; paths && paths[i]; i++) {
        if (g_hash_table_contains(seen, paths[i])) continue;
        g_hash_table_add(seen, (gpointer)paths[i]);
        g_ptr_array_add(list, g_strdup(paths[i]));
    }
    if (src->kind == ZG_SOURCE_GITHUB) {
        for (size_t f = 0; folders && folders[f]; f++) {
            char *prefix = g_strconcat(folders[f], "/", NULL);
            GHashTableIter it;
            gpointer key;
            g_hash_table_iter_init(&it, src->paths);
            while (g_hash_table_iter_next(&it, &key, NULL)) {
                if (g_str_has_prefix(key, prefix) && !g_hash_table_contains(seen, key)) {
                    g_hash_table_add(seen, key);
                    g_ptr_array_add(list, g_strdup(key));
                }
            }
            g_free(prefix);
        }
    }
    g_hash_table_unref(seen);
    return list;
}

/* -- a folder: a worker thread reads the files -- */

typedef struct {
    char *root;
    GPtrArray *paths;
    char **folders;
} FolderTask;

static void folder_task_free(gpointer data) {
    FolderTask *t = data;
    g_free(t->root);
    g_ptr_array_unref(t->paths);
    g_strfreev(t->folders);
    g_free(t);
}

/* Adds the files under dir (relative path rel) to the list. */
static void list_dir(const char *root, const char *rel, GPtrArray *out) {
    char *full = g_build_filename(root, rel, NULL);
    GDir *dir = g_dir_open(full, 0, NULL);
    if (dir) {
        const char *name;
        while ((name = g_dir_read_name(dir))) {
            char *child = g_strconcat(rel, "/", name, NULL);
            char *cfull = g_build_filename(root, child, NULL);
            if (g_file_test(cfull, G_FILE_TEST_IS_DIR)) list_dir(root, child, out);
            else if (g_file_test(cfull, G_FILE_TEST_IS_REGULAR)) g_ptr_array_add(out, g_strdup(child));
            g_free(cfull);
            g_free(child);
        }
        g_dir_close(dir);
    }
    g_free(full);
}

static void folder_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancel) {
    FolderTask *t = data;
    for (size_t f = 0; t->folders && t->folders[f]; f++) list_dir(t->root, t->folders[f], t->paths);
    GHashTable *files = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_bytes_unref);
    for (guint i = 0; i < t->paths->len; i++) {
        const char *rel = g_ptr_array_index(t->paths, i);
        if (g_hash_table_contains(files, rel)) continue;
        char *full = g_build_filename(t->root, rel, NULL);
        char *contents = NULL;
        gsize len = 0;
        GError *error = NULL;
        if (!g_file_get_contents(full, &contents, &len, &error)) {
            g_free(full);
            g_hash_table_unref(files);
            g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_FAILED, "The folder has no file %s (%s).", rel, error->message);
            g_error_free(error);
            return;
        }
        g_free(full);
        g_hash_table_insert(files, g_strdup(rel), g_bytes_new_take(contents, len));
    }
    g_task_return_pointer(task, files, (GDestroyNotify)g_hash_table_unref);
}

static void on_folder_read(GObject *source, GAsyncResult *res, gpointer data) {
    ReadJob *r = data;
    GError *error = NULL;
    GHashTable *files = g_task_propagate_pointer(G_TASK(res), &error);
    if (files) {
        g_hash_table_unref(r->files);
        r->files = files;
    } else {
        r->error = g_strdup(error->message);
        g_error_free(error);
    }
    read_finish(r);
}

/* -- GitHub: one request for each file, all at once -- */

typedef struct {
    ReadJob *job;
    char *path;
    gboolean lfs; /* the second request, to media.githubusercontent.com */
} FileGet;

static void file_get(ReadJob *r, const char *path, gboolean lfs);

static void file_done(ReadJob *r) {
    r->done++;
    if (r->progress && !r->error) r->progress(r->done, r->total, r->data);
    if (r->done == r->total) read_finish(r);
}

static void on_file(GObject *source, GAsyncResult *res, gpointer data) {
    FileGet *g = data;
    ReadJob *r = g->job;
    SoupMessage *msg = soup_session_get_async_result_message(SOUP_SESSION(source), res);
    GError *error = NULL;
    GBytes *body = soup_session_send_and_read_finish(SOUP_SESSION(source), res, &error);
    guint status = msg ? soup_message_get_status(msg) : 0;
    if (!body || status < 200 || status >= 300) {
        if (!r->error) {
            if (!body) r->error = g_strdup_printf("GitHub did not answer: %s", error->message);
            else r->error = g_strdup_printf(g->lfs ? "GitHub has no LFS file %s (%u)." : "GitHub has no file %s (%u).", g->path, status);
        }
        g_clear_error(&error);
        if (body) g_bytes_unref(body);
        file_done(r);
    } else {
        gsize len = 0;
        const char *d = g_bytes_get_data(body, &len);
        /* A Git LFS pointer: the file is in LFS storage. */
        static const char pointer[] = "version https://git-lfs";
        if (!g->lfs && len < 400 && len >= sizeof pointer - 1 && memcmp(d, pointer, sizeof pointer - 1) == 0) {
            g_bytes_unref(body);
            file_get(r, g->path, TRUE);
        } else {
            g_hash_table_insert(r->src->cache, g_strdup(g->path), g_bytes_ref(body));
            g_hash_table_insert(r->files, g_strdup(g->path), body);
            file_done(r);
        }
    }
    g_free(g->path);
    g_free(g);
}

static void file_get(ReadJob *r, const char *path, gboolean lfs) {
    /* Each part of the path, escaped. */
    char **parts = g_strsplit(path, "/", -1);
    GString *enc = g_string_new(NULL);
    for (int i = 0; parts[i]; i++) {
        if (i > 0) g_string_append_c(enc, '/');
        char *e = g_uri_escape_string(parts[i], NULL, FALSE);
        g_string_append(enc, e);
        g_free(e);
    }
    g_strfreev(parts);
    char *url = lfs ? g_strdup_printf("https://media.githubusercontent.com/media/%s/%s/%s/%s", r->src->owner, r->src->repo, r->src->sha, enc->str)
                    : g_strdup_printf("https://raw.githubusercontent.com/%s/%s/%s/%s", r->src->owner, r->src->repo, r->src->sha, enc->str);
    g_string_free(enc, TRUE);
    SoupMessage *msg = soup_message_new("GET", url);
    g_free(url);
    FileGet *g = g_new0(FileGet, 1);
    g->job = r;
    g->path = g_strdup(path);
    g->lfs = lfs;
    soup_session_send_and_read_async(session(), msg, G_PRIORITY_DEFAULT, r->cancel, on_file, g);
    g_object_unref(msg);
}

static gboolean finish_idle(gpointer data) {
    read_finish(data);
    return G_SOURCE_REMOVE;
}

void zg_source_read(ZgSource *src, const char *const *paths, const char *const *folders, GCancellable *cancel,
                    ZgSourceProgress progress, ZgSourceRead done, gpointer data) {
    ReadJob *r = g_new0(ReadJob, 1);
    r->src = zg_source_ref(src);
    r->files = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_bytes_unref);
    r->cancel = cancel ? g_object_ref(cancel) : NULL;
    r->progress = progress;
    r->callback = done;
    r->data = data;
    GPtrArray *list = wanted(src, paths, folders);
    if (src->kind == ZG_SOURCE_FOLDER) {
        FolderTask *t = g_new0(FolderTask, 1);
        t->root = g_strdup(src->path);
        t->paths = list;
        t->folders = g_strdupv((char **)folders);
        GTask *task = g_task_new(NULL, cancel, on_folder_read, r);
        g_task_set_task_data(task, t, folder_task_free);
        g_task_run_in_thread(task, folder_thread);
        g_object_unref(task);
        return;
    }
    /* GitHub: the files in the cache first, then a request for each other
     * file. */
    GPtrArray *get = g_ptr_array_new();
    for (guint i = 0; i < list->len; i++) {
        const char *path = g_ptr_array_index(list, i);
        GBytes *cached = g_hash_table_lookup(src->cache, path);
        if (cached) g_hash_table_insert(r->files, g_strdup(path), g_bytes_ref(cached));
        else if (!g_hash_table_contains(src->paths, path)) {
            if (!r->error) r->error = g_strdup_printf("GitHub has no file %s.", path);
        } else g_ptr_array_add(get, (gpointer)path);
    }
    r->total = r->error ? 0 : get->len;
    if (r->total == 0) {
        g_idle_add(finish_idle, r);
    } else {
        for (guint i = 0; i < get->len; i++) file_get(r, g_ptr_array_index(get, i), FALSE);
    }
    g_ptr_array_free(get, TRUE);
    g_ptr_array_unref(list);
}
