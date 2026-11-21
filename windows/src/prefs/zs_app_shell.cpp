// See zs_app_shell.h.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>

#include "zs_app_shell.h"

#include <algorithm>
#include <cstdio>
#include <cwctype>
#include <vector>

namespace zs::appshell
{
    namespace
    {
        wchar_t const *const prog_id = L"ZSlice.Model";
        wchar_t const *const scheme = L"zslice";
        wchar_t const *const types[] = { L".stl", L".3mf", L".step", L".stp", L".obj" };
        // A new version writes the keys again.
        DWORD const keys_version = 1;
        DWORD const max_message = 65536;

        bool SetText(std::wstring const &key, wchar_t const *name, std::wstring const &value)
        {
            return ::RegSetKeyValueW(HKEY_CURRENT_USER, key.c_str(), name, REG_SZ, value.c_str(),
                                     (DWORD)((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
        }

        std::wstring GetText(std::wstring const &key, wchar_t const *name)
        {
            DWORD size = 0;
            if (::RegGetValueW(HKEY_CURRENT_USER, key.c_str(), name, RRF_RT_REG_SZ, nullptr, nullptr, &size) != ERROR_SUCCESS || size == 0)
                return {};
            std::wstring text(size / sizeof(wchar_t), L'\0');
            if (::RegGetValueW(HKEY_CURRENT_USER, key.c_str(), name, RRF_RT_REG_SZ, nullptr, text.data(), &size) != ERROR_SUCCESS)
                return {};
            text.resize(wcsnlen(text.c_str(), text.size()));
            return text;
        }

        std::wstring PipeName(std::wstring const &key)
        {
            return L"\\\\.\\pipe\\zslice-" + key;
        }
    }

    std::wstring FirstArgument()
    {
        int count = 0;
        LPWSTR *args = ::CommandLineToArgvW(::GetCommandLineW(), &count);
        std::wstring first;
        if (args != nullptr)
        {
            if (count > 1)
                first = args[1];
            ::LocalFree(args);
        }
        return first;
    }

    bool RegisterApp(std::wstring const &exe, std::wstring const &root)
    {
        std::wstring own = root + L"\\zslice";
        DWORD version = 0, size = sizeof version;
        bool same = ::RegGetValueW(HKEY_CURRENT_USER, own.c_str(), L"KeysVersion", RRF_RT_REG_DWORD, nullptr, &version, &size) == ERROR_SUCCESS &&
                    version == keys_version && GetText(own, L"KeysExe") == exe;
        if (same)
            return false;

        std::wstring classes = root + L"\\Classes\\";
        std::wstring command = L"\"" + exe + L"\" \"%1\"";
        std::wstring icon = L"\"" + exe + L"\",0";
        size_t slash = exe.find_last_of(L"\\/");
        std::wstring exe_name = slash == std::wstring::npos ? exe : exe.substr(slash + 1);
        bool ok = true;

        // The kind of file. The type keeps its default: this only adds the
        // app to the list of the type.
        std::wstring prog = classes + prog_id;
        ok &= SetText(prog, nullptr, L"3D model");
        ok &= SetText(prog, L"FriendlyTypeName", L"3D model");
        ok &= SetText(prog + L"\\DefaultIcon", nullptr, icon);
        ok &= SetText(prog + L"\\shell\\open", L"FriendlyAppName", L"zslice");
        ok &= SetText(prog + L"\\shell\\open\\command", nullptr, command);

        std::wstring app = classes + L"Applications\\" + exe_name;
        ok &= SetText(app, L"FriendlyAppName", L"zslice");
        ok &= SetText(app + L"\\DefaultIcon", nullptr, icon);
        ok &= SetText(app + L"\\shell\\open\\command", nullptr, command);

        std::wstring caps = own + L"\\Capabilities";
        ok &= SetText(caps, L"ApplicationName", L"zslice");
        ok &= SetText(caps, L"ApplicationDescription", L"Slice 3D models for FDM printers");
        for (wchar_t const *type : types)
        {
            ok &= ::RegSetKeyValueW(HKEY_CURRENT_USER, (classes + type + L"\\OpenWithProgids").c_str(), prog_id, REG_NONE, nullptr, 0) == ERROR_SUCCESS;
            ok &= SetText(app + L"\\SupportedTypes", type, L"");
            ok &= SetText(caps + L"\\FileAssociations", type, prog_id);
        }

        // The link scheme.
        std::wstring link = classes + scheme;
        ok &= SetText(link, nullptr, L"URL:zslice");
        ok &= SetText(link, L"URL Protocol", L"");
        ok &= SetText(link + L"\\DefaultIcon", nullptr, icon);
        ok &= SetText(link + L"\\shell\\open\\command", nullptr, command);
        ok &= SetText(caps + L"\\UrlAssociations", scheme, scheme);
        ok &= SetText(root + L"\\RegisteredApplications", L"zslice", caps);

        if (!ok)
            return false;
        ok &= SetText(own, L"KeysExe", exe);
        ok &= ::RegSetKeyValueW(HKEY_CURRENT_USER, own.c_str(), L"KeysVersion", REG_DWORD, &keys_version, sizeof keys_version) == ERROR_SUCCESS;
        if (root == L"Software")
            ::SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
        return ok;
    }

    std::wstring InstanceKey(std::wstring const &state_dir)
    {
        std::wstring lower = state_dir;
        std::transform(lower.begin(), lower.end(), lower.begin(), ::towlower);
        std::replace(lower.begin(), lower.end(), L'/', L'\\');
        while (!lower.empty() && lower.back() == L'\\')
            lower.pop_back();
        unsigned long long hash = 14695981039346656037ULL;
        for (wchar_t c : lower)
        {
            hash ^= (unsigned long long)c;
            hash *= 1099511628211ULL;
        }
        wchar_t text[20];
        swprintf(text, 20, L"%016llx", hash);
        return text;
    }

    bool Claim(std::wstring const &key)
    {
        // It stays open for the life of the process.
        HANDLE mutex = ::CreateMutexW(nullptr, FALSE, (L"Local\\zslice-" + key).c_str());
        return mutex != nullptr && ::GetLastError() != ERROR_ALREADY_EXISTS;
    }

    bool HandOff(std::wstring const &key, std::wstring const &argument)
    {
        std::wstring name = PipeName(key);
        HANDLE pipe = INVALID_HANDLE_VALUE;
        // The first window can still be starting.
        for (int i = 0; i < 100 && pipe == INVALID_HANDLE_VALUE; i++)
        {
            pipe = ::CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
            if (pipe != INVALID_HANDLE_VALUE)
                break;
            if (::GetLastError() == ERROR_PIPE_BUSY)
                ::WaitNamedPipeW(name.c_str(), 100);
            else
                ::Sleep(50);
        }
        if (pipe == INVALID_HANDLE_VALUE)
            return false;
        DWORD mode = PIPE_READMODE_MESSAGE;
        ::SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);
        ULONG server = 0;
        if (::GetNamedPipeServerProcessId(pipe, &server))
            ::AllowSetForegroundWindow(server);
        // A mark first, so that no argument is still a message.
        std::wstring message = L">" + (argument.size() * sizeof(wchar_t) + 2 > max_message ? std::wstring() : argument);
        DWORD wrote = 0, got = 0;
        char answer = 0;
        bool ok = ::WriteFile(pipe, message.data(), (DWORD)(message.size() * sizeof(wchar_t)), &wrote, nullptr) &&
                  ::ReadFile(pipe, &answer, 1, &got, nullptr) && got == 1;
        ::CloseHandle(pipe);
        return ok;
    }

    OpenServer::OpenServer(std::wstring const &key, std::function<void(std::wstring)> on_open)
    {
        stop_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
        thread_ = std::thread([this, name = PipeName(key), on_open = std::move(on_open)]() mutable { Run(std::move(name), std::move(on_open)); });
    }

    OpenServer::~OpenServer()
    {
        ::SetEvent(stop_);
        if (thread_.joinable())
            thread_.join();
        ::CloseHandle(stop_);
    }

    void OpenServer::Run(std::wstring name, std::function<void(std::wstring)> on_open)
    {
        HANDLE pipe = ::CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                                         PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 16, max_message, 0, nullptr);
        if (pipe == INVALID_HANDLE_VALUE)
            return;
        HANDLE done = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
        HANDLE waits[2] = { stop_, done };
        // Waits for the I/O, or for the stop. False: it did not finish.
        auto finish = [&](OVERLAPPED &io, DWORD timeout, DWORD &bytes) {
            if (::WaitForMultipleObjects(2, waits, FALSE, timeout) != WAIT_OBJECT_0 + 1)
            {
                ::CancelIoEx(pipe, &io);
                ::GetOverlappedResult(pipe, &io, &bytes, TRUE);
                return false;
            }
            return ::GetOverlappedResult(pipe, &io, &bytes, FALSE) != FALSE;
        };
        std::vector<wchar_t> buffer(max_message / sizeof(wchar_t));
        for (;;)
        {
            if (::WaitForSingleObject(stop_, 0) == WAIT_OBJECT_0)
                break;
            OVERLAPPED io{};
            io.hEvent = done;
            ::ResetEvent(done);
            DWORD bytes = 0;
            bool joined = ::ConnectNamedPipe(pipe, &io) != FALSE;
            DWORD error = joined ? ERROR_SUCCESS : ::GetLastError();
            if (error == ERROR_IO_PENDING)
            {
                joined = finish(io, INFINITE, bytes);
                if (!joined && ::WaitForSingleObject(stop_, 0) == WAIT_OBJECT_0)
                    break;
            }
            else if (error == ERROR_PIPE_CONNECTED)
            {
                joined = true;
            }
            if (joined)
            {
                OVERLAPPED read{};
                read.hEvent = done;
                ::ResetEvent(done);
                bool got = ::ReadFile(pipe, buffer.data(), max_message, &bytes, &read) != FALSE;
                // A client that sends nothing cannot hold the pipe.
                if (!got && ::GetLastError() == ERROR_IO_PENDING)
                    got = finish(read, 2000, bytes);
                if (got && bytes >= sizeof(wchar_t) && bytes % sizeof(wchar_t) == 0 && buffer[0] == L'>')
                {
                    std::wstring argument(buffer.data() + 1, bytes / sizeof(wchar_t) - 1);
                    char answer = 1;
                    OVERLAPPED write{};
                    write.hEvent = done;
                    ::ResetEvent(done);
                    DWORD wrote = 0;
                    if (!::WriteFile(pipe, &answer, 1, &wrote, &write) && ::GetLastError() == ERROR_IO_PENDING)
                        finish(write, 2000, wrote);
                    on_open(std::move(argument));
                }
            }
            ::DisconnectNamedPipe(pipe);
        }
        ::CloseHandle(done);
        ::CloseHandle(pipe);
    }
}
