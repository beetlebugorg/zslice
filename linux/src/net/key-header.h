/* key-header.h: the API key header of a request to a printer.
 *
 * libsoup follows a redirect with the same request headers. A printer (or
 * a device that claims its address) can redirect a request to another
 * host, and that host then gets the API key. zg_soup_add_key adds the key
 * to a request, and takes it away again when a redirect goes to another
 * origin (another scheme, host, or port).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <libsoup/soup.h>

#define ZG_KEY_HEADER "X-Api-Key"

/* Adds the header X-Api-Key with `key` to `msg`, for the origin of its
 * URI only. Does nothing for a NULL or empty key. */
void zg_soup_add_key(SoupMessage *msg, const char *key);

/* TRUE if two printer addresses have one origin: the same scheme, host,
 * and port. An address with no scheme is http. An address that does not
 * parse has no origin. */
gboolean zg_same_origin(const char *a, const char *b);
