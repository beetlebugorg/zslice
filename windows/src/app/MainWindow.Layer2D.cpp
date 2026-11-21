// The 2D view of the top layer in the window: key 2 or the main menu. A drag
// pans it, the wheel and a pinch zoom it, a click selects a line, and a
// double click fits it. The behavior follows the GTK shell
// (linux/src/ui/preview.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include "Layer2D.h"

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
                Click2D(last_2d_x, last_2d_y);
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
        style.segment = selected_segment;
        zs_toolpaths tp{};
        if (selected_path >= 0 && zs_app_toolpaths(app, &tp) == ZS_OK && layer2d_layer < tp.layer_count)
        {
            int64_t first = layer2d_layer == 0 ? 0 : tp.layer_ends[layer2d_layer - 1];
            if (selected_path >= first && selected_path < (int64_t)tp.layer_ends[layer2d_layer])
                style.selected = selected_path - first;
            style.fade = LineFade().IsChecked() != nullptr && LineFade().IsChecked().Value();
        }
        double bed_x, bed_y;
        BedSize(bed_x, bed_y);
        layer2d->Draw(bed_x, bed_y, style);
    }

    void MainWindow::Click2D(double x, double y)
    {
        if (layer2d == nullptr || !layer2d->HasPaths())
            return;
        double bed_x, bed_y;
        layer2d->ToBed(x, y, bed_x, bed_y);
        size_t segment = 0;
        size_t path = zs_view_pick_layer(view, layer2d_layer, bed_x, bed_y, &segment);
        if (path != (size_t)-1)
            SelectLine((int64_t)path, (int64_t)segment);
        else
            ClearSelection();
        RequestDraw();
    }
}
