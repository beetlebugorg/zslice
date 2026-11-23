// The tools of the main window: the strip, the pointer, and the keys.
//
// V Select, M Move, R Turn, G Grab, and T Measure work here. S Support is in
// MainWindow.Support.cpp. P Paint and E Label route to MainWindow.Paint.cpp
// and MainWindow.Label.cpp. The behavior follows the GTK shell
// (linux/src/ui/view3d.c and preview.c), and the glyphs are those of the web
// app (web/app/index.html).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include "Layer2D.h"

#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Primitives = Microsoft::UI::Xaml::Controls::Primitives;
using Microsoft::UI::Input::PointerDeviceType;
using Windows::System::VirtualKey;
using Windows::System::VirtualKeyModifiers;

namespace
{
    constexpr double pi = 3.14159265358979323846;

    struct ToolInfo
    {
        wchar_t const *name;
        wchar_t const *key;
        wchar_t const *tip;
        // The markup of the glyph, in a box of 18 x 18.
        wchar_t const *glyph;
        bool ready;
    };

#define ZS_STROKE L"Stroke='{ThemeResource TextFillColorPrimaryBrush}' StrokeThickness='1.5' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'"

    ToolInfo const tools[] = {
        { L"Select", L"V", L"Select (V): click a line to see what it is, its measurements, and its settings",
          L"<Path Data='M5 2v13l3.2-3 2.3 4.5 2.1-1-2.3-4.5h4.2z' Fill='{ThemeResource TextFillColorPrimaryBrush}'/>", true },
        { L"Move", L"M", L"Move (M, also R and G): click a part for its gizmo. Drag the part to carry it on the bed (it snaps to the other parts and the center; Shift: no snap). Drag an arrow to move along X or Y, or the blue arrow to lift the part (down: it sinks into the bed). Drag a ring to turn the part in steps of 15° (Shift: 1°). Keys: the arrows move 1 mm (Shift: 10), Page Up and Page Down lift, [ and ] turn about Z, Ctrl and the arrows turn about X and Y. Tab: the next part.",
          L"<Path Data='M2 9h14M9 2v14M13.7 6.8 16 9l-2.3 2.2M4.3 6.8 2 9l2.3 2.2M6.8 4.3 9 2l2.2 2.3M6.8 13.7 9 16l2.2-2.3' " ZS_STROKE L"/>", true },
        { L"Support", L"S", L"Support (S): point at an overhang to add support",
          L"<Path Data='M2 4.5h14l-2 3H4zM5 7.5v8M9 7.5v8M13 7.5v8M3.5 15.5h11' " ZS_STROKE L"/>", true },
        { L"Measure", L"T", L"Measure (T): click two points of the print. The ends of the lines snap. Shift: no snap.",
          L"<Path Data='M1 6H17V12H1ZM4 6v2.5M6.5 6v1.5M9 6v2.5M11.5 6v1.5M14 6v2.5' " ZS_STROKE L"><Path.RenderTransform><RotateTransform Angle='-45' CenterX='9' CenterY='9'/></Path.RenderTransform></Path>", true },
        { L"Paint", L"P", L"Paint (P): paint filaments on the surface of a part. Smart select: click a raised letter, a logo, or a face; Shift adds more. Brush: drag over the surface.",
          L"<Path Data='M9 2.5a6.5 6.5 0 1 0 0 13c1 0 1.5-.6 1.5-1.3 0-1-.9-1.2-.9-2s.6-1.2 1.4-1.2h1.6a2.9 2.9 0 0 0 2.9-2.9C15.5 5 12.6 2.5 9 2.5z' " ZS_STROKE L"/>"
          L"<Path Data='M4.6 8.4a1 1 0 1 0 2 0a1 1 0 1 0-2 0ZM6.6 5.4a1 1 0 1 0 2 0a1 1 0 1 0-2 0ZM10 5.4a1 1 0 1 0 2 0a1 1 0 1 0-2 0Z' Fill='{ThemeResource TextFillColorPrimaryBrush}'/>", true },
        { L"Label", L"E", L"Label (E): click a face of a part to put text or marks on it, in another filament. Drag a label to move it (Shift: keep its plane), turn the wheel over it to turn it (Shift: 15°), and drag its corner to scale it.",
          L"<Path Data='M3.5 3.5H14.5A1.5 1.5 0 0 1 16 5V13A1.5 1.5 0 0 1 14.5 14.5H3.5A1.5 1.5 0 0 1 2 13V5A1.5 1.5 0 0 1 3.5 3.5ZM5.5 7h5M8 7v4.5M12 11.5h1.2' " ZS_STROKE L"/>", true },
    };

    FrameworkElement MakeGlyph(wchar_t const *markup)
    {
        std::wstring xaml = L"<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='18' Height='18'>";
        xaml += markup;
        xaml += L"</Grid>";
        return Markup::XamlReader::Load(xaml).as<FrameworkElement>();
    }

    bool Has(VirtualKeyModifiers mods, VirtualKeyModifiers flag)
    {
        return (mods & flag) != VirtualKeyModifiers::None;
    }
}

namespace winrt::ZSlice::implementation
{
    void MainWindow::WireTools()
    {
        fall_timer = queue.CreateTimer();
        fall_timer.Interval(std::chrono::milliseconds(16));
        fall_timer.Tick([this](auto &&, auto &&) { FallTick(); });

        for (size_t i = 0; i < std::size(tools); i++)
        {
            auto const &info = tools[i];
            Primitives::ToggleButton button;
            button.Width(40);
            button.Height(40);
            button.CornerRadius(CornerRadiusHelper::FromUniformRadius(8));
            button.Padding(ThicknessHelper::FromUniformLength(0));
            button.IsEnabled(info.ready);
            Automation::AutomationProperties::SetName(button, info.name);
            ToolTipService::SetToolTip(button, box_value(info.tip));

            Grid content;
            content.Width(40);
            content.Height(40);
            FrameworkElement glyph = MakeGlyph(info.glyph);
            glyph.HorizontalAlignment(HorizontalAlignment::Center);
            glyph.VerticalAlignment(VerticalAlignment::Center);
            content.Children().Append(glyph);
            TextBlock letter;
            letter.Text(info.key);
            letter.FontSize(9);
            letter.Opacity(0.55);
            letter.HorizontalAlignment(HorizontalAlignment::Right);
            letter.VerticalAlignment(VerticalAlignment::Bottom);
            letter.Margin(ThicknessHelper::FromLengths(0, 0, 3, 1));
            content.Children().Append(letter);
            button.Content(content);

            Tool value = static_cast<Tool>(i);
            button.Click([this, value](auto &&, auto &&) { SetTool(value); });
            tool_buttons.push_back(button);
            ToolStrip().Children().Append(button);
        }
        tool_buttons[0].IsChecked(true);

        ViewPanel().DoubleTapped([this](auto &&, Input::DoubleTappedRoutedEventArgs const &e) { OnPanelDoubleTapped(e); });
        WireView();
        WireCards();
        WireFilaments();
        WirePaint();
        WireLabel();
        WireSupport();
        WireRange();
    }

