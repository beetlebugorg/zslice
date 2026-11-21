#pragma once
// HTTP for the printer connections, with WinHTTP. A call blocks, so it runs
// on a worker thread.
//
// Three rules protect the API key:
// - A request follows no redirect. A redirect could carry the key to another
//   host. The 3xx status comes back as the answer.
// - A request uses no proxy: a printer is on the local network.
// - An error text has the Windows error only, never a header or an address.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace zs::http
{
    // Stops the requests that share it. Any thread can call Cancel.
    class Cancel
    {
    public:
        void Stop();
        bool Stopped() const { return stopped_.load(); }

        // For zs_http.cpp: the open request, so Stop can close it.
        bool Attach(void *request);
        // True if the caller still owns the handle: Stop did not close it.
        bool Detach();

    private:
        std::atomic<bool> stopped_{ false };
        std::mutex lock_;
        void *request_ = nullptr;
    };
    using CancelPtr = std::shared_ptr<Cancel>;

    struct Request
    {
        std::string method = "GET";
        std::string url;
        // Sent as the header X-Api-Key, when not empty.
        std::string api_key;
        std::string content_type;
        std::string content_encoding;
        std::string body;
        int timeout_ms = 15000;
        CancelPtr cancel;
        // The fraction of the body that went out.
        std::function<void(double)> sent;
        // Takes the reply as it comes, in place of Response::body. It
        // returns false to stop.
        std::function<bool(char const *, size_t)> sink;
    };

    struct Response
    {
        // 0: no answer. Then `error` says why.
        int status = 0;
        std::string reason;
        std::string body;
        std::string error;
        std::string content_type;
        bool cancelled = false;
        // An https reply: the SHA-256 of the certificate (hex), and the
        // start of its validity in Unix seconds.
        std::string cert_sha256;
        int64_t cert_since = 0;

        bool Ok() const { return status >= 200 && status < 300; }
    };

    Response Send(Request const &request);

    // A multipart form with one file and text fields (RFC 7578).
    struct Form
    {
        std::string boundary;
        std::string body;
        void Field(std::string const &name, std::string const &value);
        void File(std::string const &name, std::string const &filename, std::string const &bytes);
        // Ends the form, and returns its content type.
        std::string Finish();
    };
    Form NewForm();

    // The percent escape of a URL path segment.
    std::string Escape(std::string const &text);
}
