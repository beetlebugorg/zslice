/* bambu-link.h: a Bambu Lab printer in LAN mode, read only.
 *
 * The status comes over MQTT 3.1.1 on TLS (port 8883, the user "bblp", the
 * access code as the password). The app subscribes to the report topic
 * device/<serial>/report, and gives each report to the core
 * (zs_printer_status_feed with the path "report"). The app never
 * publishes: it sends no command and no request to the printer, so a
 * report has only the fields that the printer sends by itself. A printer
 * that sends only changes fills the status as they come.
 *
 * The printer has a self-signed certificate. The link pins it: the
 * SHA-256 hash of the certificate (ZgPrinter.tls_pin) is set at the first
 * connection (trust on first use), or when the user reads the serial
 * number. A later connection with another certificate stops in the TLS
 * handshake, before the access code goes out: a device on the network
 * that claims the address of the printer does not get the code. The link
 * reads only. See src/bambu.zig and REFERENCES.md.
 *
 * For tests, ZSLICE_BAMBU_MQTT_PORT, ZSLICE_BAMBU_JPEG_PORT, and
 * ZSLICE_BAMBU_RTSPS_PORT move the ports (tools/fake_bambu.py).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gio/gio.h>

#include "../prefs/printers.h"
#include "../model/app-model.h"

G_BEGIN_DECLS

typedef struct ZgBambuWatch ZgBambuWatch;

/* On the main thread: `status` has the reports so far (owned by the
 * watch, valid until the next call), or NULL with `error`. At most one
 * call each second. */
typedef void (*ZgBambuFn)(const zs_printer_status *status, const char *error, gpointer data);

/* Connects and subscribes. NULL when the printer has no address, serial,
 * or access code (`fn` gets the reason first). */
ZgBambuWatch *zg_bambu_watch(const ZgPrinter *p, ZgBambuFn fn, gpointer data);

/* Disconnects. `fn` gets no more calls. */
void zg_bambu_watch_stop(ZgBambuWatch *w);

/* The port `name` ("MQTT", "JPEG", "RTSPS"), or the variable
 * ZSLICE_BAMBU_<name>_PORT. */
int zg_bambu_port(const char *name, int port);

/* A TLS connection to address:port with the self-signed certificate of
 * the printer. `pin` (the SHA-256 hash in hex, or NULL or "" for none
 * yet) must match the certificate, or the connection fails with
 * G_IO_ERROR_PERMISSION_DENIED and a message for the user. `seen` (if not
 * NULL) gets the hash of the certificate (free it), also on a failure.
 * Blocking: call it in a thread. */
GIOStream *zg_bambu_connect(const char *address, int port, const char *pin, char **seen, GCancellable *cancel,
                            GError **error);

/* The SHA-256 hash of a certificate (its DER bytes) in hex. */
char *zg_cert_hash(GTlsCertificate *cert);

/* The first connection to the printer `id` saw the certificate with the
 * hash `pin`: the printer keeps it, unless it has a pin already. Any
 * thread. */
void zg_bambu_trust_first(const char *id, const char *pin);

/* Reads the serial number of the printer from its TLS certificate on the
 * MQTT port (its common name), with no login. *pin gets the hash of the
 * certificate: the user reads the serial number to trust the printer. */
void zg_bambu_read_serial(const char *address, GCancellable *cancel, GAsyncReadyCallback done, gpointer data);
char *zg_bambu_read_serial_finish(GAsyncResult *res, char **pin, GError **error);

G_END_DECLS
