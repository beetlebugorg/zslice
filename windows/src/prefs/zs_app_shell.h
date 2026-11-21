#pragma once
// How Windows starts the app for a file or a link.
//
// RegisterApp adds the file types and the zslice link scheme for this user
// (HKCU). The app shows in Open With and in Default Apps. It does not take
// the default of a type: Windows leaves that choice to the user.
//
// One window has each state folder, because two would overwrite each other's
// session. A second start hands its file or link to the first through a
// named pipe, and exits.
//
// It has no WinRT, so a test program can link it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include <functional>
#include <string>
#include <thread>

namespace zs::appshell
{
    // The first argument of the command line, or empty.
    std::wstring FirstArgument();

    // Writes the keys under HKCU\<root>, if they differ from this version
    // and this path. Returns true if it wrote them.
    bool RegisterApp(std::wstring const &exe, std::wstring const &root = L"Software");

    // A short key for a state folder.
    std::wstring InstanceKey(std::wstring const &state_dir);
    // True if this process is the first with this key.
    bool Claim(std::wstring const &key);
    // Gives the argument to the first process. False if it did not answer.
    bool HandOff(std::wstring const &key, std::wstring const &argument);

    // Takes the arguments of later starts, on its own thread.
    class OpenServer
    {
    public:
        OpenServer(std::wstring const &key, std::function<void(std::wstring)> on_open);
        ~OpenServer();
        OpenServer(OpenServer const &) = delete;
        OpenServer &operator=(OpenServer const &) = delete;

    private:
        void Run(std::wstring name, std::function<void(std::wstring)> on_open);
        void *stop_ = nullptr;
        std::thread thread_;
    };
}
