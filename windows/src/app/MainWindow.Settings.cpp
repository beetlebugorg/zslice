// The settings pane and the history of the main window.
//
// The pane is built from the descriptions of the core (zs_setting_get_info):
// the sections, then the settings of a section, then one setting with its
// source, its default, its formula, and its help. The search is the search
// of the core. The behavior follows the GTK shell
// (linux/src/ui/settings-browser.c and linux/src/model/app-model.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Media = Microsoft::UI::Xaml::Media;
using Windows::System::VirtualKey;

namespace
{
    struct GroupTitle
    {
        char const *group;
        wchar_t const *title;
    };
    GroupTitle const group_titles[] = {
        { "project", L"Part" },
        { "filament", L"Filament" },
        { "machine", L"Printer" },
        { "engine", L"Engine" },
    };

    wchar_t const *TitleOf(char const *group)
    {
        for (auto const &g : group_titles)
            if (strcmp(g.group, group) == 0)
                return g.title;
        return L"";
    }

    bool FindSetting(char const *name, zs_setting_info &out)
    {
        size_t n = zs_setting_count();
        for (size_t i = 0; i < n; i++)
            if (zs_setting_get_info(i, &out) == ZS_OK && strcmp(out.name, name) == 0)
                return true;
        return false;
    }

    // The help text has `code` marks.
    std::wstring PlainDoc(char const *doc)
    {
        std::wstring text = zs::ToWide(doc != nullptr ? doc : "");
        text.erase(std::remove(text.begin(), text.end(), L'`'), text.end());
        return text;
    }

    std::wstring DisplayValue(char const *name, std::string const &value, bool with_unit)
    {
        size_t len = 0;
        if (zs_setting_display(name, value.c_str(), with_unit ? 1 : 0, nullptr, 0, &len) != ZS_OK)
            return zs::ToWide(value);
        std::string text(len + 1, '\0');
        if (zs_setting_display(name, value.c_str(), with_unit ? 1 : 0, text.data(), text.size(), &len) != ZS_OK)
            return zs::ToWide(value);
        text.resize(len);
        return zs::ToWide(text);
    }

    std::vector<std::string> SplitLines(char const *text)
    {
        std::vector<std::string> lines;
        char const *c = text != nullptr ? text : "";
        while (*c != 0)
        {
            char const *end = strchr(c, '\n');
            size_t n = end != nullptr ? (size_t)(end - c) : strlen(c);
            if (n > 0)
                lines.emplace_back(c, n);
            if (end == nullptr)
                break;
            c = end + 1;
        }
        return lines;
    }

    Media::SolidColorBrush Brush(uint8_t r, uint8_t g, uint8_t b)
    {
        return Media::SolidColorBrush(Windows::UI::Color{ 255, r, g, b });
    }

    TextBlock Wrapped(std::wstring const &text, double size = 13)
    {
        TextBlock t;
        t.Text(text);
        t.TextWrapping(TextWrapping::WrapWholeWords);
        t.FontSize(size);
        return t;
    }

    Button RowButton(std::wstring const &text)
    {
        Button b;
        b.HorizontalAlignment(HorizontalAlignment::Stretch);
        b.HorizontalContentAlignment(HorizontalAlignment::Left);
        b.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        b.BorderThickness(ThicknessHelper::FromUniformLength(0));
        b.Content(box_value(text));
        return b;
    }
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    void MainWindow::WireSettings()
    {
        history_timer = queue.CreateTimer();
        history_timer.IsRepeating(false);
        history_timer.Interval(std::chrono::milliseconds(400));
        history_timer.Tick([this](auto &&, auto &&) {
            if (model != nullptr && model->HistoryCommit())
                RefreshHistoryButtons();
            // The step of a load comes after its mark: the count starts again.
            if (history_mark_late)
            {
                history_mark_late = false;
                MarkHistorySaved();
            }
        });

        SettingsToggle().Click([this](auto &&, auto &&) {
            ShowSettingsPane(SettingsToggle().IsChecked().GetBoolean());
        });
        SettingsBack().Click([this](auto &&, auto &&) { SettingsGoBack(); });
        SettingsSearch().TextChanged([this](auto &&, auto &&) {
            std::wstring query{ SettingsSearch().Text() };
            if (query == settings_query)
                return;
            settings_query = query;
            if (query.empty())
                ShowSections();
            else
                ShowSearch(query);
        });
        UndoButton().Click([this](auto &&, auto &&) {
            if (model == nullptr)
                return;
            history_timer.Stop();
            AfterRestore(model->Undo());
        });
        RedoButton().Click([this](auto &&, auto &&) {
            if (model == nullptr)
                return;
            history_timer.Stop();
            AfterRestore(model->Redo());
        });
        WireHistory();
        WireProfiles();
        ShowSections();
    }

