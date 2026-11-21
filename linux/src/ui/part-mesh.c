/* part-mesh.c: see part-mesh.h.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#include "part-mesh.h"

#include <string.h>

struct ZgPartMeshes {
    ZgModel *model;
    zs_app *core;
    GHashTable *parts; /* part index -> ZgPartMesh */
    guint gen;
};

static void entry_free(gpointer data) {
    ZgPartMesh *e = data;
    if (e->session) zs_paint_free(e->session);
    g_free(e->verts);
    g_free(e->faces);
    g_free(e);
}

ZgPartMeshes *zg_part_meshes_new(ZgModel *model) {
    ZgPartMeshes *m = g_new0(ZgPartMeshes, 1);
    m->model = model;
    m->parts = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, entry_free);
    return m;
}

void zg_part_meshes_free(ZgPartMeshes *m) {
    if (!m) return;
    g_hash_table_destroy(m->parts);
    g_free(m);
}

void zg_part_meshes_clear(ZgPartMeshes *m) {
    g_hash_table_remove_all(m->parts);
}

void zg_part_meshes_check(ZgPartMeshes *m) {
    GHashTableIter it;
    gpointer value;
    g_hash_table_iter_init(&it, m->parts);
    while (g_hash_table_iter_next(&it, NULL, &value)) ((ZgPartMesh *)value)->check = TRUE;
}

const ZgPartMesh *zg_part_meshes_get(ZgPartMeshes *m, gint64 index) {
    zs_app *core = zg_model_core(m->model);
    /* Another plate: its parts are other parts. */
    if (core != m->core) {
        g_hash_table_remove_all(m->parts);
        m->core = core;
    }
    if (index < 0 || (size_t)index >= zs_app_part_count(core)) return NULL;
    ZgPartMesh *have = g_hash_table_lookup(m->parts, GINT_TO_POINTER((int)index));
    if (have && !have->check) return have;
    const float *verts = NULL;
    const uint32_t *faces = NULL;
    size_t nv = 0, nf = 0;
    if (zs_app_part_mesh(core, (size_t)index, &verts, &nv, &faces, &nf) != ZS_OK || nf == 0) {
        g_hash_table_remove(m->parts, GINT_TO_POINTER((int)index));
        return NULL;
    }
    /* The same mesh: the session stays. */
    if (have && have->nv == nv && have->nf == nf && memcmp(have->verts, verts, 3 * nv * sizeof *verts) == 0 &&
        memcmp(have->faces, faces, 3 * nf * sizeof *faces) == 0) {
        have->check = FALSE;
        return have;
    }
    zs_paint *s = NULL;
    if (zs_paint_new(verts, nv, faces, nf, &s) != ZS_OK) {
        g_hash_table_remove(m->parts, GINT_TO_POINTER((int)index));
        return NULL;
    }
    ZgPartMesh *e = g_new0(ZgPartMesh, 1);
    e->session = s;
    e->verts = g_memdup2(verts, 3 * nv * sizeof *verts);
    e->faces = g_memdup2(faces, 3 * nf * sizeof *faces);
    e->nv = nv;
    e->nf = nf;
    e->gen = ++m->gen;
    g_hash_table_replace(m->parts, GINT_TO_POINTER((int)index), e);
    return e;
}
