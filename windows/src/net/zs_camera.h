#pragma once
// The live picture of a printer camera, on a thread of its own.
//
// Three sources give JPEG frames:
// - An MJPEG stream (multipart/x-mixed-replace, RFC 2046).
// - A snapshot address, read again every few seconds.
// - The port 6000 of a Bambu Lab P1 or A1: the frames of the core
//   (zs_bambu_jpeg_reader), over TLS with the pinned certificate.
//
// The X1, H2, P2S, and X2D send H.264 over RTSP on port 322. The core runs
// the session (zs_rtsp_*), this file moves its bytes over TLS with the same
// pin, and H264Decoder gives BGRA pictures. A model that is not known tries
// RTSP, then port 6000.
//
// A Bambu Lab printer gets one camera stream: a second feed of the same
// address waits until the first one ends.
//
// It follows linux/src/ui/camera-view.c. The API key goes only to the origin
// of the printer.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>

#include "zs_http.h"
#include "zs_printer_link.h"

namespace zs
{
    // Reads the parts of a multipart/x-mixed-replace stream.
    class MjpegParser
    {
    public:
        // `content_type` of the reply has the boundary. With none, the
        // first line that starts with "--" names it.
        explicit MjpegParser(std::string const &content_type);
        void Feed(char const *data, size_t len);
        // True and a whole JPEG, or false when more bytes must come.
        bool Next(std::string &jpeg);
        // True for a stream that cannot be frames.
        bool Broken() const { return broken_; }

    private:
        std::string boundary_;
        std::string buffer_;
        bool broken_ = false;
    };

    struct CameraSource
    {
        // HTTP.
        std::string stream, snapshot, api_key, printer_url;
        bool printdeck = false;
        bool large = false;
        // Bambu Lab, when `bambu_host` is not empty.
        std::string bambu_host, bambu_code, bambu_pin;
        int bambu_kind = 0; // zs_bambu_camera_kind
    };

    // A picture of a feed: a JPEG, or BGRA rows when `width` is not 0.
    struct CameraPicture
    {
        std::string bytes;
        int width = 0, height = 0;
    };

    class H264Decoder;

    class CameraFeed
    {
    public:
        using Frame = std::function<void(std::shared_ptr<CameraPicture const> const &)>;
        using Note = std::function<void(std::string const &)>;

        // `frame` and `note` run on the thread of the feed.
        CameraFeed(CameraSource source, Frame frame, Note note);
        ~CameraFeed();
        CameraFeed(CameraFeed const &) = delete;
        CameraFeed &operator=(CameraFeed const &) = delete;

    private:
        void Run();
        bool RunStream();
        bool RunSnapshots();
        bool RunBambu();
        bool RunBambuJpeg();
        void RunRtsp(H264Decoder &decoder, bool &any, std::string &why);
        void SendJpeg(std::string jpeg);
        void Rest(int seconds);

        CameraSource source_;
        Frame frame_;
        Note note_;
        std::atomic<bool> stop_{ false };
        http::CancelPtr cancel_;
        std::thread thread_;
    };
}