    void MainWindow::ShowSettingsPane(bool show)
    {
        SettingsToggle().IsChecked(show);
        SettingsPane().Visibility(show ? Visibility::Visible : Visibility::Collapsed);
        if (show)
            RefreshSettingValues();
    }

    void MainWindow::ClearSettingsList()
    {
        setting_editors.clear();
        speed_toggle = nullptr;
        SettingsList().Children().Clear();
        SettingsScroll().ChangeView(nullptr, box_value(0.0).as<Windows::Foundation::IReference<double>>(), nullptr, true);
    }

    void MainWindow::ShowSections()
    {
        ClearSettingsList();
        settings_page = SettingsPage::Sections;
        settings_group = nullptr;
        settings_section = nullptr;
        SettingsBack().Visibility(Visibility::Collapsed);
        SettingsCrumb().Text(L"Settings");
        size_t n = zs_setting_count();
        settings_nozzles = NozzleCount();
        AppendProfileRows();
        // Then the Speed section: the options of all groups that change the
        // time of a slice.
        if (zs_speed_count() > 0)
        {
            TextBlock slicing;
            slicing.Text(L"Slicing");
            slicing.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
            slicing.Foreground(Brush(0x5B, 0x61, 0x68));
            slicing.Margin(ThicknessHelper::FromLengths(4, 12, 0, 2));
            SettingsList().Children().Append(slicing);
            Button speed = RowButton(L"Speed");
            speed.Click([this](auto &&, auto &&) { ShowSection("speed", "Speed"); });
            SettingsList().Children().Append(speed);
        }
        for (auto const &g : group_titles)
        {
            TextBlock heading;
            heading.Text(g.title);
            heading.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
            heading.Foreground(Brush(0x5B, 0x61, 0x68));
            heading.Margin(ThicknessHelper::FromLengths(4, 12, 0, 2));
            SettingsList().Children().Append(heading);
            char const *last = nullptr;
            for (size_t i = 0; i < n; i++)
            {
                zs_setting_info info{};
                if (zs_setting_get_info(i, &info) != ZS_OK || strcmp(info.group, g.group) != 0)
                    continue;
                if (last != nullptr && strcmp(last, info.section) == 0)
                    continue;
                // The section of nozzle k only on a printer with more
                // than k nozzles.
                if (info.nozzle >= settings_nozzles)
                    continue;
                last = info.section;
                Button row = RowButton(info.section[0] != 0 ? zs::ToWide(info.section) : L"General");
                char const *group = info.group, *section = info.section;
                row.Click([this, group, section](auto &&, auto &&) { ShowSection(group, section); });
                SettingsList().Children().Append(row);
            }
        }
    }

    int MainWindow::NozzleCount()
    {
        return model != nullptr ? std::max(1, atoi(model->GetSetting("machine.nozzles").c_str())) : 1;
    }

