/* bed-model.h: the bed model of the current printer in the 3D view.
 *
 * The core finds the model of the machine profile in the printer library
 * and places the bed. This file only finds the bed folder and reads the
 * two files.
 *
 * The bed folder, the first that exists:
 *   1. $ZSLICE_BEDS_DIR,
 *   2. <the folder of the program>/../share/zslice/beds (an install),
 *   3. src/printers/beds of the source tree (a build that is not
 *      installed).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <zslice-app.h>

/* The path of a file in the bed folder, or NULL. Free with g_free. */
char *zg_bed_file_path(const char *name);

/* Shows the bed model of the printer of `app` in `view`, or the grid if it
 * has none. Reads the files only when the printer changes. */
void zg_bed_model_update(zs_view *view, const zs_app *app);
