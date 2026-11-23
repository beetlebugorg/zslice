// See Layer2D.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "Layer2D.h"

#include <d2d1_2helper.h>

#include <algorithm>
#include <cmath>

#include "zs_model.h"

using winrt::com_ptr;

namespace
{
    // The feature colors of the GTK shell (linux/src/ui/colors.h).
    constexpr float feature_rgb[][3] = {
        { 0.851f, 0.282f, 0.059f }, // outer wall
        { 0.961f, 0.624f, 0.000f }, // inner wall
        { 0.110f, 0.494f, 0.839f }, // skin
        { 0.169f, 0.541f, 0.243f }, // infill
        { 0.682f, 0.243f, 0.788f }, // ironing
        { 0.553f, 0.431f, 0.388f }, // skirt and brim
        { 0.678f, 0.710f, 0.741f }, // support
        { 0.286f, 0.314f, 0.341f }, // support interface
        { 0.047f, 0.651f, 0.682f }, // slope smoothing
        { 0.510f, 0.788f, 0.118f }, // slope ironing
        { 0.400f, 0.800f, 0.949f }, // bridge
    };

    // A realization holds for this range of zoom around its own.
    constexpr double zoom_range = 1.5;

    uint32_t PathStart(zs_layer_paths const &paths, size_t i)
    {
        return i == 0 ? 0 : paths.path_ends[i - 1];
    }
}

namespace zs
{
    Layer2D::~Layer2D()
    {
        Clear();
    }

    void Layer2D::ReleaseGeometry()
    {
        for (auto &item : strokes_)
            item = nullptr;
        for (auto &item : realized_)
            item = nullptr;
        outline_ = nullptr;
        outline_realized_ = nullptr;
        realized_scale_ = 0;
        gaps_realized_ = nullptr;
        gap_chosen_ = nullptr;
        gaps_key_ = nullptr;
    }

    void Layer2D::Clear()
    {
        ReleaseGeometry();
        if (have_paths)
            zs_layer_paths_free(&paths_);
        paths_ = {};
        have_paths = false;
    }

    void Layer2D::ReleaseDevice()
    {
        for (auto &item : realized_)
            item = nullptr;
        outline_realized_ = nullptr;
        realized_scale_ = 0;
        gaps_realized_ = nullptr;
        gap_chosen_ = nullptr;
        gaps_key_ = nullptr;
        brush_ = nullptr;
        if (context_)
            context_->SetTarget(nullptr);
        context_ = nullptr;
        device_ = nullptr;
        swapchain_ = nullptr;
        d3d_ = nullptr;
    }

