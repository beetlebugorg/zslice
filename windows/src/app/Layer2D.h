// The 2D view of one layer, drawn with Direct2D on its own swapchain.
//
// The geometry of a layer is built once. Its strokes are tessellated once
// for a range of zoom, so a pan or a zoom only sets a transform. The colors
// and the drawing order follow the GTK shell (linux/src/ui/layer-draw.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once

#include <d2d1_2.h>
#include <d3d11.h>

#include <array>

#include "zslice-app.h"

namespace zs
{
    struct Layer2DStyle
    {
        // The selected path, as an index in the paths of the layer, or -1.
        int64_t selected = -1;
        int64_t segment = -1;
        bool dark = false;
        // A selected line with "Fade the others".
        bool fade = false;
    };

    class Layer2D
    {
    public:
        Layer2D() = default;
        ~Layer2D();
        Layer2D(Layer2D const &) = delete;
        Layer2D &operator=(Layer2D const &) = delete;

        // The size of the panel, in points, and its composition scale.
        void Resize(winrt::Microsoft::UI::Xaml::Controls::SwapChainPanel const &panel, double width, double height, double scale_x,
                    double scale_y);
        // Loads the paths of a layer of a finished slice.
        void SetLayer(zs_app const *app, size_t layer);
        void Clear();
        bool HasPaths() const { return have_paths; }

        // The whole box (min x, min y, max x, max y, in mm) fits the view.
        void Fit(double const box[4]);
        bool Fitted() const { return fitted; }
        void Pan(double dx, double dy);
        void Zoom(double factor, double x, double y);
        // A point of the view, in points, to mm on the bed.
        void ToBed(double x, double y, double &bed_x, double &bed_y) const;

        bool Draw(double bed_x, double bed_y, Layer2DStyle const &style);

    private:
        bool EnsureDevice();
        void ReleaseDevice();
        bool MakeTarget();
        void ReleaseGeometry();
        winrt::com_ptr<ID2D1PathGeometry> BuildPaths(int feature, int64_t only) const;
        void Realize(float tolerance);

        winrt::Microsoft::UI::Xaml::Controls::SwapChainPanel panel_{ nullptr };
        winrt::com_ptr<ID2D1Factory2> factory_;
        winrt::com_ptr<ID3D11Device> d3d_;
        winrt::com_ptr<ID2D1Device1> device_;
        winrt::com_ptr<ID2D1DeviceContext1> context_;
        winrt::com_ptr<IDXGISwapChain2> swapchain_;
        winrt::com_ptr<ID2D1SolidColorBrush> brush_;
        winrt::com_ptr<ID2D1StrokeStyle> round_;

        // The geometry of the layer, one for each feature.
        static constexpr size_t feature_count = 11;
        std::array<winrt::com_ptr<ID2D1PathGeometry>, feature_count> strokes_;
        std::array<winrt::com_ptr<ID2D1GeometryRealization>, feature_count> realized_;
        winrt::com_ptr<ID2D1PathGeometry> outline_;
        winrt::com_ptr<ID2D1GeometryRealization> outline_realized_;
        double realized_scale_ = 0;

        zs_layer_paths paths_{};
        bool have_paths = false;

        double width_ = 0, height_ = 0, scale_x_ = 1, scale_y_ = 1;
        // Pixels for each mm are scale * the composition scale. The origin
        // is in points, from the bottom left, y up.
        double scale_ = 1, ox_ = 0, oy_ = 0;
        bool fitted = false;
    };
}
