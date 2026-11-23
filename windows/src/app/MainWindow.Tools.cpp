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
        { L"Move", L"M", L"Move (M): drag a part to move it",
          L"<Path Data='M2 9h14M9 2v14M13.7 6.8 16 9l-2.3 2.2M4.3 6.8 2 9l2.3 2.2M6.8 4.3 9 2l2.2 2.3M6.8 13.7 9 16l2.2-2.3' " ZS_STROKE L"/>", true },
        { L"Turn", L"R", L"Turn (R): click a part, then drag one of its rings to turn it",
          L"<Path Data='M14.5 9a5.5 5.5 0 1 1-1.6-3.9M13.6 2.2v3.3h-3.3' " ZS_STROKE L"/>", true },
        { L"Support", L"S", L"Support (S): point at an overhang to add support",
          L"<Path Data='M2 4.5h14l-2 3H4zM5 7.5v8M9 7.5v8M13 7.5v8M3.5 15.5h11' " ZS_STROKE L"/>", true },
        { L"Grab", L"G", L"Grab (G): click a part to pick it up, move the pointer to carry it, and click to let go. Alt and a move turn it.",
          L"<Path Data='M6 9V4.2a1.2 1.2 0 0 1 2.4 0V8M8.4 7.5V3.2a1.2 1.2 0 0 1 2.4 0V8M10.8 7.6V4.2a1.2 1.2 0 0 1 2.4 0v6.3c0 3-2 5-4.8 5-2 0-3-.9-4.2-2.6L2.6 10a1.2 1.2 0 0 1 2-1.3L6 10.4' " ZS_STROKE L"/>", true },
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
        // The tools work in the 3D view. The tape works in both.
        if (next != Tool::Select && next != Tool::Measure)
            Set2D(false);
        if (next != tool)
        {
            // The hand lets go when the tool changes.
            HandRelease();
            RangeClose();
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
        else if (hand_click)
        {
            drag = Drag::None;
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
        if (hand)
        {
            HandMove(position.X, position.Y, Has(mods, VirtualKeyModifiers::Menu), Has(mods, VirtualKeyModifiers::Shift));
            e.Handled(true);
            return;
        }
        if (drag == Drag::None)
        {
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
        bool had_click = hand_click;
        hand_click = false;
        if (drag == Drag::None && !had_click)
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
        if (view == nullptr || had_click)
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
        else if (was_tool && !range_lit && std::abs(last_x - press_x) <= 4 && std::abs(last_y - press_y) <= 4 && tool != Tool::Grab)
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
        size_t path = zs_view_pick(view, px, py);
        if (path != (size_t)-1)
        {
            ptrdiff_t part = zs_app_part_of_path(app, path);
            if (part >= 0)
                return part;
        }
        return on_bed ? zs_app_part_at(app, bx, by) : -1;
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
        // The Turn tool: a press on a ring.
        if (tool == Tool::Turn && !selected_parts.empty())
        {
            UpdateRings();
            int axis = zs_view_ring_at(view, (float)(x * s), (float)(y * s), (float)(8 * s));
            if (axis >= 0 && zs_view_ring_press(view, axis, (float)(x * s), (float)(y * s)))
            {
                turn_axis = axis;
                turn_want = turn_sent = 0;
                turn_part = selected_parts[0];
                zs_part p{};
                if (zs_app_part_get(app, (size_t)turn_part, &p) != ZS_OK)
                {
                    zs_view_ring_release(view);
                    turn_axis = -1;
                    return false;
                }
                turn_pivot[0] = p.x;
                turn_pivot[1] = p.y;
                turn_pivot[2] = p.size_z / 2;
                turn_rotation = p.rotation;
                model->Hold(true);
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
        // The Grab tool: a click takes a part, and the next click lets go.
        if (tool == Tool::Grab)
        {
            if (HandRelease())
            {
                hand_click = true;
                return false;
            }
            if (!falling)
            {
                int64_t part = PartAt(x, y, nullptr, nullptr);
                double p[3];
                if (part >= 0 && zs_view_surface_point(view, (float)(x * s), (float)(y * s), 0, p) &&
                    zs_app_grab_start(app, (size_t)part, p[0], p[1], p[2]) == 1)
                {
                    falling = true;
                    fall_app = app;
                    hand = true;
                    hand_click = true;
                    hand_turning = false;
                    hand_height = p[2] + 15;
                    hand_yaw = hand_tilt = hand_yaw_sent = hand_tilt_sent = 0;
                    HandMove(x, y, false, false);
                    fall_part = part;
                    RunFall();
                    return false;
                }
            }
        }
        // The Move tool, or Ctrl: a drag of a part.
        if (tool == Tool::Move || ctrl)
        {
            double bx = 0, by = 0;
            int64_t part = PartAt(x, y, &bx, &by);
            zs_part p{};
            if (part >= 0 && zs_app_part_get(app, (size_t)part, &p) == ZS_OK)
            {
                BeginMove(part, bx, by);
                return true;
            }
        }
        return false;
    }

    void MainWindow::BeginMove(int64_t part, double bed_x, double bed_y)
    {
        zs_app *app = model->Active();
        move_group.clear();
        move_group_xy.clear();
        bool in = std::find(selected_parts.begin(), selected_parts.end(), part) != selected_parts.end();
        if (in && selected_parts.size() > 1)
        {
            for (int64_t i : selected_parts)
            {
                zs_part q{};
                if (zs_app_part_get(app, (size_t)i, &q) != ZS_OK)
                    continue;
                move_group.push_back(i);
                move_group_xy.push_back(q.x);
                move_group_xy.push_back(q.y);
            }
        }
        else
        {
            SelectPart(part);
        }
        zs_part p{};
        zs_app_part_get(app, (size_t)part, &p);
        moving_part = part;
        move_x0 = p.x;
        move_y0 = p.y;
        bed_x0 = bed_x;
        bed_y0 = bed_y;
        moved_x = moved_y = 0;
        model->Hold(true);
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
        if (turn_axis >= 0)
        {
            turn_want = std::round(zs_view_ring_drag(view, (float)(x * s), (float)(y * s), shift ? 5.0f : 15.0f));
            double step = turn_want - turn_sent;
            if (step != 0)
            {
                turn_sent = turn_want;
                if (turn_axis == 2)
                {
                    zs_part p{};
                    if (zs_app_part_get(app, (size_t)turn_part, &p) == ZS_OK)
                        zs_app_part_rotate(app, (size_t)turn_part, p.rotation + step);
                }
                else
                {
                    zs_app_part_turn(app, (size_t)turn_part, turn_axis, step);
                }
                model->RequestSlice();
                UpdateRings();
            }
            // The beads turn in the view at once.
            double t = turn_want * pi / 180 / 2, r = turn_rotation * pi / 180;
            double ax[3] = { 0, 0, 1 };
            if (turn_axis == 0)
            {
                ax[0] = std::cos(r);
                ax[1] = std::sin(r);
                ax[2] = 0;
            }
            else if (turn_axis == 1)
            {
                ax[0] = -std::sin(r);
                ax[1] = std::cos(r);
                ax[2] = 0;
            }
            double sn = std::sin(t);
            zs_part p{};
            if (turn_want != 0 && zs_app_part_get(app, (size_t)turn_part, &p) == ZS_OK)
                zs_view_part_preview(view, (int)turn_part, (float)(ax[0] * sn), (float)(ax[1] * sn), (float)(ax[2] * sn), (float)std::cos(t),
                                     (float)turn_pivot[0], (float)turn_pivot[1], (float)turn_pivot[2], (float)p.x, (float)p.y, 0,
                                     ZS_PREVIEW_ON_BED | ZS_PREVIEW_CENTERED);
            else
                zs_view_part_preview(view, -1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0);
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
        if (moving_part >= 0)
        {
            double bx, by;
            if (!zs_view_bed_point(view, (float)(x * s), (float)(y * s), &bx, &by))
                return;
            moved_x = bx - bed_x0;
            moved_y = by - bed_y0;
            if (move_group.size() > 1)
            {
                for (size_t i = 0; i < move_group.size(); i++)
                    zs_app_part_move(app, (size_t)move_group[i], move_group_xy[2 * i] + moved_x, move_group_xy[2 * i + 1] + moved_y);
                model->RequestSlice();
            }
            else
            {
                // The beads move in the view at once. The core moves the
                // part at the release.
                zs_view_part_preview(view, (int)moving_part, 0, 0, 0, 1, 0, 0, 0, (float)moved_x, (float)moved_y, 0, 0);
                double box[4];
                zs_part p{};
                if (zs_app_part_get(app, (size_t)moving_part, &p) == ZS_OK)
                {
                    box[0] = p.x + moved_x - p.size_x / 2;
                    box[1] = p.y + moved_y - p.size_y / 2;
                    box[2] = p.x + moved_x + p.size_x / 2;
                    box[3] = p.y + moved_y + p.size_y / 2;
                    zs_view_part_boxes(view, box, 1);
                }
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
        if (turn_axis >= 0)
        {
            turn_axis = -1;
            zs_view_ring_release(view);
            model->Hold(false);
            NoteChange();
            turn_part = -1;
            UpdateRings();
            FillPartCard();
            CheckFall();
            RequestDraw();
        }
        tape_end = -1;
        if (moving_part >= 0)
        {
            int64_t part = moving_part;
            moving_part = -1;
            if (move_group.size() <= 1 && (moved_x != 0 || moved_y != 0))
                zs_app_part_move(app, (size_t)part, move_x0 + moved_x, move_y0 + moved_y);
            bool changed = moved_x != 0 || moved_y != 0;
            if (changed)
                model->RequestSlice();
            model->Hold(false);
            if (changed)
                NoteChange();
            move_group.clear();
            move_group_xy.clear();
            ApplySelection();
            FillPartCard();
            RequestDraw();
        }
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
        if (tool == Tool::Grab)
            return;
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
        if (ctrl || tool == Tool::Move || tool == Tool::Turn)
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
        return line_key != 0 && line_key_path == selected_path ? zs_app_edit_add_key(app, line_key, line_key_layer, kind, value)
                                                               : zs_app_edit_add(app, (size_t)selected_path, kind, value);
    }

    // ---- the hand and the fall ----

    void MainWindow::HandMove(double x, double y, bool alt, bool shift)
    {
        zs_app *app = model->Active();
        double s = Scale();
        if (alt)
        {
            if (!hand_turning)
            {
                hand_turning = true;
                hand_yaw = hand_tilt = hand_yaw_sent = hand_tilt_sent = 0;
                hand_turn_x = x;
                hand_turn_y = y;
            }
            // Half a degree for each pixel. Shift: steps of 15 degrees.
            hand_yaw += (x - hand_turn_x) * 0.5;
            hand_tilt += (y - hand_turn_y) * 0.5;
            hand_turn_x = x;
            hand_turn_y = y;
            double yaw = (shift ? std::round(hand_yaw / 15) * 15 : hand_yaw) - hand_yaw_sent;
            double tilt = (shift ? std::round(hand_tilt / 15) * 15 : hand_tilt) - hand_tilt_sent;
            if (yaw != 0)
                zs_app_grab_turn(app, 0, 0, 1, yaw);
            if (tilt != 0)
            {
                double ax, ay, bx, by;
                float px = (float)(hand_x * s), py = (float)(hand_y * s);
                if (zs_view_plane_point(view, px, py, hand_height, &ax, &ay) && zs_view_plane_point(view, px + 50, py, hand_height, &bx, &by))
                    zs_app_grab_turn(app, bx - ax, by - ay, 0, tilt);
            }
            hand_yaw_sent += yaw;
            hand_tilt_sent += tilt;
            return;
        }
        hand_turning = false;
        hand_x = x;
        hand_y = y;
        double bx, by;
        if (zs_view_plane_point(view, (float)(x * s), (float)(y * s), hand_height, &bx, &by))
            zs_app_grab_move(app, bx, by, hand_height);
    }

    bool MainWindow::HandRelease()
    {
        if (!hand)
            return false;
        zs_app_grab_end(model->Active());
        hand = false;
        return true;
    }

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
            zs_view_part_preview(view, (int)fall_part, (float)f[0], (float)f[1], (float)f[2], (float)f[3], (float)f[4], (float)f[5],
                                 (float)f[6], (float)f[7], (float)f[8], (float)f[9], 0);
            RequestDraw();
            return;
        }
        fall_timer.Stop();
        falling = false;
        hand = false;
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
        hand = false;
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

    void MainWindow::UpdateRings()
    {
        if (view == nullptr || model == nullptr)
            return;
        zs_part p{};
        if (tool == Tool::Turn && !selected_parts.empty() && zs_app_part_get(model->Active(), (size_t)selected_parts[0], &p) == ZS_OK)
            zs_view_set_rings(view, p.x, p.y, p.size_z / 2, 0.62 * std::max({ p.size_x, p.size_y, p.size_z }) + 4);
        else
            zs_view_set_rings(view, 0, 0, 0, 0);
        RequestDraw();
    }

    // ---- the selection ----

    void MainWindow::SelectLine(int64_t path, int64_t segment)
    {
        selected_parts.clear();
        selected_path = path;
        selected_segment = segment;
        line_card_moved = false;
        // Another line: no buttons of the body of the line before.
        ClearLineExtend();
        SaveLineAnchor();
        ApplySelection();
        FillPartCard();
        FillLineCard();
    }

    void MainWindow::SelectPart(int64_t part)
    {
        selected_path = selected_segment = -1;
        line_anchored = false;
        selected_parts.clear();
        if (part >= 0)
            selected_parts.push_back(part);
        part_card_moved = false;
        ApplySelection();
        FillLineCard();
        FillPartCard();
        if (tool == Tool::Paint)
            PaintPartSelected(part);
    }

    void MainWindow::TogglePart(int64_t part)
    {
        selected_path = selected_segment = -1;
        line_anchored = false;
        auto at = std::find(selected_parts.begin(), selected_parts.end(), part);
        if (at == selected_parts.end())
            selected_parts.push_back(part);
        else
            selected_parts.erase(at);
        ApplySelection();
        FillLineCard();
        FillPartCard();
    }

    void MainWindow::ClearSelection()
    {
        selected_path = selected_segment = -1;
        line_anchored = false;
        selected_parts.clear();
        ApplySelection();
        HideCards();
    }

    // Tells the view what is selected.
    void MainWindow::ApplySelection()
    {
        if (view == nullptr || model == nullptr)
            return;
        // During a slice the key reads 0: the same line keeps its key.
        uint64_t key = selected_path >= 0 ? zs_app_path_key(model->Active(), (size_t)selected_path) : 0;
        if (key != 0 || selected_path != line_key_path)
        {
            line_key = key;
            line_key_path = selected_path;
            ptrdiff_t key_layer = selected_path >= 0 ? zs_app_path_layer(model->Active(), (size_t)selected_path) : -1;
            line_key_layer = key_layer > 0 ? (size_t)key_layer : 0;
        }
        // The lines of a run go with the next selection.
        if (run_lit)
        {
            run_lit = false;
            run_others = 0;
            zs_view_highlight_more(view, nullptr, 0);
        }
        zs_view_highlight(view, selected_path < 0 ? (size_t)-1 : (size_t)selected_path);
        if (selected_path >= 0)
            zs_view_highlight_segment(view, (size_t)selected_path, (ptrdiff_t)selected_segment);
        zs_app *app = model->Active();
        std::vector<double> boxes;
        for (int64_t i : selected_parts)
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

    // A new slice has new paths: the place of the line finds it again.
    void MainWindow::SaveLineAnchor()
    {
        line_anchored = false;
        zs_toolpaths tp{};
        if (selected_path < 0 || zs_app_toolpaths(model->Active(), &tp) != ZS_OK || (size_t)selected_path >= tp.path_count)
            return;
        size_t path = (size_t)selected_path;
        uint32_t start = path == 0 ? 0 : tp.path_ends[path - 1], end = tp.path_ends[path];
        if (end <= start)
            return;
        uint32_t at = selected_segment >= 0 && start + (uint32_t)selected_segment < end ? start + (uint32_t)selected_segment : start;
        size_t layer = 0;
        while (layer < tp.layer_count && tp.layer_ends[layer] <= (uint32_t)path)
            layer++;
        anchor_x = tp.points[2 * at];
        anchor_y = tp.points[2 * at + 1];
        anchor_z = layer < tp.layer_count ? tp.layer_z[layer] : 0;
        anchor_feature = tp.path_features[path];
        line_anchored = true;
    }

    void MainWindow::FindLineAnchor()
    {
        if (!line_anchored)
            return;
        zs_app *app = model->Active();
        zs_toolpaths tp{};
        if (zs_app_toolpaths(app, &tp) != ZS_OK || tp.layer_count == 0)
            return;
        size_t layer = 0;
        for (size_t l = 1; l < tp.layer_count; l++)
            if (std::abs(tp.layer_z[l] - anchor_z) < std::abs(tp.layer_z[layer] - anchor_z))
                layer = l;
        size_t path = zs_app_pick_layer(app, layer, anchor_x, anchor_y);
        if (path == (size_t)-1 || tp.path_features[path] != anchor_feature)
            path = zs_app_pick_feature(app, layer, anchor_feature, anchor_x, anchor_y);
        if (path == (size_t)-1)
        {
            // No line of that kind there now. The anchor stays for the next
            // slice.
            selected_path = selected_segment = -1;
            HideCards();
            return;
        }
        if ((int64_t)path != selected_path)
            selected_segment = -1;
        selected_path = (int64_t)path;
        FillLineCard();
    }

    void MainWindow::StepLine(int direction, bool whole)
    {
        if (view == nullptr || selected_path < 0)
            return;
        size_t path = (size_t)selected_path;
        ptrdiff_t segment = (ptrdiff_t)selected_segment;
        if (!zs_view_step(view, &path, &segment, direction, whole ? 1 : 0))
            return;
        selected_path = (int64_t)path;
        selected_segment = (int64_t)segment;
        SaveLineAnchor();
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
        if (selected_path >= 0)
        {
            size_t found = zs_view_nearest_on_layer(view, (size_t)selected_path, (size_t)next - 1);
            if (found != (size_t)-1)
            {
                selected_path = (int64_t)found;
                selected_segment = -1;
                SaveLineAnchor();
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
        selected_parts.erase(std::remove_if(selected_parts.begin(), selected_parts.end(),
                                            [count](int64_t i) { return (size_t)i >= count; }),
                             selected_parts.end());
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
        if (ctrl)
            return false;
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
        if (!selected_parts.empty())
        {
            zs_app *app = model->Active();
            if (key == VirtualKey::Delete)
            {
                std::vector<int64_t> list = selected_parts;
                std::sort(list.rbegin(), list.rend());
                for (int64_t i : list)
                    zs_app_part_remove(app, (size_t)i);
                selected_parts.clear();
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
            // The Turn tool: the arrows and Page Up and Down turn the part.
            if (tool == Tool::Turn && (mx != 0 || my != 0 || key == VirtualKey::PageUp || key == VirtualKey::PageDown))
            {
                size_t part = (size_t)selected_parts[0];
                double degrees = shift ? 5 : 15;
                zs_part p{};
                if (key == VirtualKey::PageUp || key == VirtualKey::PageDown)
                    zs_app_part_turn(app, part, 1, key == VirtualKey::PageUp ? degrees : -degrees);
                else if (my != 0)
                    zs_app_part_turn(app, part, 0, my * degrees);
                else if (zs_app_part_get(app, part, &p) == ZS_OK)
                    zs_app_part_rotate(app, part, p.rotation - mx * degrees);
                PlateEdited();
                UpdateRings();
                return true;
            }
            if (mx != 0 || my != 0)
            {
                double step = shift ? 10 : 1;
                for (int64_t i : selected_parts)
                {
                    zs_part p{};
                    if (zs_app_part_get(app, (size_t)i, &p) == ZS_OK)
                        zs_app_part_move(app, (size_t)i, p.x + mx * step, p.y + my * step);
                }
                PlateEdited();
                return true;
            }
        }
        if (key == VirtualKey::Delete && selected_path >= 0)
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
        case VirtualKey::R: SetTool(Tool::Turn); return true;
        case VirtualKey::S: SetTool(Tool::Support); return true;
        case VirtualKey::G: SetTool(Tool::Grab); return true;
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
            if (HandRelease())
                return true;
            if (tool == Tool::Measure && measure_count > 0)
            {
                ClearMeasure();
                return true;
            }
            if (selected_path >= 0 || !selected_parts.empty())
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
        int64_t now = selected_parts.empty() ? -1 : selected_parts[0];
        int64_t next = now < 0 ? (direction > 0 ? 0 : count - 1) : ((now + direction) % count + count) % count;
        if (tool != Tool::Move && tool != Tool::Turn)
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
        else if (key == VirtualKey::C && !ctrl && selected_path >= 0)
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
            StepPlate(key == bracket_left ? -1 : 1);
        else if (key == VirtualKey::Home && model->PlateCount() > 1)
            FramePlate((size_t)-1);
        else if (key == VirtualKey::F || key == VirtualKey::Home)
            FramePlate(model->ActivePlate());
        else if (!OnToolKey(key, shift, ctrl))
            return;
        e.Handled(true);
    }
}