    bool Layer2D::EnsureDevice()
    {
        if (context_)
            return true;
        if (panel_ == nullptr || width_ <= 0 || height_ <= 0)
            return false;
        if (!factory_)
        {
            D2D1_FACTORY_OPTIONS options{};
            if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory2), &options, factory_.put_void())))
                return false;
            auto props = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_LINE_JOIN_ROUND);
            if (FAILED(factory_->CreateStrokeStyle(props, nullptr, 0, round_.put())))
                return false;
        }
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0, D3D11_SDK_VERSION, d3d_.put(), nullptr, nullptr);
        if (FAILED(hr))
            hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, nullptr, 0, D3D11_SDK_VERSION, d3d_.put(), nullptr, nullptr);
        if (FAILED(hr))
            return false;
        auto dxgi = d3d_.as<IDXGIDevice1>();
        dxgi->SetMaximumFrameLatency(1);
        if (FAILED(factory_->CreateDevice(dxgi.get(), device_.put())) ||
            FAILED(device_->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, context_.put())))
        {
            ReleaseDevice();
            return false;
        }
        com_ptr<IDXGIAdapter> adapter;
        com_ptr<IDXGIFactory2> dxgi_factory;
        if (FAILED(dxgi->GetAdapter(adapter.put())) || FAILED(adapter->GetParent(IID_PPV_ARGS(dxgi_factory.put()))))
        {
            ReleaseDevice();
            return false;
        }
        DXGI_SWAP_CHAIN_DESC1 desc{};
        desc.Width = (UINT)std::max(1l, std::lround(width_ * scale_x_));
        desc.Height = (UINT)std::max(1l, std::lround(height_ * scale_y_));
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        desc.Scaling = DXGI_SCALING_STRETCH;
        com_ptr<IDXGISwapChain1> chain;
        if (FAILED(dxgi_factory->CreateSwapChainForComposition(d3d_.get(), &desc, nullptr, chain.put())))
        {
            ReleaseDevice();
            return false;
        }
        swapchain_ = chain.as<IDXGISwapChain2>();
        if (FAILED(panel_.as<ISwapChainPanelNative>()->SetSwapChain(chain.get())) || !MakeTarget() ||
            FAILED(context_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0), brush_.put())))
        {
            ReleaseDevice();
            return false;
        }
        return true;
    }

    bool Layer2D::MakeTarget()
    {
        DXGI_MATRIX_3X2_F inverse{ (float)(1.0 / scale_x_), 0.0f, 0.0f, (float)(1.0 / scale_y_), 0.0f, 0.0f };
        swapchain_->SetMatrixTransform(&inverse);
        com_ptr<IDXGISurface> surface;
        if (FAILED(swapchain_->GetBuffer(0, IID_PPV_ARGS(surface.put()))))
            return false;
        float dpi_x = (float)(96 * scale_x_), dpi_y = (float)(96 * scale_y_);
        auto props = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                                             D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), dpi_x, dpi_y);
        com_ptr<ID2D1Bitmap1> target;
        if (FAILED(context_->CreateBitmapFromDxgiSurface(surface.get(), &props, target.put())))
            return false;
        context_->SetTarget(target.get());
        context_->SetDpi(dpi_x, dpi_y);
        return true;
    }

    void Layer2D::Resize(winrt::Microsoft::UI::Xaml::Controls::SwapChainPanel const &panel, double width, double height, double scale_x,
                         double scale_y)
    {
        if (width <= 0 || height <= 0 || scale_x <= 0 || scale_y <= 0)
            return;
        bool same = width == width_ && height == height_ && scale_x == scale_x_ && scale_y == scale_y_;
        panel_ = panel;
        // The bottom left stays in place on the screen.
        width_ = width;
        height_ = height;
        scale_x_ = scale_x;
        scale_y_ = scale_y;
        if (!context_ || same)
            return;
        context_->SetTarget(nullptr);
        UINT w = (UINT)std::max(1l, std::lround(width * scale_x)), h = (UINT)std::max(1l, std::lround(height * scale_y));
        HRESULT hr = swapchain_->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, 0);
        if (FAILED(hr) || !MakeTarget())
            ReleaseDevice();
    }

    // The paths of one feature, or the path `only`.
    com_ptr<ID2D1PathGeometry> Layer2D::BuildPaths(int feature, int64_t only) const
    {
        com_ptr<ID2D1PathGeometry> geometry;
        com_ptr<ID2D1GeometrySink> sink;
        if (FAILED(factory_->CreatePathGeometry(geometry.put())) || FAILED(geometry->Open(sink.put())))
            return nullptr;
        bool any = false;
        size_t first = only >= 0 ? (size_t)only : 0, end = only >= 0 ? (size_t)only + 1 : paths_.path_count;
        for (size_t i = first; i < end && i < paths_.path_count; i++)
        {
            if (only < 0 && paths_.path_features[i] != feature)
                continue;
            uint32_t a = PathStart(paths_, i), b = paths_.path_ends[i];
            if (b <= a)
                continue;
            auto const *points = reinterpret_cast<D2D1_POINT_2F const *>(paths_.points);
            sink->BeginFigure(points[a], D2D1_FIGURE_BEGIN_HOLLOW);
            // A path of one point draws as a dot of its round caps.
            if (b - a > 1)
                sink->AddLines(points + a + 1, b - a - 1);
            else
                sink->AddLine(points[a]);
            sink->EndFigure(paths_.path_closed[i] ? D2D1_FIGURE_END_CLOSED : D2D1_FIGURE_END_OPEN);
            any = true;
        }
        if (FAILED(sink->Close()) || !any)
            return nullptr;
        return geometry;
    }

    void Layer2D::SetLayer(zs_app const *app, size_t layer)
    {
        if (!factory_ && !EnsureDevice())
            return;
        zs_layer_paths next{};
        if (zs_app_layer_paths(app, layer, &next) != ZS_OK)
            return;
        Clear();
        paths_ = next;
        have_paths = true;
        for (size_t f = 0; f < feature_count; f++)
            strokes_[f] = BuildPaths((int)f, -1);

        // Outer loops turn one way and holes the other, so the winding rule
        // fills only the material.
        com_ptr<ID2D1GeometrySink> sink;
        if (paths_.outline_count > 0 && SUCCEEDED(factory_->CreatePathGeometry(outline_.put())) && SUCCEEDED(outline_->Open(sink.put())))
        {
            sink->SetFillMode(D2D1_FILL_MODE_WINDING);
            auto const *points = reinterpret_cast<D2D1_POINT_2F const *>(paths_.outline_points);
            for (size_t i = 0; i < paths_.outline_count; i++)
            {
                uint32_t a = i == 0 ? 0 : paths_.outline_ends[i - 1], b = paths_.outline_ends[i];
                if (b < a + 3)
                    continue;
                sink->BeginFigure(points[a], D2D1_FIGURE_BEGIN_FILLED);
                sink->AddLines(points + a + 1, b - a - 1);
                sink->EndFigure(D2D1_FIGURE_END_CLOSED);
            }
            if (FAILED(sink->Close()))
                outline_ = nullptr;
        }
    }

    void Layer2D::Fit(double const box[4])
    {
        if (width_ <= 0 || height_ <= 0)
            return;
        double w = std::max(box[2] - box[0], 1.0), h = std::max(box[3] - box[1], 1.0);
        scale_ = 0.85 * std::min(width_ / w, height_ / h);
        ox_ = width_ / 2 - (box[0] + box[2]) / 2 * scale_;
        oy_ = height_ / 2 - (box[1] + box[3]) / 2 * scale_;
        fitted = true;
    }

    void Layer2D::Pan(double dx, double dy)
    {
        ox_ += dx;
        oy_ -= dy;
    }

    void Layer2D::Zoom(double factor, double x, double y)
    {
        // The point under the pointer stays in place.
        double mx = (x - ox_) / scale_, my = ((height_ - y) - oy_) / scale_;
        scale_ = std::clamp(scale_ * factor, 0.05, 2000.0);
        ox_ = x - mx * scale_;
        oy_ = (height_ - y) - my * scale_;
    }

    void Layer2D::ToBed(double x, double y, double &bed_x, double &bed_y) const
    {
        bed_x = (x - ox_) / scale_;
        bed_y = ((height_ - y) - oy_) / scale_;
    }

    void Layer2D::ToView(double bed_x, double bed_y, double &x, double &y) const
    {
        x = ox_ + bed_x * scale_;
        y = height_ - (oy_ + bed_y * scale_);
    }