    // The options that change the time of a slice (src/app/speed.zig), with
    // the Faster slicing switch at the top. The switch has no value of its
    // own: its state comes from its options (zs_app_speed_state).
    void MainWindow::ShowSpeedSection()
    {
        ClearSettingsList();
        settings_page = SettingsPage::Section;
        settings_group = "speed";
        settings_section = "Speed";
        SettingsBack().Visibility(Visibility::Visible);
        SettingsCrumb().Text(L"Speed");

        Grid head;
        head.ColumnSpacing(8);
        head.Padding(ThicknessHelper::FromLengths(4, 6, 0, 8));
        ColumnDefinition names_column, switch_column;
        names_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        switch_column.Width(GridLengthHelper::Auto());
        head.ColumnDefinitions().Append(names_column);
        head.ColumnDefinitions().Append(switch_column);
        StackPanel names;
        names.Spacing(2);
        TextBlock title = Wrapped(L"Faster slicing", 14);
        title.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        TextBlock tag = Wrapped(L"", 12);
        std::wstring help = zs::ToWide(zs_speed_switch_note());
        TextBlock about = Wrapped(help, 12);
        about.Foreground(TokenBrush(Root(), L"ZsDim"));
        names.Children().Append(title);
        names.Children().Append(tag);
        names.Children().Append(about);
        head.Children().Append(names);
        ToggleSwitch toggle;
        toggle.OnContent(box_value(L""));
        toggle.OffContent(box_value(L""));
        toggle.MinWidth(0);
        toggle.VerticalAlignment(VerticalAlignment::Center);
        ToolTipService::SetToolTip(toggle, box_value(help));
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(toggle, L"Faster slicing");
        Grid::SetColumn(toggle, 1);
        head.Children().Append(toggle);
        SettingsList().Children().Append(head);
        speed_toggle = toggle;
        auto fill = [this, toggle, tag]() mutable {
            if (model == nullptr)
                return;
            int state = zs_app_speed_state(model->Active());
            filling_editor = true;
            toggle.IsOn(state == 1);
            filling_editor = false;
            tag.Text(state == 1 ? L"On" : state == 2 ? L"Custom: some options differ" : L"Off: the exact slice");
            tag.Foreground(TokenBrush(Root(), state != 0 ? L"ZsAccentText" : L"ZsDim"));
        };
        fill();
        toggle.Toggled([this](auto &&, auto &&) {
            if (filling_editor || model == nullptr)
                return;
            zs_app *app = model->Active();
            // Custom goes to on: the faster values of all options.
            if (zs_app_speed_set(app, zs_app_speed_state(app) != 1 ? 1 : 0) == ZS_OK)
            {
                model->RequestSlice();
                NoteChange();
            }
            RefreshSettingValues();
        });
        setting_editors.push_back({ "speed.switch", fill });

        for (size_t i = 0, n = zs_speed_count(); i < n; i++)
        {
            zs_speed_option option{};
            zs_setting_info info{};
            if (zs_speed_get(i, &option) != ZS_OK || !FindSetting(option.name, info))
                continue;
            Grid row = MakeSettingRow(info).as<Grid>();
            // The gain and the cost, under the name.
            auto label = row.Children().GetAt(0);
            row.Children().RemoveAt(0);
            StackPanel row_names;
            row_names.VerticalAlignment(VerticalAlignment::Center);
            row_names.Children().Append(label);
            std::wstring text = zs::ToWide(option.note);
            if (option.gcode != 0)
                text += L" Changes the G-code.";
            if (option.faster[0] != 0)
            {
                std::wstring value = info.kind == ZS_SETTING_BOOLEAN ? std::wstring(strcmp(option.faster, "true") == 0 ? L"on" : L"off")
                                                                     : DisplayValue(option.name, option.faster, true);
                text += L" Faster slicing: " + value + L".";
            }
            TextBlock note = Wrapped(text, 11.5);
            note.Foreground(TokenBrush(Root(), L"ZsDim"));
            note.Margin(ThicknessHelper::FromLengths(2, 0, 0, 2));
            row_names.Children().Append(note);
            row.Children().InsertAt(0, row_names);
            SettingsList().Children().Append(row);
        }

        // The app options (threads, draft slices, the simulation after each
        // slice) are in Preferences.
        StackPanel foot;
        foot.Spacing(6);
        foot.Margin(ThicknessHelper::FromLengths(4, 10, 0, 6));
        TextBlock prefs_note = Wrapped(zs::ToWide(zs_speed_prefs_note()), 12);
        prefs_note.Foreground(TokenBrush(Root(), L"ZsDim"));
        foot.Children().Append(prefs_note);
        Button open;
        open.Content(box_value(L"Preferences…"));
        open.Click([this](auto &&, auto &&) { ShowGeneralPreferences(); });
        foot.Children().Append(open);
        SettingsList().Children().Append(foot);
    }

