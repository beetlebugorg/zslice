// See zs_h264.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_h264.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <objbase.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstring>

using Microsoft::WRL::ComPtr;

namespace zs
{
    namespace
    {
        // CLSID_CMSH264DecoderMFT of wmcodecdsp.h.
        constexpr GUID h264_decoder = { 0x62CE7E72, 0x4C71, 0x4D20, { 0xB1, 0x5D, 0x45, 0x28, 0x31, 0xA8, 0x7D, 0x9D } };
        // 100 ns units: a frame of a 10 fps camera.
        constexpr LONGLONG frame_time = 1000000;
        constexpr int tile_halves_at = 1280;

        using StartFn = HRESULT(WINAPI *)(ULONG, DWORD);
        using ShutdownFn = HRESULT(WINAPI *)();
        using MediaTypeFn = HRESULT(WINAPI *)(IMFMediaType **);
        using SampleFn = HRESULT(WINAPI *)(IMFSample **);
        using BufferFn = HRESULT(WINAPI *)(DWORD, IMFMediaBuffer **);

        inline uint8_t Clamp8(int value)
        {
            return (uint8_t)std::clamp(value, 0, 255);
        }
    }

    struct H264Decoder::Impl
    {
        HMODULE mfplat = nullptr;
        ShutdownFn shutdown = nullptr;
        MediaTypeFn make_type = nullptr;
        SampleFn make_sample = nullptr;
        BufferFn make_buffer = nullptr;
        bool com = false;
        bool started = false;
        ComPtr<IMFTransform> transform;
        MFT_OUTPUT_STREAM_INFO info{};
        // The decoded rows, and the part of them that shows.
        UINT32 coded_width = 0, coded_height = 0, stride = 0;
        UINT32 left = 0, top = 0, width = 0, height = 0;
        bool bt709 = false, full_range = false;
        LONGLONG time = 0;
        int errors = 0;

