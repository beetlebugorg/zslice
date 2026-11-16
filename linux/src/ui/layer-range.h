/* layer-range.h: a vertical slider with two knobs, for the layers that the
 * preview shows: the top knob is the highest layer, and the bottom knob is
 * the lowest layer. Layer 0 is at the bottom.
 *
 * The widget uses the CSS nodes of a GtkScale (scale, trough, highlight,
 * slider), so the theme draws it as a native scale.
 *
 * Input: drag a knob (a press on the trough moves the nearer knob); the
 * arrow keys and the wheel move the top knob, and with Shift the bottom
 * knob; Page Up and Page Down move 10 layers; Home and End go to the ends.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

#define ZG_TYPE_LAYER_RANGE (zg_layer_range_get_type())
G_DECLARE_FINAL_TYPE(ZgLayerRange, zg_layer_range, ZG, LAYER_RANGE, GtkWidget)

GtkWidget *zg_layer_range_new(void);
/* The number of layers. The knobs stay in 0 .. count - 1. */
void zg_layer_range_set_count(ZgLayerRange *self, size_t count);
size_t zg_layer_range_get_count(ZgLayerRange *self);
/* Sets the knobs, with no "changed" signal. */
void zg_layer_range_set(ZgLayerRange *self, size_t lo, size_t hi);
size_t zg_layer_range_get_lo(ZgLayerRange *self);
size_t zg_layer_range_get_hi(ZgLayerRange *self);

/* Signal "changed" (void): the user moved a knob. */

G_END_DECLS
