// Draws the package logos of the Windows app from assets/icon with the SVG
// renderer of Direct2D, so this works on Windows with no other tool.
//
// The app is unpackaged, so it does not load these files yet. An MSIX
// package of the app uses them. The exe and the window use
// assets/icon/out/zslice.ico (ZSlice.rc).
//
// A logo has the art in the middle, on a clear background. Art below 48 px
// comes from zslice-small.svg, which has thicker lines.
//
// Usage: make_logos big.svg small.svg out-folder
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <windows.h>
#include <d2d1_3.h>
#include <shlwapi.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdio>
#include <string>

using Microsoft::WRL::ComPtr;

namespace
{
    struct Logo
    {
        wchar_t const *name;
        UINT width, height, art;
    };

    Logo const logos[] = {
        { L"Square44x44Logo.scale-200.png", 88, 88, 88 },
        { L"Square44x44Logo.targetsize-16.png", 16, 16, 16 },
        { L"Square44x44Logo.targetsize-24.png", 24, 24, 24 },
        { L"Square44x44Logo.targetsize-24_altform-unplated.png", 24, 24, 24 },
        { L"Square44x44Logo.targetsize-32.png", 32, 32, 32 },
        { L"Square44x44Logo.targetsize-48.png", 48, 48, 48 },
        { L"Square44x44Logo.targetsize-256.png", 256, 256, 256 },
        { L"Square150x150Logo.scale-200.png", 300, 300, 200 },
        { L"Wide310x150Logo.scale-200.png", 620, 300, 200 },
        { L"LockScreenLogo.scale-200.png", 48, 48, 48 },
        { L"SplashScreen.scale-200.png", 1240, 600, 300 },
        { L"StoreLogo.png", 50, 50, 50 },
    };

    HRESULT Draw(ID2D1Factory1 *d2d, IWICImagingFactory *wic, std::wstring const &svg, Logo const &logo, std::wstring const &path)
    {
        ComPtr<IWICBitmap> bitmap;
        HRESULT hr = wic->CreateBitmap(logo.width, logo.height, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnDemand, &bitmap);
        if (FAILED(hr))
            return hr;
        auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE,
                                                  D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
        ComPtr<ID2D1RenderTarget> target;
        if (FAILED(hr = d2d->CreateWicBitmapRenderTarget(bitmap.Get(), props, &target)))
            return hr;
        ComPtr<ID2D1DeviceContext5> context;
        if (FAILED(hr = target.As(&context)))
            return hr;
        ComPtr<IStream> stream;
        if (FAILED(hr = SHCreateStreamOnFileEx(svg.c_str(), STGM_READ | STGM_SHARE_DENY_WRITE, 0, FALSE, nullptr, &stream)))
            return hr;
        ComPtr<ID2D1SvgDocument> document;
        auto art = (FLOAT)logo.art;
        if (FAILED(hr = context->CreateSvgDocument(stream.Get(), D2D1::SizeF(art, art), &document)))
            return hr;
        context->BeginDraw();
        context->Clear(D2D1::ColorF(0, 0, 0, 0));
        context->SetTransform(D2D1::Matrix3x2F::Translation((logo.width - art) / 2, (logo.height - art) / 2));
        context->DrawSvgDocument(document.Get());
        if (FAILED(hr = context->EndDraw()))
            return hr;

        // PNG holds straight alpha.
        ComPtr<IWICBitmapSource> straight;
        if (FAILED(hr = WICConvertBitmapSource(GUID_WICPixelFormat32bppBGRA, bitmap.Get(), &straight)))
            return hr;
        ComPtr<IWICStream> file;
        if (FAILED(hr = wic->CreateStream(&file)) || FAILED(hr = file->InitializeFromFilename(path.c_str(), GENERIC_WRITE)))
            return hr;
        ComPtr<IWICBitmapEncoder> encoder;
        if (FAILED(hr = wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
            FAILED(hr = encoder->Initialize(file.Get(), WICBitmapEncoderNoCache)))
            return hr;
        ComPtr<IWICBitmapFrameEncode> frame;
        if (FAILED(hr = encoder->CreateNewFrame(&frame, nullptr)) || FAILED(hr = frame->Initialize(nullptr)) ||
            FAILED(hr = frame->SetSize(logo.width, logo.height)))
            return hr;
        WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
        if (FAILED(hr = frame->SetPixelFormat(&format)) || FAILED(hr = frame->WriteSource(straight.Get(), nullptr)) ||
            FAILED(hr = frame->Commit()))
            return hr;
        return encoder->Commit();
    }
}

int wmain(int argc, wchar_t **argv)
{
    if (argc != 4)
    {
        fwprintf(stderr, L"usage: make_logos big.svg small.svg out-folder\n");
        return 2;
    }
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)))
        return 1;
    ComPtr<ID2D1Factory1> d2d;
    ComPtr<IWICImagingFactory> wic;
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.GetAddressOf())) ||
        FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))))
    {
        fwprintf(stderr, L"no Direct2D or WIC\n");
        return 1;
    }
    for (auto const &logo : logos)
    {
        std::wstring path = std::wstring(argv[3]) + L"\\" + logo.name;
        HRESULT hr = Draw(d2d.Get(), wic.Get(), logo.art < 48 ? argv[2] : argv[1], logo, path);
        if (FAILED(hr))
        {
            fwprintf(stderr, L"%s: failed, 0x%08lx\n", logo.name, (unsigned long)hr);
            return 1;
        }
        wprintf(L"%s %ux%u\n", logo.name, logo.width, logo.height);
    }
    return 0;
}
