// "Import a profile…": a profile of PrusaSlicer, OrcaSlicer, Bambu Studio, or
// Cura. The core reads the file (src/import_profile.zig). Its values become
// changes of the settings of the active plate, as one step of the history,
// and a dialog shows the report: the values that zslice set, the values that
// went into the limits of their setting, and the keys with no zslice setting.
//
// The behavior follows on_import in linux/src/ui/profile-menus.c,
// zg_model_import_profile in linux/src/model/app-model.c, and importProfile
// in web/app/app.js. The file formats and their sources are in
// docs/references/prusaslicer.md, orcaslicer.md, and cura.md.
//
// This file also has the dialog that the report and the calibration share.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

#include <thread>

#ifdef ZS_DEV_HOOKS
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#endif

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Storage = Windows::Storage;
using Windows::System::VirtualKey;

namespace
{
    std::vector<std::string> SplitFields(std::string const &line)
    {
        std::vector<std::string> out;
        size_t from = 0;
        for (;;)
        {
            size_t to = line.find('\t', from);
            out.push_back(line.substr(from, to == std::string::npos ? std::string::npos : to - from));
            if (to == std::string::npos)
                return out;
            from = to + 1;
        }
    }

    struct ReportRow
    {
        std::wstring cells[3];
    };

    std::wstring Pair(std::string const &key, std::string const &value)
    {
        return zs::ToWide(key) + L" = " + zs::ToWide(value);
    }

    // One section of the report: its title with the count, then a table
    // with equal columns. Long values wrap.
    void AddSection(StackPanel const &body, std::wstring const &title, std::vector<ReportRow> const &rows, int columns)
    {
        if (rows.empty())
            return;
        TextBlock head;
        head.Text(title + L" (" + std::to_wstring(rows.size()) + L")");
        head.FontSize(13);
        head.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        head.TextWrapping(TextWrapping::Wrap);
        head.Margin(ThicknessHelper::FromLengths(0, 10, 0, 4));
        body.Children().Append(head);
        Grid table;
        for (int c = 0; c < columns; c++)
        {
            ColumnDefinition column;
            column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            table.ColumnDefinitions().Append(column);
        }
        for (size_t r = 0; r < rows.size(); r++)
        {
            RowDefinition row;
            row.Height(GridLengthHelper::Auto());
            table.RowDefinitions().Append(row);
            for (int c = 0; c < columns; c++)
            {
                if (rows[r].cells[c].empty())
                    continue;
                TextBlock cell;
                cell.Text(rows[r].cells[c]);
                cell.FontSize(12);
                cell.TextWrapping(TextWrapping::Wrap);
                cell.IsTextSelectionEnabled(true);
                cell.Margin(ThicknessHelper::FromLengths(0, 2, 12, 2));
                Grid::SetRow(cell, (int32_t)r);
                Grid::SetColumn(cell, c);
                table.Children().Append(cell);
            }
        }
        body.Children().Append(table);
    }
}

