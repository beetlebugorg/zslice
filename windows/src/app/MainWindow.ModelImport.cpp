// Import a model from a model page or a ZIP file, as in
// linux/src/ui/model-import.c. The rules are in the core (the zs_import_*
// calls) and in docs/internals/model-import.md.
//
// zslice calls no API of a model site. For a page of Printables or
// Thingiverse, the dialog says how to get the ZIP file and offers "Open the
// page". The user downloads the ZIP file there and opens it in zslice. The
// next dialog lists its files, with Cancel as the default button. The checked
// files become parts on a plate, and zs_set_spill puts the parts that do not
// fit on more plates. Nothing here starts a print.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <thread>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Media = Microsoft::UI::Xaml::Media;
using Windows::System::VirtualKey;

namespace
{
    std::wstring SizeText(uint64_t bytes)
    {
        wchar_t text[32];
        if (bytes < 1000)
            swprintf_s(text, L"%llu bytes", (unsigned long long)bytes);
        else if (bytes < 1000 * 1000)
            swprintf_s(text, L"%.1f kB", bytes / 1e3);
        else if (bytes < 1000ull * 1000 * 1000)
            swprintf_s(text, L"%.1f MB", bytes / 1e6);
        else
            swprintf_s(text, L"%.1f GB", bytes / 1e9);
        return text;
    }

    TextBlock Words(std::wstring const &text, double size = 13)
    {
        TextBlock block;
        block.Text(text);
        block.FontSize(size);
        block.TextWrapping(TextWrapping::Wrap);
        return block;
    }
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    // The dialog that is open: one import at a time.
    struct MainWindow::ImportState
    {
        ContentDialog dialog{ nullptr };
        // The address of a page.
        TextBox entry{ nullptr };
        TextBlock note{ nullptr };
        std::function<void()> find;
        zs_import_page page{};
        bool has_page = false;
        // The files of a ZIP file. The list reads its bytes.
        zs_import_list *list = nullptr;
        std::shared_ptr<std::string> zip;
        TextBlock status{ nullptr };
        std::vector<CheckBox> checks;
        bool hook_load = false;

        ~ImportState()
        {
            if (list != nullptr)
                zs_import_list_free(list);
        }
    };

    bool MainWindow::IsZipName(std::wstring const &name)
    {
        return name.size() > 4 && _wcsicmp(name.c_str() + name.size() - 4, L".zip") == 0;
    }

