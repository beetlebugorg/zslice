// The transform tool: the Move tool (M, also R and G) with a gizmo on the
// selected part. A drag of a ring turns the part about an axis of the bed, a
// drag of an arrow moves it along X or Y or lifts it, and a drag of the part
// carries it on the bed with smart guides. The behavior follows the GTK
// shell (linux/src/ui/view3d.c) and web/app/gizmo.js. The core view draws
// the gizmo and finds its handles (zs_view_set_gizmo, zs_view_gizmo_at).
//
// A press and a release at one place is a click, also on a handle, so a drag
// starts only after the pointer moves more than 4 points. The beads follow a
// drag on each frame, and the selection model has the place at once
// (zs_sel_place), so a pick finds the part where it is now. The core gets
// the place when no slice runs, and slices a draft while the drag goes on.
//
// The gizmos of PrusaSlicer and OrcaSlicer are the reference for the idea:
// docs/references/prusaslicer.md.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <algorithm>
#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using Microsoft::UI::Input::InputSystemCursor;
using Microsoft::UI::Input::InputSystemCursorShape;

namespace
{
    constexpr double pi = 3.14159265358979323846;
    wchar_t const *const axis_names[] = { L"X", L"Y", L"Z" };

    double GizmoRadius(zs_part const &p)
    {
        return 0.62 * std::max({ p.size_x, p.size_y, p.size_z }) + 4;
    }

    double Hundredths(double v)
    {
        return std::round(v * 100) / 100;
    }

    // The turn q1 about c1 and the move m1 after the turn q0 about c0 and
    // the move m0: as one turn q about c0 and a move m.
    void TurnCompose(double const q1[4], double const c1[3], double const m1[3], double const q0[4], double const c0[3], double const m0[3],
                     double q[4], double m[3])
    {
        double const t[4] = {
            q1[3] * q0[0] + q1[0] * q0[3] + q1[1] * q0[2] - q1[2] * q0[1],
            q1[3] * q0[1] - q1[0] * q0[2] + q1[1] * q0[3] + q1[2] * q0[0],
            q1[3] * q0[2] + q1[0] * q0[1] - q1[1] * q0[0] + q1[2] * q0[3],
            q1[3] * q0[3] - q1[0] * q0[0] - q1[1] * q0[1] - q1[2] * q0[2],
        };
        // The point c0 + m0 - c1 turned by q1.
        double const d[3] = { c0[0] + m0[0] - c1[0], c0[1] + m0[1] - c1[1], c0[2] + m0[2] - c1[2] };
        double const x = q1[0], y = q1[1], z = q1[2], w = q1[3];
        double const r[3] = {
            (1 - 2 * (y * y + z * z)) * d[0] + 2 * (x * y - z * w) * d[1] + 2 * (x * z + y * w) * d[2],
            2 * (x * y + z * w) * d[0] + (1 - 2 * (x * x + z * z)) * d[1] + 2 * (y * z - x * w) * d[2],
            2 * (x * z - y * w) * d[0] + 2 * (y * z + x * w) * d[1] + (1 - 2 * (x * x + y * y)) * d[2],
        };
        for (int k = 0; k < 3; k++)
            m[k] = r[k] + c1[k] + m1[k] - c0[k];
        for (int k = 0; k < 4; k++)
            q[k] = t[k];
    }
}

namespace winrt::ZSlice::implementation
{
    // ---- the gizmo ----

    void MainWindow::PlaceGizmo()
    {
        if (view == nullptr || model == nullptr)
            return;
        bool was = gizmo_on;
        gizmo_on = false;
        zs_app *app = model->Active();
        int64_t part = PrimaryPart();
        zs_part p{};
        if (tool == Tool::Move && part >= 0 && zs_app_part_get(app, (size_t)part, &p) == ZS_OK)
        {
            double x = p.x, y = p.y, z = p.z;
            if (live_on && zs_app_part_id(app, (size_t)part) == live_part)
            {
                x = live_target[0];
                y = live_target[1];
                z = live_target[2];
            }
            zs_view_set_gizmo(view, x, y, std::max(z, 0.0) + p.size_z / 2, GizmoRadius(p), 1);
            gizmo_on = true;
        }
        else if (was)
        {
            zs_view_set_gizmo(view, 0, 0, 0, 0, 0);
        }
    }