namespace winrt::ZSlice::implementation
{
    Microsoft::UI::Xaml::Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    // A dialog over the window with the colors of the dialogs of the other
    // apps. One is open at a time. The keys stay in the dialog, so a key of
    // a tool does not change the plate behind it.
    std::shared_ptr<OverlayPanel> MainWindow::PrintersUi::ShowInfoPanel(std::wstring const &title, double width, UIElement const &content, Control const &first)
    {
        if (auto open = info_panel)
            ClosePanel(open);
        auto panel = OpenPanel(title, width, 0, content);
        info_panel = panel;
        // The focus goes back to the view, so that the keys of the tools work
        // and Space presses no button of the header.
        panel->closed = [this] {
            info_panel = nullptr;
            w.ViewPanel().Focus(FocusState::Programmatic);
        };
        panel->card.CornerRadius(CornerRadiusHelper::FromUniformRadius(12));
        double room = w.Root().ActualHeight();
        if (room > 0)
            panel->card.MaxHeight(std::min(860.0, room * 0.8));
        auto paint = [this, root = make_weak(panel->root), card = make_weak(panel->card)] {
            auto r = root.get();
            auto c = card.get();
            if (r == nullptr || c == nullptr)
                return;
            r.Background(TokenBrush(w.Root(), L"ZsShade"));
            c.Background(TokenBrush(w.Root(), L"ZsDialog"));
            c.BorderBrush(TokenBrush(w.Root(), L"ZsPopoverBorder"));
        };
        paint();
        panel->root.ActualThemeChanged([paint](auto &&, auto &&) { paint(); });
        panel->root.KeyDown([](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() != VirtualKey::Tab)
                e.Handled(true);
        });
        // A menu gives the focus back as it closes, so the focus moves after it.
        panel->root.Loaded([this, target = make_weak(first)](auto &&, auto &&) {
            w.queue.TryEnqueue(Microsoft::UI::Dispatching::DispatcherQueuePriority::Low, [target] {
                if (auto control = target.get())
                    control.Focus(FocusState::Programmatic);
            });
        });
        return panel;
    }

    winrt::fire_and_forget MainWindow::PickProfile()
    {
        auto lifetime = get_strong();
#ifdef ZS_DEV_HOOKS
        // A test has no file dialog.
        wchar_t hook[MAX_PATH];
        DWORD n = ::GetEnvironmentVariableW(L"ZSLICE_IMPORT_FILE", hook, MAX_PATH);
        if (n > 0 && n < MAX_PATH)
        {
            ImportProfilePath(std::wstring(hook, n));
            co_return;
        }
#endif
        Storage::Pickers::FileOpenPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(hwnd);
        for (wchar_t const *type : { L".ini", L".json", L".3mf", L".curaprofile", L".cfg", L".gcode" })
            picker.FileTypeFilter().Append(type);
        picker.CommitButtonText(L"Import");
        auto file = co_await picker.PickSingleFileAsync();
        if (file != nullptr)
            ImportProfilePath(std::wstring(file.Path()));
    }

    void MainWindow::ImportProfilePath(std::wstring path)
    {
        if (model == nullptr)
            return;
        size_t at = path.find_last_of(L"\\/");
        ShowBusy(L"Reading " + (at == std::wstring::npos ? path : path.substr(at + 1)));
        // A 3MF project can be large: it reads off the UI thread.
        auto self = get_strong();
        auto target = queue;
        std::thread([self, target, path] {
            auto bytes = std::make_shared<std::string>();
            bool read = zs::Model::ReadFile(path, *bytes);
            target.TryEnqueue([self, path, bytes, read] { self->FinishImport(path, *bytes, read); });
        }).detach();
    }

    void MainWindow::FinishImport(std::wstring const &path, std::string const &bytes, bool read)
    {
        if (model == nullptr)
            return;
        size_t at = path.find_last_of(L"\\/");
        std::wstring name = at == std::wstring::npos ? path : path.substr(at + 1);
        if (!read)
        {
            ShowError(L"Could not read " + name);
            return;
        }
        ShowBusy(L"");
        // An edit before the import stays a step of its own.
        if (history_timer.IsRunning())
        {
            history_timer.Stop();
            model->HistoryCommit();
        }
        zs_app *app = model->Active();
        int rc = zs_app_profile_import(app, zs::ToUtf8(name).c_str(), reinterpret_cast<uint8_t const *>(bytes.data()), bytes.size());
        if (rc == ZS_INVALID_VALUE)
        {
            ShowError(L"The file is not a profile of PrusaSlicer, OrcaSlicer, Bambu Studio, or Cura.");
            return;
        }
        if (rc != ZS_OK)
        {
            ShowError(L"The profile did not import (status " + std::to_wstring(rc) + L").");
            return;
        }
        std::string report;
        size_t len = 0;
        if (zs_app_profile_import_report(app, nullptr, 0, &len) == ZS_OK)
        {
            report.assign(len + 1, '\0');
            if (zs_app_profile_import_report(app, report.data(), report.size(), &len) == ZS_OK)
                report.resize(len);
            else
                report.clear();
        }
        model->HistoryCommit();
        RefreshSettingValues();
        RefreshHistoryButtons();
        RefreshFilamentTools();
        PrintersNoteChange();
        PrintersOnPlate();
        CheckFall();
        // An empty plate has no slice to show the new bed.
        if (zs_app_part_count(app) > 0)
            model->RequestSlice();
        else
            ShowPlate();
        ShowImportReport(name, report);
    }

    void MainWindow::ShowImportReport(std::wstring const &file, std::string const &report)
    {
        if (printers == nullptr)
            return;
        std::wstring format = L"Profile";
        std::vector<ReportRow> set, clamped, unused;
        size_t from = 0;
        while (from < report.size())
        {
            size_t to = report.find('\n', from);
            if (to == std::string::npos)
                to = report.size();
            auto f = SplitFields(report.substr(from, to - from));
            from = to + 1;
            if (f.size() >= 2 && f[0] == "format")
                format = zs::ToWide(f[1]);
            else if (f.size() >= 5 && f[0] == "set")
                set.push_back({ { Pair(f[1], f[2]), Pair(f[3], f[4]), L"" } });
            else if (f.size() >= 6 && f[0] == "near")
                set.push_back({ { Pair(f[1], f[2]), Pair(f[3], f[4]), zs::ToWide(f[5]) } });
            else if (f.size() >= 6 && f[0] == "clamp")
                clamped.push_back({ { Pair(f[1], f[2]), Pair(f[3], f[4]), L"wanted " + zs::ToWide(f[5]) } });
            else if (f.size() >= 4 && f[0] == "unused")
                unused.push_back({ { Pair(f[1], f[2]), zs::ToWide(f[3]), L"" } });
        }

        StackPanel list;
        list.Padding(ThicknessHelper::FromLengths(0, 0, 14, 0));
        AddSection(list, L"Set", set, 3);
        AddSection(list, L"Clamped to the limits of the setting", clamped, 3);
        AddSection(list, L"Not imported", unused, 2);

        ScrollViewer scroll;
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        scroll.Content(list);
        Button close = ui::TextButton(L"Close");
        close.HorizontalAlignment(HorizontalAlignment::Right);
        close.Margin(ThicknessHelper::FromLengths(0, 10, 0, 0));
        Grid body;
        body.Padding(ThicknessHelper::FromLengths(16, 0, 16, 14));
        RowDefinition top, bottom;
        top.Height(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        bottom.Height(GridLengthHelper::Auto());
        body.RowDefinitions().Append(top);
        body.RowDefinitions().Append(bottom);
        body.Children().Append(scroll);
        Grid::SetRow(close, 1);
        body.Children().Append(close);

        auto panel = printers->ShowInfoPanel(format + L": " + file, 760, body, close);
        std::weak_ptr<OverlayPanel> weak = panel;
        close.Click([this, weak](auto &&, auto &&) {
            if (auto p = weak.lock(); p != nullptr && printers != nullptr)
                printers->ClosePanel(p);
        });
    }

#ifdef ZS_DEV_HOOKS
    // importmenu                 writes the import items of the menus
    // importrun quality|printer|search   runs the item of that menu
    // importfile path            the import, with no file dialog
    // importlog                  writes the state of the import
    bool MainWindow::RunImportStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        namespace Peers = Microsoft::UI::Xaml::Automation::Peers;
        namespace Provider = Microsoft::UI::Xaml::Automation::Provider;
        std::wstring const import_text = L"Import a profile…";
        if (verb == L"importmenu")
        {
            printers->FillPrinterMenu();
            printers->FillQuality();
            int in_printer = 0, in_quality = 0, in_search = 0;
            for (auto const &item : printers->printer_menu.Items())
                if (auto text = item.try_as<MenuFlyoutItem>(); text != nullptr && text.Text() == import_text)
                    in_printer++;
            for (auto const &child : printers->quality_panel.Children())
                if (auto button = child.try_as<Button>(); button != nullptr && unbox_value_or<hstring>(button.Content(), L"") == import_text)
                    in_quality++;
            for (auto const &action : SearchActions())
                if (action.label == import_text)
                    in_search++;
            zs::Log("dev: import items: printer %d quality %d search %d\n", in_printer, in_quality, in_search);
        }
        else if (verb == L"importrun" && !words.empty())
        {
            bool ran = false;
            if (words[0] == L"printer")
            {
                printers->FillPrinterMenu();
                for (auto const &item : printers->printer_menu.Items())
                    if (auto text = item.try_as<MenuFlyoutItem>(); text != nullptr && text.Text() == import_text)
                    {
                        Peers::MenuFlyoutItemAutomationPeer(text).as<Provider::IInvokeProvider>().Invoke();
                        ran = true;
                    }
            }
            else if (words[0] == L"quality")
            {
                printers->FillQuality();
                for (auto const &child : printers->quality_panel.Children())
                    if (auto button = child.try_as<Button>(); button != nullptr && unbox_value_or<hstring>(button.Content(), L"") == import_text)
                    {
                        Peers::ButtonAutomationPeer(button).as<Provider::IInvokeProvider>().Invoke();
                        ran = true;
                    }
            }
            else
            {
                for (auto const &action : SearchActions())
                    if (action.label == import_text)
                    {
                        action.run();
                        ran = true;
                    }
            }
            zs::Log("dev: import item %s\n", ran ? "ran" : "not found");
        }
        else if (verb == L"importfile" && !words.empty())
        {
            ImportProfilePath(words[0]);
        }
        else if (verb == L"importlog")
        {
            zs_app *app = model->Active();
            size_t len = 0;
            zs_app_profile_import_report(app, nullptr, 0, &len);
            std::string report(len + 1, '\0');
            zs_app_profile_import_report(app, report.data(), report.size(), &len);
            report.resize(len);
            zs::Log("dev: import report %zu bytes, %zu lines, dialog %d, history %zu now %zu, state %d draft %d, layer height %s, walls %s, infill %s, focus %s\n", len,
                    (size_t)std::count(report.begin(), report.end(), '\n'), printers->info_panel != nullptr ? 1 : 0, zs_app_history_count(app), zs_app_history_current(app),
                    zs_app_state(app), model->IsDraft() ? 1 : 0, model->GetSetting("project.layer_height").c_str(), model->GetSetting("project.wall_count").c_str(),
                    model->GetSetting("project.infill_density").c_str(),
                    to_string(get_class_name(Input::FocusManager::GetFocusedElement(Content().XamlRoot()))).c_str());
        }
        else
        {
            return false;
        }
        return true;
    }
#endif
}