    void MainWindow::ShowSection(char const *group, char const *section)
    {
        if (strcmp(group, "speed") == 0)
        {
            ShowSpeedSection();
            return;
        }
        if (strcmp(group, "profiles") == 0)
        {
            ShowProfileChanges();
            return;
        }
        ClearSettingsList();
        settings_page = SettingsPage::Section;
        settings_group = group;
        settings_section = section;
        SettingsBack().Visibility(Visibility::Visible);
        SettingsCrumb().Text(std::wstring(TitleOf(group)) + L" › " + (section[0] != 0 ? zs::ToWide(section) : L"General"));
        if (strcmp(group, "machine") == 0 || strcmp(group, "filament") == 0)
        {
            TextBlock note = Wrapped(strcmp(group, "machine") == 0
                                         ? L"Each printer keeps its own values here. They change when you change the printer."
                                         : L"Each filament keeps its own values here. They change when you change the filament.",
                                     12);
            note.Foreground(Brush(0x5B, 0x61, 0x68));
            note.Margin(ThicknessHelper::FromLengths(4, 0, 0, 6));
            SettingsList().Children().Append(note);
        }
        size_t n = zs_setting_count();
        for (size_t i = 0; i < n; i++)
        {
            zs_setting_info info{};
            if (zs_setting_get_info(i, &info) != ZS_OK || strcmp(info.group, group) != 0 || strcmp(info.section, section) != 0)
                continue;
            SettingsList().Children().Append(MakeSettingRow(info));
        }
    }

    void MainWindow::ShowSearch(std::wstring const &query)
    {
        ClearSettingsList();
        settings_page = SettingsPage::Search;
        SettingsBack().Visibility(Visibility::Collapsed);
        // All matches first: the settings of nozzles that the printer does
        // not have go before the limit of the list.
        std::vector<uint32_t> hits(std::max<size_t>(zs_setting_count(), 1));
        size_t found = std::min(zs_setting_search(zs::ToUtf8(query).c_str(), 0, hits.data(), nullptr, hits.size()), hits.size());
        size_t count = 0;
        int nozzles = NozzleCount();
        for (size_t i = 0; i < found && count < 60; i++)
        {
            zs_setting_info info{};
            if (zs_setting_get_info(hits[i], &info) == ZS_OK && info.nozzle < nozzles)
                hits[count++] = hits[i];
        }
        SettingsCrumb().Text(count == 0 ? L"No setting matches" : L"Search");
        for (size_t i = 0; i < count; i++)
        {
            zs_setting_info info{};
            if (zs_setting_get_info(hits[i], &info) != ZS_OK)
                continue;
            TextBlock where;
            where.Text(std::wstring(TitleOf(info.group)) + L" › " + zs::ToWide(info.section));
            where.FontSize(11);
            where.Foreground(Brush(0x7A, 0x80, 0x87));
            where.Margin(ThicknessHelper::FromLengths(4, 6, 0, 0));
            SettingsList().Children().Append(where);
            SettingsList().Children().Append(MakeSettingRow(info));
        }
    }

    void MainWindow::SettingsGoBack()
    {
        if (settings_page == SettingsPage::Detail)
        {
            if (detail_from == SettingsPage::Search && !settings_query.empty())
                ShowSearch(settings_query);
            else if (detail_from == SettingsPage::Section && settings_group != nullptr)
                ShowSection(settings_group, settings_section);
            else
                ShowSections();
            return;
        }
        ShowSections();
    }

