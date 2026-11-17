// gl.js: draws the frame data of the 3D view (view.js) with WebGL2.
//
// The draw calls are those of the Vulkan backend (src/render/vk.zig,
// Renderer.draw): the grid lines, the beads (instanced draws of one bead
// mesh), the marks, the beads out of a focus as ghosts (blended, no depth
// write), the extras, and the see-through toolhead of a replay. The
// shaders are ports of src/render/shaders/*.vert and *.frag to GLSL ES
// 3.00; change them together.
//
// WebGL2 has no base instance, so a draw that starts at instance k binds
// the instance attributes k * 32 bytes into the buffer, and the shader adds
// k (the uniform `base`) to gl_InstanceID.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

const MAX_EXTRAS = 4096; // max_extras in src/render/frame.zig
const STRIDE = 32; // the size of one instance (zs_web_instance)

const boxVert = `#version 300 es
// A port of src/render/shaders/box.vert. One bead of plastic for each
// toolpath segment (instanced).
precision highp float;
precision highp int;

layout(location = 0) in vec4 tv;
layout(location = 2) in vec4 seg;
layout(location = 3) in vec3 zhw;
layout(location = 4) in vec4 color;

uniform mat4 mvp;
uniform vec4 light;
uniform vec4 eye;
uniform vec4 params;
uniform float base;

out vec3 vcolor;
out vec3 vnormal;
out vec3 vpos;
out float vhigh;
out float vfocus;

const vec3 feature_rgb[14] = vec3[14](
    vec3(0.851, 0.282, 0.059), vec3(0.961, 0.624, 0.000),
    vec3(0.110, 0.494, 0.839), vec3(0.169, 0.541, 0.243),
    vec3(0.682, 0.243, 0.788), vec3(0.553, 0.431, 0.388),
    vec3(0.678, 0.710, 0.741), vec3(0.286, 0.314, 0.341),
    vec3(0.047, 0.651, 0.682), vec3(0.510, 0.788, 0.118),
    vec3(0.400, 0.800, 0.949),
    vec3(0.878, 0.102, 0.149), vec3(0.200, 0.451, 0.949),
    vec3(0.949, 0.251, 0.749));

void main() {
    vec2 a = seg.xy;
    vec2 b = seg.zw;
    vec2 d = b - a;
    float len = length(d);
    vec2 dir = len > 0.0 ? d / len : vec2(1.0, 0.0);
    vec2 side = vec2(-dir.y, dir.x);
    float h = zhw.y;
    float w = zhw.z;
    vec2 c = mix(a, b, tv.x);
    float r = min(h, w) * 0.5;
    float core = max(0.5 * w - r, 0.0);
    float zmid = zhw.x - 0.5 * h;
    vec3 pos;
    vec3 n;
    if (tv.w > 0.5) {
        pos = vec3(c, zmid + r);
        n = vec3(0.0, 0.0, 1.0);
    } else if (tv.w < -0.5) {
        pos = vec3(c, zmid - r);
        n = vec3(0.0, 0.0, -1.0);
    } else {
        vec2 np = dir * cos(tv.y) + side * sin(tv.y);
        uint feat = uint(color.a * 255.0 + 0.5);
        if (feat == 2u || feat == 7u) {
            float hw = 0.52 * w;
            float hh = 0.5 * h;
            float rr = 0.15 * min(h, w);
            float sp = sin(tv.z);
            float cp = cos(tv.z);
            float x = (hw - rr) + rr * cp;
            float z = sign(sp) * (hh - rr) + rr * sp;
            pos = vec3(c + np * x, zmid + z);
            n = normalize(vec3(np * cp, sp));
        } else {
            float out_r = core + r * cos(tv.z);
            pos = vec3(c + np * out_r, zmid + r * sin(tv.z));
            n = normalize(vec3(np * cos(tv.z), sin(tv.z)));
        }
    }
    vcolor = color.rgb;
    vnormal = n;
    vpos = pos;
    float idx = float(gl_InstanceID) + base;
    vhigh = (idx >= params.x && idx < params.y) ? 1.0 : 0.0;
    bool isolate = params.z < -0.5;
    uint mask = isolate ? 0u : uint(params.z + 0.5);
    uint feature = uint(color.a * 255.0 + 0.5);
    bool in_mask = ((mask >> feature) & 1u) != 0u;
    vfocus = (mask == 0u || (in_mask && zhw.x <= eye.w + 1e-4)) ? 1.0 : 0.0;
    if (isolate) vfocus = vhigh;
    if (mask != 0u && vfocus > 0.5 && params.w < 0.5) vcolor = feature_rgb[min(feature, 13u)];
    if (feature >= 14u) {
        vfocus = 1.0;
        vhigh = -1.0;
    } else if (feature >= 12u && !in_mask) {
        gl_Position = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }
    gl_Position = mvp * vec4(pos, 1.0);
    // The matrix is for the clip space of Vulkan: y down, depth 0 to 1.
    gl_Position.y = -gl_Position.y;
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}`;

