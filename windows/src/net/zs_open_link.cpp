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

#include <algorithm>
#include <cstdio>
#include <cwchar>
#include <cwctype>

namespace zs::openlink
{
    namespace
    {
        int const max_redirects = 5;
        size_t const max_link = 4096;

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

        std::string LowerAscii(std::string text)
        {
            std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return c >= 'A' && c <= 'Z' ? (char)(c + 32) : (char)c; });
            return text;
        }

        int HexDigit(char c)
        {
            if (c >= '0' && c <= '9')
                return c - '0';
            if (c >= 'a' && c <= 'f')
                return c - 'a' + 10;
            if (c >= 'A' && c <= 'F')
                return c - 'A' + 10;
            return -1;
        }

        bool PercentDecode(std::string const &text, std::string &out)
        {
            out.clear();
            for (size_t i = 0; i < text.size(); i++)
            {
                if (text[i] != '%')
                {
                    out += text[i];
                    continue;
                }
                if (i + 2 >= text.size())
                    return false;
                int high = HexDigit(text[i + 1]), low = HexDigit(text[i + 2]);
                if (high < 0 || low < 0)
                    return false;
                out += (char)(high * 16 + low);
                i += 2;
            }
            return true;
        }

        // A file name to show and to keep: no folder, no control character,
        // and no mark that reverses the text to hide the real extension.
        std::wstring CleanName(std::wstring const &raw)
        {
            size_t at = raw.find_last_of(L"\\/");
            std::wstring base = at == std::wstring::npos ? raw : raw.substr(at + 1);
            std::wstring out;
            for (wchar_t c : base)
            {
                bool direction = c == 0x200E || c == 0x200F || (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069);
                if (c < 0x20 || c == 0x7F || direction || wcschr(L"<>:\"|?*", c) != nullptr)
                    continue;
                out += c;
            }
            while (!out.empty() && (out.back() == L' ' || out.back() == L'.'))
                out.pop_back();
            if (out.size() > 120)
            {
                size_t dot = out.find_last_of(L'.');
                std::wstring ext = dot == std::wstring::npos || out.size() - dot > 8 ? L"" : out.substr(dot);
                out = out.substr(0, 120 - ext.size()) + ext;
            }
            return out;
        }

        bool LocalHostName(std::string const &host)
        {
            auto ends = [&](char const *tail) {
                std::string t = tail;
                return host.size() >= t.size() && host.compare(host.size() - t.size(), t.size(), t) == 0;
            };
            return ends(".local") || ends(".localhost") || ends(".internal") || ends(".lan") || ends(".home") || ends(".arpa");
        }

        // Checks an https URL and writes its clean form. The last label of
        // the host must be letters: that refuses each form of an IP address.
        bool CheckUrl(std::string const &text, std::string &url, std::string &host, std::string &why)
        {
            why = "The link does not lead to a public https address.";
            if (text.size() > max_link || LowerAscii(text.substr(0, 8)) != "https://")
                return false;
            std::string rest = text.substr(8);
            for (unsigned char c : rest)
                if (c < 0x20 || c == 0x7F || c == '\\' || c == '"' || c == '<' || c == '>')
                    return false;
            size_t hash = rest.find('#');
            if (hash != std::string::npos)
                rest.resize(hash);
            size_t end = rest.find_first_of("/?");
            std::string authority = LowerAscii(rest.substr(0, end));
            std::string tail = end == std::string::npos ? "/" : rest.substr(end);
            if (tail[0] == '?')
                tail = "/" + tail;
            if (authority.find('@') != std::string::npos)
                return false;
            size_t colon = authority.find(':');
            if (colon != std::string::npos)
            {
                if (authority.substr(colon + 1) != "443")
                    return false;
                authority.resize(colon);
            }
            if (authority.size() < 4 || authority.size() > 253 || authority.front() == '.' || authority.front() == '-' ||
                authority.back() == '.' || authority.back() == '-' || authority.find("..") != std::string::npos)
                return false;
            for (char c : authority)
                if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-'))
                    return false;
            size_t dot = authority.rfind('.');
            if (dot == std::string::npos || LocalHostName(authority))
                return false;
            std::string label = authority.substr(dot + 1);
            if (label.size() < 2)
                return false;
            bool punycode = label.rfind("xn--", 0) == 0;
            if (!punycode)
                for (char c : label)
                    if (c < 'a' || c > 'z')
                        return false;
            host = authority;
            url = "https://" + authority;
            char hex[4];
            for (unsigned char c : tail)
            {
                if (c < 0x80 && c != ' ')
                {
                    url += (char)c;
                    continue;
                }
                snprintf(hex, sizeof hex, "%%%02X", c);
                url += hex;
            }
            why.clear();
            return true;
        }

        std::wstring NameInUrl(std::string const &url)
        {
            size_t start = url.find('/', 8);
            if (start == std::string::npos)
                return {};
            std::string path = url.substr(start, url.find('?', start) - start);
            size_t slash = path.rfind('/');
            std::string decoded;
            if (!PercentDecode(path.substr(slash + 1), decoded))
                return {};
            return CleanName(Wide(decoded));
        }

        std::wstring NameInDisposition(std::string const &header)
        {
            std::string lower = LowerAscii(header);
            size_t at = lower.find("filename*=");
            if (at != std::string::npos)
            {
                std::string value = header.substr(at + 10, header.find(';', at) - at - 10);
                size_t mark = value.find("''");
                std::string decoded;
                if (mark != std::string::npos && PercentDecode(value.substr(mark + 2), decoded))
                    return CleanName(Wide(decoded));
            }
            at = lower.find("filename=");
            if (at == std::string::npos)
                return {};
            std::string value = header.substr(at + 9);
            if (!value.empty() && value[0] == '"')
                value = value.substr(1, value.find('"', 1) - 1);
            else
                value = value.substr(0, value.find(';'));
            return CleanName(Wide(value));
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

        // One request. A redirect sets `next`.
        void FetchOnce(std::string const &url, std::string const &host, http::CancelPtr const &cancel,
                       std::function<void(double)> const &progress, Download &out, std::string &next)
        {
            std::wstring wide = Wide(url);
            URL_COMPONENTS parts{};
            parts.dwStructSize = sizeof parts;
            parts.dwHostNameLength = (DWORD)-1;
            parts.dwUrlPathLength = (DWORD)-1;
            parts.dwExtraInfoLength = (DWORD)-1;
            parts.dwSchemeLength = (DWORD)-1;
            if (!::WinHttpCrackUrl(wide.c_str(), (DWORD)wide.size(), 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS)
            {
                out.error = "The link is not valid.";
                return;
            }
            std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
            if (parts.dwExtraInfoLength > 0)
                path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);

            // No proxy: the check of the address below needs the real peer.
            Handle session, connection;
            session.h = ::WinHttpOpen(L"zslice", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
            if (session.h == nullptr)
            {
                out.error = ErrorText(::GetLastError());
                return;
            }
            ::WinHttpSetTimeouts(session.h, 15000, 15000, 30000, 30000);
            DWORD no_redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
            ::WinHttpSetOption(session.h, WINHTTP_OPTION_REDIRECT_POLICY, &no_redirect, sizeof no_redirect);
            connection.h = ::WinHttpConnect(session.h, Wide(host).c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0);
            HINTERNET request = connection.h == nullptr
                                    ? nullptr
                                    : ::WinHttpOpenRequest(connection.h, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER,
                                                           WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
            if (request == nullptr)
            {
                out.error = ErrorText(::GetLastError());
                return;
            }
            DWORD no_cookies = WINHTTP_DISABLE_COOKIES;
            ::WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &no_cookies, sizeof no_cookies);
            DWORD no_logon = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
            ::WinHttpSetOption(request, WINHTTP_OPTION_AUTOLOGON_POLICY, &no_logon, sizeof no_logon);

            bool attached = false;
            auto close_request = [&] {
                bool owned = !attached || cancel->Detach();
                attached = false;
                if (owned && request != nullptr)
                    ::WinHttpCloseHandle(request);
                request = nullptr;
            };
            auto stopped = [&] { return cancel != nullptr && cancel->Stopped(); };
            auto fail = [&](std::string const &text) {
                if (stopped())
                    out.cancelled = true;
                else
                    out.error = text;
                out.bytes.clear();
                close_request();
            };
            if (cancel != nullptr)
            {
                if (!cancel->Attach(request))
                {
                    out.cancelled = true;
                    close_request();
                    return;
                }
                attached = true;
            }
            if (!::WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
                !::WinHttpReceiveResponse(request, nullptr))
            {
                fail(ErrorText(::GetLastError()));
                return;
            }
            // A public name can still resolve to a local address.
            WINHTTP_CONNECTION_INFO info{};
            info.cbSize = sizeof info;
            DWORD info_size = sizeof info;
            if (!::WinHttpQueryOption(request, WINHTTP_OPTION_CONNECTION_INFO, &info, &info_size) ||
                !IsPublicAddress(reinterpret_cast<sockaddr const *>(&info.RemoteAddress)))
            {
                fail("The link leads to a device on a local network.");
                return;
            }
            DWORD status = 0, size = sizeof status;
            if (!::WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                       &status, &size, WINHTTP_NO_HEADER_INDEX))
            {
                fail(ErrorText(::GetLastError()));
                return;
            }
            if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308)
            {
                next = QueryHeader(request, WINHTTP_QUERY_LOCATION);
                if (!next.empty() && next[0] == '/' && next.rfind("//", 0) != 0)
                    next = "https://" + host + next;
                if (next.empty())
                    fail("The site sent a redirect with no address.");
                else
                    close_request();
                return;
            }
            if (status < 200 || status >= 300)
            {
                fail("The site answered with error " + std::to_string(status) + ".");
                return;
            }
            std::string type = LowerAscii(QueryHeader(request, WINHTTP_QUERY_CONTENT_TYPE));
            if (type.rfind("text/html", 0) == 0)
            {
                fail("The link leads to a web page, not to a model file.");
                return;
            }
            std::wstring name = NameInDisposition(QueryHeader(request, WINHTTP_QUERY_CONTENT_DISPOSITION));
            if (!IsModelName(name))
                name = NameInUrl(url);
            if (IsModelName(name))
                out.name = name;

            // No length, or one past 4 GB: the limit in the loop below holds.
            DWORD total = 0, total_size = sizeof total;
            if (!::WinHttpQueryHeaders(request, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                       &total, &total_size, WINHTTP_NO_HEADER_INDEX))
                total = 0;
            if (total > max_download)
            {
                fail("The file is larger than 512 MB.");
                return;
            }
            if (total > 0)
                out.bytes.reserve((size_t)total);
            std::string buffer(256 * 1024, '\0');
            for (;;)
            {
                if (stopped())
                {
                    fail("");
                    return;
                }
                DWORD got = 0;
                if (!::WinHttpReadData(request, buffer.data(), (DWORD)buffer.size(), &got))
                {
                    fail(ErrorText(::GetLastError()));
                    return;
                }
                if (got == 0)
                    break;
                if (out.bytes.size() + got > max_download)
                {
                    fail("The file is larger than 512 MB.");
                    return;
                }
                out.bytes.append(buffer.data(), got);
                if (progress && total > 0)
                    progress((double)out.bytes.size() / (double)total);
            }
            close_request();
        }
    }

    bool IsLink(std::wstring const &text)
    {
        if (text.size() < 7)
            return false;
        std::wstring head = text.substr(0, 7);
        std::transform(head.begin(), head.end(), head.begin(), ::towlower);
        return head == L"zslice:";
    }

    bool IsModelName(std::wstring const &name)
    {
        size_t at = name.find_last_of(L'.');
        if (at == std::wstring::npos || at == 0)
            return false;
        std::wstring ext = name.substr(at);
        std::transform(ext.begin(), ext.end(), ext.begin(), ::towlower);
        return ext == L".stl" || ext == L".3mf" || ext == L".step" || ext == L".stp" || ext == L".obj";
    }

    bool Parse(std::wstring const &text, ModelLink &out, std::string &why)
    {
        why = "The link is not valid.";
        if (text.size() > max_link || !IsLink(text))
            return false;
        std::string link = Narrow(text);
        std::string lower = LowerAscii(link);
        size_t query;
        if (lower.rfind("zslice://open?", 0) == 0)
            query = 14;
        else if (lower.rfind("zslice://open/?", 0) == 0)
            query = 15;
        else
            return false;
        std::string rest = link.substr(query);
        size_t hash = rest.find('#');
        if (hash != std::string::npos)
            rest.resize(hash);
        std::string file;
        int found = 0;
        size_t at = 0;
        while (at <= rest.size())
        {
            size_t end = rest.find('&', at);
            if (end == std::string::npos)
                end = rest.size();
            std::string pair = rest.substr(at, end - at);
            if (pair.rfind("file=", 0) == 0)
            {
                found++;
                file = pair.substr(5);
            }
            at = end + 1;
        }
        if (found != 1)
            return false;
        std::string decoded;
        if (!PercentDecode(file, decoded))
            return false;
        ModelLink link_out;
        if (!CheckUrl(decoded, link_out.url, link_out.host, why))
            return false;
        link_out.name = NameInUrl(link_out.url);
        if (!IsModelName(link_out.name))
            link_out.name.clear();
        out = std::move(link_out);
        why.clear();
        return true;
    }

    bool IsPublicAddress(sockaddr const *address)
    {
        if (address == nullptr)
            return false;
        auto v4 = [](unsigned char const *b) {
            if (b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224)
                return false;
            if (b[0] == 100 && (b[1] & 0xC0) == 64)
                return false;
            if (b[0] == 169 && b[1] == 254)
                return false;
            if (b[0] == 172 && (b[1] & 0xF0) == 16)
                return false;
            if (b[0] == 192 && ((b[1] == 168) || (b[1] == 0 && b[2] == 0)))
                return false;
            if (b[0] == 198 && (b[1] == 18 || b[1] == 19))
                return false;
            return true;
        };
        if (address->sa_family == AF_INET)
            return v4(reinterpret_cast<unsigned char const *>(&reinterpret_cast<sockaddr_in const *>(address)->sin_addr));
        if (address->sa_family != AF_INET6)
            return false;
        auto const *b = reinterpret_cast<unsigned char const *>(&reinterpret_cast<sockaddr_in6 const *>(address)->sin6_addr);
        bool zero_head = std::all_of(b, b + 10, [](unsigned char c) { return c == 0; });
        if (zero_head && b[10] == 0xFF && b[11] == 0xFF)
            return v4(b + 12);
        if (zero_head && b[10] == 0 && b[11] == 0 && b[12] == 0 && b[13] == 0 && b[14] == 0 && b[15] <= 1)
            return false;
        if ((b[0] & 0xFE) == 0xFC || b[0] == 0xFF || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80))
            return false;
        return true;
    }

    Download Fetch(ModelLink const &link, http::CancelPtr cancel, std::function<void(double)> progress)
    {
        Download out;
        std::string url = link.url, host = link.host;
        for (int hop = 0; hop <= max_redirects; hop++)
        {
            std::string next;
            FetchOnce(url, host, cancel, progress, out, next);
            if (out.cancelled || !out.error.empty())
                return out;
            if (next.empty())
            {
                if (out.name.empty() && IsModelName(link.name))
                    out.name = link.name;
                if (out.name.empty())
                {
                    out.bytes.clear();
                    out.error = "The link does not lead to an STL, 3MF, STEP, or OBJ file.";
                }
                return out;
            }
            std::string why;
            if (!CheckUrl(next, url, host, why))
            {
                out.error = "The site sent the download to an address that zslice does not trust.";
                return out;
            }
        }
        out.error = "The site sent too many redirects.";
        return out;
    }
}
