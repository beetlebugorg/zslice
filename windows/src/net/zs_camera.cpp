// See zs_camera.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_camera.h"

#include "zs_bambu.h"
#include "zs_h264.h"
#include "zs_tls.h"
#include "zslice-app.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <chrono>
#include <mutex>
#include <set>

namespace zs
{
    namespace
    {
        // The largest picture of a stream.
        constexpr size_t max_frame = 16u << 20;
        constexpr int snap_tile_s = 5;
        constexpr int snap_large_s = 1;
        constexpr int retry_s = 20;
        // With no frame for this long, the camera has stopped.
        constexpr int rtsp_quiet_s = 12;
        constexpr int rtsp_keepalive_s = 30;
        // A card shows at most 4 pictures a second.
        constexpr int tile_picture_ms = 250;
        // A wait this long for another view gets a note.
        constexpr int lease_note_ms = 2000;

        // One stream to each Bambu Lab printer. A feed that ends frees its
        // address for the next one.
        class StreamLease
        {
        public:
            StreamLease(std::string host, std::atomic<bool> const &stop, std::function<void()> const &waiting) : host_(std::move(host))
            {
                auto started = std::chrono::steady_clock::now();
                bool told = false;
                while (!stop.load())
                {
                    {
                        std::lock_guard guard(Lock());
                        if (Busy().insert(host_).second)
                        {
                            held_ = true;
                            return;
                        }
                    }
                    if (!told && std::chrono::steady_clock::now() - started >= std::chrono::milliseconds(lease_note_ms))
                    {
                        told = true;
                        waiting();
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                }
            }

            ~StreamLease()
            {
                if (!held_)
                    return;
                std::lock_guard guard(Lock());
                Busy().erase(host_);
            }

            StreamLease(StreamLease const &) = delete;
            StreamLease &operator=(StreamLease const &) = delete;
            bool Held() const { return held_; }

        private:
            static std::mutex &Lock()
            {
                static std::mutex lock;
                return lock;
            }

            static std::set<std::string> &Busy()
            {
                static std::set<std::string> busy;
                return busy;
            }

            std::string host_;
            bool held_ = false;
        };

        std::string KeyFor(CameraSource const &s, std::string const &url)
        {
            // The key goes only to the printer: a camera at another address
            // gets no key.
            return link::SameOrigin(url, link::BaseUrl(s.printer_url)) ? s.api_key : std::string{};
        }
    }

    MjpegParser::MjpegParser(std::string const &content_type)
    {
        size_t at = content_type.find("boundary=");
        if (at == std::string::npos)
            return;
        std::string b = content_type.substr(at + 9);
        size_t end = b.find(';');
        if (end != std::string::npos)
            b.resize(end);
        while (!b.empty() && (b.back() == ' ' || b.back() == '"'))
            b.pop_back();
        while (!b.empty() && (b.front() == ' ' || b.front() == '"'))
            b.erase(b.begin());
        if (b.rfind("--", 0) != 0)
            b = "--" + b;
        boundary_ = b;
    }

    void MjpegParser::Feed(char const *data, size_t len)
    {
        buffer_.append(data, len);
        // Two whole frames at most wait here.
        if (buffer_.size() > 2 * max_frame)
            broken_ = true;
    }

    bool MjpegParser::Next(std::string &jpeg)
    {
        if (broken_)
            return false;
        if (boundary_.empty())
        {
            size_t at = buffer_.rfind("--", 0) == 0 ? 0 : buffer_.find("\n--");
            if (at == std::string::npos)
                return false;
            size_t start = at == 0 ? 0 : at + 1;
            size_t end = buffer_.find_first_of("\r\n", start);
            if (end == std::string::npos)
                return false;
            boundary_ = buffer_.substr(start, end - start);
        }
        for (;;)
        {
            size_t first = buffer_.find(boundary_);
            if (first == std::string::npos)
                return false;
            size_t headers = first + boundary_.size();
            size_t blank = buffer_.find("\r\n\r\n", headers);
            if (blank == std::string::npos)
                return false;
            size_t body = blank + 4;
            size_t next = buffer_.find(boundary_, body);
            if (next == std::string::npos)
                return false;
            size_t end = next;
            // The line end before the boundary is not part of the picture.
            if (end > body && buffer_[end - 1] == '\n')
                end--;
            if (end > body && buffer_[end - 1] == '\r')
                end--;
            bool is_jpeg = end - body >= 2 && (unsigned char)buffer_[body] == 0xFF && (unsigned char)buffer_[body + 1] == 0xD8;
            if (is_jpeg && end - body <= max_frame)
                jpeg.assign(buffer_, body, end - body);
            buffer_.erase(0, next);
            if (is_jpeg && end - body <= max_frame)
                return true;
        }
    }

