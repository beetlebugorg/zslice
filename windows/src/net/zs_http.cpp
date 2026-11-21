// See zs_http.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "zs_http.h"

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <winhttp.h>

#include <algorithm>
#include <cstdio>

namespace zs::http
{
    namespace
    {
        std::wstring Wide(std::string const &text)
        {
            if (text.empty())
                return {};
            int n = ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0);
            std::wstring out(n, L'\0');
            ::MultiByteToWideChar(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), n);
            return out;
        }

        std::string Narrow(std::wstring const &text)
        {
            if (text.empty())
                return {};
            int n = ::WideCharToMultiByte(CP_UTF8, 0, text.data(), (int)text.size(), nullptr, 0, nullptr, nullptr);
            std::string out(n, '\0');
            ::WideCharToMultiByte(CP_UTF8, 0, text.data(), (int)text.size(), out.data(), n, nullptr, nullptr);
            return out;
        }

        // A header value on one line: a value with a line end could add
        // another header.
        bool CleanHeader(std::string const &value)
        {
            return value.find_first_of("\r\n") == std::string::npos;
        }

        std::string ErrorText(DWORD code)
        {
            switch (code)
            {
            case ERROR_WINHTTP_TIMEOUT:
                return "The printer did not answer in time.";
            case ERROR_WINHTTP_NAME_NOT_RESOLVED:
                return "The name of the printer does not resolve.";
            case ERROR_WINHTTP_CANNOT_CONNECT:
                return "The connection to the printer failed.";
            case ERROR_WINHTTP_CONNECTION_ERROR:
                return "The connection to the printer stopped.";
            case ERROR_WINHTTP_SECURE_FAILURE:
                return "The certificate of the printer is not valid.";
            case ERROR_WINHTTP_INVALID_URL:
            case ERROR_WINHTTP_UNRECOGNIZED_SCHEME:
                return "The address is not valid.";
            default: {
                char text[64];
                snprintf(text, sizeof text, "The connection failed (error %lu).", code);
                return text;
            }
            }
        }

        struct Handle
        {
            HINTERNET h = nullptr;
            ~Handle()
            {
                if (h != nullptr)
                    ::WinHttpCloseHandle(h);
            }
        };

        std::string Sha256Hex(BYTE const *data, DWORD len)
        {
            UCHAR hash[32];
            if (!BCRYPT_SUCCESS(::BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, const_cast<PUCHAR>(data), len, hash, sizeof hash)))
                return {};
            std::string hex;
            char two[3];
            for (UCHAR b : hash)
            {
                snprintf(two, sizeof two, "%02x", b);
                hex += two;
            }
            return hex;
        }

        void ReadCertificate(HINTERNET request, Response &out)
        {
            PCCERT_CONTEXT cert = nullptr;
            DWORD size = sizeof cert;
            if (!::WinHttpQueryOption(request, WINHTTP_OPTION_SERVER_CERT_CONTEXT, &cert, &size) || cert == nullptr)
                return;
            out.cert_sha256 = Sha256Hex(cert->pbCertEncoded, cert->cbCertEncoded);
            ULARGE_INTEGER t{};
            t.LowPart = cert->pCertInfo->NotBefore.dwLowDateTime;
            t.HighPart = cert->pCertInfo->NotBefore.dwHighDateTime;
            out.cert_since = (int64_t)(t.QuadPart / 10000000ULL) - 11644473600LL;
            ::CertFreeCertificateContext(cert);
        }

        std::string QueryHeader(HINTERNET request, DWORD what)
        {
            DWORD size = 0;
            ::WinHttpQueryHeaders(request, what, WINHTTP_HEADER_NAME_BY_INDEX, nullptr, &size, WINHTTP_NO_HEADER_INDEX);
            if (::GetLastError() != ERROR_INSUFFICIENT_BUFFER || size == 0)
                return {};
            std::wstring text(size / sizeof(wchar_t), L'\0');
            if (!::WinHttpQueryHeaders(request, what, WINHTTP_HEADER_NAME_BY_INDEX, text.data(), &size, WINHTTP_NO_HEADER_INDEX))
                return {};
            text.resize(size / sizeof(wchar_t));
            return Narrow(text);
        }
    }

    void Cancel::Stop()
    {
        stopped_.store(true);
        std::lock_guard guard(lock_);
        if (request_ != nullptr)
        {
            // A close ends the blocking call on the other thread.
            ::WinHttpCloseHandle(request_);
            request_ = nullptr;
        }
    }

    bool Cancel::Attach(void *request)
    {
        std::lock_guard guard(lock_);
        if (stopped_.load())
            return false;
        request_ = request;
        return true;
    }

    bool Cancel::Detach()
    {
        std::lock_guard guard(lock_);
        bool owned = request_ != nullptr;
        request_ = nullptr;
        return owned;
    }

    Response Send(Request const &req)
    {
        Response out;
        if (!CleanHeader(req.api_key) || !CleanHeader(req.content_type))
        {
            out.error = "The key has a line break.";
            return out;
        }
        std::wstring url = Wide(req.url);
        URL_COMPONENTS parts{};
        parts.dwStructSize = sizeof parts;
        parts.dwHostNameLength = (DWORD)-1;
        parts.dwUrlPathLength = (DWORD)-1;
        parts.dwExtraInfoLength = (DWORD)-1;
        parts.dwSchemeLength = (DWORD)-1;
        if (!::WinHttpCrackUrl(url.c_str(), (DWORD)url.size(), 0, &parts) ||
            (parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS))
        {
            out.error = "The address is not valid.";
            return out;
        }
        std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
        std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
        if (parts.dwExtraInfoLength > 0)
            path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
        if (path.empty())
            path = L"/";

        Handle session, connection;
        // Handle of the request: closed here, or by Cancel::Stop.
        HINTERNET request = nullptr;
        session.h = ::WinHttpOpen(L"zslice", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (session.h == nullptr)
        {
            out.error = ErrorText(::GetLastError());
            return out;
        }
        ::WinHttpSetTimeouts(session.h, req.timeout_ms, req.timeout_ms, req.timeout_ms, req.timeout_ms);
        DWORD no_redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        ::WinHttpSetOption(session.h, WINHTTP_OPTION_REDIRECT_POLICY, &no_redirect, sizeof no_redirect);
        connection.h = ::WinHttpConnect(session.h, host.c_str(), parts.nPort, 0);
        if (connection.h != nullptr)
            request = ::WinHttpOpenRequest(connection.h, Wide(req.method).c_str(), path.c_str(), nullptr, WINHTTP_NO_REFERER,
                                           WINHTTP_DEFAULT_ACCEPT_TYPES,
                                           parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0);
        if (request == nullptr)
        {
            out.error = ErrorText(::GetLastError());
            return out;
        }

        bool attached = false;
        auto close_request = [&] {
            // Stop may have closed the handle already.
            bool owned = !attached || req.cancel->Detach();
            attached = false;
            if (owned && request != nullptr)
                ::WinHttpCloseHandle(request);
            request = nullptr;
        };
        auto stopped = [&] { return req.cancel != nullptr && req.cancel->Stopped(); };
        auto fail = [&](DWORD code) {
            if (stopped())
            {
                out.cancelled = true;
                out.error = "Canceled.";
            }
            else
                out.error = ErrorText(code);
            close_request();
            out.status = 0;
            return out;
        };

        if (req.cancel != nullptr)
        {
            if (!req.cancel->Attach(request))
            {
                out.cancelled = true;
                out.error = "Canceled.";
                close_request();
                return out;
            }
            attached = true;
        }

        std::wstring headers;
        if (!req.api_key.empty())
            headers += L"X-Api-Key: " + Wide(req.api_key) + L"\r\n";
        if (!req.content_type.empty())
            headers += L"Content-Type: " + Wide(req.content_type) + L"\r\n";
        if (!req.content_encoding.empty())
            headers += L"Content-Encoding: " + Wide(req.content_encoding) + L"\r\n";

        DWORD total = (DWORD)req.body.size();
        if (!::WinHttpSendRequest(request, headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(),
                                  headers.empty() ? 0 : (DWORD)-1L, WINHTTP_NO_REQUEST_DATA, 0, total, 0))
            return fail(::GetLastError());

        // The body in pieces: the progress, and a cancel between them.
        size_t sent = 0;
        while (sent < req.body.size())
        {
            if (stopped())
                return fail(ERROR_OPERATION_ABORTED);
            DWORD piece = (DWORD)std::min<size_t>(req.body.size() - sent, 64 * 1024);
            DWORD wrote = 0;
            if (!::WinHttpWriteData(request, req.body.data() + sent, piece, &wrote))
                return fail(::GetLastError());
            sent += wrote;
            if (req.sent)
                req.sent((double)sent / (double)req.body.size());
        }

        if (!::WinHttpReceiveResponse(request, nullptr))
            return fail(::GetLastError());

        DWORD status = 0, size = sizeof status;
        if (!::WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                   &status, &size, WINHTTP_NO_HEADER_INDEX))
            return fail(::GetLastError());
        out.status = (int)status;
        out.reason = QueryHeader(request, WINHTTP_QUERY_STATUS_TEXT);
        out.content_type = QueryHeader(request, WINHTTP_QUERY_CONTENT_TYPE);
        if (parts.nScheme == INTERNET_SCHEME_HTTPS)
            ReadCertificate(request, out);

        std::string buffer(64 * 1024, '\0');
        for (;;)
        {
            if (stopped())
                return fail(ERROR_OPERATION_ABORTED);
            DWORD got = 0;
            if (!::WinHttpReadData(request, buffer.data(), (DWORD)buffer.size(), &got))
                return fail(::GetLastError());
            if (got == 0)
                break;
            if (req.sink)
            {
                if (!req.sink(buffer.data(), got))
                    break;
            }
            else
            {
                // A reply of a printer is small. 64 MiB is a broken one.
                if (out.body.size() + got > (64u << 20))
                {
                    out.error = "The answer of the printer is too large.";
                    out.status = 0;
                    close_request();
                    return out;
                }
                out.body.append(buffer.data(), got);
            }
        }
        close_request();
        return out;
    }

    Form NewForm()
    {
        Form form;
        UCHAR random[12]{};
        ::BCryptGenRandom(nullptr, random, sizeof random, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
        form.boundary = "----zslice";
        char two[3];
        for (UCHAR b : random)
        {
            snprintf(two, sizeof two, "%02x", b);
            form.boundary += two;
        }
        return form;
    }

    void Form::Field(std::string const &name, std::string const &value)
    {
        body += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name + "\"\r\n\r\n" + value + "\r\n";
    }

    void Form::File(std::string const &name, std::string const &filename, std::string const &bytes)
    {
        // A quote or a line end would break out of the header.
        std::string safe;
        for (char c : filename)
            safe += c == '"' || c == '\r' || c == '\n' || c == '\\' ? '_' : c;
        body += "--" + boundary + "\r\nContent-Disposition: form-data; name=\"" + name + "\"; filename=\"" + safe +
                "\"\r\nContent-Type: application/octet-stream\r\n\r\n";
        body += bytes;
        body += "\r\n";
    }

    std::string Form::Finish()
    {
        body += "--" + boundary + "--\r\n";
        return "multipart/form-data; boundary=" + boundary;
    }

    std::string Escape(std::string const &text)
    {
        std::string out;
        char hex[4];
        for (unsigned char c : text)
        {
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
                out += (char)c;
            else
            {
                snprintf(hex, sizeof hex, "%%%02X", c);
                out += hex;
            }
        }
        return out;
    }
}
