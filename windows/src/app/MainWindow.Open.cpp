// A file or a link from outside the app: a double-click in Explorer, Open
// With, or a zslice://open?file=... link of a model site.
//
// A file opens on a new plate when the plate has parts, so it replaces no
// work. A link always asks first, with the file name and the site, because
// any web page can start one. A link never opens a zslice project, and
// nothing here starts a print.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace winrt::ZSlice::implementation
{
    Microsoft::UI::Xaml::Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    void MainWindow::StartOpenLinks()
    {
        if (open_server != nullptr)
            return;
        auto self = get_weak();
        auto target = queue;
        open_server = std::make_unique<zs::appshell::OpenServer>(zs::appshell::InstanceKey(zs::StateDir()), [self, target](std::wstring argument) {
            target.TryEnqueue([self, argument] {
                if (auto window = self.get())
                    window->OpenExternal(argument);
            });
        });
#ifndef ZS_DEV_HOOKS
        // A test run keeps its hands off the keys of the user.
        if (::GetEnvironmentVariableW(L"ZSLICE_STATE_DIR", nullptr, 0) == 0)
        {
            wchar_t exe[MAX_PATH * 2];
            DWORD n = ::GetModuleFileNameW(nullptr, exe, ARRAYSIZE(exe));
            if (n > 0 && n < ARRAYSIZE(exe))
                std::thread([path = std::wstring(exe, n)] { zs::appshell::RegisterApp(path); }).detach();
        }
#endif
    }

    void MainWindow::StopOpenLinks()
    {
        open_server.reset();
        if (download_cancel != nullptr)
            download_cancel->Stop();
    }

    void MainWindow::OpenExternal(std::wstring const &argument)
    {
        if (model == nullptr)
            return;
        ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
        ::SetForegroundWindow(hwnd);
        if (argument.empty())
            return;
        if (zs::openlink::IsLink(argument))
            AskOpenLink(argument);
        else if (zs::openlink::IsModelName(argument))
            LoadPath(argument, true);
        else
            ShowToast(L"zslice opens STL, 3MF, STEP, and OBJ files.");
    }

    winrt::fire_and_forget MainWindow::AskOpenLink(std::wstring text)
    {
        auto lifetime = get_strong();
        zs::openlink::ModelLink link;
        std::string why;
        if (!zs::openlink::Parse(text, link, why))
        {
            ShowError(L"This link did not open. " + zs::ToWide(why));
            co_return;
        }
        if (link_asking || download_cancel != nullptr)
        {
            ShowToast(L"Finish the link that is open, then try this one.");
            co_return;
        }
        link_asking = true;

        StackPanel content;
        content.Spacing(6);
        content.MaxWidth(420);
        TextBlock name;
        name.Text(link.name.empty() ? L"A model file" : link.name);
        name.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        name.TextWrapping(TextWrapping::Wrap);
        TextBlock from;
        from.Text(L"From " + zs::ToWide(link.host));
        from.TextWrapping(TextWrapping::Wrap);
        TextBlock note;
        note.Text(L"zslice downloads the file and opens it on a new plate. It does not start a print.");
        note.TextWrapping(TextWrapping::WrapWholeWords);
        note.FontSize(12);
        note.Foreground(TokenBrush(Root(), L"ZsDim"));
        content.Children().Append(name);
        content.Children().Append(from);
        content.Children().Append(note);

        ContentDialog dialog;
        dialog.XamlRoot(Content().XamlRoot());
        dialog.Title(box_value(L"Open this model?"));
        dialog.Content(content);
        dialog.PrimaryButtonText(L"Download and open");
        dialog.CloseButtonText(L"Cancel");
        // Enter must not start a download that the user did not read.
        dialog.DefaultButton(ContentDialogButton::Close);
        ContentDialogResult answer = ContentDialogResult::None;
        bool shown = true;
        try
        {
            answer = co_await dialog.ShowAsync();
        }
        catch (winrt::hresult_error const &)
        {
            shown = false;
        }
        link_asking = false;
        if (!shown)
        {
            ShowToast(L"Close the open dialog, then try the link again.");
            co_return;
        }
        if (answer == ContentDialogResult::Primary && model != nullptr)
            DownloadLink(link);
    }

    void MainWindow::DownloadLink(zs::openlink::ModelLink const &link)
    {
        download_cancel = std::make_shared<zs::http::Cancel>();
        std::wstring shown = link.name.empty() ? std::wstring(L"the model") : link.name;
        ShowBusy(L"Downloading " + shown + L"…");
        auto self = get_strong();
        auto target = queue;
        auto cancel = download_cancel;
        std::thread([self, target, cancel, link, shown] {
            int last = -1;
            auto progress = [&](double done) {
                int percent = (int)(done * 100);
                if (percent == last)
                    return;
                last = percent;
                target.TryEnqueue([self, shown, percent] {
                    if (self->download_cancel != nullptr)
                        self->ShowBusy(L"Downloading " + shown + L" " + std::to_wstring(percent) + L"%");
                });
            };
            auto result = std::make_shared<zs::openlink::Download>(zs::openlink::Fetch(link, cancel, progress));
            target.TryEnqueue([self, result] { self->FinishDownload(*result); });
        }).detach();
    }

    void MainWindow::FinishDownload(zs::openlink::Download const &result)
    {
        download_cancel = nullptr;
        if (model == nullptr || result.cancelled)
            return;
        if (!result.error.empty())
        {
            ShowError(zs::ToWide(result.error));
            return;
        }
        // A project replaces the plates and brings its own printer settings.
        if (zs_project_file_is(reinterpret_cast<uint8_t const *>(result.bytes.data()), result.bytes.size()))
        {
            ShowError(zs::ToWide(zs_link_message(ZS_LINK_PROJECT)));
            return;
        }
        FinishLoad(result.name, result.bytes, true, true);
    }
}
