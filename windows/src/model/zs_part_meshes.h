#pragma once
// The meshes of the parts of one plate, for the Paint and Label tools. Each
// mesh has a paint session (zs_paint), which picks a triangle under a ray
// and keeps the regions of the smart select. A session is slow to make, so
// it stays until the mesh of its part changes. The cache follows
// linux/src/ui/part-mesh.c. It has no WinRT.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <vector>

#include "zslice.h"
#include "zslice-app.h"

namespace zs
{
    struct PartMesh
    {
        PartMesh() = default;
        ~PartMesh();
        PartMesh(PartMesh const &) = delete;
        PartMesh &operator=(PartMesh const &) = delete;

        zs_paint *session = nullptr;
        std::vector<float> verts;
        std::vector<uint32_t> faces;
        size_t nv = 0;
        size_t nf = 0;
        // A new number for each new mesh: the tools compare it with the
        // mesh that the view has.
        unsigned gen = 0;
        // The part can have moved: the next Get compares the mesh.
        bool check = false;
    };

    class PartMeshes
    {
    public:
        // The mesh of part `index` of `app`, or null. Another app drops the
        // meshes of the plate before.
        PartMesh *Get(zs_app *app, int64_t index);
        // Each mesh is compared with its part at its next Get.
        void CheckAll();
        void Clear();

    private:
        zs_app *app_ = nullptr;
        unsigned gen_ = 0;
        std::map<int64_t, std::unique_ptr<PartMesh>> parts_;
    };
}
