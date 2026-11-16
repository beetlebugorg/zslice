/* licenses.h: the Licenses window.
 *
 * It lists zslice and each component in the core (from zs_license_get), and
 * the libraries that only this shell links. Each entry shows its full
 * license text.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

void zg_licenses_show(GtkWindow *parent);