    void MainWindow::SetTool(Tool next)
    {
        SelSync();
        if (sel != nullptr)
            zs_sel_tool_set(sel.get(), (int)next);
        // The tools work in the 3D view. The tape works in both.
        if (next != Tool::Select && next != Tool::Measure)
            Set2D(false);
        if (next != tool)
        {
            RangeClose();
            if (tool == Tool::Move)
                SetViewCursor(-1);
            if (tool == Tool::Measure)
                ClearMeasure();
            Tool was = tool;
            tool = next;
            // The tape has a hint until its first point.
            if (view != nullptr)
                ShowMeasure();
            if (was == Tool::Paint)
                PaintTool(false);
            if (was == Tool::Label)
                LabelTool(false);
            if (next == Tool::Paint)
                PaintTool(true);
            if (next == Tool::Label)
                LabelTool(true);
            SupportToolChanged();
        }
        for (size_t i = 0; i < tool_buttons.size(); i++)
            tool_buttons[i].IsChecked(static_cast<Tool>(i) == tool);
        UpdateRings();
        RequestDraw();
    }

    // ---- the pointer ----

    void MainWindow::OnPointerPressed(Input::PointerRoutedEventArgs const &e)
    {
        if (view == nullptr)
            return;
        auto point = e.GetCurrentPoint(ViewPanel());
        auto props = point.Properties();
        auto mods = e.KeyModifiers();
        bool touchpad = e.Pointer().PointerDeviceType() == PointerDeviceType::Touchpad;
        bool shift = Has(mods, VirtualKeyModifiers::Shift);
        bool ctrl = Has(mods, VirtualKeyModifiers::Control);
        double x = point.Position().X, y = point.Position().Y;
        last_x = press_x = x;
        last_y = press_y = y;
        tool_drag = false;
        press_shift = shift;
        press_left = props.IsLeftButtonPressed();
        pointer_alt = Has(mods, VirtualKeyModifiers::Menu);
        pointer_shift = shift;
        press_right = props.IsRightButtonPressed();

        // A left press can start a tool.
        if (props.IsLeftButtonPressed() && !props.IsMiddleButtonPressed() && ToolPress(x, y, ctrl))
        {
            tool_drag = true;
            drag = Drag::Orbit;
        }
        // A left drag orbits. A right drag orbits with a mouse, and pans
        // with a two-finger click on a touchpad. The middle button and
        // Shift pan.
        else if (props.IsMiddleButtonPressed() || (props.IsRightButtonPressed() && touchpad) || shift)
            drag = Drag::Pan;
        else if (props.IsLeftButtonPressed() || props.IsRightButtonPressed())
            drag = Drag::Orbit;
        else
            return;
        ViewPanel().CapturePointer(e.Pointer());
        ViewPanel().Focus(FocusState::Pointer);
        e.Handled(true);
    }

    void MainWindow::OnPointerMoved(Input::PointerRoutedEventArgs const &e)
    {
        if (view == nullptr)
            return;
        auto position = e.GetCurrentPoint(ViewPanel()).Position();
        auto mods = e.KeyModifiers();
        pointer_x = position.X;
        pointer_y = position.Y;
        if (drag == Drag::None)
        {
            if (tool == Tool::Move)
                GizmoHover(position.X, position.Y);
            if (tool == Tool::Paint)
                PaintHover(position.X, position.Y);
            if (tool == Tool::Label)
                LabelHover(position.X, position.Y);
            SupportPointer(position.X, position.Y);
            return;
        }
        double dx = position.X - last_x;
        double dy = position.Y - last_y;
        last_x = position.X;
        last_y = position.Y;
        if (tool_drag)
        {
            pointer_alt = Has(mods, VirtualKeyModifiers::Menu);
            ToolDrag(position.X, position.Y, Has(mods, VirtualKeyModifiers::Shift));
        }
        // An orbit is in points. A pan follows the pointer, in pixels.
        else if (drag == Drag::Pan)
        {
            zs_view_pan(view, (float)(dx * Scale()), (float)(dy * Scale()));
            PlaceLineCard();
            PlacePartCard();
        }
        else
        {
            zs_view_orbit(view, (float)dx, (float)dy);
            PlaceLineCard();
            PlacePartCard();
        }
        RequestDraw();
        e.Handled(true);
    }

    void MainWindow::OnPointerEnded(Input::PointerRoutedEventArgs const &e)
    {
        if (drag == Drag::None)
            return;
        bool was_tool = tool_drag;
        // A drag over layers that came back to its start is no click.
        bool range_lit = RangeDragLit();
        drag = Drag::None;
        tool_drag = false;
        ViewPanel().ReleasePointerCapture(e.Pointer());
        e.Handled(true);
        if (was_tool)
            ToolRelease();
        if (view == nullptr)
            return;
        pointer_alt = Has(e.KeyModifiers(), VirtualKeyModifiers::Menu);
        // A right click, or a two-finger click that does not slide, opens
        // the menu. A dot of a picked support tree has its own menu, and in
        // the Support tool a right click adds nothing.
        if (press_right)
        {
            press_right = false;
            if (std::abs(last_x - press_x) <= 4 && std::abs(last_y - press_y) <= 4 && !SupportMenu(press_x, press_y) &&
                tool != Tool::Support)
                ShowContextMenu(last_x, last_y);
            return;
        }
        // Only the primary button clicks, and a lost capture is no release.
        if (!press_left || pointer_cancelled)
            return;
        // A press and a release at one place is a click.
        if (std::abs(last_x - press_x) <= 4 && std::abs(last_y - press_y) <= 4 && !was_tool)
        {
            auto mods = e.KeyModifiers();
            ToolClick(last_x, last_y, Has(mods, VirtualKeyModifiers::Shift), Has(mods, VirtualKeyModifiers::Control));
        }
        else if (was_tool && !range_lit && std::abs(last_x - press_x) <= 4 && std::abs(last_y - press_y) <= 4)
        {
            auto mods = e.KeyModifiers();
            ToolClick(last_x, last_y, Has(mods, VirtualKeyModifiers::Shift), Has(mods, VirtualKeyModifiers::Control));
        }
    }

