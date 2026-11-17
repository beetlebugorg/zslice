/* discovery.h: find printers on the local network.
 *
 * The core builds the mDNS query and reads the answers (zs_discovery_* in
 * zslice-app.h). This file does the network I/O:
 *   1. It sends the query over UDP to 224.0.0.251:5353, at once and again
 *      after 1 s and 3 s, from two sockets: one on port 5353 in the
 *      multicast group (it shares the port with the mDNS service of the
 *      system), where the answers come, and one of its own port, for a
 *      unicast answer.
 *   2. It gives each packet to the core. After a change, it sends the
 *      query again: it has the next questions (SRV, TXT, A).
 *   3. For each new printer, it asks the HTTP API for its kind (GET
 *      /api/version) or its bed (Moonraker), with no key, and gives the
 *      answer to the core.
 * The search stops after 6 s. `changed` runs on the main thread after each
 * change of the list, and once at the end.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <glib.h>

#include "zslice-app.h"

G_BEGIN_DECLS

typedef struct ZgDiscovery ZgDiscovery;

typedef void (*ZgDiscoveryFn)(ZgDiscovery *d, gpointer data);

/* Starts a search. Free with zg_discovery_free (it stops the search). */
ZgDiscovery *zg_discovery_new(ZgDiscoveryFn changed, gpointer data);
void zg_discovery_free(ZgDiscovery *d);
/* Searches again, with the printers found so far kept. */
void zg_discovery_restart(ZgDiscovery *d);
/* TRUE while the search runs. */
gboolean zg_discovery_running(const ZgDiscovery *d);
/* The list of the core. */
const zs_discovery *zg_discovery_list(const ZgDiscovery *d);

G_END_DECLS
