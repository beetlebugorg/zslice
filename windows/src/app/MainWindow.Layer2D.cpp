// The 2D view of the top layer in the window: key 2 or the main menu. A drag
// pans it, the wheel and a pinch zoom it, a click selects a line, and a
// double click fits it. The behavior follows the GTK shell
// (linux/src/ui/preview.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include "Layer2D.h"

#include <algorithm>
#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace winrt::ZSlice::implementation
{
    void MainWindow::Wire2D()
    {
        auto panel = Layer2DPanel();
        panel.SizeChanged([this](auto &&, auto &&) { Size2D(); });
        panel.CompositionScaleChanged([this](auto &&, auto &&) { Size2D(); });
        panel.PointerPressed([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto at = e.GetCurrentPoint(Layer2DPanel()).Position();
            drag_2d = true;
            press_2d_x = last_2d_x = at.X;
            press_2d_y = last_2d_y = at.Y;
            press_2d_left = e.GetCurrentPoint(Layer2DPanel()).Properties().IsLeftButtonPressed();
            Layer2DPanel().CapturePointer(e.Pointer());
            Layer2DPanel().Focus(FocusState::Pointer);
            e.Handled(true);
        });
        panel.PointerMoved([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto at = e.GetCurrentPoint(Layer2DPanel()).Position();
            pointer_x = at.X;
            pointer_y = at.Y;
            if (!drag_2d || layer2d == nullptr)
                return;
            layer2d->Pan(at.X - last_2d_x, at.Y - last_2d_y);
            last_2d_x = at.X;
            last_2d_y = at.Y;
            RequestDraw();
            e.Handled(true);
        });
        auto ended = [this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!drag_2d)
                return;
            drag_2d = false;
            Layer2DPanel().ReleasePointerCapture(e.Pointer());
            e.Handled(true);
            if (press_2d_left && std::abs(last_2d_x - press_2d_x) <= 4 && std::abs(last_2d_y - press_2d_y) <= 4)
                Click2D(last_2d_x, last_2d_y, (static_cast<uint32_t>(e.KeyModifiers()) & static_cast<uint32_t>(Windows::System::VirtualKeyModifiers::Shift)) != 0);
        };
        panel.PointerReleased(ended);
        panel.PointerCaptureLost(ended);
        panel.PointerWheelChanged([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (layer2d == nullptr)
                return;
            auto point = e.GetCurrentPoint(Layer2DPanel());
            int delta = point.Properties().MouseWheelDelta();
            if (delta == 0)
                return;
            // One notch is a step of 20 %. A touchpad sends small deltas.
            layer2d->Zoom(std::pow(1.2, delta / 120.0), point.Position().X, point.Position().Y);
            RequestDraw();
            e.Handled(true);
        });
        panel.DoubleTapped([this](auto &&, auto &&) {
            Fit2D();
            RequestDraw();
        });
    }

    void MainWindow::Size2D()
    {
        if (layer2d == nullptr)
            return;
        auto panel = Layer2DPanel();
        layer2d->Resize(panel, panel.ActualWidth(), panel.ActualHeight(), panel.CompositionScaleX(), panel.CompositionScaleY());
        if (show_2d)
        {
            if (!layer2d->Fitted())
                Fit2D();
            RequestDraw();
        }
    }

    void MainWindow::BedSize(double &x, double &y)
    {
        x = atof(model->GetSetting("machine.bed_size_x").c_str());
        y = atof(model->GetSetting("machine.bed_size_y").c_str());
        if (x <= 0)
            x = 220;
        if (y <= 0)
            y = 220;
    }

    void MainWindow::Fit2D()
    {
        if (layer2d == nullptr || model == nullptr)
            return;
        double box[4] = {};
        if (zs_app_part_bounds(model->Active(), box) != ZS_OK)
        {
            box[0] = box[1] = 0;
            BedSize(box[2], box[3]);
        }
        layer2d->Fit(box);
    }

    void MainWindow::Set2D(bool on)
    {
        if (on == show_2d || view == nullptr)
            return;
        show_2d = on;
        if (on)
        {
            if (layer2d == nullptr)
                layer2d = std::make_unique<zs::Layer2D>();
            Layer2DPanel().Visibility(Visibility::Visible);
            ViewSign().Visibility(Visibility::Visible);
            EmptyHint().Visibility(Visibility::Collapsed);
            layer2d_dirty = true;
            Layer2DPanel().UpdateLayout();
            Size2D();
            Fit2D();
            Layer2DPanel().Focus(FocusState::Programmatic);
        }
        else
        {
            Layer2DPanel().Visibility(Visibility::Collapsed);
            ViewSign().Visibility(Visibility::Collapsed);
            ViewPanel().Focus(FocusState::Programmatic);
        }
        RequestDraw();
    }

    void MainWindow::Draw2D()
    {
        if (layer2d == nullptr || model == nullptr)
            return;
        zs_app *app = model->Active();
        int state = zs_app_state(app);
        size_t layer = layer_count > 0 ? (size_t)std::lround(LayerSlider().Value()) - 1 : 0;
        if (state == ZS_STATE_EMPTY)
        {
            layer2d->Clear();
            layer2d_dirty = false;
        }
        // While a slice runs the view keeps the last layer.
        else if (state == ZS_STATE_DONE && layer_count > 0 && (layer2d_dirty || layer != layer2d_layer))
        {
            layer2d->SetLayer(app, layer);
            layer2d_layer = layer;
            layer2d_dirty = false;
        }

        zs::Layer2DStyle style;
        style.dark = Root().ActualTheme() == ElementTheme::Dark;
        style.segment = SelectedSegment();
        zs_toolpaths tp{};
        if (SelectedPath() >= 0 && zs_app_toolpaths(app, &tp) == ZS_OK && layer2d_layer < tp.layer_count)
        {
            int64_t first = layer2d_layer == 0 ? 0 : tp.layer_ends[layer2d_layer - 1];
            if (SelectedPath() >= first && SelectedPath() < (int64_t)tp.layer_ends[layer2d_layer])
                style.selected = SelectedPath() - first;
            style.fade = LineFade().IsChecked() != nullptr && LineFade().IsChecked().Value();
        }
        if (!line_more.empty() && zs_app_toolpaths(app, &tp) == ZS_OK && layer2d_layer < tp.layer_count)
        {
            int64_t first = layer2d_layer == 0 ? 0 : tp.layer_ends[layer2d_layer - 1];
            for (MoreLine const &line : line_more)
                if (line.path >= first && line.path < (int64_t)tp.layer_ends[layer2d_layer])
                    style.more.push_back(line.path - first);
        }
        if (gaps_on && state == ZS_STATE_DONE && layer_count > 0)
        {
            size_t runs = 0;
            if (zs_app_layer_gaps(app, layer2d_layer, &style.gaps, &style.gap_count, &style.gap_runs, &runs) != ZS_OK)
                style.gap_count = 0;
            else if (GapCard().Visibility() == Visibility::Visible && gap_selected_layer == layer2d_layer)
                style.gap_selected = gap_selected;
        }
        style.tape_count = measure_count;
        std::copy(measure, measure + 6, style.tape);
        double bed_x, bed_y;
        BedSize(bed_x, bed_y);
        layer2d->Draw(bed_x, bed_y, style);
    }

    // A click of the tape: a point on the top layer, or the center of a
    // circle or an arc there. shift: the point itself.
    void MainWindow::MeasureClick2D(double x, double y, bool shift)
    {
        zs_app *app = model->Active();
        if (zs_app_state(app) != ZS_STATE_DONE)
            return;
        double mx, my;
        layer2d->ToBed(x, y, mx, my);
        zs_toolpaths tp{};
        bool have = zs_app_toolpaths(app, &tp) == ZS_OK && layer2d_layer < tp.layer_count;
        double z = have ? tp.layer_z[layer2d_layer] : 0, radius = 0;
        int shape = 0;
        size_t path = zs_app_pick_layer(app, layer2d_layer, mx, my);
        if (!shift && have && path != (size_t)-1)
        {
            // The segment of the path nearest to the point.
            uint32_t a = path == 0 ? 0 : tp.path_ends[path - 1], b = tp.path_ends[path];
            size_t segment = 0;
            double best = 1e30;
            for (uint32_t k = a; k + 1 < b; k++)
            {
                double ax = tp.points[2 * k], ay = tp.points[2 * k + 1], dx = tp.points[2 * k + 2] - ax, dy = tp.points[2 * k + 3] - ay;
                double l2 = dx * dx + dy * dy;
                double u = l2 > 0 ? std::clamp(((mx - ax) * dx + (my - ay) * dy) / l2, 0.0, 1.0) : 0;
                double d = std::hypot(mx - ax - u * dx, my - ay - u * dy);
                if (d < best)
                {
                    best = d;
                    segment = k - a;
                }
            }
            zs_measure m{};
            if (zs_app_measure(app, path, segment, &m) == ZS_OK && (m.shape == 1 || m.shape == 2))
            {
                mx = m.center_x;
                my = m.center_y;
                radius = m.radius;
                shape = m.shape;
                if (m.shape == 1 || m.shape == 2)
                    SelectLine((int64_t)path, (int64_t)segment);
            }
        }
        AddMeasure(mx, my, z, radius, shape);
    }

    void MainWindow::Click2D(double x, double y, bool shift)
    {
        if (layer2d == nullptr || !layer2d->HasPaths())
            return;
        if (tool == Tool::Measure)
        {
            MeasureClick2D(x, y, shift);
            return;
        }
        // A click elsewhere ends a range of layers.
        RangeClose();
        double bed_x, bed_y;
        layer2d->ToBed(x, y, bed_x, bed_y);
        size_t segment = 0;
        size_t path = zs_view_pick_layer(view, layer2d_layer, bed_x, bed_y, &segment);
        // Shift and a click: the line joins the selection, or leaves it.
        if (shift)
        {
            if (path != (size_t)-1)
                ToggleMoreLine((int64_t)path);
            RequestDraw();
            return;
        }
        if (path != (size_t)-1)
        {
            page_gap = false;
            SelectLine((int64_t)path, (int64_t)segment);
            GoToSelected();
        }
        else
            ClearSelection();
        RequestDraw();
    }
}