    CameraFeed::CameraFeed(CameraSource source, Frame frame, Note note)
        : source_(std::move(source)), frame_(std::move(frame)), note_(std::move(note))
    {
        cancel_ = std::make_shared<http::Cancel>();
        thread_ = std::thread([this] { Run(); });
    }

    CameraFeed::~CameraFeed()
    {
        stop_.store(true);
        cancel_->Stop();
        if (thread_.joinable())
            thread_.join();
        ::SecureZeroMemory(source_.bambu_code.data(), source_.bambu_code.size());
    }

    void CameraFeed::Rest(int seconds)
    {
        for (int i = 0; i < seconds * 10 && !stop_.load(); i++)
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    void CameraFeed::Run()
    {
        while (!stop_.load())
        {
            bool again = true;
            if (!source_.bambu_host.empty())
                again = RunBambu();
            else if (!source_.stream.empty())
                again = RunStream();
            else if (!source_.snapshot.empty())
                again = RunSnapshots();
            else
                again = false;
            if (!again || stop_.load())
                return;
            Rest(retry_s);
        }
    }

    bool CameraFeed::RunStream()
    {
        std::string url = source_.stream;
        if (source_.printdeck)
        {
            // printdeck: a small picture at a low rate for a tile, the whole
            // picture at 10 frames a second for the large view.
            url += url.find('?') == std::string::npos ? '?' : '&';
            url += source_.large ? "fps=10" : "w=480&fps=4";
        }
        http::Request head;
        head.url = url;
        head.api_key = KeyFor(source_, url);
        head.cancel = cancel_;
        head.timeout_ms = 20000;
        std::unique_ptr<MjpegParser> parser;
        bool any = false;
        head.sink = [&](char const *data, size_t len) {
            if (parser == nullptr)
                parser = std::make_unique<MjpegParser>("");
            parser->Feed(data, len);
            std::string jpeg;
            while (parser->Next(jpeg))
            {
                any = true;
                SendJpeg(std::move(jpeg));
                jpeg.clear();
            }
            return !parser->Broken() && !stop_.load();
        };
        http::Response r = http::Send(head);
        if (stop_.load())
            return false;
        if (!any)
            note_(r.status == 0 ? "The camera did not answer." : "The camera gave no picture.");
        return true;
    }

    bool CameraFeed::RunSnapshots()
    {
        int every = source_.large ? snap_large_s : snap_tile_s;
        while (!stop_.load())
        {
            http::Request req;
            req.url = source_.snapshot;
            req.api_key = KeyFor(source_, source_.snapshot);
            req.cancel = cancel_;
            http::Response r = http::Send(req);
            if (stop_.load())
                return false;
            if (!r.Ok() || r.body.size() < 2 || (unsigned char)r.body[0] != 0xFF || (unsigned char)r.body[1] != 0xD8)
            {
                note_("The camera gave no picture.");
                return true;
            }
            SendJpeg(std::move(r.body));
            Rest(every);
        }
        return false;
    }

    void CameraFeed::SendJpeg(std::string jpeg)
    {
        auto picture = std::make_shared<CameraPicture>();
        picture->bytes = std::move(jpeg);
        frame_(picture);
    }

    bool CameraFeed::RunBambu()
    {
        StreamLease lease(source_.bambu_host, stop_, [this] { note_("This camera plays in another view."); });
        if (!lease.Held())
            return false;
        if (source_.bambu_kind == 2)
            return RunBambuJpeg();
        H264Decoder decoder;
        if (!decoder.Ready())
        {
            if (source_.bambu_kind == 0)
                return RunBambuJpeg();
            note_("This Windows has no H.264 decoder. Add the Media Feature Pack in Settings, under Optional features.");
            return false;
        }
        bool any = false;
        std::string why;
        RunRtsp(decoder, any, why);
        if (stop_.load())
            return false;
        // A model that is not known: RTSP first, then the JPEG frames.
        if (source_.bambu_kind == 0 && !any)
            return RunBambuJpeg();
        if (!why.empty())
            note_(why);
        return true;
    }

    // The loop of zslice-app.h: write the output, read, feed, write again,
    // and take each frame. The access code goes only to the session.
    void CameraFeed::RunRtsp(H264Decoder &decoder, bool &any, std::string &why)
    {
        using Clock = std::chrono::steady_clock;
        TlsClient tls;
        std::string seen, common_name, error;
        int port = BambuPort("RTSPS", 322);
        if (!tls.Connect(source_.bambu_host, port, source_.bambu_pin, seen, common_name, &stop_, error))
        {
            why = "The camera did not answer.";
            return;
        }
        std::string url = "rtsps://" + source_.bambu_host + ":" + std::to_string(port) + "/streaming/live/1";
        std::unique_ptr<zs_rtsp, decltype(&zs_rtsp_free)> session(zs_rtsp_new(url.c_str(), "bblp", source_.bambu_code.c_str()), zs_rtsp_free);
        if (session == nullptr)
        {
            why = "The camera could not start.";
            return;
        }
        auto flush = [&] {
            uint8_t const *bytes = nullptr;
            size_t len = 0;
            zs_rtsp_output(session.get(), &bytes, &len);
            return len == 0 || tls.Write(bytes, len);
        };
        if (!flush())
        {
            why = "The camera closed the connection.";
            return;
        }
        Clock::time_point next_picture{};
        auto want = [&] {
            if (source_.large)
                return true;
            auto now = Clock::now();
            if (now < next_picture)
                return false;
            next_picture = now + std::chrono::milliseconds(tile_picture_ms);
            return true;
        };
        auto picture = [&](std::string &&bgra, int width, int height) {
            any = true;
            auto shown = std::make_shared<CameraPicture>();
            shown->bytes = std::move(bgra);
            shown->width = width;
            shown->height = height;
            frame_(shown);
        };
        std::string buffer(64 * 1024, '\0');
        auto heard = Clock::now(), alive = Clock::now();
        while (!stop_.load())
        {
            int n = tls.Read(buffer.data(), buffer.size(), 500);
            if (n < 0)
            {
                why = "The camera closed the connection.";
                return;
            }
            if (n > 0)
                zs_rtsp_feed(session.get(), reinterpret_cast<uint8_t const *>(buffer.data()), (size_t)n);
            int state = zs_rtsp_state(session.get());
            if (state < 0)
            {
                why = zs_rtsp_message(session.get());
                return;
            }
            auto now = Clock::now();
            if (state == 1 && now - alive >= std::chrono::seconds(rtsp_keepalive_s))
            {
                zs_rtsp_keepalive(session.get());
                alive = now;
            }
            if (!flush())
            {
                why = "The camera closed the connection.";
                return;
            }
            uint8_t const *frame = nullptr;
            size_t len = 0;
            int key = 0;
            while (zs_rtsp_next_frame(session.get(), &frame, &len, &key) == 1)
            {
                heard = Clock::now();
                decoder.Decode(frame, len, !source_.large, want, picture);
            }
            if (Clock::now() - heard >= std::chrono::seconds(rtsp_quiet_s))
            {
                why = "No picture came from the camera. The camera can be off, or out of reach.";
                return;
            }
        }
        zs_rtsp_teardown(session.get());
        flush();
    }

    bool CameraFeed::RunBambuJpeg()
    {
        TlsClient tls;
        std::string seen, common_name, why;
        if (!tls.Connect(source_.bambu_host, BambuPort("JPEG", 6000), source_.bambu_pin, seen, common_name, &stop_, why))
        {
            if (!stop_.load())
                note_("The camera did not answer.");
            return true;
        }
        uint8_t auth[80];
        int rc = zs_bambu_camera_auth(source_.bambu_code.c_str(), auth);
        bool sent = rc == ZS_OK && tls.Write(auth, sizeof auth);
        ::SecureZeroMemory(auth, sizeof auth);
        if (!sent)
        {
            note_("The camera did not take the access code.");
            return true;
        }
        std::unique_ptr<zs_bambu_jpeg_reader, decltype(&zs_bambu_jpeg_reader_free)> reader(zs_bambu_jpeg_reader_new(), zs_bambu_jpeg_reader_free);
        std::string buffer(64 * 1024, '\0');
        while (!stop_.load())
        {
            int n = tls.Read(buffer.data(), buffer.size(), 500);
            if (n < 0)
            {
                if (!stop_.load())
                    note_("The camera closed the connection.");
                return true;
            }
            if (n == 0)
                continue;
            if (zs_bambu_jpeg_reader_feed(reader.get(), reinterpret_cast<uint8_t const *>(buffer.data()), (size_t)n) != ZS_OK)
            {
                note_("The camera did not send frames.");
                return true;
            }
            uint8_t const *jpeg = nullptr;
            size_t len = 0;
            int got;
            while ((got = zs_bambu_jpeg_reader_next(reader.get(), &jpeg, &len)) == 1)
                SendJpeg(std::string(reinterpret_cast<char const *>(jpeg), len));
            if (got < 0)
            {
                note_("The camera did not send frames.");
                return true;
            }
        }
        return false;
    }
}