    void MainWindow::UpdateRings()
    {
        PlaceGizmo();
        RequestDraw();
    }

    // A ring (0 to 2), an arrow (3 to 5), or -1, within 9 points.
    int MainWindow::HandleAt(double x, double y)
    {
        PlaceGizmo();
        if (!gizmo_on)
            return -1;
        double s = Scale();
        return zs_view_gizmo_at(view, (float)(x * s), (float)(y * s), (float)(9 * s));
    }

    void MainWindow::SetViewCursor(int shape)
    {
        auto panel = ViewPanel().try_as<IUIElementProtected>();
        if (panel == nullptr)
            return;
        auto now = panel.ProtectedCursor().try_as<InputSystemCursor>();
        if ((now != nullptr ? (int)now.CursorShape() : -1) == shape)
            return;
        if (shape < 0)
            panel.ProtectedCursor(nullptr);
        else
            panel.ProtectedCursor(InputSystemCursor::Create(static_cast<InputSystemCursorShape>(shape)));
    }

    // A hand over a ring, and a cross of arrows over an arrow.
    void MainWindow::GizmoHover(double x, double y)
    {
        int handle = HandleAt(x, y);
        SetViewCursor(handle >= 3 ? (int)InputSystemCursorShape::SizeAll : handle >= 0 ? (int)InputSystemCursorShape::Hand : -1);
    }

    void MainWindow::ShowDragLabel(std::wstring const &text, double x, double y)
    {
        DragLabelText().Text(text);
        DragLabel().Margin(ThicknessHelper::FromLengths(x + 16, std::max(0.0, y - 30), 0, 0));
        DragLabel().Visibility(Visibility::Visible);
    }

    void MainWindow::HideDragLabel()
    {
        DragLabel().Visibility(Visibility::Collapsed);
    }

    // The drag of a handle starts at the point of the press.
    void MainWindow::GizmoStart(int handle, double x, double y)
    {
        zs_app *app = model->Active();
        int64_t part = PrimaryPart();
        if (part < 0)
            return;
        double s = Scale();
        float px = (float)(x * s), py = (float)(y * s);
        if (handle >= 3)
        {
            if (zs_view_arrow_press(view, handle - 3, px, py))
            {
                LiveBegin(zs_app_part_id(app, (size_t)part), handle - 3);
                SetViewCursor((int)InputSystemCursorShape::SizeAll);
            }
            return;
        }
        zs_part p{};
        if (zs_app_part_get(app, (size_t)part, &p) != ZS_OK || !zs_view_ring_press(view, handle, px, py))
            return;
        turn_axis = handle;
        turn_want = turn_sent = 0;
        turn_part = zs_app_part_id(app, (size_t)part);
        turn_pivot[0] = p.x;
        turn_pivot[1] = p.y;
        turn_pivot[2] = std::max(p.z, 0.0) + p.size_z / 2;
        // A turn that waits for its slice: this drag goes on from it.
        press_on = base_on && base_part == turn_part;
        press_gen = base_gen;
        std::copy(base_q, base_q + 4, press_q);
        std::copy(base_c, base_c + 3, press_c);
        std::copy(base_m, base_m + 3, press_m);
        base_part = turn_part;
        model->Hold(true);
        SetViewCursor((int)InputSystemCursorShape::Hand);
    }

    // ---- a turn ----

