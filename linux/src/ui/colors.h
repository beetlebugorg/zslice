/* colors.h: the feature colors of the previews, in the order of
 * enum zs_feature. All shells use these colors (docs/app/README.md).
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

static const double zg_feature_rgb[][3] = {
    {0.851, 0.282, 0.059}, /* outer wall: orange */
    {0.961, 0.624, 0.000}, /* inner wall: yellow */
    {0.110, 0.494, 0.839}, /* skin: blue */
    {0.169, 0.541, 0.243}, /* infill: green */
    {0.682, 0.243, 0.788}, /* ironing: purple */
    {0.553, 0.431, 0.388}, /* skirt and brim: brown */
    {0.678, 0.710, 0.741}, /* support: light gray */
    {0.286, 0.314, 0.341}, /* support interface: dark gray */
    {0.047, 0.651, 0.682}, /* slope smoothing: teal */
};

#define ZG_N_FEATURES (sizeof zg_feature_rgb / sizeof zg_feature_rgb[0])

/* The marks after the features (ZS_MARK_SEAM, ZS_MARK_TRAVEL,
 * ZS_MARK_RETRACT), as in src/render/view.zig. */
static const double zg_mark_rgb[][3] = {
    {0.878, 0.102, 0.149}, /* seam: red */
    {0.200, 0.451, 0.949}, /* travel: blue */
    {0.949, 0.251, 0.749}, /* retraction: pink */
};