    FrameworkElement MainWindow::MakeSettingRow(zs_setting_info const &info)
    {
        Grid row;
        row.ColumnSpacing(8);
        row.Padding(ThicknessHelper::FromLengths(4, 3, 0, 3));
        ColumnDefinition label_column, editor_column;
        label_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        editor_column.Width(GridLengthHelper::FromValueAndType(170, GridUnitType::Pixel));
        row.ColumnDefinitions().Append(label_column);
        row.ColumnDefinitions().Append(editor_column);

        HyperlinkButton label;
        label.Content(box_value(zs::ToWide(info.label)));
        label.Padding(ThicknessHelper::FromUniformLength(2));
        label.Foreground(Brush(0x24, 0x28, 0x2E));
        label.HorizontalAlignment(HorizontalAlignment::Left);
        label.VerticalAlignment(VerticalAlignment::Center);
        ToolTipService::SetToolTip(label, box_value(PlainDoc(info.doc)));
        char const *name = info.name;
        label.Click([this, name](auto &&, auto &&) {
            detail_from = settings_page;
            ShowDetail(name);
        });
        row.Children().Append(label);

        FrameworkElement editor = MakeEditor(info, in_profile ? profile_target : nullptr);
        // A row with a note under its name is taller than its editor.
        editor.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(editor, 1);
        row.Children().Append(editor);
        if (in_profile)
        {
            // A change of the profile has the accent color. A setting for
            // the whole print is dim: it cannot change for some layers.
            std::string key = info.name;
            label.Opacity(info.per_layer != 0 ? 1.0 : 0.6);
            auto tint = [this, label, key]() mutable {
                if (ProfileHas(key))
                    label.Foreground(TokenBrush(Root(), L"ZsAccentText"));
                else
                    label.Foreground(Brush(0x24, 0x28, 0x2E));
            };
            tint();
            setting_editors.push_back({ key, tint });
        }
        return row;
    }

    FrameworkElement MainWindow::MakeEditor(zs_setting_info const &info, std::shared_ptr<EditorTarget> const &target)
    {
        std::string name = info.name;
        zs_setting_info copy = info;
        auto value = [this, name, target]() {
            if (model == nullptr)
                return std::string();
            return target != nullptr ? target->get(name) : model->GetSetting(name.c_str());
        };
        auto commit = [this, target](std::string const &key, std::string const &text) {
            if (target != nullptr)
                target->set(key, text);
            else
                CommitSetting(key, text);
        };

        if (info.kind == ZS_SETTING_BOOLEAN)
        {
            ToggleSwitch toggle;
            toggle.OnContent(box_value(L""));
            toggle.OffContent(box_value(L""));
            toggle.MinWidth(0);
            toggle.HorizontalAlignment(HorizontalAlignment::Right);
            auto fill = [this, toggle, value]() mutable {
                filling_editor = true;
                toggle.IsOn(value() == "true");
                filling_editor = false;
            };
            fill();
            toggle.Toggled([this, toggle, name, commit](auto &&, auto &&) {
                if (!filling_editor)
                    commit(name, toggle.IsOn() ? "true" : "false");
            });
            setting_editors.push_back({ name, fill });
            return toggle;
        }

        if (info.kind == ZS_SETTING_CHOICE)
        {
            ComboBox combo;
            combo.HorizontalAlignment(HorizontalAlignment::Stretch);
            auto choices = std::make_shared<std::vector<std::string>>(SplitLines(info.choices));
            for (auto const &choice : *choices)
                combo.Items().Append(box_value(DisplayValue(name.c_str(), choice, false)));
            auto fill = [this, combo, choices, value]() mutable {
                filling_editor = true;
                std::string now = value();
                auto at = std::find(choices->begin(), choices->end(), now);
                combo.SelectedIndex(at == choices->end() ? -1 : (int32_t)(at - choices->begin()));
                filling_editor = false;
            };
            fill();
            combo.SelectionChanged([this, combo, choices, name, commit](auto &&, auto &&) {
                int32_t i = combo.SelectedIndex();
                if (!filling_editor && i >= 0 && (size_t)i < choices->size())
                    commit(name, (*choices)[(size_t)i]);
            });
            setting_editors.push_back({ name, fill });
            return combo;
        }

        // A number or a text: a field, with its unit after it.
        TextBox box;
        box.HorizontalAlignment(HorizontalAlignment::Stretch);
        box.MinHeight(30);
        box.MinWidth(0);
        box.Padding(ThicknessHelper::FromLengths(8, 4, 8, 4));
        if (info.kind != ZS_SETTING_TEXT)
            box.TextAlignment(TextAlignment::Right);
        bool multiline = info.kind == ZS_SETTING_TEXT && info.multiline != 0;
        if (multiline)
        {
            box.AcceptsReturn(true);
            box.TextWrapping(TextWrapping::Wrap);
            box.MaxHeight(160);
            box.FontFamily(Media::FontFamily(L"Cascadia Mono, Consolas"));
            box.FontSize(12);
        }
        auto fill = [this, box, name, value, kind = info.kind]() mutable {
            auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot());
            if (focused != nullptr && focused == box.try_as<Windows::Foundation::IInspectable>())
                return;
            filling_editor = true;
            box.Text(kind == ZS_SETTING_TEXT ? zs::ToWide(value()) : DisplayValue(name.c_str(), value(), false));
            filling_editor = false;
        };
        fill();
        box.GotFocus([this, name](auto &&, auto &&) {
            if (model != nullptr && model->HistoryFocus(name.c_str()))
                RefreshHistoryButtons();
        });
        box.LostFocus([this, box, copy, target](auto &&, auto &&) {
            CommitSettingText(copy, std::wstring(box.Text()), target.get());
            if (model != nullptr && model->HistoryFocus(nullptr))
                RefreshHistoryButtons();
        });
        if (!multiline)
        {
            box.KeyDown([this, box, copy, target](auto &&, Input::KeyRoutedEventArgs const &e) {
                if (e.Key() == VirtualKey::Enter)
                {
                    CommitSettingText(copy, std::wstring(box.Text()), target.get());
                    e.Handled(true);
                }
            });
        }
        setting_editors.push_back({ name, fill });
        if (info.unit == nullptr || info.unit[0] == 0)
            return box;

