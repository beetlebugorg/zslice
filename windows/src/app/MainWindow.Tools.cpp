// The tools of the main window: the strip, the pointer, and the keys.
//
// V Select, M Move, R Turn, G Grab, and T Measure work here. S Support,
// P Paint, and E Label have their buttons. The behavior follows the GTK
// shell (linux/src/ui/view3d.c and preview.c), and the glyphs are those of
// the web app (web/app/index.html).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

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
          L"<Path Data='M2 4.5h14l-2 3H4zM5 7.5v8M9 7.5v8M13 7.5v8M3.5 15.5h11' " ZS_STROKE L"/>", false },
        { L"Grab", L"G", L"Grab (G): click a part to pick it up, move the pointer to carry it, and click to let go. Alt and a move turn it.",
          L"<Path Data='M6 9V4.2a1.2 1.2 0 0 1 2.4 0V8M8.4 7.5V3.2a1.2 1.2 0 0 1 2.4 0V8M10.8 7.6V4.2a1.2 1.2 0 0 1 2.4 0v6.3c0 3-2 5-4.8 5-2 0-3-.9-4.2-2.6L2.6 10a1.2 1.2 0 0 1 2-1.3L6 10.4' " ZS_STROKE L"/>", true },
        { L"Measure", L"T", L"Measure (T): click two points of the print. The ends of the lines snap. Shift: no snap.",
          L"<Path Data='M1 6H17V12H1ZM4 6v2.5M6.5 6v1.5M9 6v2.5M11.5 6v1.5M14 6v2.5' RenderTransformOrigin='0.5,0.5' " ZS_STROKE L"><Path.RenderTransform><RotateTransform Angle='-45' CenterX='9' CenterY='9'/></Path.RenderTransform></Path>", true },
        { L"Paint", L"P", L"Paint (P): paint filaments on the surface of a part",
          L"<Path Data='M15.5 2.5 8.6 9.4M8.6 9.4c-1.3-.6-2.9-.1-3.5 1.3-.6 1.3-.2 2.4-1.6 3.8 2.6.7 4.9.2 5.7-1.4.6-1.3.4-2.7-.6-3.7z' " ZS_STROKE L"/>", false },
        { L"Label", L"E", L"Label (E): click a face of a part to put text or marks on it",
          L"<Path Data='M3.5 3.5H14.5A1.5 1.5 0 0 1 16 5V13A1.5 1.5 0 0 1 14.5 14.5H3.5A1.5 1.5 0 0 1 2 13V5A1.5 1.5 0 0 1 3.5 3.5ZM5.5 7h5M8 7v4.5M12 11.5h1.2' " ZS_STROKE L"/>", false },
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
            button.Width(38);
            button.Height(38);
            button.Padding(ThicknessHelper::FromUniformLength(0));
            button.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            button.BorderThickness(ThicknessHelper::FromUniformLength(0));
            button.IsEnabled(info.ready);
            Automation::AutomationProperties::SetName(button, info.name);
            ToolTipService::SetToolTip(button, box_value(info.tip));

            Grid content;
            content.Width(34);
            content.Height(34);
            FrameworkElement glyph = MakeGlyph(info.glyph);
            glyph.HorizontalAlignment(HorizontalAlignment::Center);
            glyph.VerticalAlignment(VerticalAlignment::Center);
            content.Children().Append(glyph);
            TextBlock letter;
            letter.Text(info.key);
            letter.FontSize(9);
            letter.Opacity(0.65);
            letter.HorizontalAlignment(HorizontalAlignment::Right);
            letter.VerticalAlignment(VerticalAlignment::Bottom);
            letter.Margin(ThicknessHelper::FromLengths(0, 0, 1, 0));
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
    }

    void MainWindow::SetTool(Tool next)
    {
        if (next != tool)
        {
            // The hand lets go when the tool changes.
            HandRelease();
            if (tool == Tool::Measure)
                ClearMeasure();
            tool = next;
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
            return;
        double dx = position.X - last_x;
        double dy = position.Y - last_y;
        last_x = position.X;
        last_y = position.Y;
        if (tool_drag)
        {
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
        drag = Drag::None;
        tool_drag = false;
        ViewPanel().ReleasePointerCapture(e.Pointer());
        e.Handled(true);
        if (was_tool)
            ToolRelease();
        if (view == nullptr || had_click)
            return;
        // A right click, or a two-finger click that does not slide, opens
        // the menu.
        if (press_right)
        {
            press_right = false;
            if (std::abs(last_x - press_x) <= 4 && std::abs(last_y - press_y) <= 4)
                ShowContextMenu(last_x, last_y);
            return;
        }
        // A press and a release at one place is a click.
        if (std::abs(last_x - press_x) <= 4 && std::abs(last_y - press_y) <= 4 && !was_tool)
        {
            auto mods = e.KeyModifiers();
            ToolClick(last_x, last_y, Has(mods, VirtualKeyModifiers::Shift), Has(mods, VirtualKeyModifiers::Control));
        }
        else if (was_tool && std::abs(last_x - press_x) <= 4 && std::abs(last_y - press_y) <= 4 && tool != Tool::Grab)
        {
            auto mods = e.KeyModifiers();
            ToolClick(last_x, last_y, Has(mods, VirtualKeyModifiers::Shift), Has(mods, VirtualKeyModifiers::Control));
        }
    }

    void MainWindow::OnPanelDoubleTapped(Input::DoubleTappedRoutedEventArgs const &e)
    {
        if (view == nullptr)
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
        if (tool == Tool::Measure)
        {
            MeasureClick(x, y, shift);
            return;
        }
        if (tool == Tool::Grab)
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
        if (path == (size_t)-1)
            ClearSelection();
        else
            SelectLine((int64_t)path, (int64_t)segment);
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

    // A part that cannot stand as it is falls.
    void MainWindow::CheckFall()
    {
        if (model == nullptr || falling)
            return;
        ptrdiff_t part = zs_app_fall_pending(model->Active());
        if (part < 0 || zs_app_fall_start(model->Active(), (size_t)part) != 1)
            return;
        falling = true;
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
        // A third point starts a new measure.
        if (measure_count >= 2)
            measure_count = 0;
        int i = measure_count;
        measure[3 * i] = p[0];
        measure[3 * i + 1] = p[1];
        measure[3 * i + 2] = p[2];
        measure_radius[i] = 0;
        measure_shape[i] = 0;
        // A circle or an arc under the pointer: the point is its center.
        size_t segment = 0;
        size_t path = zs_view_pick_segment(view, (float)(x * s), (float)(y * s), &segment);
        zs_measure m{};
        if (!shift && path != (size_t)-1 && zs_app_measure(model->Active(), path, segment, &m) == ZS_OK && (m.shape == 1 || m.shape == 2))
        {
            measure[3 * i] = m.center_x;
            measure[3 * i + 1] = m.center_y;
            measure_radius[i] = m.radius;
            measure_shape[i] = m.shape;
        }
        measure_count++;
        ShowMeasure();
    }

    void MainWindow::ShowMeasure()
    {
        zs_view_set_measure(view, (size_t)measure_count, measure);
        RequestDraw();
        if (measure_count == 0)
        {
            MeasureCard().Visibility(Visibility::Collapsed);
            return;
        }
        wchar_t text[200];
        if (measure_count == 1)
        {
            if (measure_shape[0] == 1)
                swprintf_s(text, L"Circle ⌀ %.2f mm. Click a second point.", 2 * measure_radius[0]);
            else if (measure_shape[0] == 2)
                swprintf_s(text, L"Arc r %.2f mm. Click a second point.", measure_radius[0]);
            else
                swprintf_s(text, L"Click a second point.");
        }
        else
        {
            double dx = measure[3] - measure[0], dy = measure[4] - measure[1], dz = measure[5] - measure[2];
            swprintf_s(text, L"%.2f mm   (x %.2f, y %.2f, z %.2f)", std::sqrt(dx * dx + dy * dy + dz * dz), std::abs(dx), std::abs(dy), std::abs(dz));
        }
        MeasureText().Text(text);
        MeasureCard().Visibility(Visibility::Visible);
        Canvas::SetLeft(MeasureCard(), 64);
        Canvas::SetTop(MeasureCard(), 12);
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
            int mx = key == VirtualKey::Left ? -1 : key == VirtualKey::Right ? 1 : 0;
            int my = key == VirtualKey::Down ? -1 : key == VirtualKey::Up ? 1 : 0;
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
            if (zs_app_edit_add(model->Active(), (size_t)selected_path, 0, 1) == ZS_OK)
            {
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
        case VirtualKey::G: SetTool(Tool::Grab); return true;
        case VirtualKey::T: SetTool(Tool::Measure); return true;
        case VirtualKey::B: ToggleBed(); return true;
        case VirtualKey::H:
        case VirtualKey::Left: StepLine(-1, shift); return true;
        case VirtualKey::L:
        case VirtualKey::Right: StepLine(1, shift); return true;
        case VirtualKey::K:
        case VirtualKey::Up: StepLayer(1); return true;
        case VirtualKey::J:
        case VirtualKey::Down: StepLayer(-1); return true;
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

    void MainWindow::OnKeyDown(Input::KeyRoutedEventArgs const &e)
    {
        if (model == nullptr || view == nullptr)
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
            ShowContextMenu(pointer_x, pointer_y);
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
            ShowShortcuts();
        }
        else if (key == slash)
        {
            ShowSettingsPane(true);
            SettingsSearch().Focus(FocusState::Keyboard);
        }
        else if (key == bracket_left || key == bracket_right)
            StepPlate(key == bracket_left ? -1 : 1);
        else if (key == VirtualKey::Home && model->PlateCount() > 1)
            FramePlate((size_t)-1);
        else if (key == VirtualKey::F)
            FramePlate(model->ActivePlate());
        else if (!OnToolKey(key, shift, ctrl))
            return;
        e.Handled(true);
    }
}
