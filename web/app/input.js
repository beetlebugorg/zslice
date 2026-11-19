// input.js: the mouse, the touch screen, and the wheel over the view (the
// canvas of app.js).
//
// The mouse. In 3D: a left drag orbits, a middle or a right drag (or Shift
// and a drag) pans, and the wheel zooms toward the pointer
// (linux/src/ui/view3d.c). On a trackpad: two fingers pressed down and
// dragged pan, and a light two-finger swipe or a pinch zooms.
// In 2D: a drag pans, and the wheel zooms (preview.c). In both: a click (a
// release within 4 pixels of the press) selects the line under the
// pointer, and a right click opens the context menu there.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// ctx: { app, view (View3D), view2d, tools (tools.js), supportTool
//        (support.js), requestFrame(), pickAt(px, py, picked), hitAt(px,
//        py), select(path, seg, picked), showContextMenu(x, y),
//        activatePlate(i, frame) }
export function attachViewInput(canvas, ctx) {
  const { app, view, view2d, tools, supportTool, requestFrame, pickAt, hitAt, select, showContextMenu, activatePlate, grab } = ctx;
  let drag = null;
  const dpr = () => window.devicePixelRatio || 1;

  // Two fingers on a touch screen: a pinch zooms about the point between
  // them, and a move of that point pans. These listeners run first (the
  // capture phase) and stop the one-pointer handlers while two fingers are
  // down. One finger orbits, as a left drag does.
  const touches = new Map();
  let pinch = null;
  const touchPair = () => {
    const [a, b] = [...touches.values()];
    return { dist: Math.hypot(a.x - b.x, a.y - b.y), mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2 };
  };
  canvas.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch") return;
    touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (touches.size === 2) {
      canvas.setPointerCapture(e.pointerId);
      // The first finger's drag ends: no orbit, and no click at the end.
      drag = null;
      pinch = touchPair();
      e.stopImmediatePropagation();
    }
  }, { capture: true });
  canvas.addEventListener("pointermove", (e) => {
    if (e.pointerType !== "touch" || !touches.has(e.pointerId)) return;
    touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (!pinch || touches.size !== 2) return;
    e.stopImmediatePropagation();
    const now = touchPair();
    const r = canvas.getBoundingClientRect();
    const px = (now.mx - r.left) * dpr();
    const py = (now.my - r.top) * dpr();
    const k = pinch.dist > 0 && now.dist > 0 ? now.dist / pinch.dist : 1;
    if (app.page === "2d") {
      view2d.pan((now.mx - pinch.mx) * dpr(), (now.my - pinch.my) * dpr());
      if (k !== 1) view2d.zoomAt(k, px, py, canvas.height);
    } else {
      view.pan((now.mx - pinch.mx) * dpr(), (now.my - pinch.my) * dpr());
      if (k !== 1) view.zoomAt(1 / k, px, py);
    }
    pinch = now;
    requestFrame();
  }, { capture: true });
  const touchUp = (e) => {
    if (e.pointerType !== "touch") return;
    touches.delete(e.pointerId);
    if (pinch) {
      // The end of a pinch is no click, also for the last finger.
      e.stopImmediatePropagation();
      if (touches.size === 0) pinch = null;
      drag = null;
      canvas.style.cursor = "";
    }
  };
  canvas.addEventListener("pointerup", touchUp, { capture: true });
  canvas.addEventListener("pointercancel", touchUp, { capture: true });

  canvas.addEventListener("pointerdown", (e) => {
    if (pinch) return;
    canvas.setPointerCapture(e.pointerId);
    drag = { button: e.button, x: e.clientX, y: e.clientY, x0: e.clientX, y0: e.clientY, moved: false, part: null };
    canvas.style.cursor = "grabbing";
    canvas.focus({ preventScroll: true });
    // The measure tape: a left drag on an end of it moves that end.
    if (e.button === 0 && tools.tool === "measure" && tools.pts.length > 0) {
      const r = canvas.getBoundingClientRect();
      const end = tools.endAt((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr(), dpr());
      if (end >= 0) {
        drag.tape = end;
        canvas.style.cursor = "grabbing";
        return;
      }
    }
    // The Grab tool in 3D: a press on a part takes it in the hand.
    if (e.button === 0 && app.page === "3d" && view.loaded && tools.tool === "grab" && grab) {
      const d = drag;
      d.hand = "pending";
      const r = canvas.getBoundingClientRect();
      grab.start((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr()).then((ok) => {
        if (drag === d) d.hand = ok ? "on" : null;
        else if (ok) grab.end();
      });
      return;
    }
    // The move tool, or Ctrl, in 3D: a left drag on a part moves it.
    if (e.button === 0 && app.page === "3d" && view.loaded && (tools.tool === "move" || e.ctrlKey)) {
      const d = drag;
      d.part = "pending";
      const r = canvas.getBoundingClientRect();
      tools.moveStart((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr()).then((ok) => {
        if (drag === d) d.part = ok ? "moving" : null;
      });
    }
  });
  canvas.addEventListener("pointermove", (e) => {
    if (!drag) return;
    const dx = e.clientX - drag.x;
    const dy = e.clientY - drag.y;
    drag.x = e.clientX;
    drag.y = e.clientY;
    if (dx === 0 && dy === 0) return;
    if (Math.abs(e.clientX - drag.x0) > 4 || Math.abs(e.clientY - drag.y0) > 4) drag.moved = true;
    if (drag.tape !== undefined) {
      const r = canvas.getBoundingClientRect();
      tools.dragEnd(drag.tape, (e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr(), e.shiftKey);
      return;
    }
    if (drag.part === "moving") {
      const r = canvas.getBoundingClientRect();
      tools.moveTo((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr());
      return;
    }
    if (drag.hand) {
      if (drag.hand !== "on") return;
      // Alt and a drag: turn the part in the hand (0.5 degree a pixel).
      // Shift snaps the turn to steps of 15 degrees.
      if (e.altKey) {
        const t = (drag.turn ??= { yaw: 0, tilt: 0, sentYaw: 0, sentTilt: 0 });
        t.yaw += dx * 0.5;
        t.tilt += dy * 0.5;
        const snap = (v) => (e.shiftKey ? Math.round(v / 15) * 15 : v);
        const yaw = snap(t.yaw) - t.sentYaw;
        const tilt = snap(t.tilt) - t.sentTilt;
        if (yaw || tilt) {
          grab.turn(yaw, tilt);
          t.sentYaw += yaw;
          t.sentTilt += tilt;
        }
        return;
      }
      const r = canvas.getBoundingClientRect();
      grab.move((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr());
      return;
    }
    if (drag.part === "pending") return;
    // A left drag orbits. A right drag (two fingers pressed down on a
    // touchpad) and a middle drag pan, as Shift with a left drag does.
    if (app.page === "2d") view2d.pan(dx * dpr(), dy * dpr());
    else if (drag.button === 1 || drag.button === 2 || e.shiftKey) view.pan(dx * dpr(), dy * dpr());
    else view.orbit(dx, dy);
    requestFrame();
  });
  canvas.addEventListener("pointerup", (e) => {
    const d = drag;
    endDrag();
    if (d?.hand) {
      grab.end();
      return;
    }
    if (d?.part === "moving") {
      tools.moveEnd();
      return;
    }
    // A press on an end of the tape: a drag moved it; a click leaves it.
    if (d?.tape !== undefined) return;
    if (!d || d.moved || !view.loaded) return;
    const r = canvas.getBoundingClientRect();
    const px = (e.clientX - r.left) * dpr();
    const py = (e.clientY - r.top) * dpr();
    // A click on another plate (its bed or its beads) makes it active.
    if (d.button === 0 && app.page === "3d" && app.plates.length > 1) {
      const i = view.plateAt(px, py);
      if (i >= 0 && i !== app.activePlate) {
        activatePlate(i, false);
        return;
      }
    }
    if (d.button === 0 && tools.tool === "support" && app.page === "3d") supportTool.click(px, py, e.shiftKey, e.altKey);
    else if (d.button === 0 && tools.tool === "measure") tools.measureClick(px, py, e.shiftKey);
    else if (d.button === 0 && app.page === "3d" && (tools.tool === "move" || tools.tool === "turn" || e.ctrlKey)) tools.pickPart(px, py);
    else if (d.button === 0) pickAt(px, py, true);
    else if (d.button === 2) {
      // A right click: the line there, then the menu.
      if (hitAt(px, py)) select(view.hit[0], view.hit[1], false);
      showContextMenu(e.clientX, e.clientY);
    }
  });
  const endDrag = () => {
    drag = null;
    canvas.style.cursor = "";
  };
  canvas.addEventListener("pointercancel", endDrag);
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());
  // A double click: on another plate (with more than one), the camera goes
  // to it and it becomes the active plate; on a side of a part (3D), the view
  // turns to face that side and zooms to it; elsewhere, the view resets.
  canvas.addEventListener("dblclick", async (e) => {
    if (app.page === "2d") {
      view2d.fit(canvas.width, canvas.height);
      requestFrame();
      return;
    }
    if (app.plates.length > 1) {
      const r = canvas.getBoundingClientRect();
      const i = view.plateAt((e.clientX - r.left) * dpr(), (e.clientY - r.top) * dpr());
      if (i >= 0 && i !== app.activePlate) {
        activatePlate(i, true);
        return;
      }
    }
    const px = e.offsetX * dpr();
    const py = e.offsetY * dpr();
    // The side of the print under the pointer (zs_view_look_at_side), from
    // the size of its part.
    const part = app.state !== "empty" ? await tools.partAt(px, py) : null;
    const size = part ? Math.max(part.sizeX, part.sizeY, part.sizeZ) : 0;
    if (app.state !== "empty" && view.x.zs_view_look_at_side(view.v, px, py, size)) {
      // The first click of the double click picked a line: not wanted.
      select(-1, -1, false);
      requestFrame();
      return;
    }
    view.resetSmooth();
    requestFrame();
  });
  // A wheel event from a trackpad: two fingers that move (pixels, small
  // steps, or a sideways part) pan the view, as in Fusion and Tinkercad. A
  // mouse wheel gives steps of 100 pixels or more, or lines, and zooms. A
  // pinch has Ctrl, and zooms. Shift and a mouse wheel: zoom too.
  let trackpadUntil = 0;
  function fromTrackpad(e) {
    if (e.ctrlKey || e.deltaMode !== 0) return false;
    const now = performance.now();
    // A sideways part, or a small step: a trackpad. Its next events in the
    // same gesture count as the trackpad too (a fast swipe has big steps).
    if (e.deltaX !== 0 || Math.abs(e.deltaY) < 50 || !Number.isInteger(e.deltaY)) {
      trackpadUntil = now + 300;
      return true;
    }
    return now < trackpadUntil;
  }

  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const r = canvas.getBoundingClientRect();
    // The hand holds a part: the wheel lifts it or lowers it.
    if (grab?.holding()) {
      grab.lift(e.deltaMode === 1 ? e.deltaY * 33 : e.deltaY);
      return;
    }
    // The move tool and a mouse wheel: turn the selected part 15° a step.
    if (tools.tool === "move" && tools.part && !e.ctrlKey && !fromTrackpad(e)) {
      tools.turn(e.deltaY);
      return;
    }
    if (fromTrackpad(e)) {
      // A two-finger swipe zooms toward the pointer, as a pinch does: 40
      // pixels of the swipe are one wheel step.
      const steps = e.deltaY / 40;
      const px = (e.clientX - r.left) * dpr();
      const py = (e.clientY - r.top) * dpr();
      if (app.page === "2d") view2d.zoomAt(Math.pow(1.2, -steps), px, py, canvas.height);
      else view.zoomAt(Math.pow(1.15, steps), px, py);
      requestFrame();
      return;
    }
    // One wheel step is about 100 pixels (deltaMode 0) or 3 lines.
    // A pinch on a trackpad comes as a wheel event with Ctrl and small
    // steps, so it counts more for each pixel.
    const per = e.ctrlKey ? 25 : 100;
    const steps = e.deltaMode === 1 ? e.deltaY / 3 : e.deltaMode === 2 ? e.deltaY : e.deltaY / per;
    const px = (e.clientX - r.left) * dpr();
    const py = (e.clientY - r.top) * dpr();
    if (app.page === "2d") view2d.zoomAt(Math.pow(1.2, -steps), px, py, canvas.height);
    else view.zoomAt(Math.pow(1.15, steps), px, py);
    requestFrame();
  }, { passive: false });
}
