// The main menu, the sheet of the keyboard shortcuts, Licenses, About, and
// the theme. The items and words follow the GTK shell
// (linux/src/ui/window.c and shortcuts.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace
{
    struct Key
    {
        char const *keys, *what;
    };
    struct Group
    {
        char const *group;
        Key keys[36];
    };

#include "ShortcutsTable.inc"

    TextBlock Line(hstring const &text, double size = 13, bool bold = false)
    {
        TextBlock t;
        t.Text(text);
        t.FontSize(size);
        t.TextWrapping(TextWrapping::WrapWholeWords);
        if (bold)
            t.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        return t;
    }
}

namespace winrt::ZSlice::implementation
{
    void MainWindow::WireMenu()
    {
        auto add = [this](hstring const &text, auto const &action) {
            MenuFlyoutItem item;
            item.Text(text);
            item.Click([action](auto &&, auto &&) { action(); });
            MainMenu().Items().Append(item);
            return item;
        };
        auto line = [this] { MainMenu().Items().Append(MenuFlyoutSeparator{}); };

        menu_undo = add(L"Undo", [this] {
            if (model != nullptr)
            {
                history_timer.Stop();
                AfterRestore(model->Undo());
            }
        });
        menu_redo = add(L"Redo", [this] {
            if (model != nullptr)
            {
                history_timer.Stop();
                AfterRestore(model->Redo());
            }
        });
        line();
        add(L"Save this plate as 3MF…", [this] {
            if (printers != nullptr)
                printers->SavePlate3mf();
        });
        add(L"Save project (all plates)…", [this] {
            if (printers != nullptr)
                printers->SaveProject();
        });
        add(L"Send all plates", [this] {
            if (printers != nullptr)
                printers->SendAll();
        });
        add(L"Export all plates…", [this] {
            if (printers != nullptr)
                printers->ExportAll();
        });
        line();
        add(L"Smart placement", [this] {
            if (model != nullptr && zs_app_part_count(model->Active()) > 0)
            {
                if (!zs_app_plate_smart_place(model->Active()))
                    ShowToast(L"Not all parts fit on the bed.");
                PlateEdited();
            }
        });
        add(L"Arrange the plate", [this] {
            if (model != nullptr && zs_app_part_count(model->Active()) > 0)
            {
                if (!zs_app_plate_arrange(model->Active()))
                    ShowToast(L"Not all parts fit on the bed.");
                PlateEdited();
            }
        });
        add(L"Clear the plate", [this] {
            if (model != nullptr)
            {
                ClearSelection();
                zs_app_plate_clear(model->Active());
                PlateEdited();
            }
        });
        add(L"Remove this plate", [this] {
            if (model != nullptr && model->RemovePlate(model->ActivePlate()))
                ShowPlate();
        });
        AddCalibrateMenu();
        add(L"Compare with Cura…", [this] { ShowCuraCompare(); });
        line();
        add(L"Printers", [this] {
            if (printers != nullptr)
                printers->ShowPage(true);
        });
        add(L"History", [this] { HistoryFlyout().ShowAt(HistoryButton()); });
        AddProjectMenuItems();
        line();
        menu_bed = ToggleMenuFlyoutItem{};
        menu_bed.Text(L"Hide the bed");
        menu_bed.Click([this](auto &&, auto &&) { ToggleBed(); });
        MainMenu().Items().Append(menu_bed);
        menu_2d = ToggleMenuFlyoutItem{};
        menu_2d.Text(L"2D view");
        menu_2d.Click([this](auto &&, auto &&) { Set2D(!show_2d); });
        MainMenu().Items().Append(menu_2d);
        line();
        add(L"Keyboard shortcuts", [this] { ShowShortcuts(); });
        add(L"Preferences", [this] { ShowPreferences(); }).KeyboardAcceleratorTextOverride(L"Ctrl+,");
        add(L"Licenses", [this] { ShowLicenses(); });
        add(L"About zslice", [this] { ShowAbout(); });
        MainMenu().Opening([this](auto &&, auto &&) {
            if (model != nullptr)
            {
                zs_app *app = model->Active();
                menu_undo.IsEnabled(zs_app_history_current(app) > 0 || zs_app_history_pending(app) != 0);
                menu_redo.IsEnabled(zs_app_history_current(app) + 1 < zs_app_history_count(app));
            }
            menu_bed.IsChecked(bed_hidden);
            menu_2d.IsChecked(show_2d);
            RefreshProjectMenu();
        });

        // The theme follows the system, or the choice in Preferences.
        Root().ActualThemeChanged([this](auto &&, auto &&) { ApplyTheme(); });
        WirePreferences();

        EmptyOpen().Click([this](auto &&, auto &&) { PickFile(); });
        toast_timer = queue.CreateTimer();
        toast_timer.IsRepeating(false);
        toast_timer.Interval(std::chrono::seconds(4));
        toast_timer.Tick([this](auto &&, auto &&) { ToastCard().Visibility(Visibility::Collapsed); });
    }

    void MainWindow::ShowToast(winrt::param::hstring const &text)
    {
        ToastText().Text(text);
        ToastCard().Visibility(Visibility::Visible);
        toast_timer.Stop();
        toast_timer.Start();
    }