    // The dialog of a page: the address, then how to get the ZIP file.
    winrt::fire_and_forget MainWindow::AskImport(std::wstring text, bool from_link)
    {
        auto lifetime = get_strong();
        if (import_state != nullptr)
        {
            ShowToast(L"Finish the import that is open, then try this one.");
            co_return;
        }
        auto state = std::make_shared<ImportState>();
        import_state = state;

        StackPanel content;
        content.Spacing(10);
        content.Width(460);
        // The last line of a note keeps its descenders.
        content.Padding(ThicknessHelper::FromLengths(0, 0, 0, 6));
        TextBlock ask = Words(L"Paste the address of a model page on Printables or Thingiverse.", 14);
        ask.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        TextBox entry;
        entry.PlaceholderText(L"https://www.printables.com/model/…");
        entry.Text(text);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(entry, L"The address of the model page");
        TextBlock note = Words(L"zslice then says how to get all the files of the model as one ZIP file.", 12.5);
        note.Foreground(TokenBrush(Root(), L"ZsDim"));
        content.Children().Append(ask);
        content.Children().Append(entry);
        content.Children().Append(note);
        state->entry = entry;
        state->note = note;

        ContentDialog dialog;
        dialog.XamlRoot(Content().XamlRoot());
        ThemeDialog(dialog);
        dialog.Title(box_value(L"Import a model"));
        dialog.Content(content);
        dialog.PrimaryButtonText(L"Continue");
        dialog.PrimaryButtonStyle(Application::Current().Resources().Lookup(box_value(L"AccentButtonStyle")).as<Style>());
        dialog.CloseButtonText(L"Cancel");
        dialog.Resources().Insert(box_value(L"ContentDialogMaxWidth"), box_value(620.0));
        state->dialog = dialog;

        // ImportState holds the dialog, so these hold the state weakly.
        std::weak_ptr<ImportState> weak = state;
        state->find = [this, weak] {
            auto s = weak.lock();
            if (s == nullptr)
                return;
            std::string address = zs::ToUtf8(std::wstring(s->entry.Text()));
            s->has_page = zs_import_page_check(address.c_str(), &s->page) == ZS_IMPORT_OK;
            if (s->has_page)
            {
                s->note.Text(zs::ToWide(zs_import_page_text(s->page.site)));
                s->note.Foreground(TokenBrush(Root(), L"ZsDim"));
                s->dialog.PrimaryButtonText(L"Open the page");
            }
            else
            {
                s->note.Text(zs::ToWide(zs_import_message(ZS_IMPORT_NOT_A_PAGE)));
                s->note.Foreground(TokenBrush(Root(), L"ZsWarning"));
                s->dialog.PrimaryButtonText(L"Continue");
            }
        };
        entry.TextChanged([weak](auto &&, auto &&) {
            auto s = weak.lock();
            if (s != nullptr && s->has_page)
            {
                s->has_page = false;
                s->dialog.PrimaryButtonText(L"Continue");
            }
        });
        entry.KeyDown([weak](auto &&, Input::KeyRoutedEventArgs const &e) {
            auto s = weak.lock();
            if (s == nullptr || e.Key() != VirtualKey::Enter)
                return;
            e.Handled(true);
            // Enter never opens a browser: the button does.
            if (!s->has_page)
                s->find();
        });
        dialog.PrimaryButtonClick([weak](auto &&, ContentDialogButtonClickEventArgs const &e) {
            auto s = weak.lock();
            if (s != nullptr && !s->has_page)
            {
                e.Cancel(true);
                s->find();
            }
        });
        if (from_link)
            state->find();
        else if (text.empty())
        {
            // A page address on the clipboard fills the field.
            try
            {
                auto clip = Windows::ApplicationModel::DataTransfer::Clipboard::GetContent();
                if (clip.Contains(Windows::ApplicationModel::DataTransfer::StandardDataFormats::Text()))
                {
                    hstring value = co_await clip.GetTextAsync();
                    zs_import_page page{};
                    if (entry.Text().empty() && zs_import_page_check(zs::ToUtf8(std::wstring(value)).c_str(), &page) == ZS_IMPORT_OK)
                        entry.Text(value);
                }
            }
            catch (winrt::hresult_error const &)
            {
            }
        }

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
        bool open_page = answer == ContentDialogResult::Primary && state->has_page;
        std::wstring url = zs::ToWide(state->page.url);
        import_state = nullptr;
        if (!shown)
            ShowToast(L"Close the open dialog, then try again.");
        else if (open_page)
            ::ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }

