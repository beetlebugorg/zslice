/* part-mesh.h: the meshes of the parts at their places on the bed, each
 * in a paint session of the core (zs_app_part_mesh, zs_paint_new). The
 * Label tool picks the face under the pointer on it (zs_label_place), and
 * the Paint tool paints it (zs_paint_*). Both tools share one cache, so a
 * part makes one session.
 *
 * A session lives while the mesh of its part stays the same. After a
 * slice, an undo, or a switch of the plate, zg_part_meshes_check marks
 * each session for a check: the next get reads the mesh of the part again
 * and makes a new session only if the mesh changed (a move or a turn).
 * The gen of an entry changes with each new session.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

#include "../model/app-model.h"

typedef struct ZgPartMeshes ZgPartMeshes;

typedef struct {
    zs_paint *session;
    /* A copy of the mesh: nv points (x, y, z, mm) and nf triangles. */
    float *verts;
    uint32_t *faces;
    size_t nv, nf;
    guint gen;
    gboolean check;
} ZgPartMesh;

ZgPartMeshes *zg_part_meshes_new(ZgModel *model);
void zg_part_meshes_free(ZgPartMeshes *m);
/* The mesh of part `index` of the current plate, or NULL (no such part,
 * or no mesh). The entry stays valid until the next call of
 * zg_part_meshes_get for the same part, or zg_part_meshes_clear. */
const ZgPartMesh *zg_part_meshes_get(ZgPartMeshes *m, gint64 index);
/* After a slice, an undo, or a switch of the plate: the next get of each
 * part checks its mesh. */
void zg_part_meshes_check(ZgPartMeshes *m);
/* No sessions. */
void zg_part_meshes_clear(ZgPartMeshes *m);
