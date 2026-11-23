// See zs_open_link.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>

#include "zs_open_link.h"

#include "zslice.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>

namespace zs::openlink
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

        void CopyField(char *field, size_t cap, std::string const &text)
        {
            size_t n = std::min(text.size(), cap - 1);
            memcpy(field, text.data(), n);
            field[n] = 0;
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

        // True if a header is there. It can be empty.
        bool QueryHeader(HINTERNET request, DWORD what, std::string &out)
        {
            out.clear();
            DWORD size = 0;
            ::WinHttpQueryHeaders(request, what, WINHTTP_HEADER_NAME_BY_INDEX, nullptr, &size, WINHTTP_NO_HEADER_INDEX);
            if (::GetLastError() != ERROR_INSUFFICIENT_BUFFER || size == 0)
                return false;
            std::wstring text(size / sizeof(wchar_t), L'\0');
            if (!::WinHttpQueryHeaders(request, what, WINHTTP_HEADER_NAME_BY_INDEX, text.data(), &size, WINHTTP_NO_HEADER_INDEX))
                return false;
            text.resize(size / sizeof(wchar_t));
            out = Narrow(text);
            return true;
        }

        std::string ErrorText(DWORD code)
        {
            switch (code)
            {
            case ERROR_WINHTTP_TIMEOUT:
                return "The site did not answer in time.";
            case ERROR_WINHTTP_NAME_NOT_RESOLVED:
                return "The name of the site does not resolve.";
            case ERROR_WINHTTP_CANNOT_CONNECT:
            case ERROR_WINHTTP_CONNECTION_ERROR:
                return "The connection to the site failed.";
            case ERROR_WINHTTP_SECURE_FAILURE:
                return "The certificate of the site is not valid.";
            default: {
                char text[64];
                snprintf(text, sizeof text, "The download failed (error %lu).", code);
                return text;
            }
            }
        }

        // The address that WinHTTP gives to its callback, as text.
        bool PublicAddressText(wchar_t const *text)
        {
            if (text == nullptr)
                return false;
            std::wstring address = text;
            address.erase(std::remove_if(address.begin(), address.end(), [](wchar_t c) { return c == L'[' || c == L']'; }), address.end());
            size_t zone = address.find(L'%');
            if (zone != std::wstring::npos)
                address.resize(zone);
            uint8_t bytes[16];
            if (::InetPtonW(AF_INET, address.c_str(), bytes) == 1)
                return zs_link_address_public(bytes, 4) == 1;
            if (::InetPtonW(AF_INET6, address.c_str(), bytes) == 1)
                return zs_link_address_public(bytes, 16) == 1;
            return false;
        }

        // The request of one hop, with what the callback needs to stop it.
        struct Hop
        {
            HINTERNET request = nullptr;
            http::Cancel *cancel = nullptr;
            bool attached = false;
            bool blocked = false;

            void Close()
            {
                bool owned = !attached || cancel->Detach();
                attached = false;
                if (owned && request != nullptr)
                    ::WinHttpCloseHandle(request);
                request = nullptr;
            }
        };

        // WinHTTP names the address as it connects. A name that changes to
        // a local address gets no TLS handshake and no request.
        void CALLBACK OnStatus(HINTERNET, DWORD_PTR context, DWORD status, LPVOID info, DWORD)
        {
            if (status != WINHTTP_CALLBACK_STATUS_CONNECTING_TO_SERVER && status != WINHTTP_CALLBACK_STATUS_CONNECTED_TO_SERVER)
                return;
            auto *hop = reinterpret_cast<Hop *>(context);
            if (hop == nullptr || hop->blocked || PublicAddressText(static_cast<wchar_t const *>(info)))
                return;
            hop->blocked = true;
            hop->Close();
        }

        // ZS_LINK_OK, ZS_LINK_LOCAL_ADDRESS, or -1 if the name has no address.
        int ResolvePublic(char const *host)
        {
            addrinfo hints{};
            hints.ai_family = AF_UNSPEC;
            hints.ai_socktype = SOCK_STREAM;
            addrinfo *found = nullptr;
            if (::getaddrinfo(host, "443", &hints, &found) != 0 || found == nullptr)
                return -1;
            int result = ZS_LINK_OK;
            for (addrinfo *at = found; at != nullptr; at = at->ai_next)
                if (!IsPublicAddress(at->ai_addr))
                    result = ZS_LINK_LOCAL_ADDRESS;
            ::freeaddrinfo(found);
            return result;
        }

        // One request. `redirected` is true if `link` has a new URL.
        void FetchOnce(zs_link &link, http::CancelPtr const &cancel, std::function<void(double)> const &progress, FetchSeam const &seam,
                       Download &out, bool &redirected)
        {
            if (!seam.skip_resolve)
            {
                int resolved = ResolvePublic(link.host);
                if (resolved != ZS_LINK_OK)
                {
                    out.error = resolved < 0 ? ErrorText(ERROR_WINHTTP_NAME_NOT_RESOLVED) : zs_link_message(resolved);
                    return;
                }
            }
            std::wstring wide = Wide(link.url);
            URL_COMPONENTS parts{};
            parts.dwStructSize = sizeof parts;
            parts.dwHostNameLength = (DWORD)-1;
            parts.dwUrlPathLength = (DWORD)-1;
            parts.dwExtraInfoLength = (DWORD)-1;
            parts.dwSchemeLength = (DWORD)-1;
            if (!::WinHttpCrackUrl(wide.c_str(), (DWORD)wide.size(), 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS)
            {
                out.error = zs_link_message(ZS_LINK_NOT_PUBLIC);
                return;
            }
            std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
            if (parts.dwExtraInfoLength > 0)
                path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);

            // No proxy: the check of the address needs the real peer.
            Handle session, connection;
            session.h = ::WinHttpOpen(Wide(zs_import_user_agent()).c_str(), WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
            if (session.h == nullptr)
            {
                out.error = ErrorText(::GetLastError());
                return;
            }
            ::WinHttpSetTimeouts(session.h, 15000, 15000, 30000, 30000);
            DWORD no_redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
            ::WinHttpSetOption(session.h, WINHTTP_OPTION_REDIRECT_POLICY, &no_redirect, sizeof no_redirect);
            connection.h = ::WinHttpConnect(session.h, Wide(link.host).c_str(), seam.port != 0 ? seam.port : INTERNET_DEFAULT_HTTPS_PORT, 0);
            Hop hop;
            hop.cancel = cancel.get();
            if (connection.h != nullptr)
                hop.request = ::WinHttpOpenRequest(connection.h, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER,
                                                   WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
            if (hop.request == nullptr)
            {
                out.error = ErrorText(::GetLastError());
                return;
            }
            DWORD no_cookies = WINHTTP_DISABLE_COOKIES;
            ::WinHttpSetOption(hop.request, WINHTTP_OPTION_DISABLE_FEATURE, &no_cookies, sizeof no_cookies);
            DWORD no_logon = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
            ::WinHttpSetOption(hop.request, WINHTTP_OPTION_AUTOLOGON_POLICY, &no_logon, sizeof no_logon);
            DWORD_PTR context = reinterpret_cast<DWORD_PTR>(&hop);
            ::WinHttpSetOption(hop.request, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof context);
            if (::WinHttpSetStatusCallback(hop.request, OnStatus, WINHTTP_CALLBACK_FLAG_CONNECT_TO_SERVER, 0) == WINHTTP_INVALID_STATUS_CALLBACK)
            {
                out.error = ErrorText(::GetLastError());
                hop.Close();
                return;
            }

            auto stopped = [&] { return cancel != nullptr && cancel->Stopped(); };
            auto fail = [&](std::string const &text) {
                if (hop.blocked)
                    out.error = zs_link_message(ZS_LINK_LOCAL_ADDRESS);
                else if (stopped())
                    out.cancelled = true;
                else
                    out.error = text;
                out.bytes.clear();
                hop.Close();
            };
            if (cancel != nullptr)
            {
                if (!cancel->Attach(hop.request))
                {
                    out.cancelled = true;
                    hop.Close();
                    return;
                }
                hop.attached = true;
            }
            if (!::WinHttpSendRequest(hop.request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, context) || hop.blocked ||
                !::WinHttpReceiveResponse(hop.request, nullptr))
            {
                fail(ErrorText(::GetLastError()));
                return;
            }
            // The address of the connection that answered.
            WINHTTP_CONNECTION_INFO info{};
            info.cbSize = sizeof info;
            DWORD info_size = sizeof info;
            if (!::WinHttpQueryOption(hop.request, WINHTTP_OPTION_CONNECTION_INFO, &info, &info_size) ||
                !IsPublicAddress(reinterpret_cast<sockaddr const *>(&info.RemoteAddress)))
            {
                fail(zs_link_message(ZS_LINK_LOCAL_ADDRESS));
                return;
            }
            DWORD status = 0, size = sizeof status;
            if (!::WinHttpQueryHeaders(hop.request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                       &status, &size, WINHTTP_NO_HEADER_INDEX))
            {
                fail(ErrorText(::GetLastError()));
                return;
            }
            std::string header;
            if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308)
            {
                QueryHeader(hop.request, WINHTTP_QUERY_LOCATION, header);
                int rc = header.empty() ? (int)ZS_LINK_BAD_REDIRECT : zs_link_redirect(header.c_str(), &link);
                if (rc != ZS_LINK_OK)
                {
                    fail(zs_link_message(rc));
                    return;
                }
                redirected = true;
                hop.Close();
                return;
            }
            if (status < 200 || status >= 300)
            {
                fail("The site answered with error " + std::to_string(status) + ".");
                return;
            }
            std::string type, length_text;
            QueryHeader(hop.request, WINHTTP_QUERY_CONTENT_TYPE, type);
            int64_t length = QueryHeader(hop.request, WINHTTP_QUERY_CONTENT_LENGTH, length_text) ? _strtoi64(length_text.c_str(), nullptr, 10) : -1;
            int rc = zs_link_check_reply(type.c_str(), length);
            if (rc != ZS_LINK_OK)
            {
                fail(zs_link_message(rc));
                return;
            }
            bool has_name = QueryHeader(hop.request, WINHTTP_QUERY_CONTENT_DISPOSITION, header);
            rc = zs_link_file_name(has_name ? header.c_str() : nullptr, &link);
            if (rc != ZS_LINK_OK)
            {
                fail(zs_link_message(rc));
                return;
            }
            out.name = Wide(link.name);
            if (length > 0)
                out.bytes.reserve((size_t)length);
            std::string buffer(256 * 1024, '\0');
            for (;;)
            {
                if (stopped())
                {
                    fail("");
                    return;
                }
                DWORD got = 0;
                if (!::WinHttpReadData(hop.request, buffer.data(), (DWORD)buffer.size(), &got))
                {
                    fail(ErrorText(::GetLastError()));
                    return;
                }
                if (got == 0)
                    break;
                if (out.bytes.size() + got > ZS_LINK_MAX_BYTES)
                {
                    fail(zs_link_message(ZS_LINK_TOO_LARGE));
                    return;
                }
                out.bytes.append(buffer.data(), got);
                if (progress && length > 0)
                    progress((double)out.bytes.size() / (double)length);
            }
            hop.Close();
        }
    }

    bool IsLink(std::wstring const &text)
    {
        return zs_link_is_link(Narrow(text).c_str()) == 1;
    }

    bool IsModelName(std::wstring const &name)
    {
        return zs_link_is_model_name(Narrow(name).c_str()) == 1;
    }

    bool Parse(std::wstring const &text, ModelLink &out, std::string &why)
    {
        auto link = std::make_unique<zs_link>();
        int rc = zs_link_check(Narrow(text).c_str(), link.get());
        if (rc != ZS_LINK_OK)
        {
            why = zs_link_message(rc);
            return false;
        }
        out.url = link->url;
        out.host = link->host;
        out.name = Wide(link->name);
        why.clear();
        return true;
    }

    bool IsPublicAddress(sockaddr const *address)
    {
        if (address == nullptr)
            return false;
        if (address->sa_family == AF_INET)
            return zs_link_address_public(reinterpret_cast<uint8_t const *>(&reinterpret_cast<sockaddr_in const *>(address)->sin_addr), 4) == 1;
        if (address->sa_family == AF_INET6)
            return zs_link_address_public(reinterpret_cast<uint8_t const *>(&reinterpret_cast<sockaddr_in6 const *>(address)->sin6_addr), 16) == 1;
        return false;
    }

    Download Fetch(ModelLink const &link, http::CancelPtr cancel, std::function<void(double)> progress, FetchSeam const &seam)
    {
        Download out;
        auto state = std::make_unique<zs_link>();
        CopyField(state->url, sizeof state->url, link.url);
        CopyField(state->host, sizeof state->host, link.host);
        CopyField(state->name, sizeof state->name, Narrow(link.name));
        WSADATA wsa{};
        bool started = ::WSAStartup(MAKEWORD(2, 2), &wsa) == 0;
        for (int hop = 0;; hop++)
        {
            bool redirected = false;
            FetchOnce(*state, cancel, progress, seam, out, redirected);
            if (out.cancelled || !out.error.empty() || !redirected)
                break;
            if (hop >= ZS_LINK_MAX_REDIRECTS)
            {
                out.error = zs_link_message(ZS_LINK_TOO_MANY_REDIRECTS);
                break;
            }
        }
        if (started)
            ::WSACleanup();
        return out;
    }
}