    // The dialog of a ZIP file: its files, and the choice before the load.
    winrt::fire_and_forget MainWindow::ImportZip(std::wstring name, std::shared_ptr<std::string> bytes)
    {
        auto lifetime = get_strong();
        if (import_state != nullptr)
        {
            ShowToast(L"Finish the import that is open, then try this one.");
            co_return;
        }
        zs_import_list *list = nullptr;
        int rc = zs_import_list_zip(reinterpret_cast<uint8_t const *>(bytes->data()), bytes->size(), &list);
        if (rc != ZS_IMPORT_OK)
        {
            ShowAlert(L"The ZIP file did not open", zs::ToWide(zs_import_message(rc)));
            co_return;
        }
        auto state = std::make_shared<ImportState>();
        state->list = list;
        state->zip = bytes;
        import_state = state;

        zs_import_info info{};
        zs_import_list_info(list, &info);
        StackPanel content;
        content.Spacing(8);
        content.Width(560);
        std::wstring sub;
        if (info.author != nullptr && info.author[0] != 0)
            sub = L"By " + zs::ToWide(info.author);
        if (info.license != nullptr && info.license[0] != 0)
            sub += (sub.empty() ? L"" : L". ") + std::wstring(L"License: ") + zs::ToWide(info.license);
        if (info.page_url != nullptr && info.page_url[0] != 0)
            sub += (sub.empty() ? L"" : L". ") + std::wstring(L"From ") + zs::ToWide(info.page_url);
        sub += (sub.empty() ? L"" : L". ") + std::wstring(L"The files of the ZIP file");
        TextBlock facts = Words(sub, 12.5);
        facts.Foreground(TokenBrush(Root(), L"ZsDim"));
        content.Children().Append(facts);
        if (info.note != nullptr && info.note[0] != 0)
            content.Children().Append(Words(zs::ToWide(info.note), 12.5));

        StackPanel rows;
        rows.Spacing(4);
        rows.Padding(ThicknessHelper::FromLengths(0, 4, 14, 4));
        std::weak_ptr<ImportState> weak = state;
        auto update = [this, weak] {
            auto s = weak.lock();
            if (s == nullptr || s->status == nullptr)
                return;
            size_t files = 0;
            uint64_t size = 0;
            int ready = zs_import_ready(s->list, &files, &size);
            s->dialog.IsPrimaryButtonEnabled(ready == ZS_IMPORT_OK);
            if (ready != ZS_IMPORT_OK)
            {
                s->status.Text(zs::ToWide(zs_import_message(ready)));
                s->status.Foreground(TokenBrush(Root(), ready == ZS_IMPORT_NOTHING_CHECKED ? L"ZsFg" : L"ZsWarning"));
                return;
            }
            s->status.Text(std::to_wstring(files) + (files == 1 ? L" file, " : L" files, ") + SizeText(size) +
                           L". zslice puts the parts of the checked files on plates. It does not start a print.");
            s->status.Foreground(TokenBrush(Root(), L"ZsFg"));
        };
        std::string group;
        for (size_t i = 0, n = zs_import_count(list); i < n; i++)
        {
            zs_import_file f{};
            if (zs_import_file_get(list, i, &f) != ZS_IMPORT_OK)
                continue;
            if (i == 0 || group != f.kind_label)
            {
                group = f.kind_label;
                TextBlock heading = Words(zs::ToWide(group), 13);
                heading.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
                heading.Margin(ThicknessHelper::FromLengths(0, i > 0 ? 10 : 0, 0, 0));
                rows.Children().Append(heading);
            }
            StackPanel texts;
            std::wstring file_name = zs::ToWide(f.name);
            TextBlock title = Words(file_name);
            if (f.can_load == 0)
                title.Opacity(0.6);
            texts.Children().Append(title);
            std::wstring detail = f.kind == ZS_IMPORT_KIND_OTHER ? L"" : zs::ToWide(f.kind_label);
            if (f.size > 0)
                detail += (detail.empty() ? L"" : L", ") + SizeText(f.size);
            if (f.plates > 1)
                detail += L", " + std::to_wstring(f.plates) + L" plates";
            if (f.folder != nullptr && f.folder[0] != 0)
                detail += L". In the folder " + zs::ToWide(f.folder);
            if (f.note != nullptr && f.note[0] != 0)
                detail += (detail.empty() ? L"" : L". ") + zs::ToWide(f.note);
            if (!detail.empty())
            {
                TextBlock more = Words(detail, 12);
                more.Foreground(TokenBrush(Root(), L"ZsDim"));
                texts.Children().Append(more);
            }
            CheckBox check;
            check.Content(texts);
            check.IsChecked(f.checked != 0);
            check.IsEnabled(f.can_load != 0);
            check.HorizontalAlignment(HorizontalAlignment::Stretch);
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(check, file_name);
            auto toggled = [weak, update, i, check](auto &&, auto &&) {
                auto s = weak.lock();
                if (s == nullptr)
                    return;
                zs_import_check(s->list, i, check.IsChecked() != nullptr && check.IsChecked().Value() ? 1 : 0);
                update();
            };
            check.Checked(toggled);
            check.Unchecked(toggled);
            state->checks.push_back(check);
            rows.Children().Append(check);
        }
        ScrollViewer scroll;
        scroll.MaxHeight(380);
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        scroll.Content(rows);
        content.Children().Append(scroll);
        TextBlock status = Words(L"", 12.5);
        state->status = status;
        content.Children().Append(status);

        ContentDialog dialog;
        dialog.XamlRoot(Content().XamlRoot());
        ThemeDialog(dialog);
        dialog.Title(box_value(info.title != nullptr && info.title[0] != 0 ? zs::ToWide(info.title) : name));
        dialog.Content(content);
        dialog.PrimaryButtonText(L"Load");
        dialog.CloseButtonText(L"Cancel");
        // Enter must not start a load that the user did not read.
        dialog.DefaultButton(ContentDialogButton::Close);
        dialog.Resources().Insert(box_value(L"ContentDialogMaxWidth"), box_value(680.0));
        state->dialog = dialog;
        update();

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
        import_state = nullptr;
        if (!shown)
            ShowToast(L"Close the open dialog, then open the ZIP file again.");
        else if ((answer == ContentDialogResult::Primary || state->hook_load) && model != nullptr)
            RunImport(state);
    }

