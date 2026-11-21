#include "pch.h"
#include "App.xaml.h"
#include "zs_model.h"
#include "MainWindow.xaml.h"

// InitializeComponent and wWinMain of App are in App.xaml.g.hpp, which
// winrt_glue.cpp compiles through XamlTypeInfo.g.cpp.

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::ZSlice::implementation
{
    App::App()
    {
        InitializeComponent();
        // An error that no code caught: its reason goes to the log.
        UnhandledException([](auto &&, Microsoft::UI::Xaml::UnhandledExceptionEventArgs const &e) {
            zs::Log("shell: unhandled error 0x%08x: %s\n", (unsigned)e.Exception().value, winrt::to_string(e.Message()).c_str());
        });
    }

    void App::OnLaunched(LaunchActivatedEventArgs const &)
    {
        // ZSLICE_LOG=path: a WinUI app has no console, so the shell and the
        // core write their log lines to this file, through the Win32 handle.
        wchar_t path[512];
        if (::GetEnvironmentVariableW(L"ZSLICE_LOG", path, ARRAYSIZE(path)) > 0)
        {
            HANDLE h = ::CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                     OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (h != INVALID_HANDLE_VALUE)
                ::SetStdHandle(STD_ERROR_HANDLE, h);
        }
        // One window has each state folder. A later start gives its file or
        // link to that window. If the window does not answer, this one runs.
        std::wstring key = zs::appshell::InstanceKey(zs::StateDir());
        if (!zs::appshell::Claim(key) && zs::appshell::HandOff(key, zs::appshell::FirstArgument()))
        {
            Exit();
            return;
        }
        window = make<MainWindow>();
        window.Activate();
    }
}
