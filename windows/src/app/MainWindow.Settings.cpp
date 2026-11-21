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
    void MainWindow::WireSettings()
    {
        history_timer = queue.CreateTimer();
        history_timer.IsRepeating(false);
        history_timer.Interval(std::chrono::milliseconds(400));
        history_timer.Tick([this](auto &&, auto &&) {
            if (model != nullptr && model->HistoryCommit())
                RefreshHistoryButtons();
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
                last = info.section;
                Button row = RowButton(info.section[0] != 0 ? zs::ToWide(info.section) : L"General");
                char const *group = info.group, *section = info.section;
                row.Click([this, group, section](auto &&, auto &&) { ShowSection(group, section); });
                SettingsList().Children().Append(row);
            }
        }
    }

    void MainWindow::ShowSection(char const *group, char const *section)
    {
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
        std::vector<uint32_t> hits(60);
        size_t count = zs_setting_search(zs::ToUtf8(query).c_str(), 0, hits.data(), nullptr, hits.size());
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

        FrameworkElement editor = MakeEditor(info);
        Grid::SetColumn(editor, 1);
        row.Children().Append(editor);
        return row;
    }

    FrameworkElement MainWindow::MakeEditor(zs_setting_info const &info)
    {
        std::string name = info.name;
        zs_setting_info copy = info;
        auto value = [this, name]() { return model != nullptr ? model->GetSetting(name.c_str()) : std::string(); };

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
            toggle.Toggled([this, toggle, name](auto &&, auto &&) {
                if (!filling_editor)
                    CommitSetting(name, toggle.IsOn() ? "true" : "false");
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
            combo.SelectionChanged([this, combo, choices, name](auto &&, auto &&) {
                int32_t i = combo.SelectedIndex();
                if (!filling_editor && i >= 0 && (size_t)i < choices->size())
                    CommitSetting(name, (*choices)[(size_t)i]);
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
        box.LostFocus([this, box, copy](auto &&, auto &&) {
            CommitSettingText(copy, std::wstring(box.Text()));
            if (model != nullptr && model->HistoryFocus(nullptr))
                RefreshHistoryButtons();
        });
        if (!multiline)
        {
            box.KeyDown([this, box, copy](auto &&, Input::KeyRoutedEventArgs const &e) {
                if (e.Key() == VirtualKey::Enter)
                {
                    CommitSettingText(copy, std::wstring(box.Text()));
                    e.Handled(true);
                }
            });
        }
        setting_editors.push_back({ name, fill });
        if (info.unit == nullptr || info.unit[0] == 0)
            return box;

        Grid with_unit;
        with_unit.ColumnSpacing(6);
        ColumnDefinition field, unit_column;
        field.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        unit_column.Width(GridLengthHelper::Auto());
        with_unit.ColumnDefinitions().Append(field);
        with_unit.ColumnDefinitions().Append(unit_column);
        with_unit.Children().Append(box);
        TextBlock unit;
        unit.Text(zs::ToWide(info.unit));
        unit.FontSize(12);
        unit.Foreground(Brush(0x5B, 0x61, 0x68));
        unit.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(unit, 1);
        with_unit.Children().Append(unit);
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
        page.Children().Append(MakeEditor(info));

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
        auto fill_source = [this, source, reset, key, default_value = std::string(info.default_value != nullptr ? info.default_value : "")]() mutable {
            if (model == nullptr)
                return;
            std::wstring text = L"From: " + zs::ToWide(model->SourceTag(key.c_str()));
            text += L"\nDefault: " + DisplayValue(key.c_str(), default_value, true);
            source.Text(text);
            reset.IsEnabled(model->GetSetting(key.c_str()) != model->BaseValue(key.c_str()) || !model->Formula(key.c_str()).empty());
        };
        fill_source();
        setting_editors.push_back({ key, fill_source });
        reset.Click([this, key](auto &&, auto &&) {
            if (model != nullptr)
                CommitSetting(key, model->BaseValue(key.c_str()));
        });

        // A formula makes the value follow other settings.
        if (info.kind != ZS_SETTING_TEXT)
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

    void MainWindow::CommitSettingText(zs_setting_info const &info, std::wstring const &text)
    {
        if (model == nullptr || filling_editor)
            return;
        std::string utf8 = zs::ToUtf8(text);
        std::string value = utf8;
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
            if (DisplayValue(info.name, model->GetSetting(info.name), false) == text)
                return;
        }
        else if (model->GetSetting(info.name) == value)
        {
            return;
        }
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
        NoteChange();
        // A formula can change other settings.
        RefreshSettingValues();
    }

    void MainWindow::RefreshSettingValues()
    {
        if (model == nullptr)
            return;
        for (auto &editor : setting_editors)
            editor.refresh();
        RefreshSearchValues();
        RefreshHistoryValues();
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
        RefreshTimeline();
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
