#pragma once
// The signs of the plates: a small card on the bed in front of each plate,
// with its name, its printer, and its status or its print time. The core
// draws them in the world (zs_view_set_signs), and this code draws their
// text into one image, as the other shells do.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstdint>
#include <string>
#include <vector>

#include "zslice-app.h"

namespace zs
{
    struct SignImage
    {
        std::vector<float> rects; // x, y, w, h for each plate
        std::vector<uint8_t> rgba;
        uint32_t width = 0;
        uint32_t height = 0;
        float scale = 1; // the image pixels for one view pixel
    };

    // The signs of the set at the view scale `dpi_scale`. `key` holds the
    // text of the last image. False when the signs did not change.
    bool DrawPlateSigns(zs_set *set, double dpi_scale, std::wstring &key, SignImage &out);
}