    void MainWindow::ApplyTheme()
    {
        PreferencesThemeChanged();
        if (view == nullptr || model == nullptr)
            return;
        bool dark = Root().ActualTheme() == ElementTheme::Dark;
        zs_view_set_dark(view, dark ? 1 : 0);
        // The rows of the search take their colors again.
        if (search_open)
            FillSearch();
        // The marks of the timeline take their colors again.
        if (HistoryFlyout().IsOpen())
            FillHistoryList();
        // The view takes new colors from a load.
        if (zs_app_state(model->Active()) == ZS_STATE_DONE)
            ShowSlice();
        RequestDraw();
    }

    void MainWindow::ShowDialog(hstring const &title, UIElement const &content)
    {
        ContentDialog dialog;
        dialog.XamlRoot(Content().XamlRoot());
        ThemeDialog(dialog);
        dialog.Title(box_value(title));
        ScrollViewer scroll;
        scroll.MaxHeight(560);
        scroll.Content(content);
        dialog.Content(scroll);
        dialog.CloseButtonText(L"Close");
        dialog.Resources().Insert(box_value(L"ContentDialogMaxWidth"), box_value(980.0));
        dialog.ShowAsync();
    }

    void MainWindow::ShowShortcuts()
    {
        // Two columns, the keys in 170 px.
        Grid columns;
        columns.ColumnSpacing(28);
        ColumnDefinition left, right;
        left.Width(GridLengthHelper::FromValueAndType(430, GridUnitType::Pixel));
        right.Width(GridLengthHelper::FromValueAndType(430, GridUnitType::Pixel));
        columns.ColumnDefinitions().Append(left);
        columns.ColumnDefinitions().Append(right);
        StackPanel column_a, column_b;
        column_a.Spacing(3);
        column_b.Spacing(3);
        size_t total = 0;
        for (auto const &group : shortcuts)
        {
            total += 2;
            for (Key const *k = group.keys; k->keys != nullptr; k++)
                total++;
        }
        size_t done = 0;
        for (auto const &group : shortcuts)
        {
            StackPanel &target = done < total / 2 ? column_a : column_b;
            auto heading = Line(to_hstring(group.group), 14, true);
            heading.Margin(ThicknessHelper::FromLengths(0, 10, 0, 3));
            target.Children().Append(heading);
            done += 2;
            for (Key const *k = group.keys; k->keys != nullptr; k++, done++)
            {
                Grid row;
                row.ColumnSpacing(8);
                ColumnDefinition keys, what;
                keys.Width(GridLengthHelper::FromValueAndType(170, GridUnitType::Pixel));
                what.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                row.ColumnDefinitions().Append(keys);
                row.ColumnDefinitions().Append(what);
                auto key_text = Line(to_hstring(k->keys), 12, true);
                row.Children().Append(key_text);
                auto what_text = Line(to_hstring(k->what), 12);
                Grid::SetColumn(what_text, 1);
                row.Children().Append(what_text);
                target.Children().Append(row);
            }
        }
        columns.Children().Append(column_a);
        Grid::SetColumn(column_b, 1);
        columns.Children().Append(column_b);
        ShowDialog(L"Keyboard shortcuts", columns);
    }

    void MainWindow::ShowLicenses()
    {
        StackPanel list;
        list.Spacing(4);
        list.Width(720);
        auto note = Line(L"zslice is free software under the AGPL-3.0-or-later. The app also uses the Windows App SDK and C++/WinRT (MIT).", 12);
        note.Margin(ThicknessHelper::FromLengths(0, 0, 0, 6));
        list.Children().Append(note);
        size_t n = zs_license_count();
        for (size_t i = 0; i < n; i++)
        {
            zs_license license{};
            if (zs_license_get(i, &license) != ZS_OK)
                continue;
            Expander item;
            item.HorizontalAlignment(HorizontalAlignment::Stretch);
            item.HorizontalContentAlignment(HorizontalAlignment::Stretch);
            item.Header(box_value(to_hstring(license.name) + L" (" + to_hstring(license.license) + L")"));
            // The text is long: it goes in when the item opens.
            std::string text = license.text != nullptr ? license.text : "";
            item.Expanding([text](Expander const &self, auto &&) {
                if (self.Content() != nullptr)
                    return;
                TextBox body;
                body.IsReadOnly(true);
                body.AcceptsReturn(true);
                body.TextWrapping(TextWrapping::Wrap);
                body.FontSize(11);
                body.MaxHeight(320);
                body.Text(to_hstring(text));
                self.Content(body);
            });
            list.Children().Append(item);
        }
        ShowDialog(L"Licenses", list);
    }

    void MainWindow::ShowAbout()
    {
        StackPanel page;
        page.Spacing(6);
        page.Width(380);
        page.Children().Append(Line(L"zslice " + to_hstring(zs_version()), 18, true));
        page.Children().Append(Line(L"A 3D printing slicer, written from scratch.", 13));
        page.Children().Append(Line(L"Free software under the AGPL-3.0-or-later.", 12));
        HyperlinkButton link;
        link.Content(box_value(L"github.com/beetlebugorg/zslice"));
        link.NavigateUri(Windows::Foundation::Uri(L"https://github.com/beetlebugorg/zslice"));
        link.Padding(ThicknessHelper::FromUniformLength(0));
        page.Children().Append(link);
        ShowDialog(L"About zslice", page);
    }
}
