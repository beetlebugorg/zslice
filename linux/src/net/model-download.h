/* model-download.h: the download of a model file from a zslice:// link.
 *
 * The rules come from the core (zs_link_* in zslice.h, and
 * docs/internals/open-links.md). This file does the network part:
 *
 * - It resolves the host first, and refuses the download if an address is
 *   not public. It checks the address of each connection again, before
 *   the TLS handshake, so a name that changes its address cannot reach a
 *   device on the local network.
 * - It uses no proxy (the check needs the real peer), no cookie, and no
 *   credentials.
 * - It follows each redirect by itself, with the check of the core.
 * - It stops at ZS_LINK_MAX_BYTES.
 * - Each request has the User-Agent of zs_import_user_agent.
 *
 * The caller asks the user before it calls zg_model_download.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gio/gio.h>

#include "zslice.h"

/* The progress of a download, from 0 to 1, on the thread of the caller.
 * It comes only when the answer has a length. */
typedef void (*ZgDownloadProgress)(double fraction, gpointer data);

/* Downloads the file of a checked link on a worker thread. The callback
 * runs on the thread of the caller. */
void zg_model_download(const zs_link *link, GCancellable *cancel, ZgDownloadProgress progress, GAsyncReadyCallback done,
                       gpointer data);
/* The bytes of the file, and its name (free with g_free). NULL and an
 * error (G_IO_ERROR, with a message for the user) on a failure. */
GBytes *zg_model_download_finish(GAsyncResult *result, char **name, GError **error);

/* Resolves host with the default resolver. FALSE and an error if it has
 * no address or an address that is not public. */
gboolean zg_model_download_check_host(const char *host, GCancellable *cancel, GError **error);

/* A request of an import (docs/internals/model-import.md) with the same
 * checks: a POST of the JSON `body` to an API (no redirect), or a GET
 * when body is NULL (a preview image; the redirects of the core). The
 * answer must be 2xx and at most `limit` bytes. No check of the type or
 * the name. */
void zg_net_request(const zs_link *link, const char *body, guint64 limit, GCancellable *cancel, GAsyncReadyCallback done,
                    gpointer data);
/* The bytes of the answer, or NULL and an error. */
GBytes *zg_net_request_finish(GAsyncResult *result, GError **error);