    void MainWindow::OnPanelDoubleTapped(Input::DoubleTappedRoutedEventArgs const &e)
    {
        // The Paint tool: two quick clicks paint two times. The view stays.
        if (view == nullptr || tool == Tool::Paint)
            return;
        auto at = e.GetPosition(ViewPanel());
        // On a side of the print the view turns to it. Elsewhere it resets.
        if (!zs_view_look_at_side(view, (float)(at.X * Scale()), (float)(at.Y * Scale()), 0))
            zs_view_reset_smooth(view);
        StartAnimation();
        RequestDraw();
    }

    int64_t MainWindow::PartAt(double x, double y, double *bed_x, double *bed_y)
    {
        float px = (float)(x * Scale()), py = (float)(y * Scale());
        zs_app *app = model->Active();
        double bx = 0, by = 0;
        bool on_bed = zs_view_bed_point(view, px, py, &bx, &by) != 0;
        if (bed_x != nullptr)
            *bed_x = bx;
        if (bed_y != nullptr)
            *bed_y = by;
        (void)on_bed;
        // The model picks at the current places, also before a new slice.
        SelSync();
        uint64_t id = zs_sel_pick(sel.get(), view, px, py);
        return id != 0 ? zs_app_part_index(app, id) : -1;
    }

    // A left press. True when a tool takes the drag.
    bool MainWindow::ToolPress(double x, double y, bool ctrl)
    {
        if (model == nullptr)
            return false;
        double s = Scale();
        zs_app *app = model->Active();
        // The Paint tool: a press paints. Ctrl and a press still move a part.
        if (tool == Tool::Paint && !ctrl && PaintPress(x, y, press_shift))
            return true;
        // The Label tool: a press on a label drags it.
        if (tool == Tool::Label && !ctrl && LabelPress(x, y))
            return true;
        // The Support tool: a press on a point, a dot, a ring, or a segment.
        if (tool == Tool::Support && SupportPress(x, y))
            return true;
        // The Select tool: a press on a dot of a picked support tree.
        if (tool == Tool::Select && !ctrl && !pointer_shift && !pointer_alt && SupportPicked() && SupportPress(x, y))
            return true;
        // The Select tool: a press on a printed line starts a drag over
        // layers. A release at the same place is a click.
        if (tool == Tool::Select && !ctrl && !pointer_shift && !pointer_alt && RangePress(x, y))
            return true;
        // The transform tool: a handle of the gizmo. The drag starts when
        // the pointer moves, so a click there goes to the part under it.
        if (tool == Tool::Move && !falling)
        {
            int handle = HandleAt(x, y);
            if (handle >= 0)
            {
                pending_handle = handle;
                return true;
            }
        }
        // The Measure tool: a press on an end of the tape moves it.
        if (tool == Tool::Measure)
        {
            double best = 14 * s;
            tape_end = -1;
            for (int i = 0; i < measure_count; i++)
            {
                float qx, qy;
                if (!zs_view_pixel_of(view, measure[3 * i], measure[3 * i + 1], measure[3 * i + 2], &qx, &qy))
                    continue;
                double d = std::hypot(qx - x * s, qy - y * s);
                if (d < best)
                {
                    best = d;
                    tape_end = i;
                }
            }
            if (tape_end >= 0)
                return true;
        }
        // The Move tool, or Ctrl: a drag of a part.
        if (tool == Tool::Move || ctrl)
        {
            double bx = 0, by = 0;
            int64_t part = PartAt(x, y, &bx, &by);
            zs_part p{};
            if (part >= 0 && zs_app_part_get(app, (size_t)part, &p) == ZS_OK)
            {
                BeginMove(part, x, y, bx, by);
                return true;
            }
        }
        return false;
    }

    void MainWindow::BeginMove(int64_t part, double x, double y, double bed_x, double bed_y)
    {
        zs_app *app = model->Active();
        double s = Scale();
        move_group.clear();
        move_group_xy.clear();
        std::vector<int64_t> group = SelectedParts();
        if (PartSelected(part) && group.size() > 1)
        {
            for (int64_t i : group)
            {
                zs_part q{};
                if (zs_app_part_get(app, (size_t)i, &q) != ZS_OK)
                    continue;
                move_group.push_back(zs_app_part_id(app, (size_t)i));
                move_group_xy.push_back(q.x);
                move_group_xy.push_back(q.y);
            }
        }
        else
        {
            SelectPart(part);
            // The point of the press stays under the pointer, on its level.
            double sp[3];
            live_hz = zs_view_surface_point(view, (float)(x * s), (float)(y * s), 0, sp) ? std::max(sp[2], 0.0) : 0;
            if (!zs_view_plane_point(view, (float)(x * s), (float)(y * s), live_hz, &bed_x, &bed_y))
                live_hz = 0;
        }
        moving_part = zs_app_part_id(app, (size_t)part);
        move_started = false;
        bed_x0 = bed_x;
        bed_y0 = bed_y;
        moved_x = moved_y = 0;
    }

    void MainWindow::ToolDrag(double x, double y, bool shift)
    {
        double s = Scale();
        zs_app *app = model->Active();
        if (RangeDragging())
        {
            RangeDrag(x, y);
            return;
        }
        if (PaintPressed())
        {
            PaintDrag(x, y);
            return;
        }
        if (LabelDragging())
        {
            LabelDrag(x, y, shift);
            return;
        }
        if (SupportDragging())
        {
            SupportDrag(x, y, shift);
            return;
        }
        // A drag of a handle starts past 4 points from the press.
        if (pending_handle >= 0)
        {
            if (std::abs(x - press_x) <= 4 && std::abs(y - press_y) <= 4)
                return;
            int handle = pending_handle;
            pending_handle = -1;
            GizmoStart(handle, press_x, press_y);
        }
        if (turn_axis >= 0)
        {
            TurnMove(x, y, shift);
            return;
        }
        if (live_on && !live_done && moving_part == 0)
        {
            ArrowMove(x, y, shift);
            return;
        }
        if (tape_end >= 0)
        {
            double p[3];
            if (zs_view_surface_point(view, (float)(x * s), (float)(y * s), shift ? 0 : 1, p))
            {
                measure[3 * tape_end] = p[0];
                measure[3 * tape_end + 1] = p[1];
                measure[3 * tape_end + 2] = p[2];
                measure_radius[tape_end] = 0;
                measure_shape[tape_end] = 0;
                ShowMeasure();
            }
            return;
        }
        if (moving_part != 0)
        {
            if (!move_started)
            {
                if (std::abs(x - press_x) <= 4 && std::abs(y - press_y) <= 4)
                    return;
                move_started = true;
                if (move_group.size() > 1)
                    model->Hold(true);
                else if (!falling)
                    LiveBegin(moving_part, -1);
            }
            if (move_group.size() > 1)
            {
                double bx, by;
                if (!zs_view_bed_point(view, (float)(x * s), (float)(y * s), &bx, &by))
                    return;
                moved_x = bx - bed_x0;
                moved_y = by - bed_y0;
                for (size_t i = 0; i < move_group.size(); i++)
                {
                    ptrdiff_t index = zs_app_part_index(app, move_group[i]);
                    if (index >= 0)
                        {
                            double to_x = move_group_xy[2 * i] + moved_x, to_y = move_group_xy[2 * i + 1] + moved_y;
                            zs_part q{};
                            zs_app_part_move(app, (size_t)index, to_x, to_y);
                            if (sel != nullptr && zs_app_part_get(app, (size_t)index, &q) == ZS_OK)
                                zs_sel_place(sel.get(), move_group[i], to_x, to_y, q.z);
                        }
                }
                model->RequestSlice();
            }
            else if (live_on && !live_done)
            {
                BodyMove(x, y, shift);
            }
        }
    }

