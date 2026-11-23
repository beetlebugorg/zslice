#pragma once
// Decodes the H.264 frames of a printer camera with the decoder of Windows
// (Media Foundation, the H.264 Video Decoder MFT), for the RTSP camera of a
// Bambu Lab printer (src/rtsp.zig).
//
// A frame comes as an access unit in Annex B. The decoder runs in software
// and in low latency mode, so a picture comes out for each frame. Each frame
// is decoded, because the next frames need it. A picture becomes BGRA only
// when `want` says yes, so a small card does not pay for each frame.
//
// The app loads mfplat.dll when a camera starts. A Windows N edition has no
// Media Foundation until the user adds the Media Feature Pack. The app still
// starts there, and Ready() is false.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace zs
{
    class H264Decoder
    {
    public:
        // BGRA rows, top first, with alpha 255.
        using Picture = std::function<void(std::string &&bgra, int width, int height)>;

        // On the thread that decodes. It joins the COM apartment of the
        // thread for its life.
        H264Decoder();
        ~H264Decoder();
        H264Decoder(H264Decoder const &) = delete;
        H264Decoder &operator=(H264Decoder const &) = delete;

        // False when this Windows has no H.264 decoder.
        bool Ready() const;
        // One access unit. `tile` halves a picture of 1280 pixels or wider.
        void Decode(uint8_t const *au, size_t len, bool tile, std::function<bool()> const &want, Picture const &picture);
        // The frames that did not decode, for a test.
        int Errors() const;

    private:
        struct Impl;
        std::unique_ptr<Impl> impl_;
    };
}
