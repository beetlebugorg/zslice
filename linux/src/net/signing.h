/* signing.h: the signing key of this install of zslice, and the signature
 * of each G-code file that the app exports or sends.
 *
 * The key is an Ed25519 key pair (src/gcode_sign.zig). The app makes it at
 * the first use from the random source of the OS (getrandom), and keeps
 * its secret key text in <config>/zslice/signing.key, a file that only the
 * user can read (mode 0600). A printdeck that pairs with zslice ("Get a
 * key") gets the public key, and can then accept only the files that this
 * key signed ("Signed prints only").
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

/* The public key text ("ed25519 <base64>"), or NULL when the key file
 * does not read or write. */
const char *zg_signing_public_key(void);
/* The key id: 16 hex characters, or NULL. */
const char *zg_signing_key_id(void);
/* A signed copy of the G-code. With no key, a new reference to `gcode`. */
GBytes *zg_sign_gcode(GBytes *gcode);

G_END_DECLS
