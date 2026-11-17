/* project-source.h: the files of a printdeck.yml project.
 *
 * A source is a folder on this computer, or a public GitHub repository at
 * one commit. The project page reads only the files that a plate needs:
 * the model files of its parts, and the files of profiles/<folder>/.
 *
 * GitHub: the commit and the list of files come from api.github.com (3
 * requests: the repository for its default branch, the commit of the
 * branch, and the tree of the commit). Each file comes from
 * raw.githubusercontent.com. A file in Git LFS comes from
 * media.githubusercontent.com. The requests send no token.
 *
 * All calls run on the main thread. The reads are async: a folder reads
 * its files in a worker thread, and GitHub uses libsoup.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gio/gio.h>

G_BEGIN_DECLS

typedef enum { ZG_SOURCE_FOLDER, ZG_SOURCE_GITHUB } ZgSourceKind;

typedef struct {
    ZgSourceKind kind;
    char *path;              /* the folder */
    char *owner, *repo, *sha; /* the repository and the commit */
    GHashTable *paths;       /* GitHub: the paths of the files (a set) */
    GHashTable *cache;       /* GitHub: path -> GBytes of the files read */
} ZgSource;

/* A source with a reference count. */
ZgSource *zg_source_folder_new(const char *path);
ZgSource *zg_source_ref(ZgSource *src);
void zg_source_unref(ZgSource *src);

/* TRUE if the source has the file (a path relative to its root). */
gboolean zg_source_has(ZgSource *src, const char *path);

/* "owner/repo", "github.com/owner/repo", or a URL with /tree/<ref>. ref
 * gets "" with no /tree/. FALSE if the text is not one of these. Free the
 * strings with g_free. */
gboolean zg_github_parse(const char *text, char **owner, char **repo, char **ref);

/* src: a new source (the receiver owns it), or NULL with the reason. */
typedef void (*ZgSourceOpened)(ZgSource *src, const char *error, gpointer data);
/* Opens a GitHub repository. With a sha, it reads only the tree of that
 * commit (a project saved before). Else it reads the commit of ref (the
 * default branch if ref is "" or NULL). */
void zg_source_github_open(const char *owner, const char *repo, const char *ref, const char *sha, GCancellable *cancel,
                           ZgSourceOpened done, gpointer data);

/* files: path -> GBytes (the receiver owns it), or NULL with the reason. */
typedef void (*ZgSourceRead)(GHashTable *files, const char *error, gpointer data);
typedef void (*ZgSourceProgress)(guint done, guint total, gpointer data);
/* Reads the files `paths` (NULL-terminated), and each file under the
 * folders `folders` (NULL-terminated; can be NULL). */
void zg_source_read(ZgSource *src, const char *const *paths, const char *const *folders, GCancellable *cancel,
                    ZgSourceProgress progress, ZgSourceRead done, gpointer data);

G_END_DECLS