    void MainWindow::ToolRelease()
    {
        zs_app *app = model != nullptr ? model->Active() : nullptr;
        if (app == nullptr)
            return;
        RangeRelease();
        PaintRelease();
        LabelRelease();
        SupportRelease();
        // A press on a handle with no drag is a click.
        pending_handle = -1;
        if (turn_axis >= 0)
            TurnEnd();
        tape_end = -1;
        if (moving_part != 0)
        {
            bool group_moved = move_started && move_group.size() > 1;
            moving_part = 0;
            move_started = false;
            if (group_moved)
            {
                model->Hold(false);
                if (moved_x != 0 || moved_y != 0)
                    NoteChange();
                ApplySelection();
                FillPartCard();
                RequestDraw();
            }
            move_group.clear();
            move_group_xy.clear();
        }
        if (live_on && !live_done)
            LiveEnd();
    }

    void MainWindow::ToolClick(double x, double y, bool shift, bool ctrl)
    {
        double s = Scale();
        click_x = x;
        click_y = y;
        // A click on the sign of a plate makes that plate active.
        int64_t sign = zs_view_sign_at(view, (float)(x * s), (float)(y * s));
        if (sign >= 0)
        {
            SelectPlate((size_t)sign);
            return;
        }
        // A click elsewhere ends a range of layers.
        if (press_left)
            RangeClose();
        if (tool == Tool::Measure)
        {
            MeasureClick(x, y, shift);
            return;
        }
        // The Support tool: a point of an area, or a click on an outline.
        if (tool == Tool::Support && !ctrl)
        {
            SupportClick(x, y, shift, pointer_alt);
            return;
        }
        // The Label tool: a label, or a new label on the face there. A click
        // of another button does nothing here.
        if (tool == Tool::Label && !ctrl)
        {
            if (press_left)
                LabelClick(x, y);
            return;
        }
        // The Paint tool: the press painted.
        if (tool == Tool::Paint && !ctrl)
            return;
        // Shift adds a part to the selection, or takes it out.
        bool select_tool = tool == Tool::Select;
        if (shift && (!select_tool || ctrl))
        {
            int64_t part = PartAt(x, y, nullptr, nullptr);
            if (part >= 0)
            {
                TogglePart(part);
                return;
            }
        }
        if (ctrl || tool == Tool::Move)
        {
            SelectPart(PartAt(x, y, nullptr, nullptr));
            return;
        }
        // The gaps view: a click on a gap shows it.
        if (GapClick(x, y))
            return;
        size_t segment = 0;
        size_t path = zs_view_pick_segment(view, (float)(x * s), (float)(y * s), &segment);
        // The Select tool: a click on a support line selects that support.
        if (tool == Tool::Select && path != (size_t)-1 && SupportSelectLine(path, segment))
            return;
        SupportClearPick();
        if (path == (size_t)-1)
            ClearSelection();
        else if (shift && select_tool)
            SelectRun(path, segment);
        else
            SelectLine((int64_t)path, (int64_t)segment);
    }

    // The line and its run, from the retraction before it to the next one:
    // one extrusion, lit together. A note gives the count.
    void MainWindow::SelectRun(size_t path, size_t segment)
    {
        SelectLine((int64_t)path, (int64_t)segment);
        size_t first = 0, last = 0;
        if (zs_app_path_run(model->Active(), path, &first, &last) != ZS_OK || last < first)
            return;
        constexpr size_t run_max = 20000;
        std::vector<size_t> others;
        others.reserve(std::min(last - first + 1, run_max));
        for (size_t i = first; i <= last && others.size() < run_max; i++)
            if (i != path)
                others.push_back(i);
        zs_view_highlight_more(view, others.data(), others.size());
        run_lit = true;
        run_others = others.size();
        RequestDraw();
        ShowToast(last > first ? L"A run of " + std::to_wstring(last - first + 1) + L" lines: one extrusion, from a retraction to the next."
                               : std::wstring(L"A run of one line: it has a retraction before and after it."));
    }

    int MainWindow::EditSelectedLine(int kind, double value)
    {
        zs_app *app = model->Active();
        uint64_t key = 0;
        ptrdiff_t path = -1;
        zs_sel_line_get(sel.get(), &key, &path, nullptr);
        return key != 0 ? zs_app_edit_add_key(app, key, line_key_layer, kind, value) : zs_app_edit_add(app, (size_t)path, kind, value);
    }

    // ---- the fall ----

    void MainWindow::RunFall()
    {
        fall_last = std::chrono::steady_clock::now();
        if (!fall_timer.IsRunning())
            fall_timer.Start();
    }