    // The bytes of each checked file, off the UI thread.
    void MainWindow::RunImport(std::shared_ptr<ImportState> state)
    {
        size_t total = 0;
        if (zs_import_ready(state->list, &total, nullptr) != ZS_IMPORT_OK)
            return;
        ShowBusy(L"Reading the files of the ZIP file…");
        auto self = get_strong();
        auto target = queue;
        std::thread([self, target, state, total] {
            auto files = std::make_shared<std::vector<std::pair<std::wstring, std::string>>>();
            auto errors = std::make_shared<std::wstring>();
            auto const *zip = reinterpret_cast<uint8_t const *>(state->zip->data());
            size_t index = 0;
            for (size_t i = 0, n = zs_import_count(state->list); i < n; i++)
            {
                zs_import_file f{};
                if (zs_import_file_get(state->list, i, &f) != ZS_IMPORT_OK || f.checked == 0)
                    continue;
                index++;
                std::wstring name = zs::ToWide(f.name);
                target.TryEnqueue([self, name, index, total] {
                    self->ShowBusy(L"File " + std::to_wstring(index) + L" of " + std::to_wstring(total) + L": " + name);
                });
                uint8_t *out = nullptr;
                size_t len = 0;
                if (zs_import_zip_file(state->list, zip, state->zip->size(), i, &out, &len) != ZS_IMPORT_OK)
                {
                    *errors += name + L": " + zs::ToWide(zs_import_message(ZS_IMPORT_NOT_ZIP)) + L"\n";
                    continue;
                }
                // A project replaces the plates, so an import never opens one.
                if (zs_project_file_is(out, len))
                    *errors += name + L": " + zs::ToWide(zs_link_message(ZS_LINK_PROJECT)) + L"\n";
                else
                    files->emplace_back(name, std::string(reinterpret_cast<char const *>(out), len));
                zs_buffer_free(out, len);
            }
            target.TryEnqueue([self, files, errors, total] { self->FinishImport(*files, *errors, total); });
        }).detach();
    }

