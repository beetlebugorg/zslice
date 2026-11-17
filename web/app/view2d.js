// view2d.js: the 2D layer view (linux/src/ui/preview.c, the "2d" page):
// one layer from the top, the bed, the outline of the layer, and the
// beads in their feature colors. A drag pans, the wheel zooms toward the
// pointer, and a double click fits the part in the view.
//
// The data is in the core: the view of the main thread (view.js) gives
// the beads of a layer and of a path, the outlines, and a pick in mm. The
// beads are the instances of the 3D view on the GPU, so gl.js draws a
// layer with one range of them. A new layer costs no upload and no
// allocation.
//
// The camera maps mm to device pixels: a point (x, y) is at
// (ox + x * scale, oy + y * scale) from the bottom left of the canvas. The
// y axis goes up, as on the bed.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

export class View2D {
  constructor(view, gl) {
    this.view = view;
    this.gl = gl;
    this.scale = 1;
    this.ox = 0;
    this.oy = 0;
    this.fitted = false;
    // The draw state for gl.draw2d, made once.
    this.state = {
      width: 1, height: 1, scale: 1, ox: 0, oy: 0, layer: 0,
      beads: new Uint32Array(2), marks: new Uint32Array(2), sel: new Uint32Array(2),
      seg: -1, mask: 0, dim: 0,
    };
    this.selRange = new Uint32Array(2);
  }

  // Fits the beads (or the bed, with no beads) in the view: 85 % of it,
  // as preview.c does.
  fit(width, height) {
    const b = this.view.bounds() ?? [0, 0, this.gl.bed[0] || 220, this.gl.bed[1] || 220];
    const bw = Math.max(b[2] - b[0], 1);
    const bh = Math.max(b[3] - b[1], 1);
    this.scale = 0.85 * Math.min(width / bw, height / bh);
    this.ox = width / 2 - ((b[0] + b[2]) / 2) * this.scale;
    this.oy = height / 2 - ((b[1] + b[3]) / 2) * this.scale;
    this.fitted = true;
  }

  // A drag of dx, dy device pixels (y down on the screen).
  pan(dx, dy) {
    this.ox += dx;
    this.oy -= dy;
  }

  // Zooms by `factor` about the device pixel (px, py) from the top left.
  zoomAt(factor, px, py, height) {
    const y = height - py;
    const mx = (px - this.ox) / this.scale;
    const my = (y - this.oy) / this.scale;
    this.scale = Math.min(2000, Math.max(0.05, this.scale * factor));
    this.ox = px - mx * this.scale;
    this.oy = y - my * this.scale;
  }

  // The path and the segment at a device pixel on `layer`: sets
  // view.hit and returns true, or returns false.
  pick(layer, px, py, height) {
    const x = (px - this.ox) / this.scale;
    const y = (height - py - this.oy) / this.scale;
    return this.view.pickLayer(layer, x, y);
  }

  // Draws `layer`. sel: the selected path (-1: none), seg its segment
  // (-1: none); mask: the focus bits; dim: 1 to draw all beads faint
  // ("Fade others" with a selection, or a focus on the first layer while
  // this is another layer).
  draw(width, height, layer, sel, seg, mask, dim) {
    if (!this.fitted) this.fit(width, height);
    const s = this.state;
    const v = this.view;
    s.width = width;
    s.height = height;
    s.scale = this.scale;
    s.ox = this.ox;
    s.oy = this.oy;
    s.layer = layer;
    s.mask = mask;
    s.dim = dim;
    v.layerBeads(layer, s.beads);
    v.layerMarks(layer, s.marks);
    s.sel[0] = 0;
    s.sel[1] = 0;
    s.seg = -1;
    if (sel >= 0) {
      v.pathBeads(sel, this.selRange);
      // Only a path of this layer shows.
      if (this.selRange[0] >= s.beads[0] && this.selRange[1] <= s.beads[1]) {
        s.sel[0] = this.selRange[0];
        s.sel[1] = this.selRange[1];
        if (seg >= 0 && this.selRange[0] + seg < this.selRange[1]) s.seg = this.selRange[0] + seg;
      }
    }
    this.gl.draw2d(s);
  }
}