    void MainWindow::FallTick()
    {
        if (model == nullptr || view == nullptr)
        {
            fall_timer.Stop();
            return;
        }
        auto now = std::chrono::steady_clock::now();
        double dt = std::min(std::chrono::duration<double>(now - fall_last).count(), 0.05);
        fall_last = now;
        double f[10];
        int rc = zs_app_fall_step(model->Active(), dt, f);
        if (rc == 1)
        {
            // The beads are at fall_off from the start of the fall, when the
            // slice of a live move came before its end.
            double qx = f[0], qy = f[1], qz = f[2], qw = f[3];
            double const *o = fall_off;
            double mx = f[7] + (1 - 2 * (qy * qy + qz * qz)) * o[0] + 2 * (qx * qy - qz * qw) * o[1] + 2 * (qx * qz + qy * qw) * o[2];
            double my = f[8] + 2 * (qx * qy + qz * qw) * o[0] + (1 - 2 * (qx * qx + qz * qz)) * o[1] + 2 * (qy * qz - qx * qw) * o[2];
            double mz = f[9] + 2 * (qx * qz - qy * qw) * o[0] + 2 * (qy * qz + qx * qw) * o[1] + (1 - 2 * (qx * qx + qy * qy)) * o[2];
            zs_view_part_preview(view, (int)fall_part, (float)f[0], (float)f[1], (float)f[2], (float)f[3], (float)f[4], (float)f[5],
                                 (float)f[6], (float)mx, (float)my, (float)mz, 0);
            RequestDraw();
            return;
        }
        fall_timer.Stop();
        falling = false;
        if (rc == 0)
        {
            // At rest: the new place, and one step of the history.
            model->RequestSlice();
            if (model->HistoryCommit())
                RefreshHistoryButtons();
            FillPartCard();
        }
        else
        {
            zs_view_part_preview(view, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
        }
        RequestDraw();
    }

    // The plate changes under a fall: the part stays where it was.
    void MainWindow::CancelFall()
    {
        if (!falling)
            return;
        fall_timer.Stop();
        if (fall_app != nullptr)
            zs_app_fall_cancel(fall_app);
        fall_app = nullptr;
        falling = false;
        if (view != nullptr)
        {
            zs_view_part_preview(view, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
            RequestDraw();
        }
    }

    // A part that cannot stand as it is falls.
    void MainWindow::CheckFall()
    {
        if (model == nullptr || falling)
            return;
        ptrdiff_t part = zs_app_fall_pending(model->Active());
        if (part < 0 || zs_app_fall_start(model->Active(), (size_t)part) != 1)
            return;
        falling = true;
        fall_app = model->Active();
        fall_part = part;
        fall_off[0] = fall_off[1] = fall_off[2] = 0;
        if (live_on && live_part == zs_app_part_id(model->Active(), (size_t)part))
        {
            for (int k = 0; k < 3; k++)
                fall_off[k] = live_target[k] - live_shown[k];
            live_on = false;
        }
        RunFall();
    }

    // ---- measure ----

    void MainWindow::MeasureClick(double x, double y, bool shift)
    {
        double s = Scale();
        double p[3];
        if (!zs_view_surface_point(view, (float)(x * s), (float)(y * s), shift ? 0 : 1, p))
            return;
        double radius = 0;
        int shape = 0;
        double px = p[0], py = p[1];
        // A circle or an arc under the pointer: the point is its center.
        size_t segment = 0;
        size_t path = zs_view_pick_segment(view, (float)(x * s), (float)(y * s), &segment);
        zs_measure m{};
        if (!shift && path != (size_t)-1 && zs_app_measure(model->Active(), path, segment, &m) == ZS_OK && (m.shape == 1 || m.shape == 2))
        {
            px = m.center_x;
            py = m.center_y;
            radius = m.radius;
            shape = m.shape;
        }
        AddMeasure(px, py, p[2], radius, shape);
    }

    void MainWindow::AddMeasure(double x, double y, double z, double radius, int shape)
    {
        // A third point starts a new measure.
        if (measure_count >= 2)
            measure_count = 0;
        int i = measure_count;
        measure[3 * i] = x;
        measure[3 * i + 1] = y;
        measure[3 * i + 2] = z;
        measure_radius[i] = radius;
        measure_shape[i] = shape;
        measure_count++;
        ShowMeasure();
    }

    // The readout: the distance, and its parts along x, y, and z. A circle
    // or an arc at a point gives its size, and the point is its center.
    void MainWindow::ShowMeasure()
    {
        zs_view_set_measure(view, (size_t)measure_count, measure);
        RequestDraw();
        if (tool != Tool::Measure)
        {
            MeasureCard().Visibility(Visibility::Collapsed);
            return;
        }
        std::wstring shapes[2];
        wchar_t part[96];
        for (int i = 0; i < measure_count; i++)
        {
            if (measure_radius[i] <= 0)
                continue;
            if (measure_shape[i] == 1)
                swprintf_s(part, L"circle ⌀ %.2f mm (radius %.2f)", 2 * measure_radius[i], measure_radius[i]);
            else
                swprintf_s(part, L"arc radius %.2f mm", measure_radius[i]);
            shapes[i] = part;
        }
        wchar_t text[320];
        if (measure_count == 0)
        {
            swprintf_s(text, L"Click a point of the print, or a circle or an arc for its size and center. Shift: no snap.");
        }
        else if (measure_count == 1)
        {
            if (!shapes[0].empty())
                swprintf_s(text, L"%s, center %.2f, %.2f mm: click a second point to measure from its center.", shapes[0].c_str(), measure[0], measure[1]);
            else
                swprintf_s(text, L"From %.2f, %.2f, %.2f mm: click a second point.", measure[0], measure[1], measure[2]);
        }
        else
        {
            double dx = measure[3] - measure[0], dy = measure[4] - measure[1], dz = measure[5] - measure[2];
            bool any = !shapes[0].empty() || !shapes[1].empty();
            std::wstring what = any ? L"\nFirst: " + (shapes[0].empty() ? std::wstring(L"a point") : shapes[0]) + L"   ·   second: " + (shapes[1].empty() ? std::wstring(L"a point") : shapes[1])
                                    : std::wstring();
            swprintf_s(text, L"%.2f mm%s   ·   ΔX %.2f   ΔY %.2f   ΔZ %.2f   ·   on the bed %.2f mm%s", std::sqrt(dx * dx + dy * dy + dz * dz), any ? L" between the centers" : L"",
                       std::abs(dx), std::abs(dy), std::abs(dz), std::sqrt(dx * dx + dy * dy), what.c_str());
        }
        MeasureText().Text(text);
        MeasureCard().Visibility(Visibility::Visible);
        measure_box[0] = 1e9;
        PlaceMeasure();
    }

    void MainWindow::PlaceMeasure()
    {
        if (view == nullptr || MeasureCard().Visibility() != Visibility::Visible)
            return;
        if (measure_count == 0)
        {
            Canvas::SetLeft(MeasureCard(), 64);
            Canvas::SetTop(MeasureCard(), 10);
            return;
        }
        double box[4] = { 1e9, 1e9, -1e9, -1e9 };
        for (int i = 0; i < measure_count; i++)
        {
            double x = 0, y = 0;
            if (show_2d && layer2d != nullptr)
            {
                layer2d->ToView(measure[3 * i], measure[3 * i + 1], x, y);
            }
            else
            {
                float qx, qy;
                if (!zs_view_pixel_of(view, measure[3 * i], measure[3 * i + 1], measure[3 * i + 2], &qx, &qy))
                    continue;
                x = qx / Scale();
                y = qy / Scale();
            }
            box[0] = std::min(box[0], x - 12);
            box[1] = std::min(box[1], y - 12);
            box[2] = std::max(box[2], x + 12);
            box[3] = std::max(box[3], y + 12);
        }
        if (box[0] > box[2])
            return;
        bool same = true;
        for (int i = 0; i < 4; i++)
            same = same && std::abs(box[i] - measure_box[i]) < 0.5;
        if (same)
            return;
        std::copy(box, box + 4, measure_box);
        PlaceCard(MeasureCard(), box);
    }

    void MainWindow::ClearMeasure()
    {
        measure_count = 0;
        tape_end = -1;
        if (view != nullptr)
            ShowMeasure();
    }

    // ---- the selection ----

    // After each change of the set. With `scene`, the view has this slice.
    void MainWindow::SelSync(bool scene)
    {
        if (model == nullptr)
            return;
        if (sel == nullptr)
        {
            zs_selection *made = nullptr;
            if (zs_sel_new(&made) != ZS_OK)
                return;
            sel.reset(made);
        }
        zs_sel_sync(sel.get(), model->Set(), scene ? 1 : 0);
    }

    // The indices of the selected parts now. The last one is the primary.
    std::vector<int64_t> MainWindow::SelectedParts() const
    {
        std::vector<int64_t> out;
        if (sel == nullptr || model == nullptr)
            return out;
        zs_app *app = model->Active();
        for (size_t k = 0, n = zs_sel_count(sel.get()); k < n; k++)
        {
            ptrdiff_t index = zs_app_part_index(app, zs_sel_get(sel.get(), k));
            if (index >= 0)
                out.push_back(index);
        }
        return out;
    }

    int64_t MainWindow::PrimaryPart() const
    {
        std::vector<int64_t> parts = SelectedParts();
        return parts.empty() ? -1 : parts.back();
    }

    bool MainWindow::PartSelected(int64_t part) const
    {
        if (sel == nullptr || model == nullptr || part < 0)
            return false;
        return zs_sel_has(sel.get(), zs_app_part_id(model->Active(), (size_t)part)) != 0;
    }

    void MainWindow::SetSelectedParts(std::vector<int64_t> const &parts)
    {
        SelSync();
        if (sel == nullptr)
            return;
        zs_sel_clear(sel.get());
        zs_app *app = model->Active();
        for (int64_t part : parts)
            if (part >= 0)
                zs_sel_select(sel.get(), zs_app_part_id(app, (size_t)part), ZS_SEL_ADD);
    }

    // The camera goes to this plate when its slice shows.
    void MainWindow::RequestFrame(ptrdiff_t target)
    {
        SelSync();
        if (sel != nullptr)
            zs_sel_frame_request(sel.get(), target);
    }

    int64_t MainWindow::SelectedPath() const
    {
        ptrdiff_t path = -1;
        if (sel != nullptr)
            zs_sel_line_get(sel.get(), nullptr, &path, nullptr);
        return path;
    }

    int64_t MainWindow::SelectedSegment() const
    {
        ptrdiff_t segment = -1;
        if (sel != nullptr)
            zs_sel_line_get(sel.get(), nullptr, nullptr, &segment);
        return segment;
    }

    // The line by its key. During a slice the key reads 0, so the same line
    // keeps the key that it has.
    void MainWindow::SetSelectedLine(int64_t path, int64_t segment)
    {
        if (sel == nullptr)
            SelSync();
        if (sel == nullptr)
            return;
        uint64_t old_key = 0;
        ptrdiff_t old_path = -1;
        zs_sel_line_get(sel.get(), &old_key, &old_path, nullptr);
        zs_app *app = model->Active();
        uint64_t key = path >= 0 ? zs_app_path_key(app, (size_t)path) : 0;
        if (key != 0 || path != old_path)
        {
            ptrdiff_t layer = path >= 0 ? zs_app_path_layer(app, (size_t)path) : -1;
            line_key_layer = layer > 0 ? (size_t)layer : 0;
        }
        else
            key = old_key;
        zs_sel_line_set(sel.get(), key, path, segment);
        if (path < 0)
            line_placed = false;
    }

    void MainWindow::SelectLine(int64_t path, int64_t segment)
    {
        SetSelectedParts({});
        SetSelectedLine(path, segment);
        SaveLinePlace();
        line_card_moved = false;
        // Another line: no buttons of the body of the line before.
        ClearLineExtend();
        ApplySelection();
        FillPartCard();
        FillLineCard();
    }

    void MainWindow::SelectPart(int64_t part)
    {
        SetSelectedLine(-1, -1);
        SetSelectedParts(part >= 0 ? std::vector<int64_t>{ part } : std::vector<int64_t>{});
        part_card_moved = false;
        ApplySelection();
        FillLineCard();
        FillPartCard();
        if (tool == Tool::Paint)
            PaintPartSelected(part);
    }

    void MainWindow::TogglePart(int64_t part)
    {
        SetSelectedLine(-1, -1);
        SelSync();
        if (sel != nullptr && part >= 0)
            zs_sel_select(sel.get(), zs_app_part_id(model->Active(), (size_t)part), ZS_SEL_TOGGLE);
        ApplySelection();
        FillLineCard();
        FillPartCard();
    }

    void MainWindow::ClearSelection()
    {
        SetSelectedLine(-1, -1);
        SetSelectedParts({});
        ApplySelection();
        HideCards();
    }

    // Tells the view what is selected.
    void MainWindow::ApplySelection()
    {
        if (view == nullptr || model == nullptr)
            return;
        // The lines of a run go with the next selection.
        if (run_lit)
        {
            run_lit = false;
            run_others = 0;
            zs_view_highlight_more(view, nullptr, 0);
        }
        zs_view_highlight(view, SelectedPath() < 0 ? (size_t)-1 : (size_t)SelectedPath());
        if (SelectedPath() >= 0)
            zs_view_highlight_segment(view, (size_t)SelectedPath(), (ptrdiff_t)SelectedSegment());
        zs_app *app = model->Active();
        std::vector<double> boxes;
        for (int64_t i : SelectedParts())
        {
            zs_part p{};
            if (zs_app_part_get(app, (size_t)i, &p) != ZS_OK)
                continue;
            boxes.push_back(p.x - p.size_x / 2);
            boxes.push_back(p.y - p.size_y / 2);
            boxes.push_back(p.x + p.size_x / 2);
            boxes.push_back(p.y + p.size_y / 2);
        }
        zs_view_part_boxes(view, boxes.data(), boxes.size() / 4);
        UpdateRings();
        RequestDraw();
    }

    void MainWindow::SaveLinePlace()
    {
        line_placed = false;
        int64_t selected = SelectedPath(), segment = SelectedSegment();
        zs_toolpaths tp{};
        if (selected < 0 || zs_app_toolpaths(model->Active(), &tp) != ZS_OK || (size_t)selected >= tp.path_count)
            return;
        size_t path = (size_t)selected;
        uint32_t start = path == 0 ? 0 : tp.path_ends[path - 1], end = tp.path_ends[path];
        if (end <= start)
            return;
        uint32_t at = segment >= 0 && start + (uint32_t)segment < end ? start + (uint32_t)segment : start;
        size_t layer = 0;
        while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path)
            layer++;
        line_place_x = tp.points[2 * at];
        line_place_y = tp.points[2 * at + 1];
        line_place_z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
        line_place_feature = tp.path_features[path];
        zs_sel_line_get(sel.get(), &line_place_key, nullptr, nullptr);
        line_place_segment = segment;
        line_placed = true;
    }

    // A new slice can renumber the paths: the key of the line finds it, and
    // then its place. With neither, the line selection ends.
    void MainWindow::FindSelectedLine()
    {
        if (sel == nullptr)
            return;
        uint64_t key = 0;
        ptrdiff_t path = -1;
        zs_sel_line_get(sel.get(), &key, &path, nullptr);
        if (path < 0)
            return;
        zs_app *app = model->Active();
        if (zs_app_state(app) != ZS_STATE_DONE)
            return;
        ptrdiff_t found = key != 0 ? zs_app_path_of_key(app, key) : -1;
        if (found < 0)
        {
            zs_toolpaths places{};
            size_t closest = (size_t)-1;
            if (line_placed && zs_app_toolpaths(app, &places) == ZS_OK && places.layer_count > 0)
            {
                size_t layer = 0;
                for (size_t l = 1; l < places.layer_count; l++)
                    if (std::abs(places.layer_z[l] - line_place_z) < std::abs(places.layer_z[layer] - line_place_z))
                        layer = l;
                closest = zs_app_pick_layer(app, layer, line_place_x, line_place_y);
                if (closest == (size_t)-1 || places.path_features[closest] != line_place_feature)
                    closest = zs_app_pick_feature(app, layer, line_place_feature, line_place_x, line_place_y);
            }
            if (closest == (size_t)-1)
            {
                SetSelectedLine(-1, -1);
                HideCards();
                return;
            }
            // Another key: the line closest the old place. The place stays, so
            // a line does not drift from slice to slice.
            SetSelectedLine((int64_t)closest, -1);
            RestoreLineSegment((int64_t)closest);
            FillLineCard();
            return;
        }
        ptrdiff_t segments = 0;
        zs_toolpaths tp{};
        if (zs_app_toolpaths(app, &tp) == ZS_OK && (size_t)found < tp.path_count)
        {
            uint32_t start = found == 0 ? 0 : tp.path_ends[found - 1], end = tp.path_ends[found];
            segments = end > start + 1 ? (ptrdiff_t)(end - start - 1) : 1;
        }
        zs_sel_line_found(sel.get(), found, segments);
        RestoreLineSegment(found);
        FillLineCard();
    }

    // A draft can miss the key of the line. When the exact slice makes the
    // same line again, it gets its segment back.
    void MainWindow::RestoreLineSegment(int64_t path)
    {
        if (line_placed && line_place_segment >= 0 && SelectedSegment() < 0 && line_place_key != 0 &&
            zs_app_path_key(model->Active(), (size_t)path) == line_place_key)
            SetSelectedLine(path, line_place_segment);
    }

    void MainWindow::StepLine(int direction, bool whole)
    {
        if (view == nullptr || SelectedPath() < 0)
            return;
        size_t path = (size_t)SelectedPath();
        ptrdiff_t segment = (ptrdiff_t)SelectedSegment();
        if (!zs_view_step(view, &path, &segment, direction, whole ? 1 : 0))
            return;
        SetSelectedLine((int64_t)path, (int64_t)segment);
        SaveLinePlace();
        ApplySelection();
        FillLineCard();
    }

    // K and J: one layer up or down. A selected line goes to the nearest
    // line of that layer.
    void MainWindow::StepLayer(int direction)
    {
        if (layer_count == 0)
            return;
        double next = std::clamp(LayerSlider().Value() + direction, 1.0, (double)layer_count);
        LayerSlider().Value(next);
        if (SelectedPath() >= 0)
        {
            size_t found = zs_view_nearest_on_layer(view, (size_t)SelectedPath(), (size_t)next - 1);
            if (found != (size_t)-1)
            {
                SetSelectedLine((int64_t)found, -1);
                SaveLinePlace();
                ApplySelection();
                FillLineCard();
            }
        }
    }

    // After a change of the parts: a new slice, and a step of the history.
    void MainWindow::PlateEdited()
    {
        if (model == nullptr)
            return;
        CancelFall();
        zs_app *app = model->Active();
        size_t count = zs_app_part_count(app);
        SelSync();
        NoteChange();
        if (count > 0)
            model->RequestSlice();
        else
            ShowPlate();
        ApplySelection();
        FillPartCard();
        zs_set_view_sync(model->Set(), view);
        RefreshPlates();
    }

    // ---- the keys ----

    bool MainWindow::OnToolKey(VirtualKey key, bool shift, bool ctrl)
    {
        // Ctrl and an arrow turn the selected part.
        if (ctrl)
            return PartTurnKey(key, shift);
        // Delete, Backspace, and Esc act on the selected label first.
        if (tool == Tool::Label && LabelKey(key))
            return true;
        if (tool == Tool::Paint && key == VirtualKey::Escape)
        {
            SetTool(Tool::Select);
            return true;
        }
        // The Support tool first: Enter, Backspace, Delete, and Esc. The
        // Select tool: Delete and Esc for a support that it picked.
        if ((tool == Tool::Support || tool == Tool::Select) && SupportKey(key))
            return true;
        if (key == VirtualKey::Escape && RangeOpen())
        {
            RangeClose();
            return true;
        }
        // The arrows and Delete act on the selected parts first.
        if (!SelectedParts().empty())
        {
            zs_app *app = model->Active();
            if (key == VirtualKey::Delete)
            {
                std::vector<int64_t> list = SelectedParts();
                std::sort(list.rbegin(), list.rend());
                for (int64_t i : list)
                    zs_app_part_remove(app, (size_t)i);
                SetSelectedParts({});
                HideCards();
                PlateEdited();
                return true;
            }
            if (key == VirtualKey::D)
            {
                DuplicateParts();
                return true;
            }
            int mx = key == VirtualKey::Left ? -1 : key == VirtualKey::Right ? 1 : 0;
            int my = key == VirtualKey::Down ? -1 : key == VirtualKey::Up ? 1 : 0;
            // Page Up and Page Down lift the part 1 mm (Shift: 10 mm).
            if (key == VirtualKey::PageUp || key == VirtualKey::PageDown)
            {
                size_t part = (size_t)PrimaryPart();
                zs_part p{};
                if (zs_app_part_get(app, part, &p) == ZS_OK)
                {
                    HoldForKeys();
                    double lift = shift ? 10 : 1;
                    zs_app_part_lift(app, part, std::round((p.z + (key == VirtualKey::PageUp ? lift : -lift)) * 100) / 100);
                    PlateEdited();
                }
                return true;
            }
            if (mx != 0 || my != 0)
            {
                HoldForKeys();
                double step = shift ? 10 : 1;
                for (int64_t i : SelectedParts())
                {
                    zs_part p{};
                    if (zs_app_part_get(app, (size_t)i, &p) == ZS_OK)
                        zs_app_part_move(app, (size_t)i, p.x + mx * step, p.y + my * step);
                }
                PlateEdited();
                return true;
            }
        }
        if (key == VirtualKey::Delete && SelectedPath() >= 0)
        {
            if (EditSelectedLine(0, 1) == ZS_OK)
            {
                // A second Delete must not take the line that comes next.
                ClearSelection();
                model->RequestSlice();
                NoteChange();
            }
            return true;
        }
        switch (key)
        {
        case VirtualKey::V: SetTool(Tool::Select); return true;
        case VirtualKey::M: SetTool(Tool::Move); return true;
        case VirtualKey::R: SetTool(Tool::Move); return true;
        case VirtualKey::S: SetTool(Tool::Support); return true;
        case VirtualKey::G: SetTool(Tool::Move); return true;
        case VirtualKey::T: SetTool(Tool::Measure); return true;
        case VirtualKey::B: ToggleBed(); return true;
        // P and E close their tool when it is open.
        case VirtualKey::P: SetTool(tool == Tool::Paint ? Tool::Select : Tool::Paint); return true;
        case VirtualKey::E: SetTool(tool == Tool::Label ? Tool::Select : Tool::Label); return true;
        case VirtualKey::N: ShowSettingsPane(SettingsPane().Visibility() != Visibility::Visible); return true;
        case VirtualKey::PageUp: StepLayer(10); return true;
        case VirtualKey::PageDown: StepLayer(-10); return true;
        case VirtualKey::H:
        case VirtualKey::Left: StepLine(-1, shift); return true;
        case VirtualKey::L:
        case VirtualKey::Right: StepLine(1, shift); return true;
        // Shift+K and Shift+J grow a range of layers and open its card.
        case VirtualKey::K: if (shift) RangeKey(1); else StepLayer(1); return true;
        case VirtualKey::J: if (shift) RangeKey(-1); else StepLayer(-1); return true;
        case VirtualKey::Up: if (shift) StepLayerLo(1); else StepLayer(1); return true;
        case VirtualKey::Down: if (shift) StepLayerLo(-1); else StepLayer(-1); return true;
        case VirtualKey::Escape:
            if (tool == Tool::Measure && measure_count > 0)
            {
                ClearMeasure();
                return true;
            }
            if (SelectedPath() >= 0 || !SelectedParts().empty())
            {
                ClearSelection();
                return true;
            }
            SetTool(Tool::Select);
            return true;
        default:
            return false;
        }
    }

    // Tab goes through the parts only from the view. In the chrome it moves
    // the focus, as it should.
    bool MainWindow::InViewFocus(Windows::Foundation::IInspectable const &focused)
    {
        return focused == ViewPanel() || focused == Layer2DPanel();
    }

    void MainWindow::StepPart(int direction)
    {
        int64_t count = (int64_t)zs_app_part_count(model->Active());
        int64_t now = SelectedParts().empty() ? -1 : PrimaryPart();
        int64_t next = now < 0 ? (direction > 0 ? 0 : count - 1) : ((now + direction) % count + count) % count;
        if (tool != Tool::Move)
            SetTool(Tool::Move);
        SelectPart(next);
        RequestDraw();
    }

    void MainWindow::OnKeyDown(Input::KeyRoutedEventArgs const &e)
    {
        if (model == nullptr || view == nullptr || PreferencesOpen())
            return;
        // A key in a text field is text.
        auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot());
        if (focused.try_as<TextBox>() != nullptr || focused.try_as<NumberBox>() != nullptr)
            return;
        constexpr auto bracket_left = static_cast<VirtualKey>(219);
        constexpr auto bracket_right = static_cast<VirtualKey>(221);
        constexpr auto slash = static_cast<VirtualKey>(191);
        auto state = [](VirtualKey k) {
            return (Microsoft::UI::Input::InputKeyboardSource::GetKeyStateForCurrentThread(k) &
                    Windows::UI::Core::CoreVirtualKeyStates::Down) == Windows::UI::Core::CoreVirtualKeyStates::Down;
        };
        bool shift = state(VirtualKey::Shift), ctrl = state(VirtualKey::Control);
        auto key = e.Key();
        if (ctrl && ClipKey(key, shift))
        {
        }
        else if (key == VirtualKey::Application || (key == VirtualKey::F10 && shift))
        {
            // The menu is of the 3D view.
            Set2D(false);
            ShowContextMenu(pointer_x, pointer_y);
        }
        else if (!ctrl && !shift && (key == VirtualKey::Number2 || key == VirtualKey::NumberPad2))
        {
            Set2D(!show_2d);
        }
        else if (!ctrl && !shift && (key == VirtualKey::Number3 || key == VirtualKey::NumberPad3))
        {
            Set2D(false);
        }
        else if (key == VirtualKey::C && !ctrl && shift)
        {
            ShowAllLayers();
        }
        else if (key == VirtualKey::C && !ctrl && SelectedPath() >= 0)
        {
            PreviewToLine();
        }
        else if (key == slash && shift)
        {
            if (search_open)
                CloseSearch();
            ShowShortcuts();
        }
        else if (key == slash)
        {
            // / again closes the search: it stays open while the view moves.
            if (search_open)
                CloseSearch();
            else
                OpenSearch(true);
        }
        else if (key == VirtualKey::Escape && search_open)
        {
            CloseSearch();
        }
        else if (key == VirtualKey::Tab && !ctrl && InViewFocus(focused) && zs_app_part_count(model->Active()) > 0)
        {
            StepPart(shift ? -1 : 1);
        }
        // [ and ] are the plate before and the next plate.
        else if (key == bracket_left || key == bracket_right)
        {
            if (!PartBracket(key == bracket_right, shift))
                StepPlate(key == bracket_left ? -1 : 1);
        }
        else if (key == VirtualKey::Home && model->PlateCount() > 1)
            FramePlate((size_t)-1);
        else if (key == VirtualKey::F || key == VirtualKey::Home)
            FramePlate(model->ActivePlate());
        else if (!OnToolKey(key, shift, ctrl))
            return;
        e.Handled(true);
    }
}