    void MainWindow::FinishImport(std::vector<std::pair<std::wstring, std::string>> const &files, std::wstring errors, size_t total)
    {
        if (model == nullptr)
            return;
        ShowBusy(L"");
        size_t loaded = 0;
        ptrdiff_t plates = 0;
        if (!files.empty())
        {
            // An import replaces no work on this plate.
            if (zs_app_part_count(model->Active()) > 0 && model->AddPlate())
                ShowPlate();
            ProjectFileOpening(false, true);
            RangeClose();
            frame_next = true;
            for (auto const &[name, bytes] : files)
            {
                zs_app *app = model->Active();
                if (zs_app_part_count(app) == 0)
                {
                    std::string message;
                    if (model->Load(name, bytes, message) == ZS_OK)
                        loaded++;
                    else
                        errors += name + L": " + zs::ToWide(message) + L"\n";
                    continue;
                }
                ptrdiff_t part = zs_app_add_stl(app, zs::ToUtf8(name).c_str(), bytes.data(), bytes.size());
                if (part >= 0)
                    loaded++;
                else
                    errors += name + L": " + zs::ToWide(zs_status_message((int)-part)) + L"\n";
            }
            if (loaded > 0)
            {
                plates = 1;
                ptrdiff_t more = zs_set_spill(model->Set(), model->ActivePlate());
                if (more > 0)
                    plates += more;
                for (size_t i = 0; i < model->PlateCount(); i++)
                    zs_set_changed(model->Set(), i);
                EmptyHint().Visibility(Visibility::Collapsed);
                NoteChange();
                ShowPlate();
                MarkHistorySaved();
                history_mark_late = true;
            }
            else
            {
                frame_next = false;
            }
        }
        zs::Log("shell: import: %zu of %zu files on %zd plates\n", loaded, total, plates);
        if (!errors.empty())
        {
            StackPanel lines;
            lines.Children().Append(Words(errors));
            ShowDialog(loaded > 0 ? hstring(std::to_wstring(loaded) + L" of " + std::to_wstring(total) + L" files loaded") : hstring(L"No file loaded"), lines);
        }
        else if (loaded > 0)
        {
            ShowToast(std::to_wstring(loaded) + (loaded == 1 ? L" file on " : L" files on ") + std::to_wstring(plates) + (plates == 1 ? L" plate." : L" plates."));
        }
    }

#ifdef ZS_DEV_HOOKS
    // miask [text], migo, mizip path, micheck i 0|1, miok, micancel, milog.
    // No step opens a browser.
    bool MainWindow::RunModelImportStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        if (verb.rfind(L"mi", 0) != 0 || model == nullptr)
            return false;
        auto s = import_state;
        if (verb == L"miask")
            AskImport(words.empty() ? std::wstring() : words[0]);
        else if (verb == L"migo" && s != nullptr && s->find)
            s->find();
        else if (verb == L"mizip" && !words.empty())
            LoadPath(words[0], true);
        else if (verb == L"micheck" && words.size() >= 2 && s != nullptr && (size_t)_wtoi(words[0].c_str()) < s->checks.size())
            s->checks[(size_t)_wtoi(words[0].c_str())].IsChecked(_wtoi(words[1].c_str()) != 0);
        else if (verb == L"miok" && s != nullptr)
        {
            s->hook_load = true;
            s->dialog.Hide();
        }
        else if (verb == L"micancel" && s != nullptr)
            s->dialog.Hide();
        else if (verb == L"milog")
        {
            std::string files;
            if (s != nullptr && !s->checks.empty())
                files = std::string("first box ") + (s->checks[0].IsChecked() == nullptr ? "null" : s->checks[0].IsChecked().Value() ? "true" : "false") + " three " + (s->checks[0].IsThreeState() ? "1" : "0") + " | ";
            if (s != nullptr && s->list != nullptr)
                for (size_t i = 0, n = zs_import_count(s->list); i < n; i++)
                {
                    zs_import_file f{};
                    if (zs_import_file_get(s->list, i, &f) == ZS_IMPORT_OK)
                        files += std::string(f.name) + "[" + f.kind_label + " load " + std::to_string(f.can_load) + " on " + std::to_string(f.checked) + "] ";
                }
            zs::Log("dev: import open %d | page %d url '%s' button '%s' | note '%s' | status '%s' load on %d | files %s| plates %zu parts %zu\n", s != nullptr ? 1 : 0, s != nullptr && s->has_page ? 1 : 0,
                    s != nullptr ? s->page.url : "", s != nullptr ? to_string(s->dialog.PrimaryButtonText()).c_str() : "",
                    s != nullptr && s->note != nullptr ? to_string(s->note.Text()).c_str() : "", s != nullptr && s->status != nullptr ? to_string(s->status.Text()).c_str() : "",
                    s != nullptr && s->dialog.IsPrimaryButtonEnabled() ? 1 : 0, files.c_str(), model->PlateCount(), zs_app_part_count(model->Active()));
        }
        else
            return false;
        return true;
    }
#endif
}