        Impl()
        {
            HRESULT co = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            com = SUCCEEDED(co);
            mfplat = ::LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
            if (mfplat == nullptr)
                return;
            auto start = reinterpret_cast<StartFn>(::GetProcAddress(mfplat, "MFStartup"));
            shutdown = reinterpret_cast<ShutdownFn>(::GetProcAddress(mfplat, "MFShutdown"));
            make_type = reinterpret_cast<MediaTypeFn>(::GetProcAddress(mfplat, "MFCreateMediaType"));
            make_sample = reinterpret_cast<SampleFn>(::GetProcAddress(mfplat, "MFCreateSample"));
            make_buffer = reinterpret_cast<BufferFn>(::GetProcAddress(mfplat, "MFCreateMemoryBuffer"));
            if (start == nullptr || shutdown == nullptr || make_type == nullptr || make_sample == nullptr || make_buffer == nullptr)
                return;
            if (FAILED(start(MF_VERSION, MFSTARTUP_LITE)))
                return;
            started = true;
            ComPtr<IMFTransform> made;
            if (FAILED(::CoCreateInstance(h264_decoder, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&made))))
                return;
            ComPtr<IMFAttributes> attributes;
            if (SUCCEEDED(made->GetAttributes(&attributes)))
                attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
            ComPtr<IMFMediaType> input;
            if (FAILED(make_type(&input)))
                return;
            input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
            input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
            input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_MixedInterlaceOrProgressive);
            if (FAILED(made->SetInputType(0, input.Get(), 0)))
                return;
            transform = made;
            if (!PickOutput())
            {
                transform.Reset();
                return;
            }
            transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
            transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        }

        ~Impl()
        {
            if (transform != nullptr)
            {
                transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
                transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
                transform.Reset();
            }
            if (started)
                shutdown();
            // The decoder DLLs stay loaded: COM holds them for the process.
            if (mfplat != nullptr)
                ::FreeLibrary(mfplat);
            if (com)
                ::CoUninitialize();
        }

        // NV12 output, with the size and the colors of the stream. It runs
        // again when the stream changes its format.
        bool PickOutput()
        {
            for (DWORD i = 0;; i++)
            {
                ComPtr<IMFMediaType> type;
                if (FAILED(transform->GetOutputAvailableType(0, i, &type)))
                    return false;
                GUID subtype{};
                if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) || subtype != MFVideoFormat_NV12)
                    continue;
                if (FAILED(transform->SetOutputType(0, type.Get(), 0)))
                    return false;
                ReadFormat(type.Get());
                return SUCCEEDED(transform->GetOutputStreamInfo(0, &info));
            }
        }

        void ReadFormat(IMFMediaType *type)
        {
            UINT64 size = 0;
            type->GetUINT64(MF_MT_FRAME_SIZE, &size);
            coded_width = (UINT32)(size >> 32);
            coded_height = (UINT32)size;
            UINT32 row = 0;
            stride = SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &row)) ? (UINT32)std::abs((INT32)row) : coded_width;
            stride = std::max(stride, coded_width);
            left = top = 0;
            width = coded_width;
            height = coded_height;
            MFVideoArea area{};
            if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8 *>(&area), sizeof area, nullptr)) && area.Area.cx > 0 && area.Area.cy > 0)
            {
                left = (UINT32)std::max<int>(area.OffsetX.value, 0);
                top = (UINT32)std::max<int>(area.OffsetY.value, 0);
                width = std::min((UINT32)area.Area.cx, coded_width - std::min(left, coded_width));
                height = std::min((UINT32)area.Area.cy, coded_height - std::min(top, coded_height));
            }
            UINT32 matrix = MFVideoTransferMatrix_Unknown;
            type->GetUINT32(MF_MT_YUV_MATRIX, &matrix);
            // A stream that does not say: BT.709 for HD, as is usual.
            bt709 = matrix == MFVideoTransferMatrix_BT709 || (matrix != MFVideoTransferMatrix_BT601 && height >= 720);
            UINT32 range = MFNominalRange_Unknown;
            type->GetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, &range);
            full_range = range == MFNominalRange_0_255;
        }

        ComPtr<IMFSample> NewSample(DWORD size, DWORD alignment)
        {
            ComPtr<IMFSample> sample;
            ComPtr<IMFMediaBuffer> buffer;
            if (FAILED(make_sample(&sample)) || FAILED(make_buffer(size + alignment, &buffer)) || FAILED(sample->AddBuffer(buffer.Get())))
                return nullptr;
            return sample;
        }

        // BGRA of the part of the NV12 rows that shows. `step` 2 keeps each
        // second row and column.
        void Convert(BYTE const *rows, int step, std::string &out, int &w, int &h) const
        {
            w = (int)width / step;
            h = (int)height / step;
            out.resize((size_t)w * h * 4);
            int cr_r, cb_g, cr_g, cb_b, luma, zero;
            if (full_range)
            {
                luma = 256, zero = 0;
                cr_r = bt709 ? 403 : 359, cb_g = bt709 ? 48 : 88, cr_g = bt709 ? 120 : 183, cb_b = bt709 ? 475 : 454;
            }
            else
            {
                luma = 298, zero = 16;
                cr_r = bt709 ? 459 : 409, cb_g = bt709 ? 55 : 100, cr_g = bt709 ? 136 : 208, cb_b = bt709 ? 541 : 516;
            }
            BYTE const *chroma = rows + (size_t)stride * coded_height;
            auto *to = reinterpret_cast<uint8_t *>(out.data());
            for (int y = 0; y < h; y++)
            {
                size_t row = top + (size_t)y * step;
                BYTE const *line = rows + stride * row + left;
                BYTE const *pairs = chroma + stride * (row / 2);
                for (int x = 0; x < w; x++, to += 4)
                {
                    size_t column = (size_t)x * step;
                    size_t pair = ((left + column) / 2) * 2;
                    int c = luma * (line[column] - zero);
                    int d = pairs[pair] - 128;
                    int e = pairs[pair + 1] - 128;
                    to[0] = Clamp8((c + cb_b * d + 128) >> 8);
                    to[1] = Clamp8((c - cb_g * d - cr_g * e + 128) >> 8);
                    to[2] = Clamp8((c + cr_r * e + 128) >> 8);
                    to[3] = 255;
                }
            }
        }

        void Show(IMFSample *sample, bool tile, std::function<bool()> const &want, Picture const &picture)
        {
            if (width == 0 || height == 0 || !want())
                return;
            ComPtr<IMFMediaBuffer> buffer;
            if (FAILED(sample->ConvertToContiguousBuffer(&buffer)))
                return;
            BYTE *rows = nullptr;
            DWORD length = 0;
            if (FAILED(buffer->Lock(&rows, nullptr, &length)))
                return;
            std::string bgra;
            int w = 0, h = 0;
            size_t need = (size_t)stride * coded_height * 3 / 2;
            if (length >= need)
                Convert(rows, tile && (int)width >= tile_halves_at ? 2 : 1, bgra, w, h);
            buffer->Unlock();
            if (w > 0 && h > 0)
                picture(std::move(bgra), w, h);
        }

        // Takes each picture that the decoder has ready.
        void Drain(bool tile, std::function<bool()> const &want, Picture const &picture)
        {
            bool provides = (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
            for (;;)
            {
                ComPtr<IMFSample> own;
                if (!provides)
                {
                    own = NewSample(info.cbSize, info.cbAlignment);
                    if (own == nullptr)
                    {
                        errors++;
                        return;
                    }
                }
                MFT_OUTPUT_DATA_BUFFER out{};
                out.pSample = own.Get();
                DWORD status = 0;
                HRESULT hr = transform->ProcessOutput(0, 1, &out, &status);
                if (out.pEvents != nullptr)
                    out.pEvents->Release();
                ComPtr<IMFSample> result = own;
                if (provides && out.pSample != nullptr)
                    result.Attach(out.pSample);
                if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT)
                    return;
                if (hr == MF_E_TRANSFORM_STREAM_CHANGE)
                {
                    if (!PickOutput())
                    {
                        errors++;
                        return;
                    }
                    provides = (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
                    continue;
                }
                if (FAILED(hr) || result == nullptr)
                {
                    errors++;
                    return;
                }
                Show(result.Get(), tile, want, picture);
            }
        }
    };

    H264Decoder::H264Decoder() : impl_(std::make_unique<Impl>()) {}

    H264Decoder::~H264Decoder() = default;

    bool H264Decoder::Ready() const
    {
        return impl_->transform != nullptr;
    }

    int H264Decoder::Errors() const
    {
        return impl_->errors;
    }

    void H264Decoder::Decode(uint8_t const *au, size_t len, bool tile, std::function<bool()> const &want, Picture const &picture)
    {
        Impl &d = *impl_;
        if (d.transform == nullptr || au == nullptr || len == 0 || len > MAXDWORD / 2)
            return;
        ComPtr<IMFSample> sample = d.NewSample((DWORD)len, 0);
        ComPtr<IMFMediaBuffer> buffer;
        BYTE *bytes = nullptr;
        if (sample == nullptr || FAILED(sample->GetBufferByIndex(0, &buffer)) || FAILED(buffer->Lock(&bytes, nullptr, nullptr)))
        {
            d.errors++;
            return;
        }
        memcpy(bytes, au, len);
        buffer->Unlock();
        buffer->SetCurrentLength((DWORD)len);
        sample->SetSampleTime(d.time);
        sample->SetSampleDuration(frame_time);
        d.time += frame_time;
        HRESULT hr = d.transform->ProcessInput(0, sample.Get(), 0);
        if (hr == MF_E_NOTACCEPTING)
        {
            d.Drain(tile, want, picture);
            hr = d.transform->ProcessInput(0, sample.Get(), 0);
        }
        if (FAILED(hr))
            d.errors++;
        d.Drain(tile, want, picture);
    }
}