const boxFrag = `#version 300 es
// A port of src/render/shaders/box.frag.
precision highp float;

uniform vec4 light;
uniform vec4 eye;
uniform vec4 params;

in vec3 vcolor;
in vec3 vnormal;
in vec3 vpos;
in float vhigh;
in float vfocus;
out vec4 frag;

vec3 toLinear(vec3 c) { return pow(c, vec3(2.2)); }
vec3 toSrgb(vec3 c) { return pow(clamp(c, 0.0, 1.0), vec3(1.0 / 2.2)); }

void main() {
    bool focus = params.z > 0.5 || params.z < -0.5;
    if (focus && params.w > 1.5 && params.w < 2.5) {
        if (vfocus > 0.5) discard;
        float rim = 1.0 - abs(dot(normalize(vnormal), normalize(eye.xyz - vpos)));
        frag = vec4(vec3(0.55, 0.58, 0.62), 0.03 + 0.09 * rim);
        return;
    }
    if (focus && vfocus < 0.5) discard;
    vec3 n = normalize(vnormal);
    vec3 l = normalize(light.xyz);
    vec3 v = normalize(eye.xyz - vpos);
    vec3 base = toLinear(vcolor);
    if (params.y > params.x && vhigh > 0.5) {
        base = toLinear(vec3(1.0, 0.78, 0.05));
    }
    float ambient = mix(0.18, 0.32, 0.5 + 0.5 * n.z);
    float diffuse = max(dot(n, l), 0.0);
    vec3 hv = normalize(l + v);
    float spec = pow(max(dot(n, hv), 0.0), 40.0) * 0.18;
    vec3 c = base * (ambient + 0.85 * diffuse) + vec3(spec);
    if (params.w > 2.5) {
        float rim = 1.0 - abs(dot(n, v));
        frag = vec4(toSrgb(c + vec3(0.25 * rim * rim)), 0.38 + 0.3 * rim);
        return;
    }
    frag = vec4(toSrgb(c), 1.0);
}`;

const gridVert = `#version 300 es
// A port of src/render/shaders/grid.vert.
precision highp float;
layout(location = 0) in vec3 pos;
uniform mat4 mvp;
void main() {
    gl_Position = mvp * vec4(pos, 1.0);
    gl_Position.y = -gl_Position.y;
    gl_Position.z = 2.0 * gl_Position.z - gl_Position.w;
}`;

const gridFrag = `#version 300 es
precision highp float;
uniform vec4 color;
out vec4 frag;
void main() {
    frag = vec4(color.rgb, 1.0);
}`;

function compile(gl, vs, fs) {
  const prog = gl.createProgram();
  for (const [type, src] of [[gl.VERTEX_SHADER, vs], [gl.FRAGMENT_SHADER, fs]]) {
    const sh = gl.createShader(type);
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) throw new Error(`shader: ${gl.getShaderInfoLog(sh)}`);
    gl.attachShader(prog, sh);
  }
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(`program: ${gl.getProgramInfoLog(prog)}`);
  const u = {};
  const n = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < n; i++) {
    const name = gl.getActiveUniform(prog, i).name;
    u[name] = gl.getUniformLocation(prog, name);
  }
  return { prog, u };
}

export class GlRenderer {
  constructor(canvas) {
    const gl = canvas.getContext("webgl2", { antialias: true, alpha: false, preserveDrawingBuffer: true });
    if (!gl) throw new Error("This browser has no WebGL2.");
    this.gl = gl;
    this.box = compile(gl, boxVert, boxFrag);
    this.grid = compile(gl, gridVert, gridFrag);
    this.meshVbo = gl.createBuffer();
    this.meshIbo = gl.createBuffer();
    this.instVbo = gl.createBuffer();
    this.gridVbo = gl.createBuffer();
    this.boxVao = gl.createVertexArray();
    this.gridVao = gl.createVertexArray();
    this.gen = { mesh: -1, instances: -1, grid: -1 };
    this.indexCount = 0;
    this.instanceCount = 0;
    this.instCapacity = 0;

    gl.bindVertexArray(this.gridVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.gridVbo);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 12, 0);