        Grid with_unit;
        with_unit.ColumnSpacing(6);
        ColumnDefinition field, unit_column, hint_column;
        field.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        unit_column.Width(GridLengthHelper::Auto());
        hint_column.Width(GridLengthHelper::Auto());
        with_unit.ColumnDefinitions().Append(field);
        with_unit.ColumnDefinitions().Append(unit_column);
        with_unit.ColumnDefinitions().Append(hint_column);
        with_unit.Children().Append(box);
        TextBlock unit;
        unit.Text(zs::ToWide(info.unit));
        unit.FontSize(12);
        unit.Foreground(TokenBrush(Root(), L"ZsDim"));
        unit.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(unit, 1);
        with_unit.Children().Append(unit);
        // A speed ratio: the speed in mm/s that it gives on this printer.
        TextBlock hint;
        hint.FontSize(12);
        hint.Foreground(TokenBrush(Root(), L"ZsDim"));
        hint.VerticalAlignment(VerticalAlignment::Center);
        hint.TextAlignment(TextAlignment::Right);
        ToolTipService::SetToolTip(hint, box_value(L"The speed of this ratio on this printer, for a line of the line width at the layer height (the flow limit can make it lower)."));
        Grid::SetColumn(hint, 2);
        with_unit.Children().Append(hint);
        auto fill_hint = [this, hint, name, value]() mutable {
            double mm_s = 0;
            bool shown = model != nullptr && zs_app_ratio_speed(model->Active(), name.c_str(), value().c_str(), &mm_s) == ZS_OK && mm_s > 0;
            hint.Visibility(shown ? Visibility::Visible : Visibility::Collapsed);
            if (shown)
                hint.Text(L"≈ " + std::to_wstring(std::lround(mm_s)) + L" mm/s");
        };
        fill_hint();
        setting_editors.push_back({ name, fill_hint });
        return with_unit;
    }

    void MainWindow::ShowDetail(char const *name)
    {
        zs_setting_info info{};
        if (!FindSetting(name, info))
            return;
        ClearSettingsList();
        settings_page = SettingsPage::Detail;
        SettingsBack().Visibility(Visibility::Visible);
        SettingsCrumb().Text(std::wstring(TitleOf(info.group)) + L" › " + zs::ToWide(info.section));

        StackPanel page;
        page.Spacing(10);
        page.Padding(ThicknessHelper::FromLengths(4, 2, 0, 12));
        TextBlock title = Wrapped(zs::ToWide(info.label), 18);
        title.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        page.Children().Append(title);
        page.Children().Append(MakeEditor(info, in_profile ? profile_target : nullptr));

        TextBlock source = Wrapped(L"", 12);
        source.Foreground(Brush(0x5B, 0x61, 0x68));
        Button reset;
        reset.Content(box_value(L"Reset"));
        Grid source_row;
        ColumnDefinition text_column, button_column;
        text_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        button_column.Width(GridLengthHelper::Auto());
        source_row.ColumnDefinitions().Append(text_column);
        source_row.ColumnDefinitions().Append(button_column);
        source.VerticalAlignment(VerticalAlignment::Center);
        source_row.Children().Append(source);
        Grid::SetColumn(reset, 1);
        source_row.Children().Append(reset);
        page.Children().Append(source_row);

        std::string key = info.name;
        auto fill_source = [this, source, reset, key, per_layer = info.per_layer != 0, default_value = std::string(info.default_value != nullptr ? info.default_value : "")]() mutable {
            if (model == nullptr)
                return;
            if (in_profile)
            {
                // Changed for these layers, or the value of all layers.
                bool changed = ProfileHas(key);
                source.Text(!per_layer ? std::wstring(L"This setting is for the whole print. It cannot change for some layers.")
                            : changed  ? std::wstring(L"Changed in this profile.")
                                       : L"The same as for all layers (" + DisplayValue(key.c_str(), model->GetSetting(key.c_str()), true) + L").");
                reset.Content(box_value(L"Remove the change"));
                reset.IsEnabled(changed);
                reset.Opacity(changed ? 1 : 0);
                return;
            }
            reset.Content(box_value(L"Reset"));
            reset.Opacity(1);
            std::wstring text = L"From: " + zs::ToWide(model->SourceTag(key.c_str()));
            text += L"\nDefault: " + DisplayValue(key.c_str(), default_value, true);
            source.Text(text);
            reset.IsEnabled(model->GetSetting(key.c_str()) != model->BaseValue(key.c_str()) || !model->Formula(key.c_str()).empty());
        };
        fill_source();
        setting_editors.push_back({ key, fill_source });
        reset.Click([this, key](auto &&, auto &&) {
            if (in_profile)
                ProfileClear(key);
            else if (model != nullptr)
                CommitSetting(key, model->BaseValue(key.c_str()));
        });

        // A formula makes the value follow other settings. It is for the
        // whole print, so a layer profile has none.
        if (info.kind != ZS_SETTING_TEXT && !in_profile)
        {
            TextBox formula;
            formula.Header(box_value(L"Formula"));
            formula.PlaceholderText(L"= {line_width} * 2");
            ToolTipService::SetToolTip(formula, box_value(L"A formula makes the value follow other settings: {name} is a setting (for example {layer_height} or {filament.nozzle_temp}); + - * / ^, min, max, round, clamp, and cond ? a : b. Enter sets it. A plain value in the field above removes it."));
            auto fill_formula = [this, formula, key]() mutable {
                if (model == nullptr)
                    return;
                std::string f = model->Formula(key.c_str());
                formula.Text(f.empty() ? L"" : L"= " + zs::ToWide(f));
            };
            fill_formula();
            formula.KeyDown([this, formula, key](auto &&, Input::KeyRoutedEventArgs const &e) {
                if (e.Key() != VirtualKey::Enter || model == nullptr)
                    return;
                e.Handled(true);
                std::string text = zs::ToUtf8(std::wstring(formula.Text()));
                size_t first = text.find_first_not_of(" \t");
                text = first == std::string::npos ? std::string() : text.substr(first);
                // An empty field: the value now, as a plain value.
                if (text.empty())
                    text = model->GetSetting(key.c_str());
                else if (text[0] != '=')
                    text = "= " + text;
                CommitSetting(key, text);
            });
            page.Children().Append(formula);
        }

        page.Children().Append(Wrapped(PlainDoc(info.doc)));
        SettingsList().Children().Append(page);
    }

    void MainWindow::CommitSettingText(zs_setting_info const &info, std::wstring const &text, EditorTarget const *target)
    {
        if (model == nullptr || filling_editor)
            return;
        std::string utf8 = zs::ToUtf8(text);
        std::string value = utf8;
        std::string now = target != nullptr ? target->get(info.name) : model->GetSetting(info.name);
        if (info.kind != ZS_SETTING_TEXT)
        {
            size_t len = 0;
            int rc = zs_setting_parse(info.name, utf8.c_str(), nullptr, 0, &len);
            if (rc == ZS_OK)
            {
                value.assign(len + 1, '\0');
                rc = zs_setting_parse(info.name, utf8.c_str(), value.data(), value.size(), &len);
                value.resize(len);
            }
            if (rc != ZS_OK)
            {
                ShowToast(zs::ToWide(info.label) + L": " + zs::ToWide(zs_status_message(rc)));
                return;
            }
            // The text of the value now: no change, no step in the history.
            if (DisplayValue(info.name, now, false) == text)
                return;
        }
        else if (now == value)
        {
            return;
        }
        if (target != nullptr)
            target->set(info.name, value);
        else
            CommitSetting(info.name, value);
    }

    void MainWindow::CommitSetting(std::string const &name, std::string const &value)
    {
        if (model == nullptr)
            return;
        std::string error;
        if (!model->SetSetting(name.c_str(), value, error))
        {
            ShowToast(zs::ToWide(name) + L": " + zs::ToWide(error));
            RefreshSettingValues();
            return;
        }
        KeepEnginePref(name);
        NoteChange();
        // A formula can change other settings.
        RefreshSettingValues();
    }

    void MainWindow::RefreshSettingValues()
    {
        if (model == nullptr)
            return;
        // The section of each nozzle comes and goes with the number of
        // nozzles. An open section of a nozzle that went closes.
        int nozzles = NozzleCount();
        bool gone = false;
        if (nozzles != settings_nozzles && settings_page == SettingsPage::Section && settings_group != nullptr)
        {
            for (size_t i = 0, n = zs_setting_count(); i < n && !gone; i++)
            {
                zs_setting_info info{};
                if (zs_setting_get_info(i, &info) == ZS_OK && strcmp(info.group, settings_group) == 0 &&
                    strcmp(info.section, settings_section) == 0)
                    gone = info.nozzle >= nozzles;
            }
        }
        if (nozzles != settings_nozzles && settings_page != SettingsPage::Sections && !gone)
            settings_nozzles = nozzles;
        if (nozzles != settings_nozzles)
        {
            ShowSections();
            // The list of the pane also refreshes the line card.
            setting_editors.insert(setting_editors.end(), line_editors.begin(), line_editors.end());
        }
        for (auto &editor : setting_editors)
            editor.refresh();
        RefreshSearchValues();
        RangeRefresh();
        CuraSettingsChanged();
        ProfilesRefresh();
    }

    // The history commits 400 ms after the last change.
    void MainWindow::NoteChange()
    {
        history_timer.Stop();
        history_timer.Start();
        RefreshHistoryButtons();
        PrintersNoteChange();
    }

    void MainWindow::RefreshHistoryButtons()
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        size_t count = zs_app_history_count(app), current = zs_app_history_current(app);
        UndoButton().IsEnabled(current > 0 || zs_app_history_pending(app) != 0);
        RedoButton().IsEnabled(count > 0 && current + 1 < count);
        UndoButton().Opacity(UndoButton().IsEnabled() ? 1 : 0.4);
        RedoButton().Opacity(RedoButton().IsEnabled() ? 1 : 0.4);
        RefreshHistoryButton();
    }

    // After an undo, a redo, or a jump: the editors, and a new slice.
    void MainWindow::AfterRestore(int bits)
    {
        if (model != nullptr && (bits & ZS_HISTORY_MOVED) != 0)
        {
            SupportReload();
            RefreshSettingValues();
            if (zs_app_part_count(model->Active()) > 0)
                model->RequestSlice();
            else
                ShowPlate();
            RefreshFilamentTools();
        }
        RefreshHistoryButtons();
    }
}