#ifdef ZS_DEV_HOOKS
    // The back buffer, before the present, as a 32-bit BMP.
    void Layer2D::SaveFrame()
    {
        std::wstring path = std::move(save_path);
        save_path.clear();
        com_ptr<ID3D11Texture2D> back, copy;
        com_ptr<ID3D11DeviceContext> device_context;
        if (FAILED(swapchain_->GetBuffer(0, IID_PPV_ARGS(back.put()))))
            return;
        D3D11_TEXTURE2D_DESC desc{};
        back->GetDesc(&desc);
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        desc.MiscFlags = 0;
        if (FAILED(d3d_->CreateTexture2D(&desc, nullptr, copy.put())))
            return;
        d3d_->GetImmediateContext(device_context.put());
        device_context->CopyResource(copy.get(), back.get());
        D3D11_MAPPED_SUBRESOURCE map{};
        if (FAILED(device_context->Map(copy.get(), 0, D3D11_MAP_READ, 0, &map)))
            return;
        FILE *out = nullptr;
        if (_wfopen_s(&out, path.c_str(), L"wb") == 0 && out != nullptr)
        {
            BITMAPINFOHEADER info{};
            info.biSize = sizeof info;
            info.biWidth = (LONG)desc.Width;
            info.biHeight = -(LONG)desc.Height;
            info.biPlanes = 1;
            info.biBitCount = 32;
            info.biCompression = BI_RGB;
            BITMAPFILEHEADER head{};
            head.bfType = 0x4D42;
            head.bfOffBits = sizeof head + sizeof info;
            head.bfSize = head.bfOffBits + 4 * desc.Width * desc.Height;
            fwrite(&head, sizeof head, 1, out);
            fwrite(&info, sizeof info, 1, out);
            for (UINT y = 0; y < desc.Height; y++)
                fwrite(static_cast<uint8_t const *>(map.pData) + y * map.RowPitch, 4, desc.Width, out);
            fclose(out);
        }
        device_context->Unmap(copy.get(), 0);
    }