    gl.bindVertexArray(this.boxVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.meshVbo);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 4, gl.FLOAT, false, 16, 0);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.meshIbo);
    for (const loc of [2, 3, 4]) {
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribDivisor(loc, 1);
    }
    gl.bindVertexArray(null);
  }

  // Binds the instance attributes from instance `first` on.
  bindInstances(first) {
    const gl = this.gl;
    const off = first * STRIDE;
    gl.bindBuffer(gl.ARRAY_BUFFER, this.instVbo);
    gl.vertexAttribPointer(2, 4, gl.FLOAT, false, STRIDE, off);
    gl.vertexAttribPointer(3, 3, gl.FLOAT, false, STRIDE, off + 16);
    gl.vertexAttribPointer(4, 4, gl.UNSIGNED_BYTE, true, STRIDE, off + 28);
  }

  setPush(push) {
    const gl = this.gl;
    const u = this.box.u;
    gl.uniformMatrix4fv(u.mvp, false, push.subarray(0, 16));
    gl.uniform4fv(u.light, push.subarray(16, 20));
    gl.uniform4fv(u.eye, push.subarray(20, 24));
    gl.uniform4fv(u.params, push.subarray(24, 28));
  }

  drawBeads(first, count) {
    if (count <= 0) return;
    const gl = this.gl;
    this.bindInstances(first);
    gl.uniform1f(this.box.u.base, first);
    gl.drawElementsInstanced(gl.TRIANGLES, this.indexCount, gl.UNSIGNED_SHORT, 0, count);
  }

  // Draws one frame of view.js (View3D.frame).
  draw(f) {
    const gl = this.gl;
    // The buffers that changed.
    if (f.meshGen !== this.gen.mesh) {
      gl.bindVertexArray(null);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.meshVbo);
      gl.bufferData(gl.ARRAY_BUFFER, f.meshVerts, gl.STATIC_DRAW);
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.meshIbo);
      gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, f.meshIndex, gl.STATIC_DRAW);
      this.indexCount = f.meshIndex.length;
      this.gen.mesh = f.meshGen;
    }
    if (f.instancesGen !== this.gen.instances) {
      gl.bindBuffer(gl.ARRAY_BUFFER, this.instVbo);
      const need = (f.instanceCount + MAX_EXTRAS) * STRIDE;
      if (need > this.instCapacity) {
        gl.bufferData(gl.ARRAY_BUFFER, need, gl.DYNAMIC_DRAW);
        this.instCapacity = need;
      }
      if (f.instances.length > 0) gl.bufferSubData(gl.ARRAY_BUFFER, 0, f.instances);
      this.instanceCount = f.instanceCount;
      this.gen.instances = f.instancesGen;
    }
    if (f.gridGen !== this.gen.grid) {
      gl.bindBuffer(gl.ARRAY_BUFFER, this.gridVbo);
      gl.bufferData(gl.ARRAY_BUFFER, f.gridPoints, gl.STATIC_DRAW);
      this.gen.grid = f.gridGen;
    }

    gl.viewport(0, 0, f.width, f.height);
    gl.clearColor(f.clear[0], f.clear[1], f.clear[2], 1);
    gl.clearDepth(1);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.LEQUAL);
    gl.disable(gl.CULL_FACE);
    gl.disable(gl.BLEND);
    gl.depthMask(true);

    if (f.gridVertices > 0) {
      gl.useProgram(this.grid.prog);
      gl.uniformMatrix4fv(this.grid.u.mvp, false, f.grid.subarray(0, 16));
      gl.uniform4fv(this.grid.u.color, f.grid.subarray(16, 20));
      gl.bindVertexArray(this.gridVao);
      gl.drawArrays(gl.LINES, 0, f.gridVertices);
    }

    if (this.indexCount === 0 || this.instCapacity === 0) return;
    gl.useProgram(this.box.prog);
    gl.bindVertexArray(this.boxVao);
    this.setPush(f.box);
    const first = Math.min(f.boxFirst, f.boxCount);
    this.drawBeads(first, f.boxCount - first);
    this.drawBeads(f.markFirst, f.markCount);
    // With a focus: the beads out of it, as ghosts (params.w = 2).
    if (f.box[26] !== 0) {
      const ghost = f.box.slice();
      ghost[27] = 2;
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      gl.depthMask(false);
      this.setPush(ghost);
      this.drawBeads(first, f.boxCount - first);
      this.drawBeads(f.markFirst, f.markCount);
      gl.disable(gl.BLEND);
      gl.depthMask(true);
      this.setPush(f.box);
    }
    // The extras and the toolhead, in the spare slots after the instances.
    gl.bindBuffer(gl.ARRAY_BUFFER, this.instVbo);
    if (f.extrasCount > 0) {
      gl.bufferSubData(gl.ARRAY_BUFFER, this.instanceCount * STRIDE, f.extras);
      this.drawBeads(this.instanceCount, f.extrasCount);
    }
    if (f.headCount > 0) {
      const at = this.instanceCount + f.extrasCount;
      gl.bindBuffer(gl.ARRAY_BUFFER, this.instVbo);
      gl.bufferSubData(gl.ARRAY_BUFFER, at * STRIDE, f.head);
      const see = f.box.slice();
      see[26] = 0;
      see[27] = 3;
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      gl.depthMask(false);
      this.setPush(see);
      this.drawBeads(at, f.headCount);
      gl.disable(gl.BLEND);
      gl.depthMask(true);
    }
    gl.bindVertexArray(null);
  }
}
