// See zs_part_meshes.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_part_meshes.h"

#include <cstring>

namespace zs
{
    PartMesh::~PartMesh()
    {
        if (session != nullptr)
            zs_paint_free(session);
    }

    void PartMeshes::CheckAll()
    {
        for (auto &entry : parts_)
            entry.second->check = true;
    }

    void PartMeshes::Clear()
    {
        parts_.clear();
    }

    PartMesh *PartMeshes::Get(zs_app *app, int64_t index)
    {
        // Another plate: its parts are other parts.
        if (app != app_)
        {
            parts_.clear();
            app_ = app;
        }
        if (app == nullptr || index < 0 || (size_t)index >= zs_app_part_count(app))
            return nullptr;
        auto found = parts_.find(index);
        PartMesh *have = found != parts_.end() ? found->second.get() : nullptr;
        if (have != nullptr && !have->check)
            return have;
        float const *verts = nullptr;
        uint32_t const *faces = nullptr;
        size_t nv = 0, nf = 0;
        if (zs_app_part_mesh(app, (size_t)index, &verts, &nv, &faces, &nf) != ZS_OK || nf == 0)
        {
            parts_.erase(index);
            return nullptr;
        }
        // The same mesh: the session stays.
        if (have != nullptr && have->nv == nv && have->nf == nf && std::memcmp(have->verts.data(), verts, 3 * nv * sizeof(float)) == 0 &&
            std::memcmp(have->faces.data(), faces, 3 * nf * sizeof(uint32_t)) == 0)
        {
            have->check = false;
            return have;
        }
        zs_paint *session = nullptr;
        if (zs_paint_new(verts, nv, faces, nf, &session) != ZS_OK)
        {
            parts_.erase(index);
            return nullptr;
        }
        auto mesh = std::make_unique<PartMesh>();
        mesh->session = session;
        mesh->verts.assign(verts, verts + 3 * nv);
        mesh->faces.assign(faces, faces + 3 * nf);
        mesh->nv = nv;
        mesh->nf = nf;
        mesh->gen = ++gen_;
        PartMesh *out = mesh.get();
        parts_[index] = std::move(mesh);
        return out;
    }
}