    // Steps of 15 degrees, or 1 degree with Shift. The core gives the angle
    // in the sense of the ring on the screen.
    void MainWindow::TurnMove(double x, double y, bool fine)
    {
        if (turn_axis < 0)
            return;
        double s = Scale();
        zs_app *app = model->Active();
        turn_want = std::round(zs_view_ring_drag(view, (float)(x * s), (float)(y * s), fine ? 1.0f : 15.0f));
        wchar_t text[48];
        swprintf_s(text, L"%s%.0f° about %s", turn_want > 0 ? L"+" : L"", turn_want, axis_names[turn_axis]);
        ShowDragLabel(text, x, y);
        ptrdiff_t index = zs_app_part_index(app, turn_part);
        if (index < 0)
            return;
        zs_part p{};
        double step = turn_want - turn_sent;
        if (step != 0)
        {
            turn_sent = turn_want;
            if (turn_axis == 2)
            {
                if (zs_app_part_get(app, (size_t)index, &p) == ZS_OK)
                    zs_app_part_rotate(app, (size_t)index, p.rotation + step);
            }
            else
            {
                zs_app_part_turn(app, (size_t)index, turn_axis, step);
            }
            model->NoteEdit();
            model->RequestSlice();
            PlaceGizmo();
        }
        TurnPreview();
        RequestDraw();
    }

    // The beads turn in the view at once, about the axis of the bed, after
    // the base at the press if the slice of an earlier turn has not come.
    void MainWindow::TurnPreview()
    {
        zs_app *app = model->Active();
        double t = turn_want * pi / 360, sn = std::sin(t);
        double q1[4] = { 0, 0, 0, std::cos(t) };
        q1[turn_axis] = sn;
        double const zero[3] = { 0, 0, 0 };
        if (press_on)
        {
            TurnCompose(q1, turn_pivot, zero, press_q, press_c, press_m, base_q, base_m);
            std::copy(press_c, press_c + 3, base_c);
        }
        else
        {
            std::copy(q1, q1 + 4, base_q);
            std::copy(turn_pivot, turn_pivot + 3, base_c);
        }
        base_on = press_on || turn_want != 0;
        base_gen = model->EditGen();
        ptrdiff_t index = zs_app_part_index(app, base_part);
        zs_part p{};
        if (!base_on || index < 0 || zs_app_part_get(app, (size_t)index, &p) != ZS_OK)
        {
            base_on = false;
            ShowPartPreview();
            return;
        }
        // The view places the turned beads as the core places the part. The
        // base keeps the move that the view found.
        zs_view_part_preview(view, (int)index, (float)base_q[0], (float)base_q[1], (float)base_q[2], (float)base_q[3], (float)base_c[0],
                             (float)base_c[1], (float)base_c[2], (float)p.x, (float)p.y, (float)std::max(p.z, 0.0),
                             ZS_PREVIEW_ON_BED | ZS_PREVIEW_CENTERED);
        float moved[3];
        if (zs_view_part_preview_move(view, moved))
            for (int k = 0; k < 3; k++)
                base_m[k] = moved[k];
    }