#endif

    void Layer2D::Realize(float tolerance)
    {
        for (size_t f = 0; f < feature_count; f++)
        {
            realized_[f] = nullptr;
            if (strokes_[f])
                context_->CreateStrokedGeometryRealization(strokes_[f].get(), tolerance, paths_.width, round_.get(), realized_[f].put());
        }
        outline_realized_ = nullptr;
        if (outline_)
            context_->CreateFilledGeometryRealization(outline_.get(), tolerance, outline_realized_.put());
        realized_scale_ = scale_;
    }

    void Layer2D::BuildGaps(Layer2DStyle const &style, float tolerance)
    {
        gaps_key_ = style.gaps;
        gaps_key_count_ = style.gap_count;
        gaps_key_selected_ = style.gap_selected;
        gaps_scale_ = realized_scale_;
        auto build = [&](bool chosen, com_ptr<ID2D1GeometryRealization> &out) {
            out = nullptr;
            com_ptr<ID2D1PathGeometry> geometry;
            com_ptr<ID2D1GeometrySink> sink;
            if (FAILED(factory_->CreatePathGeometry(geometry.put())) || FAILED(geometry->Open(sink.put())))
                return;
            sink->SetFillMode(D2D1_FILL_MODE_WINDING);
            bool any = false;
            for (size_t i = 0; i < style.gap_count; i++)
            {
                if ((style.gap_selected == (int64_t)i) != chosen)
                    continue;
                for (uint32_t k = 0; k < style.gaps[i].run_len; k++)
                {
                    zs_gap_run const &r = style.gap_runs[style.gaps[i].run_start + k];
                    float x0 = (float)r.x0, x1 = (float)r.x1, y0 = (float)r.y - 0.02f, y1 = (float)r.y + 0.02f;
                    D2D1_POINT_2F corners[3] = { { x1, y0 }, { x1, y1 }, { x0, y1 } };
                    sink->BeginFigure({ x0, y0 }, D2D1_FIGURE_BEGIN_FILLED);
                    sink->AddLines(corners, 3);
                    sink->EndFigure(D2D1_FIGURE_END_CLOSED);
                    any = true;
                }
            }
            if (SUCCEEDED(sink->Close()) && any)
                context_->CreateFilledGeometryRealization(geometry.get(), tolerance, out.put());
        };
        build(false, gaps_realized_);
        build(true, gap_chosen_);
    }

    bool Layer2D::Draw(double bed_x, double bed_y, Layer2DStyle const &style)
    {
        if (!EnsureDevice())
            return false;
        auto color = [this](float r, float g, float b, float a = 1.0f) { brush_->SetColor(D2D1::ColorF(r, g, b, a)); };

        context_->BeginDraw();
        context_->SetTransform(D2D1::Matrix3x2F::Identity());
        context_->Clear(style.dark ? D2D1::ColorF(0.114f, 0.114f, 0.125f) : D2D1::ColorF(0.965f, 0.969f, 0.973f));
        context_->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
        auto world = D2D1::Matrix3x2F((float)scale_, 0, 0, (float)-scale_, (float)ox_, (float)(height_ - oy_));
        context_->SetTransform(world);

        // The bed and a grid of 10 mm, with lines of one point.
        color(style.dark ? 0.16f : 0.906f, style.dark ? 0.16f : 0.914f, style.dark ? 0.18f : 0.925f);
        context_->FillRectangle(D2D1::RectF(0, 0, (float)bed_x, (float)bed_y), brush_.get());
        color(style.dark ? 0.25f : 0.82f, style.dark ? 0.26f : 0.84f, style.dark ? 0.28f : 0.86f);
        float hair = (float)(1.0 / scale_);
        for (double x = 0; x <= bed_x; x += 10)
            context_->DrawLine(D2D1::Point2F((float)x, 0), D2D1::Point2F((float)x, (float)bed_y), brush_.get(), hair);
        for (double y = 0; y <= bed_y; y += 10)
            context_->DrawLine(D2D1::Point2F(0, (float)y), D2D1::Point2F((float)bed_x, (float)y), brush_.get(), hair);

        if (have_paths)
        {
            // A new tessellation only when the zoom leaves its range.
            float tolerance = D2D1::ComputeFlatteningTolerance(world, 96 * (float)scale_x_, 96 * (float)scale_y_, (float)zoom_range);
            if (realized_scale_ <= 0 || scale_ > realized_scale_ * zoom_range || scale_ < realized_scale_ / (zoom_range * zoom_range))
                Realize(tolerance);

            if (outline_realized_)
            {
                color(style.dark ? 0.30f : 0.80f, style.dark ? 0.32f : 0.83f, style.dark ? 0.35f : 0.86f);
                context_->DrawGeometryRealization(outline_realized_.get(), brush_.get());
            }
            bool selected = style.selected >= 0 && (size_t)style.selected < paths_.path_count;
            com_ptr<ID2D1PathGeometry> line = selected ? BuildPaths(0, style.selected) : nullptr;
            // The selected path: a wide yellow line under the paths.
            if (line)
            {
                color(1.0f, 0.82f, 0.1f, 0.9f);
                context_->DrawGeometry(line.get(), brush_.get(), paths_.width * 2.5f, round_.get());
            }
            for (size_t f = 0; f < feature_count; f++)
            {
                if (!realized_[f])
                    continue;
                color(feature_rgb[f][0], feature_rgb[f][1], feature_rgb[f][2], style.fade ? 0.12f : 0.9f);
                context_->DrawGeometryRealization(realized_[f].get(), brush_.get());
            }
            if (line)
            {
                // The selected line on top, and its segment in orange.
                color(1.0f, 0.78f, 0.05f);
                context_->DrawGeometry(line.get(), brush_.get(), paths_.width, round_.get());
                uint32_t start = PathStart(paths_, (size_t)style.selected), end = paths_.path_ends[style.selected];
                if (style.segment >= 0 && end > start + 1 && start + (uint32_t)style.segment < end)
                {
                    uint32_t a = start + (uint32_t)style.segment, b = a + 1 < end ? a + 1 : start;
                    color(1.0f, 0.35f, 0.0f);
                    context_->DrawLine(D2D1::Point2F(paths_.points[2 * a], paths_.points[2 * a + 1]),
                                       D2D1::Point2F(paths_.points[2 * b], paths_.points[2 * b + 1]), brush_.get(), paths_.width * 1.6f,
                                       round_.get());
                }
            }

            // The gaps: red cells, the selected gap brighter.
            if (style.gap_count > 0)
            {
                if (style.gaps != gaps_key_ || style.gap_count != gaps_key_count_ || style.gap_selected != gaps_key_selected_ || gaps_scale_ != realized_scale_)
                    BuildGaps(style, tolerance);
                if (gaps_realized_)
                {
                    color(0.9f, 0.1f, 0.15f, 0.75f);
                    context_->DrawGeometryRealization(gaps_realized_.get(), brush_.get());
                }
                if (gap_chosen_)
                {
                    color(1.0f, 0.1f, 0.1f);
                    context_->DrawGeometryRealization(gap_chosen_.get(), brush_.get());
                }
            }
        }

        // The measure tape, in points of the screen: a gold line between
        // the points, and a ring at each point.
        if (style.tape_count > 0)
        {
            context_->SetTransform(D2D1::Matrix3x2F::Identity());
            D2D1_POINT_2F at[2];
            for (int i = 0; i < style.tape_count && i < 2; i++)
            {
                double x, y;
                ToView(style.tape[3 * i], style.tape[3 * i + 1], x, y);
                at[i] = D2D1::Point2F((float)x, (float)y);
            }
            if (style.tape_count == 2)
            {
                color(0, 0, 0, 0.45f);
                context_->DrawLine(at[0], at[1], brush_.get(), 4, round_.get());
                color(0.96f, 0.72f, 0.10f);
                context_->DrawLine(at[0], at[1], brush_.get(), 2, round_.get());
            }
            for (int i = 0; i < style.tape_count && i < 2; i++)
            {
                auto ring = D2D1::Ellipse(at[i], 5, 5);
                color(0.96f, 0.72f, 0.10f);
                context_->FillEllipse(ring, brush_.get());
                color(0, 0, 0, 0.6f);
                context_->DrawEllipse(ring, brush_.get(), 1.5f);
            }
        }

        HRESULT hr = context_->EndDraw();
#ifdef ZS_DEV_HOOKS
        if (SUCCEEDED(hr) && !save_path.empty())
            SaveFrame();
#endif
        if (SUCCEEDED(hr))
            hr = swapchain_->Present(1, 0);
        if (hr == D2DERR_RECREATE_TARGET || hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET)
        {
            zs::Log("shell: the 2D view lost its device\n");
            ReleaseDevice();
            return false;
        }
        if (FAILED(hr))
            zs::Log("shell: the 2D view did not draw (0x%08lx)\n", (unsigned long)hr);
        return SUCCEEDED(hr);
    }
}
