#include "pch.h"
#include "App.xaml.h"
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
    }

    void App::OnLaunched(LaunchActivatedEventArgs const &)
    {
        // ZSLICE_LOG=path: a WinUI app has no console, so the shell and the
        // core write their log lines to this file. The core writes through
        // the Win32 handle, and the shell through the C stream.
        wchar_t path[512];
        if (::GetEnvironmentVariableW(L"ZSLICE_LOG", path, ARRAYSIZE(path)) > 0)
        {
            HANDLE h = ::CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                     OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (h != INVALID_HANDLE_VALUE)
                ::SetStdHandle(STD_ERROR_HANDLE, h);
            FILE *f = nullptr;
            _wfreopen_s(&f, path, L"a", stderr);
            setvbuf(stderr, nullptr, _IONBF, 0);
        }
        window = make<MainWindow>();
        window.Activate();
    }
}