    // The part in the view: the beads of the last slice turned by the base,
    // and by the fall on top of it, or moved by a live drag.
    void MainWindow::ShowPartPreview()
    {
        if (view == nullptr || model == nullptr)
            return;
        zs_app *app = model->Active();
        ptrdiff_t base_index = base_on ? zs_app_part_index(app, base_part) : -1;
        if (fall_shown)
        {
            double const *f = fall_f;
            if (base_index < 0 || base_index != fall_part)
            {
                // The beads are at fall_off from the start of the fall (the
                // slice of a live move came before its end).
                double const x = f[0], y = f[1], z = f[2], w = f[3];
                double const *o = fall_off;
                double mx = f[7] + (1 - 2 * (y * y + z * z)) * o[0] + 2 * (x * y - z * w) * o[1] + 2 * (x * z + y * w) * o[2];
                double my = f[8] + 2 * (x * y + z * w) * o[0] + (1 - 2 * (x * x + z * z)) * o[1] + 2 * (y * z - x * w) * o[2];
                double mz = f[9] + 2 * (x * z - y * w) * o[0] + 2 * (y * z + x * w) * o[1] + (1 - 2 * (x * x + y * y)) * o[2];
                zs_view_part_preview(view, (int)fall_part, (float)f[0], (float)f[1], (float)f[2], (float)f[3], (float)f[4], (float)f[5], (float)f[6],
                                     (float)mx, (float)my, (float)mz, 0);
                return;
            }
            double q[4], m[3];
            TurnCompose(f, f + 4, f + 7, base_q, base_c, base_m, q, m);
            zs_view_part_preview(view, (int)fall_part, (float)q[0], (float)q[1], (float)q[2], (float)q[3], (float)base_c[0], (float)base_c[1],
                                 (float)base_c[2], (float)m[0], (float)m[1], (float)m[2], 0);
            return;
        }
        if (base_index >= 0)
        {
            zs_view_part_preview(view, (int)base_index, (float)base_q[0], (float)base_q[1], (float)base_q[2], (float)base_q[3], (float)base_c[0],
                                 (float)base_c[1], (float)base_c[2], (float)base_m[0], (float)base_m[1], (float)base_m[2], 0);
            return;
        }
        if (live_on)
        {
            LivePreview();
            return;
        }
        zs_view_part_preview(view, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
    }

    // A load ends the preview of a part. The beads of the slice of the part
    // as it is now end the turn and the fall.
    void MainWindow::BaseLoaded()
    {
        int64_t shown = model->ShownGen();
        if (shown >= base_gen)
            base_on = false;
        if (shown >= fall_gen)
            fall_shown = false;
        // The turn of the press is in these beads now: a drag goes on from
        // them alone, and does not turn them twice.
        if (press_on && shown >= press_gen)
        {
            press_on = false;
            if (turn_axis >= 0)
                TurnPreview();
        }
    }

    void MainWindow::TurnEnd()
    {
        bool turned = turn_sent != 0;
        turn_axis = -1;
        turn_part = 0;
        HideDragLabel();
        zs_view_ring_release(view);
        if (!turned)
            ShowPartPreview();
        model->Hold(false);
        if (turned)
            NoteChange();
        UpdateRings();
        FillPartCard();
        if (turned)
            CheckFall();
        SetViewCursor(-1);
        RequestDraw();
    }

    // ---- a live move: an arrow, or a drag of the part ----

    void MainWindow::LiveBegin(uint64_t part, int axis)
    {
        zs_app *app = model->Active();
        ptrdiff_t index = zs_app_part_index(app, part);
        zs_part p{};
        if (index < 0 || zs_app_part_get(app, (size_t)index, &p) != ZS_OK)
            return;
        live_on = true;
        live_done = false;
        live_part = part;
        arrow_axis = axis;
        double pose[3] = { p.x, p.y, p.z };
        for (int k = 0; k < 3; k++)
            live_start[k] = live_target[k] = live_sent[k] = live_shown[k] = pose[k];
        live_size[0] = p.size_x;
        live_size[1] = p.size_y;
        live_size[2] = p.size_z;
        live_gen = -1;
        live_history_n = 0;
        model->Hold(true);
    }

    // The beads at the target, from the place of the slice in the view.
    // Down, the part sinks into the bed, and the bed hides it.
    void MainWindow::LivePreview()
    {
        if (view == nullptr || !live_on)
            return;
        ptrdiff_t index = zs_app_part_index(model->Active(), live_part);
        if (index < 0)
            return;
        double const *t = live_target, *s = live_shown;
        zs_view_part_preview(view, (int)index, 0, 0, 0, 1, 0, 0, 0, (float)(t[0] - s[0]), (float)(t[1] - s[1]), (float)(t[2] - s[2]),
                             t[2] < 0 ? ZS_PREVIEW_SINK : 0);
    }

    // The target goes to the core when no slice runs, and it slices as a
    // draft while the drag goes on.
    void MainWindow::LivePush()
    {
        if (!live_on)
            return;
        double const *t = live_target;
        if (t[0] == live_sent[0] && t[1] == live_sent[1] && t[2] == live_sent[2])
            return;
        zs_app *app = model->Active();
        if (!live_done && zs_app_state(app) == ZS_STATE_SLICING)
            return;
        ptrdiff_t index = zs_app_part_index(app, live_part);
        if (index < 0)
            return;
        double was[3] = { live_sent[0], live_sent[1], live_sent[2] };
        for (int k = 0; k < 3; k++)
            live_sent[k] = t[k];
        if (t[0] != was[0] || t[1] != was[1])
            zs_app_part_move(app, (size_t)index, t[0], t[1]);
        if (t[2] != was[2])
            zs_app_part_lift(app, (size_t)index, t[2]);
        live_gen = model->NoteEdit();
        int slot = live_history_n++ % 8;
        live_history_gen[slot] = live_gen;
        for (int k = 0; k < 3; k++)
            live_history[slot][k] = t[k];
        model->RequestSlice();
        if (!live_done)
            model->SliceNow();
    }

    // After a load: the slice of a place that was sent is in the view, so
    // the preview moves on from there. The slice of the end ends the drag.
    void MainWindow::LiveLoaded()
    {
        if (!live_on)
            return;
        if (live_gen >= 0)
        {
            int64_t shown = model->ShownGen(), best = -1;
            for (int k = 0; k < std::min(live_history_n, 8); k++)
                if (live_history_gen[k] <= shown && live_history_gen[k] > best)
                {
                    best = live_history_gen[k];
                    for (int c = 0; c < 3; c++)
                        live_shown[c] = live_history[k][c];
                }
            if (shown >= live_gen && live_done)
            {
                live_on = false;
                PlaceGizmo();
                return;
            }
            LivePush();
        }
    }

    // A plate change ends a move.
    void MainWindow::LiveCancel()
    {
        live_on = live_done = false;
        base_on = press_on = fall_shown = false;
        arrow_axis = -1;
        moving_part = 0;
        pending_handle = -1;
        if (view != nullptr)
            zs_view_set_guides(view, nullptr, 0);
        HideDragLabel();
    }

    // mm on the bed for one point of the screen near the point x, y.
    double MainWindow::MmPerPoint(double x, double y)
    {
        double s = Scale(), ax, ay, bx, by;
        if (!zs_view_bed_point(view, (float)(x * s), (float)(y * s), &ax, &ay) ||
            !zs_view_bed_point(view, (float)((x + 10) * s), (float)(y * s), &bx, &by))
            return 0.2;
        return std::max(std::hypot(bx - ax, by - ay) / 10, 0.01);
    }

    // mm along an axis for one point of the screen, at the gizmo.
    double MainWindow::MmPerPointAxis(int axis)
    {
        double c[3] = { live_start[0], live_start[1], std::max(live_start[2], 0.0) + live_size[2] / 2 };
        double d[3] = { c[0], c[1], c[2] };
        d[axis] += 10;
        float ax, ay, bx, by;
        if (!zs_view_pixel_of(view, c[0], c[1], c[2], &ax, &ay) || !zs_view_pixel_of(view, d[0], d[1], d[2], &bx, &by))
            return 0.2;
        double points = std::hypot(bx - ax, by - ay) / Scale();
        return points > 0.5 ? 10 / points : 0.2;
    }

    // The snap to the other parts and the bed center, and its guides: only
    // those along the axis of an arrow.
    void MainWindow::LiveSnap(double &x, double &y, int axis, double px, double py)
    {
        double tol = (axis >= 0 ? MmPerPointAxis(axis) : MmPerPoint(px, py)) * 8;
        zs_app *app = model->Active();
        size_t n = zs_app_part_count(app);
        std::vector<double> others;
        others.reserve(4 * n);
        for (size_t i = 0; i < n; i++)
        {
            zs_part q{};
            if (zs_app_part_id(app, i) == live_part || zs_app_part_get(app, i, &q) != ZS_OK)
                continue;
            others.push_back(q.x - q.size_x / 2);
            others.push_back(q.y - q.size_y / 2);
            others.push_back(q.x + q.size_x / 2);
            others.push_back(q.y + q.size_y / 2);
        }
        double bed_x = atof(model->GetSetting("machine.bed_size_x").c_str());
        double bed_y = atof(model->GetSetting("machine.bed_size_y").c_str());
        double box[4] = { x - live_size[0] / 2, y - live_size[1] / 2, x + live_size[0] / 2, y + live_size[1] / 2 };
        double move[2] = { 0, 0 }, guides[12 * 4];
        size_t count = zs_part_snap(box, others.data(), others.size() / 4, bed_x > 0 ? bed_x : 220, bed_y > 0 ? bed_y : 220, tol, move, guides, 12);
        if (axis != 1)
            x += move[0];
        if (axis != 0)
            y += move[1];
        double keep[12 * 4];
        size_t kept = 0;
        for (size_t i = 0; i < count; i++)
        {
            double const *g = guides + 4 * i;
            bool vertical = g[0] == g[2];
            if ((axis == 0 && !vertical) || (axis == 1 && vertical))
                continue;
            std::copy(g, g + 4, keep + 4 * kept++);
        }
        zs_view_set_guides(view, keep, kept);
    }

    // The part goes to the target: the view and the model at once, the
    // core when it can.
    void MainWindow::LiveMove()
    {
        if (sel != nullptr)
            zs_sel_place(sel.get(), live_part, live_target[0], live_target[1], live_target[2]);
        PlaceGizmo();
        double box[4] = { live_target[0] - live_size[0] / 2, live_target[1] - live_size[1] / 2, live_target[0] + live_size[0] / 2,
                          live_target[1] + live_size[1] / 2 };
        zs_view_part_boxes(view, box, 1);
        LivePreview();
        LivePush();
        RequestDraw();
    }

    void MainWindow::ArrowMove(double x, double y, bool free)
    {
        double s = Scale(), d = 0;
        if (!zs_view_arrow_drag(view, (float)(x * s), (float)(y * s), &d))
            return;
        for (int k = 0; k < 3; k++)
            live_target[k] = live_start[k];
        int a = arrow_axis;
        wchar_t text[64];
        if (a == 2)
        {
            double z = live_start[2] + d;
            // The bed snaps. At least 0.5 mm of the part stays over it.
            if (!free && std::abs(z) < MmPerPointAxis(2) * 8)
                z = 0;
            z = Hundredths(std::max(z, -(live_size[2] - 0.5)));
            live_target[2] = z;
            if (z == 0)
                swprintf_s(text, L"On the bed");
            else if (z > 0)
                swprintf_s(text, L"Lift %.2f mm", z);
            else
                swprintf_s(text, L"%.2f mm into the bed", -z);
        }
        else
        {
            live_target[a] = live_start[a] + d;
            if (!free)
                LiveSnap(live_target[0], live_target[1], a, x, y);
            else
                zs_view_set_guides(view, nullptr, 0);
            live_target[a] = Hundredths(live_target[a]);
            double moved = live_target[a] - live_start[a];
            swprintf_s(text, L"%s%.2f mm along %s", moved >= 0 ? L"+" : L"", moved, axis_names[a]);
        }
        ShowDragLabel(text, x, y);
        LiveMove();
    }

    // The point of the press stays under the pointer, on its level plane.
    void MainWindow::BodyMove(double x, double y, bool free)
    {
        double s = Scale(), bx, by;
        if (!zs_view_plane_point(view, (float)(x * s), (float)(y * s), live_hz, &bx, &by))
            return;
        live_target[0] = live_start[0] + bx - bed_x0;
        live_target[1] = live_start[1] + by - bed_y0;
        live_target[2] = live_start[2];
        if (!free)
            LiveSnap(live_target[0], live_target[1], -1, x, y);
        else
            zs_view_set_guides(view, nullptr, 0);
        live_target[0] = Hundredths(live_target[0]);
        live_target[1] = Hundredths(live_target[1]);
        LiveMove();
    }

    // The last place, one step of the history, the exact slice, and the
    // physics. The preview stays until the slice of the last place shows.
    void MainWindow::LiveEnd()
    {
        if (!live_on || live_done)
            return;
        live_done = true;
        arrow_axis = -1;
        HideDragLabel();
        zs_view_ring_release(view);
        zs_view_set_guides(view, nullptr, 0);
        bool moved = live_target[0] != live_start[0] || live_target[1] != live_start[1] || live_target[2] != live_start[2];
        LivePush();
        model->Hold(false);
        if (moved)
        {
            NoteChange();
        }
        else
        {
            live_on = false;
            ShowPartPreview();
        }
        ApplySelection();
        FillPartCard();
        if (moved)
            CheckFall();
        SetViewCursor(-1);
        RequestDraw();
    }

    // ---- the keys and the wheel ----

    // The keys move and turn a part at once. The slice waits for a pause
    // of 0.6 s, and the physics comes after it.
    void MainWindow::HoldForKeys()
    {
        model->Hold(true);
        if (keys_timer == nullptr)
        {
            keys_timer = queue.CreateTimer();
            keys_timer.Interval(std::chrono::milliseconds(600));
            keys_timer.IsRepeating(false);
            keys_timer.Tick([this](auto &&, auto &&) {
                if (model == nullptr)
                    return;
                model->Hold(false);
                CheckFall();
            });
        }
        keys_timer.Stop();
        keys_timer.Start();
    }

    // The arrows with Ctrl turn about X (Up, Down) and Y (Left, Right), 15
    // degrees, or 1 with Shift.
    bool MainWindow::PartTurnKey(Windows::System::VirtualKey key, bool shift)
    {
        using Windows::System::VirtualKey;
        int dx = key == VirtualKey::Left ? -1 : key == VirtualKey::Right ? 1 : 0;
        int dy = key == VirtualKey::Down ? -1 : key == VirtualKey::Up ? 1 : 0;
        int64_t part = PrimaryPart();
        if ((dx == 0 && dy == 0) || part < 0)
            return false;
        HoldForKeys();
        double degrees = shift ? 1 : 15;
        if (dx != 0)
            zs_app_part_turn(model->Active(), (size_t)part, 1, dx * degrees);
        else
            zs_app_part_turn(model->Active(), (size_t)part, 0, -dy * degrees);
        PlateEdited();
        return true;
    }

    // [ and ] turn a selected part about Z.
    bool MainWindow::PartBracket(bool forward, bool shift)
    {
        int64_t part = PrimaryPart();
        zs_part p{};
        if (part < 0 || zs_app_part_get(model->Active(), (size_t)part, &p) != ZS_OK)
            return false;
        HoldForKeys();
        double step = shift ? 1 : 15;
        zs_app_part_rotate(model->Active(), (size_t)part, p.rotation + (forward ? step : -step));
        PlateEdited();
        return true;
    }

    // The wheel over the view turns the part 15 degrees. A touchpad sends
    // small steps, so they add up to a notch first.
    bool MainWindow::PartWheel(int delta)
    {
        int64_t part = PrimaryPart();
        zs_part p{};
        if (part < 0 || zs_app_part_get(model->Active(), (size_t)part, &p) != ZS_OK)
            return false;
        wheel_turn += delta;
        int notches = wheel_turn / 120;
        wheel_turn -= notches * 120;
        if (notches != 0)
        {
            HoldForKeys();
            zs_app_part_rotate(model->Active(), (size_t)part, p.rotation + notches * 15.0);
            PlateEdited();
        }
        return true;
    }
}
