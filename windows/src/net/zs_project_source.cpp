// See zs_project_source.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>

#include "zs_project_source.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

#include "zs_json.h"
#include "zs_open_link.h"

namespace zs::project
{
    namespace
    {
        int const max_redirects = 5;
        int const max_depth = 32;
        size_t const max_name = 100;
        size_t const max_ref = 255;
        size_t const max_url = 8192;
        // A file over this size is not kept in memory for a second load.
        size_t const max_cached_file = size_t(32) << 20;
        size_t const max_cached = size_t(512) << 20;

        char const *const allowed_hosts[] = {
            "github.com",
            "api.github.com",
            "raw.githubusercontent.com",
            "media.githubusercontent.com",
        };

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

        std::string Lower(std::string text)
        {
            std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return c >= 'A' && c <= 'Z' ? (char)(c + 32) : (char)c; });
            return text;
        }

        std::string Trim(std::string const &text)
        {
            size_t a = text.find_first_not_of(" \t\r\n");
            if (a == std::string::npos)
                return {};
            size_t b = text.find_last_not_of(" \t\r\n");
            return text.substr(a, b - a + 1);
        }

        // Percent-encodes a piece of a URL path. Only the unreserved
        // characters of RFC 3986 stay.
        std::string Encode(std::string const &text)
        {
            std::string out;
            char hex[4];
            for (unsigned char c : text)
            {
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
                {
                    out += (char)c;
                    continue;
                }
                snprintf(hex, sizeof hex, "%%%02X", c);
                out += hex;
            }
            return out;
        }

        // Each part of a path, encoded, with the slashes between them.
        std::string EncodePath(std::string const &path)
        {
            std::string out;
            size_t at = 0;
            for (;;)
            {
                size_t slash = path.find('/', at);
                out += Encode(path.substr(at, slash == std::string::npos ? slash : slash - at));
                if (slash == std::string::npos)
                    return out;
                out += '/';
                at = slash + 1;
            }
        }

        // A path of a tree: relative, with no empty part, no "." or "..",
        // and no backslash or control character.
        bool IsTreePath(std::string const &path)
        {
            if (path.empty() || path.size() > 4096 || path[0] == '/')
                return false;
            for (unsigned char c : path)
                if (c < 0x20 || c == 0x7F || c == '\\')
                    return false;
            size_t at = 0;
            for (;;)
            {
                size_t slash = path.find('/', at);
                std::string part = path.substr(at, slash == std::string::npos ? slash : slash - at);
                if (part.empty() || part == "." || part == "..")
                    return false;
                if (slash == std::string::npos)
                    return true;
                at = slash + 1;
            }
        }

        // A ref by the rules of git check-ref-format.
        bool IsRef(std::string const &ref)
        {
            if (ref.empty() || ref.size() > max_ref || ref.front() == '/' || ref.back() == '/' || ref.back() == '.' || ref.front() == '-')
                return false;
            if (ref.find("..") != std::string::npos || ref.find("//") != std::string::npos || ref.find("@{") != std::string::npos)
                return false;
            for (unsigned char c : ref)
                if (c <= 0x20 || c == 0x7F || strchr("~^:?*[\\", c) != nullptr)
                    return false;
            return true;
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

        struct Reply
        {
            int status = 0;
            std::string body;
            std::string error;
            bool cancelled = false;
            bool too_large = false;
        };

        std::string ErrorText(DWORD code)
        {
            switch (code)
            {
            case ERROR_WINHTTP_TIMEOUT:
                return "GitHub did not answer in time.";
            case ERROR_WINHTTP_NAME_NOT_RESOLVED:
            case ERROR_WINHTTP_CANNOT_CONNECT:
            case ERROR_WINHTTP_CONNECTION_ERROR:
                return "GitHub did not answer. Check the connection.";
            case ERROR_WINHTTP_SECURE_FAILURE:
                return "The certificate of GitHub is not valid.";
            default: {
                char text[64];
                snprintf(text, sizeof text, "GitHub did not answer (error %lu).", code);
                return text;
            }
            }
        }

        std::string LocationOf(HINTERNET request)
        {
            DWORD size = 0;
            ::WinHttpQueryHeaders(request, WINHTTP_QUERY_LOCATION, WINHTTP_HEADER_NAME_BY_INDEX, nullptr, &size, WINHTTP_NO_HEADER_INDEX);
            if (::GetLastError() != ERROR_INSUFFICIENT_BUFFER || size == 0)
                return {};
            std::wstring text(size / sizeof(wchar_t), L'\0');
            if (!::WinHttpQueryHeaders(request, WINHTTP_QUERY_LOCATION, WINHTTP_HEADER_NAME_BY_INDEX, text.data(), &size, WINHTTP_NO_HEADER_INDEX))
                return {};
            text.resize(size / sizeof(wchar_t));
            return Narrow(text);
        }

        // One request. A redirect sets `next`.
        void GetOnce(HINTERNET session, std::string const &url, wchar_t const *headers, size_t limit, http::CancelPtr const &cancel, Reply &out, std::string &next)
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
                out.error = "The address of the repository is not valid.";
                return;
            }
            std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
            std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
            if (parts.dwExtraInfoLength > 0)
                path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);

            Handle connection;
            connection.h = ::WinHttpConnect(session, host.c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0);
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
                out.body.clear();
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
            if (!::WinHttpSendRequest(request, headers, headers != nullptr ? (DWORD)-1L : 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
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
                !openlink::IsPublicAddress(reinterpret_cast<sockaddr const *>(&info.RemoteAddress)))
            {
                fail("The address of GitHub leads to a device on a local network.");
                return;
            }
            DWORD status = 0, size = sizeof status;
            if (!::WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                       &status, &size, WINHTTP_NO_HEADER_INDEX))
            {
                fail(ErrorText(::GetLastError()));
                return;
            }
            out.status = (int)status;
            if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308)
            {
                next = LocationOf(request);
                if (!next.empty() && next[0] == '/' && next.rfind("//", 0) != 0)
                    next = "https://" + Narrow(host) + next;
                if (next.empty())
                    fail("GitHub sent a redirect with no address.");
                else
                    close_request();
                return;
            }
            // The body of an error is not read.
            if (status < 200 || status >= 300)
            {
                close_request();
                return;
            }
            // No length, or one past 4 GB: the limit in the loop below holds.
            DWORD total = 0, total_size = sizeof total;
            if (!::WinHttpQueryHeaders(request, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                       &total, &total_size, WINHTTP_NO_HEADER_INDEX))
                total = 0;
            if (total > limit)
            {
                out.too_large = true;
                fail("A file of the project is too large.");
                return;
            }
            if (total > 0)
                out.body.reserve((size_t)total);
            std::string buffer(128 * 1024, '\0');
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
                if (out.body.size() + got > limit)
                {
                    out.too_large = true;
                    fail("A file of the project is too large.");
                    return;
                }
                out.body.append(buffer.data(), got);
            }
            close_request();
        }

        // A GET with each redirect checked.
        Reply Get(HINTERNET session, std::string url, wchar_t const *headers, size_t limit, http::CancelPtr const &cancel)
        {
            Reply out;
            for (int hop = 0; hop <= max_redirects; hop++)
            {
                if (!IsAllowedUrl(url))
                {
                    out.error = "GitHub sent the request to an address that zslice does not trust.";
                    return out;
                }
                std::string next;
                out = Reply{};
                GetOnce(session, url, headers, limit, cancel, out, next);
                if (out.cancelled || !out.error.empty() || next.empty())
                    return out;
                url = std::move(next);
            }
            out = Reply{};
            out.error = "GitHub sent too many redirects.";
            return out;
        }

        wchar_t const *const api_headers = L"Accept: application/vnd.github+json\r\n";

        // One answer of the API as JSON.
        bool ApiGet(HINTERNET session, GithubRepo const &repo, std::string const &tail, http::CancelPtr const &cancel, json::Value &out, std::string &error)
        {
            std::string url = "https://api.github.com/repos/" + repo.owner + "/" + repo.repo + tail;
            Reply reply = Get(session, url, api_headers, max_api, cancel);
            if (reply.cancelled)
                return false;
            if (!reply.error.empty())
            {
                error = reply.error;
                return false;
            }
            if (reply.status == 404)
            {
                error = "GitHub has no public repository " + repo.owner + "/" + repo.repo + (repo.ref.empty() ? "" : " with " + repo.ref) + ".";
                return false;
            }
            if (reply.status == 403 || reply.status == 429)
            {
                error = "GitHub refused the request (the limit of requests with no login is 60 an hour). Try again later.";
                return false;
            }
            if (reply.status < 200 || reply.status >= 300)
            {
                error = "GitHub answered " + std::to_string(reply.status) + ".";
                return false;
            }
            if (!json::Parse(reply.body, out) || !out.IsObject())
            {
                error = "GitHub answered with no valid JSON.";
                return false;
            }
            return true;
        }

        std::wstring LongPath(std::wstring const &path)
        {
            if (path.rfind(L"\\\\?\\", 0) == 0)
                return path;
            if (path.rfind(L"\\\\", 0) == 0)
                return L"\\\\?\\UNC\\" + path.substr(2);
            return L"\\\\?\\" + path;
        }

        // Adds the files under a folder. It skips .git, links, and junctions.
        bool Walk(std::wstring const &root, std::string const &relative, int depth, std::unordered_set<std::string> &out, http::CancelPtr const &cancel, std::string &error)
        {
            if (depth > max_depth)
                return true;
            if (cancel != nullptr && cancel->Stopped())
                return false;
            std::wstring dir = root;
            if (!relative.empty())
            {
                std::wstring tail = Wide(relative);
                std::replace(tail.begin(), tail.end(), L'/', L'\\');
                dir += L"\\" + tail;
            }
            WIN32_FIND_DATAW found{};
            HANDLE find = ::FindFirstFileExW(LongPath(dir + L"\\*").c_str(), FindExInfoBasic, &found, FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
            if (find == INVALID_HANDLE_VALUE)
                return true;
            bool ok = true;
            do
            {
                std::wstring name = found.cFileName;
                if (name == L"." || name == L".." || (found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
                    continue;
                std::string child = (relative.empty() ? "" : relative + "/") + Narrow(name);
                if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
                {
                    if (name == L".git")
                        continue;
                    ok = Walk(root, child, depth + 1, out, cancel, error);
                }
                else
                {
                    if (out.size() >= max_paths)
                    {
                        error = "The folder has too many files for a project.";
                        ok = false;
                    }
                    else
                    {
                        out.insert(std::move(child));
                    }
                }
            } while (ok && ::FindNextFileW(find, &found));
            ::FindClose(find);
            return ok;
        }
    }

    bool IsRepoName(std::string const &name)
    {
        if (name.empty() || name.size() > max_name || name == "." || name == "..")
            return false;
        for (unsigned char c : name)
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-'))
                return false;
        return true;
    }

    bool IsCommit(std::string const &sha)
    {
        if (sha.size() != 40 && sha.size() != 64)
            return false;
        return std::all_of(sha.begin(), sha.end(), [](unsigned char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); });
    }

    bool ParseGithub(std::string const &raw, GithubRepo &out)
    {
        std::string text = Trim(raw);
        if (text.empty() || text.size() > max_url)
            return false;
        for (unsigned char c : text)
            if (c <= 0x20 || c == 0x7F || c == '\\' || c == '?' || c == '#' || c == '@' || c == '%')
                return false;
        if (text.size() > 4 && Lower(text.substr(text.size() - 4)) == ".git")
            text.resize(text.size() - 4);
        size_t scheme = text.find("://");
        if (scheme != std::string::npos)
        {
            if (Lower(text.substr(0, scheme)) != "https")
                return false;
            text = text.substr(scheme + 3);
            size_t slash = text.find('/');
            if (slash == std::string::npos)
                return false;
            std::string host = Lower(text.substr(0, slash));
            if (host != "github.com" && host != "www.github.com")
                return false;
            text = text.substr(slash + 1);
        }
        else
        {
            std::string lower = Lower(text);
            if (lower.rfind("www.github.com/", 0) == 0)
                text = text.substr(15);
            else if (lower.rfind("github.com/", 0) == 0)
                text = text.substr(11);
        }
        while (!text.empty() && text.back() == '/')
            text.pop_back();
        size_t slash = text.find('/');
        if (slash == std::string::npos)
            return false;
        std::string owner = text.substr(0, slash), rest = text.substr(slash + 1), ref;
        size_t tree = rest.find("/tree/");
        if (tree != std::string::npos)
        {
            ref = rest.substr(tree + 6);
            rest.resize(tree);
            if (!IsRef(ref))
                return false;
        }
        if (rest.size() > 4 && Lower(rest.substr(rest.size() - 4)) == ".git")
            rest.resize(rest.size() - 4);
        if (!IsRepoName(owner) || !IsRepoName(rest))
            return false;
        out.owner = std::move(owner);
        out.repo = std::move(rest);
        out.ref = std::move(ref);
        return true;
    }

    bool IsAllowedUrl(std::string const &url)
    {
        if (url.size() > max_url || url.size() < 9 || Lower(url.substr(0, 8)) != "https://")
            return false;
        std::string rest = url.substr(8);
        for (unsigned char c : rest)
            if (c <= 0x20 || c >= 0x7F || c == '\\' || c == '"' || c == '<' || c == '>')
                return false;
        std::string authority = Lower(rest.substr(0, rest.find_first_of("/?#")));
        if (authority.find('@') != std::string::npos)
            return false;
        size_t colon = authority.find(':');
        if (colon != std::string::npos)
        {
            if (authority.substr(colon + 1) != "443")
                return false;
            authority.resize(colon);
        }
        return std::any_of(std::begin(allowed_hosts), std::end(allowed_hosts), [&](char const *host) { return authority == host; });
    }

    Source::Source() = default;

    Source::~Source()
    {
        if (session_ != nullptr)
            ::WinHttpCloseHandle(session_);
    }

    std::vector<std::string> Source::List(std::string const &folder_path) const
    {
        std::string prefix = folder_path + "/";
        std::vector<std::string> out;
        for (auto const &path : paths_)
            if (path.rfind(prefix, 0) == 0)
                out.push_back(path);
        std::sort(out.begin(), out.end());
        return out;
    }

    bool Source::Read(std::string const &path, std::string &bytes, std::string &error, http::CancelPtr const &cancel)
    {
        if (!Has(path))
        {
            error = (kind == Kind::Github ? "GitHub has no file " : "The folder has no file ") + path + ".";
            return false;
        }
        {
            std::lock_guard guard(lock_);
            auto it = cache_.find(path);
            if (it != cache_.end())
            {
                bytes = it->second;
                return true;
            }
        }
        bool ok = kind == Kind::Github ? ReadGithub(path, bytes, error, cancel) : ReadFolder(path, bytes, error);
        if (ok && kind == Kind::Github && bytes.size() <= max_cached_file)
        {
            std::lock_guard guard(lock_);
            if (cached_ + bytes.size() <= max_cached && cache_.emplace(path, bytes).second)
                cached_ += bytes.size();
        }
        return ok;
    }

    bool Source::ReadGithub(std::string const &path, std::string &bytes, std::string &error, http::CancelPtr const &cancel)
    {
        std::string tail = owner + "/" + repo + "/" + sha + "/" + EncodePath(path);
        Reply reply = Get(session_, "https://raw.githubusercontent.com/" + tail, nullptr, max_file, cancel);
        if (reply.cancelled)
            return false;
        auto failed = [&](char const *what) {
            if (reply.too_large)
                error = path + " is larger than 256 MB.";
            else if (!reply.error.empty())
                error = reply.error;
            else
                error = std::string(what) + path + " (" + std::to_string(reply.status) + ").";
        };
        if (!reply.error.empty() || reply.status < 200 || reply.status >= 300)
        {
            failed("GitHub has no file ");
            return false;
        }
        // A Git LFS pointer: the file is in LFS storage.
        static char const pointer[] = "version https://git-lfs";
        if (reply.body.size() < 400 && reply.body.rfind(pointer, 0) == 0)
        {
            reply = Get(session_, "https://media.githubusercontent.com/media/" + tail, nullptr, max_file, cancel);
            if (reply.cancelled)
                return false;
            if (!reply.error.empty() || reply.status < 200 || reply.status >= 300)
            {
                failed("GitHub has no LFS file ");
                return false;
            }
        }
        bytes = std::move(reply.body);
        return true;
    }

    bool Source::ReadFolder(std::string const &path, std::string &bytes, std::string &error)
    {
        std::wstring tail = Wide(path);
        std::replace(tail.begin(), tail.end(), L'/', L'\\');
        // The handle is of the file itself, so a link made after the walk
        // is seen here.
        HANDLE file = ::CreateFileW(LongPath(folder + L"\\" + tail).c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (file == INVALID_HANDLE_VALUE)
        {
            error = "The folder has no file " + path + ".";
            return false;
        }
        BY_HANDLE_FILE_INFORMATION info{};
        bool ok = ::GetFileInformationByHandle(file, &info) != 0 &&
                  (info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) == 0;
        if (!ok)
        {
            ::CloseHandle(file);
            error = "The folder has no file " + path + ".";
            return false;
        }
        unsigned long long size = ((unsigned long long)info.nFileSizeHigh << 32) | info.nFileSizeLow;
        if (size > max_file)
        {
            ::CloseHandle(file);
            error = path + " is larger than 256 MB.";
            return false;
        }
        bytes.resize((size_t)size);
        size_t done = 0;
        while (ok && done < bytes.size())
        {
            DWORD got = 0;
            DWORD piece = (DWORD)std::min<size_t>(bytes.size() - done, 1u << 24);
            ok = ::ReadFile(file, bytes.data() + done, piece, &got, nullptr) != 0 && got > 0;
            done += got;
        }
        ::CloseHandle(file);
        if (!ok)
        {
            bytes.clear();
            error = "The file " + path + " did not read.";
        }
        return ok;
    }

    std::shared_ptr<Source> OpenGithub(GithubRepo const &repo, std::string const &sha_in, http::CancelPtr const &cancel, std::string &error)
    {
        if (!IsRepoName(repo.owner) || !IsRepoName(repo.repo) || (!sha_in.empty() && !IsCommit(sha_in)))
        {
            error = "The address of the repository is not valid.";
            return nullptr;
        }
        auto source = std::make_shared<Source>();
        source->kind = Source::Kind::Github;
        source->owner = repo.owner;
        source->repo = repo.repo;
        // No proxy: the check of the address needs the real peer.
        HINTERNET session = ::WinHttpOpen(L"zslice", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (session == nullptr)
        {
            error = ErrorText(::GetLastError());
            return nullptr;
        }
        source->session_ = session;
        ::WinHttpSetTimeouts(session, 15000, 15000, 30000, 30000);
        DWORD no_redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        ::WinHttpSetOption(session, WINHTTP_OPTION_REDIRECT_POLICY, &no_redirect, sizeof no_redirect);

        std::string sha = sha_in;
        if (sha.empty())
        {
            std::string branch = repo.ref;
            json::Value answer;
            if (branch.empty())
            {
                if (!ApiGet(session, repo, "", cancel, answer, error))
                    return nullptr;
                branch = answer.Str("default_branch");
                if (!IsRef(branch))
                {
                    error = "GitHub answered with no default branch.";
                    return nullptr;
                }
            }
            if (!ApiGet(session, repo, "/commits/" + Encode(branch), cancel, answer, error))
                return nullptr;
            sha = answer.Str("sha");
            if (!IsCommit(sha))
            {
                error = "GitHub answered with no commit.";
                return nullptr;
            }
        }
        json::Value tree;
        if (!ApiGet(session, repo, "/git/trees/" + sha + "?recursive=1", cancel, tree, error))
            return nullptr;
        json::Value const *entries = tree.Get("tree");
        if (entries == nullptr || !entries->IsArray())
        {
            error = "GitHub answered with no list of files.";
            return nullptr;
        }
        source->sha = sha;
        for (auto const &entry : entries->items)
        {
            if (entry.Str("type") != "blob")
                continue;
            std::string path = entry.Str("path");
            if (!IsTreePath(path))
                continue;
            if (source->paths_.size() >= max_paths)
            {
                error = "The repository has too many files for a project.";
                return nullptr;
            }
            source->paths_.insert(std::move(path));
        }
        return source;
    }

    std::shared_ptr<Source> OpenFolder(std::wstring const &folder, http::CancelPtr const &cancel, std::string &error)
    {
        wchar_t full[4096];
        DWORD n = ::GetFullPathNameW(folder.c_str(), ARRAYSIZE(full), full, nullptr);
        if (n == 0 || n >= ARRAYSIZE(full))
        {
            error = "The folder is not there.";
            return nullptr;
        }
        std::wstring root(full, n);
        while (root.size() > 3 && (root.back() == L'\\' || root.back() == L'/'))
            root.pop_back();
        DWORD attributes = ::GetFileAttributesW(LongPath(root).c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0)
        {
            error = "The folder " + Narrow(root) + " is not there.";
            return nullptr;
        }
        auto source = std::make_shared<Source>();
        source->kind = Source::Kind::Folder;
        // A drive root loses its slash: each path adds one.
        if (root.back() == L'\\')
            root.pop_back();
        source->folder = root;
        std::string why;
        if (!Walk(root, "", 0, source->paths_, cancel, why))
        {
            error = why;
            return nullptr;
        }
        return source;
    }
}
