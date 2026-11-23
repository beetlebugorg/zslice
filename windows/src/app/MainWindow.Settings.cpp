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

#include <winrt/Microsoft.UI.Xaml.Documents.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>

#include <algorithm>
#include <cmath>
#include <cwchar>
#include <cwctype>

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

    // The features, then the marks (seams, travel, retractions), in the
    // order of the bits of zs_setting_effect, with the colors of the views.
    constexpr int effect_count = ZS_FEATURE_COUNT + 3;
    wchar_t const *const feature_titles[effect_count] = {
        L"Outer wall", L"Inner wall", L"Skin", L"Sparse infill", L"Ironing", L"Skirt or brim", L"Support", L"Support interface",
        L"Slope smoothing", L"Slope ironing", L"Bridge", L"Seams", L"Travel moves", L"Retractions",
    };
    Windows::UI::Color const feature_colors[effect_count] = {
        { 255, 217, 72, 15 },  { 255, 245, 159, 0 },  { 255, 28, 126, 214 },  { 255, 43, 138, 62 },  { 255, 174, 62, 201 },
        { 255, 141, 110, 99 }, { 255, 173, 181, 189 }, { 255, 73, 80, 87 },   { 255, 12, 166, 174 }, { 255, 130, 201, 30 },
        { 255, 102, 204, 242 }, { 255, 224, 26, 38 },  { 255, 51, 115, 242 }, { 255, 242, 64, 191 },
    };

    // A whole number in the text, with a dot as the decimal mark.
    bool ParsesAsNumber(std::wstring const &text)
    {
        if (text.empty())
            return false;
        wchar_t *end = nullptr;
        wcstod(text.c_str(), &end);
        return end != nullptr && *end == 0;
    }

    bool ParsesAsNumber(std::string const &text)
    {
        if (text.empty())
            return false;
        char *end = nullptr;
        strtod(text.c_str(), &end);
        return end != nullptr && *end == 0;
    }

    // A range in the units that the editors show (a ratio as a percentage).
    std::wstring RangeText(zs_setting_info const &info, double lo, double hi)
    {
        double k = info.unit != nullptr && strcmp(info.unit, "%") == 0 ? 100 : 1;
        wchar_t text[96];
        swprintf_s(text, L"%.6g to %.6g %hs", lo * k, hi * k, info.unit != nullptr ? info.unit : "");
        return text;
    }

    // A TextBox gives its line breaks as CR. The core and the G-code use LF.
    std::wstring WithLineFeeds(std::wstring text)
    {
        size_t at = 0;
        while ((at = text.find(L"\r\n", at)) != std::wstring::npos)
            text.erase(at, 1);
        std::replace(text.begin(), text.end(), L'\r', L'\n');
        return text;
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
        // Alt+Left and the back button of the mouse: the place before.
        Input::KeyboardAccelerator back_key;
        back_key.Key(VirtualKey::Left);
        back_key.Modifiers(Windows::System::VirtualKeyModifiers::Menu);
        back_key.Invoked([this](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
            if (SettingsPane().Visibility() != Visibility::Visible)
                return;
            PaneHistoryBack();
            e.Handled(true);
        });
        Root().KeyboardAcceleratorPlacementMode(Input::KeyboardAcceleratorPlacementMode::Hidden);
        Root().KeyboardAccelerators().Append(back_key);
        SettingsPane().AddHandler(UIElement::PointerPressedEvent(), box_value(Input::PointerEventHandler([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (e.GetCurrentPoint(SettingsPane()).Properties().IsXButton1Pressed())
            {
                PaneHistoryBack();
                e.Handled(true);
            }
        })), true);
        // Up and Down move between the rows. Right opens a row, Left goes
        // back. A text field and a list keep their own keys.
        SettingsList().XYFocusKeyboardNavigation(Input::XYFocusKeyboardNavigationMode::Enabled);
        SettingsList().KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() != VirtualKey::Left && e.Key() != VirtualKey::Right)
                return;
            auto button = Input::FocusManager::GetFocusedElement(Content().XamlRoot()).try_as<Button>();
            if (button == nullptr || button.Tag() == nullptr)
                return;
            if (e.Key() == VirtualKey::Right)
                Microsoft::UI::Xaml::Automation::Peers::ButtonAutomationPeer(button).Invoke();
            else if (settings_page != SettingsPage::Sections)
                SettingsGoBack();
            else
                return;
            e.Handled(true);
            queue.TryEnqueue([this] {
                if (auto first = Input::FocusManager::FindFirstFocusableElement(SettingsList()).try_as<Control>())
                    first.Focus(FocusState::Keyboard);
            });
        });
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
        WireScope();
        WirePartSettings();
        ShowSections();
    }

    void MainWindow::ShowSettingsPane(bool show)
    {
        SettingsToggle().IsChecked(show);
        SettingsPane().Visibility(show ? Visibility::Visible : Visibility::Collapsed);
        if (show)
            RefreshSettingValues();
        ApplyPaneFocus();
    }

    // The view shows the lines that the open setting changes, while the
    // pane shows it.
    void MainWindow::SetPaneFocus(uint32_t mask, bool first_layer)
    {
        pane_focus = mask;
        pane_focus_first = first_layer;
        ApplyPaneFocus();
    }

    void MainWindow::ApplyPaneFocus()
    {
        if (view == nullptr || model == nullptr || search_eye_set || tool == Tool::Support)
            return;
        bool on = pane_focus != 0 && SettingsPane().Visibility() == Visibility::Visible;
        if (!on)
        {
            if (pane_focus_on)
            {
                pane_focus_on = false;
                zs_view_focus(view, 0, -1);
                RequestDraw();
            }
            return;
        }
        double zmax = -1;
        zs_toolpaths paths{};
        if (pane_focus_first && zs_app_toolpaths(model->Active(), &paths) == ZS_OK && paths.layer_count > 0)
            zmax = paths.layer_z[0];
        zs_view_focus(view, pane_focus, zmax);
        pane_focus_on = true;
        RequestDraw();
    }

    // What a setting changes: its lines, with their share of the print
    // time. A click on a row lists the settings of those lines.
    void MainWindow::FillEffect(StackPanel const &box, std::string const &key)
    {
        box.Children().Clear();
        zs_setting_effect effect{};
        zs_setting_get_effect(key.c_str(), &effect);
        auto dim = [this](std::wstring const &text) {
            TextBlock line = Wrapped(text, 12);
            line.Foreground(TokenBrush(Root(), L"ZsDim"));
            return line;
        };
        if (effect.features == 0)
        {
            std::wstring note = effect.note != nullptr && effect.note[0] != 0 ? zs::ToWide(effect.note) : L"It changes no line.";
            box.Children().Append(dim(note + L" The preview shows all lines, in their feature colors."));
            return;
        }
        zs_feature_stats stats[ZS_FEATURE_COUNT]{};
        bool have = model != nullptr && zs_app_feature_stats(model->Active(), stats) == ZS_OK;
        double total = 0;
        if (have)
            for (auto const &s : stats)
                total += s.time_s;
        box.Children().Append(Wrapped(effect.first_layer_only != 0 ? L"It changes these lines on the first layer:" : L"It changes these lines:", 13));
        int shown = 0;
        for (int f = 0; f < effect_count; f++)
        {
            if (((effect.features >> f) & 1) == 0 || (f < ZS_FEATURE_COUNT && have && stats[f].paths == 0))
                continue;
            Grid line;
            line.ColumnSpacing(8);
            ColumnDefinition dot_column, name_column, time_column;
            dot_column.Width(GridLengthHelper::Auto());
            name_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            time_column.Width(GridLengthHelper::Auto());
            line.ColumnDefinitions().Append(dot_column);
            line.ColumnDefinitions().Append(name_column);
            line.ColumnDefinitions().Append(time_column);
            Microsoft::UI::Xaml::Shapes::Ellipse dot;
            dot.Width(9);
            dot.Height(9);
            dot.VerticalAlignment(VerticalAlignment::Center);
            dot.Fill(Media::SolidColorBrush(feature_colors[f]));
            line.Children().Append(dot);
            TextBlock name = Wrapped(feature_titles[f]);
            Grid::SetColumn(name, 1);
            line.Children().Append(name);
            if (f < ZS_FEATURE_COUNT && have && total > 0 && effect.first_layer_only == 0)
            {
                wchar_t share[48];
                swprintf_s(share, L"%.0f min · %.0f %%", stats[f].time_s / 60, 100 * stats[f].time_s / total);
                TextBlock time = dim(share);
                time.TextWrapping(TextWrapping::NoWrap);
                time.VerticalAlignment(VerticalAlignment::Center);
                Grid::SetColumn(time, 2);
                line.Children().Append(time);
            }
            Button row;
            row.HorizontalAlignment(HorizontalAlignment::Stretch);
            row.HorizontalContentAlignment(HorizontalAlignment::Stretch);
            row.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            row.BorderThickness(ThicknessHelper::FromUniformLength(0));
            row.Padding(ThicknessHelper::FromLengths(4, 3, 4, 3));
            row.Content(line);
            std::wstring tip = std::wstring(L"Show all settings that change the ") + feature_titles[f] + L" lines";
            ToolTipService::SetToolTip(row, box_value(tip));
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(row, tip);
            row.Click([this, f](auto &&, auto &&) {
                // After the click: the row goes away with the page.
                queue.TryEnqueue([this, f] { ShowFeature(f); });
            });
            box.Children().Append(row);
            shown++;
        }
        box.Children().Append(dim(shown == 0 ? L"This part has none of these lines now." : L"The preview shows these lines, and the other lines fade."));
    }

    // The settings that change the lines of one feature.
    void MainWindow::ShowFeature(int feature)
    {
        if (feature < 0 || feature >= effect_count)
            return;
        ClearSettingsList();
        settings_page = SettingsPage::Section;
        settings_group = "feature";
        settings_section = "";
        settings_feature = feature;
        SettingsBack().Visibility(Visibility::Visible);
        SettingsCrumb().Text(std::wstring(feature_titles[feature]) + L" lines");
        uint32_t all = (1u << ZS_FEATURE_COUNT) - 1;
        for (size_t i = 0, n = zs_setting_count(); i < n; i++)
        {
            zs_setting_info info{};
            zs_setting_effect effect{};
            if (zs_setting_get_info(i, &info) != ZS_OK || zs_setting_get_effect(info.name, &effect) != ZS_OK)
                continue;
            if (((effect.features >> feature) & 1) == 0 || (effect.features & all) == all)
                continue;
            SettingsList().Children().Append(MakeSettingRow(info, true));
        }
        SetPaneFocus(1u << feature, false);
        NotePanePlace();
    }

    void MainWindow::ClearSettingsList()
    {
        pane_fill++;
        pane_leaving = SettingsScroll().VerticalOffset();
        setting_editors.clear();
        speed_toggle = nullptr;
        effect_box = nullptr;
        SetPaneFocus(0, false);
        SettingsList().Children().Clear();
        SettingsScroll().ChangeView(nullptr, box_value(0.0).as<Windows::Foundation::IReference<double>>(), nullptr, true);
    }

    void MainWindow::ShowSections()
    {
        // The section that was open keeps a mark.
        std::string chosen_group = settings_group != nullptr ? settings_group : "", chosen_section = settings_section != nullptr ? settings_section : "";
        auto mark_chosen = [this](Button const &row) {
            auto color = TokenBrush(Root(), L"ZsAccent").as<Media::SolidColorBrush>().Color();
            color.A = 0x2E;
            row.Background(Media::SolidColorBrush(color));
        };
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
            slicing.Foreground(TokenBrush(Root(), L"ZsDim"));
            slicing.Margin(ThicknessHelper::FromLengths(4, 12, 0, 2));
            SettingsList().Children().Append(slicing);
            Button speed = RowButton(L"Speed");
            speed.Click([this](auto &&, auto &&) { ShowSection("speed", "Speed"); });
            speed.Tag(box_value(L"open"));
            if (chosen_group == "speed")
                mark_chosen(speed);
            SettingsList().Children().Append(speed);
        }
        for (auto const &g : group_titles)
        {
            TextBlock heading;
            heading.Text(g.title);
            heading.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
            heading.Foreground(TokenBrush(Root(), L"ZsDim"));
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
                row.Tag(box_value(L"open"));
                if (chosen_group == group && chosen_section == section)
                    mark_chosen(row);
                SettingsList().Children().Append(row);
            }
        }
        NotePanePlace();
    }

    // Custom goes to on: the faster values of all options.
    void MainWindow::ToggleFasterSlicing()
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        if (zs_app_speed_set(app, zs_app_speed_state(app) != 1 ? 1 : 0) == ZS_OK)
        {
            model->RequestSlice();
            NoteChange();
        }
        RefreshSettingValues();
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
            if (!filling_editor)
                ToggleFasterSlicing();
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
        NotePanePlace();
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
        if (strcmp(group, "feature") == 0)
        {
            ShowFeature(settings_feature);
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
            FrameworkElement note = OwnerLabel(group, strcmp(group, "machine") == 0
                                                          ? L": each printer keeps its own values here. They change when you change the printer."
                                                          : L": each filament keeps its own values here. They change when you change the filament.");
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
        // A new section: its lines show, until a setting of it is picked.
        SetPaneFocus(SectionFocus(group, section), false);
        NotePanePlace();
    }

    void MainWindow::ShowSearch(std::wstring const &query)
    {
        ClearSettingsList();
        settings_page = SettingsPage::Search;
        SettingsBack().Visibility(Visibility::Visible);
        // A part of the name, the help, or the key, in the order of the
        // settings. The settings of nozzles the printer lacks stay out.
        std::wstring needle = query;
        std::transform(needle.begin(), needle.end(), needle.begin(), [](wchar_t c) { return (wchar_t)towlower(c); });
        auto has = [&needle](std::wstring text) {
            std::transform(text.begin(), text.end(), text.begin(), [](wchar_t c) { return (wchar_t)towlower(c); });
            return text.find(needle) != std::wstring::npos;
        };
        auto hits = std::make_shared<std::vector<uint32_t>>();
        int nozzles = NozzleCount();
        for (size_t i = 0, n = zs_setting_count(); i < n; i++)
        {
            zs_setting_info info{};
            if (zs_setting_get_info(i, &info) != ZS_OK || info.nozzle >= nozzles)
                continue;
            if (has(zs::ToWide(info.label)) || has(PlainDoc(info.doc)) || has(zs::ToWide(info.name)))
                hits->push_back((uint32_t)i);
        }
        SettingsCrumb().Text(L"Search");
        if (hits->empty())
        {
            TextBlock none = Wrapped(L"No setting matches.");
            none.Foreground(TokenBrush(Root(), L"ZsDim"));
            none.Margin(ThicknessHelper::FromLengths(4, 6, 0, 0));
            SettingsList().Children().Append(none);
        }
        NotePanePlace();
        AppendSearchRows(hits, 0, pane_fill);
    }

    void MainWindow::AppendSearchRows(std::shared_ptr<std::vector<uint32_t>> const &hits, size_t from, uint64_t fill)
    {
        // Another page or a new search took the list.
        if (fill != pane_fill || settings_page != SettingsPage::Search)
            return;
        size_t end = std::min(from + 30, hits->size());
        for (size_t i = from; i < end; i++)
        {
            zs_setting_info info{};
            if (zs_setting_get_info((*hits)[i], &info) == ZS_OK)
                SettingsList().Children().Append(MakeSettingRow(info, true));
        }
        if (end < hits->size())
            queue.TryEnqueue(Microsoft::UI::Dispatching::DispatcherQueuePriority::Low, [this, hits, end, fill] { AppendSearchRows(hits, end, fill); });
        else
            ApplyPaneScroll();
    }

    bool MainWindow::SamePlace(PanePlace const &a, PanePlace const &b)
    {
        auto same = [](char const *x, char const *y) { return x == y || (x != nullptr && y != nullptr && strcmp(x, y) == 0); };
        return a.page == b.page && same(a.group, b.group) && same(a.section, b.section) && a.feature == b.feature && a.detail == b.detail &&
               (a.page != SettingsPage::Search || a.query == b.query);
    }

    // After each page: the place before goes on the history, and the path
    // over the list follows.
    void MainWindow::NotePanePlace()
    {
        PanePlace now;
        now.page = settings_page;
        now.group = settings_group;
        now.section = settings_section;
        now.feature = settings_group != nullptr && strcmp(settings_group, "feature") == 0 ? settings_feature : -1;
        now.query = settings_query;
        now.detail = settings_page == SettingsPage::Detail ? settings_detail : std::string();
        now.detail_from = detail_from;
        bool same = SamePlace(pane_now, now);
        if (same)
        {
            // The same page again (a new scope or theme) keeps its scroll.
            if (!pane_restoring && pane_scroll_wanted < 0)
                pane_scroll_wanted = pane_leaving;
        }
        else
        {
            if (now.page == SettingsPage::Detail && pane_now.page != SettingsPage::Detail)
                pane_list_scroll = pane_leaving;
            // Typing in the search is one place.
            bool typing = now.page == SettingsPage::Search && pane_now.page == SettingsPage::Search;
            if (!pane_restoring && !typing)
            {
                PanePlace before = pane_now;
                before.scroll = pane_leaving;
                pane_history.push_back(std::move(before));
                if (pane_history.size() > 50)
                    pane_history.erase(pane_history.begin());
            }
        }
        pane_now = std::move(now);
        UpdateCrumbs();
        // The rows of a search come in batches: its scroll waits for them.
        if (settings_page != SettingsPage::Search)
            ApplyPaneScroll();
    }

    void MainWindow::ApplyPaneScroll()
    {
        if (pane_scroll_wanted < 0)
            return;
        double at = pane_scroll_wanted;
        pane_scroll_wanted = -1;
        queue.TryEnqueue(Microsoft::UI::Dispatching::DispatcherQueuePriority::Low, [this, at] {
            SettingsScroll().UpdateLayout();
            SettingsScroll().ChangeView(nullptr, box_value(at).as<Windows::Foundation::IReference<double>>(), nullptr, true);
        });
    }

    void MainWindow::RestorePanePlace(PanePlace const &place)
    {
        pane_restoring = true;
        pane_scroll_wanted = place.scroll;
        detail_from = place.detail_from;
        settings_query = place.query;
        if (std::wstring(SettingsSearch().Text()) != place.query)
            SettingsSearch().Text(place.query);
        if (place.page == SettingsPage::Section && place.group != nullptr)
        {
            settings_feature = place.feature;
            ShowSection(place.group, place.section != nullptr ? place.section : "");
        }
        else if (place.page == SettingsPage::Search && !place.query.empty())
        {
            ShowSearch(place.query);
        }
        else if (place.page == SettingsPage::Detail && !place.detail.empty())
        {
            settings_group = place.group;
            settings_section = place.section;
            ShowDetail(std::string(place.detail).c_str());
        }
        else
        {
            ShowSections();
        }
        pane_restoring = false;
    }

    // The place before, or with no history the column before.
    void MainWindow::PaneHistoryBack()
    {
        if (pane_history.empty())
        {
            if (settings_page != SettingsPage::Sections)
                SettingsGoBack();
            return;
        }
        PanePlace place = std::move(pane_history.back());
        pane_history.pop_back();
        RestorePanePlace(place);
    }

    // The path: Settings, the list, and the setting. A click goes there.
    void MainWindow::UpdateCrumbs()
    {
        // Links in one text: a long path wraps, and no name is cut off.
        namespace Documents = Microsoft::UI::Xaml::Documents;
        auto crumbs = SettingsCrumbs();
        crumbs.Inlines().Clear();
        auto add = [this, &crumbs](std::wstring const &text, int column, bool last) {
            if (crumbs.Inlines().Size() > 0)
            {
                Documents::Run arrow;
                arrow.Text(L"  ›  ");
                arrow.Foreground(TokenBrush(Root(), L"ZsDim"));
                crumbs.Inlines().Append(arrow);
            }
            Documents::Run name;
            name.Text(text);
            if (last)
            {
                name.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
                crumbs.Inlines().Append(name);
                return;
            }
            Documents::Hyperlink link;
            link.UnderlineStyle(Documents::UnderlineStyle::None);
            link.Foreground(TokenBrush(Root(), L"ZsFg"));
            link.Inlines().Append(name);
            link.Click([this, column](auto &&, auto &&) {
                queue.TryEnqueue([this, column] {
                    if (column == 0)
                    {
                        settings_query.clear();
                        SettingsSearch().Text(L"");
                        ShowSections();
                    }
                    else if (column == 1 && settings_page == SettingsPage::Detail)
                    {
                        SettingsGoBack();
                    }
                });
            });
            crumbs.Inlines().Append(link);
        };
        bool detail = settings_page == SettingsPage::Detail;
        add(L"Settings", 0, settings_page == SettingsPage::Sections);
        if (settings_page != SettingsPage::Sections)
        {
            std::wstring list;
            if (settings_page == SettingsPage::Search || (detail && detail_from == SettingsPage::Search))
                list = L"Search";
            else if (settings_group != nullptr && strcmp(settings_group, "feature") == 0 && settings_feature >= 0)
                list = std::wstring(feature_titles[settings_feature]) + L" lines";
            else if (settings_group != nullptr && strcmp(settings_group, "speed") == 0)
                list = L"Slicing · Speed";
            else if (settings_group != nullptr && strcmp(settings_group, "profiles") == 0)
                list = RangeName(profile_min, profile_max);
            else if (settings_group != nullptr)
                list = std::wstring(TitleOf(settings_group)) + L" · " + (settings_section != nullptr && settings_section[0] != 0 ? zs::ToWide(settings_section) : std::wstring(L"General"));
            if (!list.empty())
                add(list, 1, !detail);
        }
        zs_setting_info info{};
        if (detail && FindSetting(settings_detail.c_str(), info))
            add(zs::ToWide(info.label), 2, true);
    }

    uint32_t MainWindow::SectionFocus(char const *group, char const *section)
    {
        uint32_t mask = 0;
        for (size_t i = 0, n = zs_setting_count(); i < n; i++)
        {
            zs_setting_info info{};
            zs_setting_effect effect{};
            if (zs_setting_get_info(i, &info) != ZS_OK || strcmp(info.group, group) != 0 || strcmp(info.section, section) != 0)
                continue;
            if (zs_setting_get_effect(info.name, &effect) == ZS_OK)
                mask |= effect.features;
        }
        return mask != 0 ? mask : (1u << ZS_FEATURE_COUNT) - 1;
    }

    std::wstring MainWindow::OwnerText(bool printer)
    {
        std::wstring who = printer ? L"Printer" : L"Filament";
        std::string name = model != nullptr ? model->GetSetting(printer ? "machine.name" : "filament.name") : std::string();
        return name.empty() ? who : who + L" · " + zs::ToWide(name);
    }

    FrameworkElement MainWindow::OwnerLabel(char const *group, wchar_t const *rest)
    {
        bool printer = strcmp(group, "machine") == 0;
        if (!printer && strcmp(group, "filament") != 0)
            return nullptr;
        auto ink = TokenBrush(Root(), printer ? L"ZsOwnerMachine" : L"ZsOwnerFilament");
        std::string key = printer ? "machine.name" : "filament.name";
        TextBlock text;
        text.TextWrapping(TextWrapping::Wrap);
        if (rest != nullptr)
        {
            namespace Documents = Microsoft::UI::Xaml::Documents;
            Documents::Run who, tail;
            who.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
            who.Foreground(ink);
            tail.Text(rest);
            text.FontSize(12);
            text.Inlines().Append(who);
            text.Inlines().Append(tail);
            auto fill = [this, who, printer]() mutable { who.Text(OwnerText(printer)); };
            fill();
            setting_editors.push_back({ key, fill });
            return text;
        }
        text.FontSize(11);
        text.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        text.Foreground(ink);
        auto fill = [this, text, printer]() mutable { text.Text(OwnerText(printer)); };
        fill();
        setting_editors.push_back({ key, fill });
        Border badge;
        badge.HorizontalAlignment(HorizontalAlignment::Left);
        badge.CornerRadius(CornerRadiusHelper::FromUniformRadius(9));
        badge.Padding(ThicknessHelper::FromLengths(6, 0, 6, 1));
        badge.Background(Media::SolidColorBrush(printer ? Windows::UI::Color{ 41, 28, 126, 214 } : Windows::UI::Color{ 36, 217, 72, 15 }));
        badge.Child(text);
        ToolTipService::SetToolTip(badge, box_value(printer ? L"A printer setting: each printer has its own value, and it changes when you change the printer."
                                                            : L"A filament setting: each filament has its own value, and it changes when you change the filament."));
        return badge;
    }

    // The page again, with the colors of the theme.
    void MainWindow::RedrawSettingsPage()
    {
        if (settings_page == SettingsPage::Sections)
            ShowSections();
        else if (settings_page == SettingsPage::Section && settings_group != nullptr)
            ShowSection(settings_group, settings_section);
        else if (settings_page == SettingsPage::Search)
            ShowSearch(settings_query);
        else if (settings_page == SettingsPage::Detail && !settings_detail.empty())
            ShowDetail(std::string(settings_detail).c_str());
    }

    void MainWindow::SettingsGoBack()
    {
        if (settings_page == SettingsPage::Detail)
        {
            // The list comes back at its place, with this row marked.
            pane_scroll_wanted = pane_list_scroll;
            if (detail_from == SettingsPage::Search && !settings_query.empty())
                ShowSearch(settings_query);
            else if (detail_from == SettingsPage::Section && settings_group != nullptr)
                ShowSection(settings_group, settings_section);
            else
                ShowSections();
            return;
        }
        // Back from a search ends it.
        if (settings_page == SettingsPage::Search)
        {
            settings_query.clear();
            SettingsSearch().Text(L"");
        }
        ShowSections();
    }

    // A setting that the scope cannot have shows, and is off.
    void MainWindow::TurnOffForScope(FrameworkElement const &editor, zs_setting_info const &info)
    {
        if (ScopeEditable(info))
            return;
        auto grid = editor.try_as<Grid>();
        auto control = (grid != nullptr ? grid.Children().GetAt(0) : editor).try_as<Control>();
        if (control != nullptr)
            control.IsEnabled(false);
        if (auto chips = editor.try_as<VariableSizedWrapGrid>())
        {
            chips.IsHitTestVisible(false);
            chips.Opacity(0.5);
        }
        ToolTipService::SetToolTip(editor, box_value(ScopeOffTip()));
    }

    std::wstring MainWindow::RowSource(std::string const &key, bool per_part, bool &mine)
    {
        mine = false;
        if (ScopeIsGlobal())
            return key.rfind("project.", 0) == 0 ? L"Global" : L"In the printer or filament profile";
        if (settings_scope >= 0 && !per_part)
            return L"Same for all parts";
        if (in_profile || model == nullptr)
            return {};
        ptrdiff_t part = settings_scope >= 0 ? (ptrdiff_t)settings_scope : -1;
        if (part < 0)
        {
            std::string formula = model->Formula(key.c_str());
            if (!formula.empty())
            {
                mine = true;
                return L"= " + zs::ToWide(formula);
            }
        }
        int level = ZS_LEVEL_DEFAULT;
        char profile[256] = "";
        if (zs_app_setting_source(model->Active(), part, key.c_str(), &level, profile, sizeof profile) != ZS_OK)
            return {};
        std::wstring from = zs::ToWide(profile);
        switch (level)
        {
        case ZS_LEVEL_GLOBAL: return L"Global";
        case ZS_LEVEL_MACHINE: return from.empty() ? L"Printer" : from;
        case ZS_LEVEL_FILAMENT: return from.empty() ? L"Filament" : from;
        case ZS_LEVEL_QUALITY: return from.empty() ? L"Quality" : from;
        case ZS_LEVEL_PRINT: mine = true; return L"This print";
        case ZS_LEVEL_PART: mine = true; return L"This part";
        default: return {};
        }
    }

    FrameworkElement MainWindow::MakeSettingRow(zs_setting_info const &info, bool with_section)
    {
        Grid row;
        row.ColumnSpacing(8);
        row.Padding(ThicknessHelper::FromLengths(4, 3, 0, 3));
        ColumnDefinition label_column, editor_column, more_column;
        label_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        editor_column.Width(GridLengthHelper::FromValueAndType(170, GridUnitType::Pixel));
        more_column.Width(GridLengthHelper::Auto());
        row.ColumnDefinitions().Append(label_column);
        row.ColumnDefinitions().Append(editor_column);
        row.ColumnDefinitions().Append(more_column);

        std::string key = info.name;
        char const *name = info.name;
        auto open = [this, name] {
            detail_from = settings_page;
            ShowDetail(name);
        };

        // The name, where its value comes from, and in a mixed list its
        // place and its owner. A click here opens the setting.
        StackPanel names;
        names.VerticalAlignment(VerticalAlignment::Center);
        names.Padding(ThicknessHelper::FromUniformLength(2));
        names.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        ToolTipService::SetToolTip(names, box_value(PlainDoc(info.doc)));
        if (auto element = names.try_as<IUIElementProtected>())
            element.ProtectedCursor(Microsoft::UI::Input::InputSystemCursor::Create(Microsoft::UI::Input::InputSystemCursorShape::Hand));
        names.Tapped([this, open](auto &&, Input::TappedRoutedEventArgs const &e) {
            e.Handled(true);
            // After the tap: the row goes away with the page.
            queue.TryEnqueue([open] { open(); });
        });
        TextBlock label = Wrapped(zs::ToWide(info.label));
        label.Foreground(TokenBrush(Root(), L"ZsFg"));
        names.Children().Append(label);
        TextBlock tag = Wrapped(L"", 11);
        names.Children().Append(tag);
        auto fill_tag = [this, tag, key, per_part = info.per_part != 0]() mutable {
            bool mine = false;
            std::wstring text = RowSource(key, per_part, mine);
            tag.Text(text);
            tag.Visibility(text.empty() ? Visibility::Collapsed : Visibility::Visible);
            tag.Opacity(mine ? 1.0 : 0.6);
            tag.Foreground(TokenBrush(Root(), mine ? L"ZsAccentText" : L"ZsFg"));
        };
        fill_tag();
        setting_editors.push_back({ key, fill_tag });
        if (with_section)
        {
            TextBlock where = Wrapped(std::wstring(TitleOf(info.group)) + L" › " + zs::ToWide(info.section), 11);
            where.Foreground(TokenBrush(Root(), L"ZsDim"));
            names.Children().Append(where);
            // A mixed list: a badge on each printer and filament setting.
            if (FrameworkElement badge = OwnerLabel(info.group, nullptr); badge != nullptr)
            {
                badge.Margin(ThicknessHelper::FromLengths(0, 2, 0, 0));
                names.Children().Append(badge);
            }
        }
        row.Children().Append(names);

        // A quick change: the editor in the row. A text (the start G-code)
        // shows its value, and opens on the detail page.
        FrameworkElement editor{ nullptr };
        if (info.kind == ZS_SETTING_TEXT)
        {
            TextBlock shown = Wrapped(L"", 12);
            shown.TextAlignment(TextAlignment::Right);
            auto target = PaneTarget();
            auto fill_shown = [this, shown, key, target]() mutable {
                if (model != nullptr)
                    shown.Text(DisplayValue(key.c_str(), target != nullptr ? target->get(key) : model->GetSetting(key.c_str()), true));
            };
            fill_shown();
            setting_editors.push_back({ key, fill_shown });
            editor = shown;
        }
        else
        {
            editor = MakeEditor(info, PaneTarget());
            TurnOffForScope(editor, info);
        }
        // A row with a note under its name is taller than its editor.
        editor.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(editor, 1);
        row.Children().Append(editor);

        // The detail page: what it does, and the lines and time it changes.
        Button more;
        more.Width(24);
        more.Height(28);
        more.MinWidth(0);
        more.MinHeight(0);
        more.Padding(ThicknessHelper::FromUniformLength(0));
        more.BorderThickness(ThicknessHelper::FromUniformLength(0));
        more.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        more.VerticalAlignment(VerticalAlignment::Center);
        FontIcon chevron;
        chevron.Glyph(L"\xE76C");
        chevron.FontSize(10);
        more.Content(chevron);
        ToolTipService::SetToolTip(more, box_value(L"What it does, and the lines and the time it changes"));
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(more, zs::ToWide(info.label) + L": what it does");
        more.Click([this, open](auto &&, auto &&) { queue.TryEnqueue([open] { open(); }); });
        more.Tag(box_value(L"open"));
        if (key == settings_detail)
        {
            auto color = TokenBrush(Root(), L"ZsAccent").as<Media::SolidColorBrush>().Color();
            color.A = 0x2E;
            row.Background(Media::SolidColorBrush(color));
        }
        Grid::SetColumn(more, 2);
        row.Children().Append(more);

        if (in_profile)
        {
            // A change of the profile has the accent color. A setting for
            // the whole print is dim: it cannot change for some layers.
            names.Opacity(info.per_layer != 0 ? 1.0 : 0.6);
            auto tint = [this, label, key]() mutable {
                label.Foreground(TokenBrush(Root(), ProfileHas(key) ? L"ZsAccentText" : L"ZsFg"));
            };
            tint();
            setting_editors.push_back({ key, tint });
        }
        return row;
    }

    FrameworkElement MainWindow::MakeEditor(zs_setting_info const &info, std::shared_ptr<EditorTarget> const &target)
    {
        made_field = nullptr;
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
        // A switch or a list with the focus: Ctrl+C and Ctrl+V take its
        // value. A text field keeps its own copy and paste.
        auto watch_focus = [this, name, value, commit](Control const &control) {
            control.GotFocus([this, control, name, value, commit](auto &&, auto &&) {
                focused_editor = ClipEditor{ control, name, value, [name, commit](std::string const &text) { commit(name, text); } };
            });
            control.LostFocus([this](auto &&, auto &&) { focused_editor.reset(); });
        };

        // A filament: a chip for each filament of the plate.
        if (IsFilamentSetting(info.name))
        {
            VariableSizedWrapGrid chips;
            chips.Orientation(Orientation::Horizontal);
            chips.ItemWidth(30);
            chips.ItemHeight(30);
            chips.MaximumRowsOrColumns(5);
            chips.HorizontalAlignment(HorizontalAlignment::Right);
            auto key = std::make_shared<std::string>();
            wchar_t const *zero = ZeroChip(info.name);
            auto fill = [this, chips, key, value, commit, name, zero]() mutable {
                int now = atoi(value().c_str());
                if (now < 0 || (zero == nullptr && now < 1))
                    now = zero != nullptr ? 0 : 1;
                FillFilamentChips(chips, *key, now, L"", [commit, name](int k) { commit(name, std::to_string(k)); }, zero);
            };
            fill();
            setting_editors.push_back({ name, fill });
            return chips;
        }

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
            watch_focus(toggle);
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
            watch_focus(combo);
            return combo;
        }

        // A number or a text: a field, with its unit after it.
        bool is_number = info.kind == ZS_SETTING_NUMBER || info.kind == ZS_SETTING_INTEGER;
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
        auto field = std::make_shared<EditorField>();
        field->box = box;
        field->doc = PlainDoc(info.doc);
        ToolTipService::SetToolTip(box, box_value(field->doc));
        if (is_number)
        {
            // A ring over the field: its style owns the colors of the field.
            Border mark;
            mark.IsHitTestVisible(false);
            mark.BorderThickness(ThicknessHelper::FromUniformLength(1.5));
            mark.CornerRadius(CornerRadiusHelper::FromUniformRadius(4));
            mark.Visibility(Visibility::Collapsed);
            field->mark = mark;
        }
        auto fill = [this, box, name, value, field, copy, kind = info.kind]() mutable {
            std::string now = value();
            ShowUnusual(*field, copy, now);
            if (field->follow)
                field->follow(now);
            auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot());
            if (focused != nullptr && focused == box.try_as<Windows::Foundation::IInspectable>())
                return;
            std::wstring text = kind == ZS_SETTING_TEXT ? zs::ToWide(now) : DisplayValue(name.c_str(), now, false);
            field->shown = text;
            filling_editor = true;
            box.Text(text);
            filling_editor = false;
            if (field->state == 2)
            {
                SetFieldState(*field, 0, field->doc);
                ShowUnusual(*field, copy, now);
            }
        };
        fill();
        box.GotFocus([this, name](auto &&, auto &&) {
            if (model != nullptr && model->HistoryFocus(name.c_str()))
                RefreshHistoryButtons();
        });
        box.LostFocus([this, box, copy, target, field](auto &&, auto &&) {
            if (field->live != nullptr)
                field->live.Stop();
            CommitSettingText(copy, std::wstring(box.Text()), target.get(), field.get());
            if (model != nullptr && model->HistoryFocus(nullptr))
                RefreshHistoryButtons();
        });
        if (is_number)
        {
            // A number applies 350 ms after the last key. A half-typed
            // number ("", "-", "0.") waits for more typing.
            field->live = queue.CreateTimer();
            field->live.IsRepeating(false);
            std::weak_ptr<EditorField> weak = field;
            field->live.Tick([this, weak, copy, target](auto &&, auto &&) {
                auto f = weak.lock();
                if (f == nullptr)
                    return;
                f->live.Stop();
                std::wstring text{ f->box.Text() };
                if (ParsesAsNumber(text) && text.back() != L'.')
                    CommitSettingText(copy, text, target.get(), f.get(), true);
            });
            box.Unloaded([field](auto &&, auto &&) { field->live.Stop(); });
            // Up and Down step the last decimal. Shift or Page: ten steps.
            // Ctrl: one decimal finer.
            box.PreviewKeyDown([this, field, copy](auto &&, Input::KeyRoutedEventArgs const &e) {
                auto key = e.Key();
                bool page = key == VirtualKey::PageUp || key == VirtualKey::PageDown;
                if (key != VirtualKey::Up && key != VirtualKey::Down && !page)
                    return;
                if (!ParsesAsNumber(std::wstring(field->box.Text())))
                    return;
                auto held = [](VirtualKey k) {
                    return (Microsoft::UI::Input::InputKeyboardSource::GetKeyStateForCurrentThread(k) & Windows::UI::Core::CoreVirtualKeyStates::Down) ==
                           Windows::UI::Core::CoreVirtualKeyStates::Down;
                };
                double steps = key == VirtualKey::Up || key == VirtualKey::PageUp ? 1 : -1;
                if (page || held(VirtualKey::Shift))
                    steps *= 10;
                StepField(*field, copy, std::wstring(field->box.Text()), steps, held(VirtualKey::Control), 150);
                e.Handled(true);
            });
        }
        box.TextChanged([this, field, is_number](auto &&, auto &&) {
            std::wstring text{ field->box.Text() };
            if (text == field->shown)
                return;
            if (field->state == 2)
                SetFieldState(*field, 0, field->doc);
            if (is_number)
            {
                field->live.Stop();
                field->live.Interval(std::chrono::milliseconds(350));
                field->live.Start();
            }
        });
        if (!multiline)
        {
            box.KeyDown([this, box, copy, target, field](auto &&, Input::KeyRoutedEventArgs const &e) {
                if (e.Key() == VirtualKey::Enter)
                {
                    if (field->live != nullptr)
                        field->live.Stop();
                    CommitSettingText(copy, std::wstring(box.Text()), target.get(), field.get());
                    e.Handled(true);
                }
            });
        }
        setting_editors.push_back({ name, fill });
        made_field = field;
        if (!is_number && (info.unit == nullptr || info.unit[0] == 0))
            return box;

        Grid with_unit;
        with_unit.ColumnSpacing(6);
        ColumnDefinition field_column, unit_column, hint_column;
        field_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        unit_column.Width(GridLengthHelper::Auto());
        hint_column.Width(GridLengthHelper::Auto());
        with_unit.ColumnDefinitions().Append(field_column);
        with_unit.ColumnDefinitions().Append(unit_column);
        bool no_hint = target != nullptr && target->no_hint;
        if (!no_hint)
            with_unit.ColumnDefinitions().Append(hint_column);
        with_unit.Children().Append(box);
        TextBlock unit;
        unit.Text(zs::ToWide(info.unit != nullptr ? info.unit : ""));
        unit.FontSize(12);
        unit.Foreground(TokenBrush(Root(), L"ZsDim"));
        unit.VerticalAlignment(VerticalAlignment::Center);
        Grid::SetColumn(unit, 1);
        with_unit.Children().Append(unit);
        if (field->mark != nullptr)
            with_unit.Children().Append(field->mark);
        if (no_hint)
            return with_unit;
        // A speed ratio: the speed in mm/s that it gives on this printer. A
        // thickness: the layers that cover it, rounded up as the slicer
        // counts them.
        TextBlock hint;
        hint.FontSize(12);
        hint.Foreground(TokenBrush(Root(), L"ZsDim"));
        hint.VerticalAlignment(VerticalAlignment::Center);
        hint.TextAlignment(TextAlignment::Right);
        ToolTipService::SetToolTip(hint, box_value(L"The speed of this ratio on this printer, for a line of the line width at the layer height (the flow limit can make it lower)."));
        Grid::SetColumn(hint, 2);
        with_unit.Children().Append(hint);
        bool thickness = name == "project.top_thickness" || name == "project.bottom_thickness";
        auto fill_hint = [this, hint, name, value, target, thickness]() mutable {
            if (thickness && model != nullptr)
            {
                std::string height = target != nullptr ? target->get("project.layer_height") : model->GetSetting("project.layer_height");
                double h = strtod(height.c_str(), nullptr), t = strtod(value().c_str(), nullptr);
                hint.Visibility(h > 0 ? Visibility::Visible : Visibility::Collapsed);
                if (h <= 0)
                    return;
                long n = t <= 0 ? 0 : (long)std::ceil(t / h - 1e-6);
                bool exact = std::abs(n * h - t) < 1e-6;
                hint.Text((exact ? L"= " : L"→ ") + std::to_wstring(n) + (n == 1 ? L" layer" : L" layers"));
                wchar_t tip[120];
                if (exact)
                    swprintf_s(tip, L"%ld layers of %.2f mm.", n, h);
                else
                    swprintf_s(tip, L"Not a multiple of the layer height (%.2f mm): it prints %ld layers, %.2f mm.", h, n, n * h);
                ToolTipService::SetToolTip(hint, box_value(tip));
                return;
            }
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
        if (detail_from != SettingsPage::Search && detail_from != SettingsPage::Section)
        {
            settings_group = info.group;
            settings_section = info.section;
            detail_from = SettingsPage::Section;
        }
        settings_page = SettingsPage::Detail;
        settings_detail = name;
        SettingsBack().Visibility(Visibility::Visible);
        SettingsCrumb().Text(std::wstring(TitleOf(info.group)) + L" › " + zs::ToWide(info.section));

        StackPanel page;
        page.Spacing(10);
        page.Padding(ThicknessHelper::FromLengths(4, 2, 0, 12));
        TextBlock title = Wrapped(zs::ToWide(info.label), 18);
        title.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        page.Children().Append(title);
        TextBlock path = Wrapped(std::wstring(TitleOf(info.group)) + L" › " + zs::ToWide(info.section), 12);
        path.Foreground(TokenBrush(Root(), L"ZsDim"));
        path.Margin(ThicknessHelper::FromLengths(0, -6, 0, 0));
        page.Children().Append(path);
        // A setting of the printer or the filament: say so, with the name.
        if (FrameworkElement owner = OwnerLabel(info.group, strcmp(info.group, "machine") == 0
                                                                ? L": each printer has its own value. It changes when you change the printer."
                                                                : L": each filament has its own value. It changes when you change the filament.");
            owner != nullptr)
            page.Children().Append(owner);
        // The name and its editor, the slider, and the formula, in one grid.
        Grid form;
        form.ColumnSpacing(10);
        form.RowSpacing(6);
        ColumnDefinition form_name, form_value;
        form_name.Width(GridLengthHelper::Auto());
        form_value.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        form.ColumnDefinitions().Append(form_name);
        form.ColumnDefinitions().Append(form_value);
        int form_row = 0;
        auto form_add = [&form, &form_row](FrameworkElement const &left, FrameworkElement const &right) {
            RowDefinition line;
            line.Height(GridLengthHelper::Auto());
            form.RowDefinitions().Append(line);
            if (left != nullptr)
            {
                Grid::SetRow(left, form_row);
                form.Children().Append(left);
            }
            Grid::SetRow(right, form_row);
            Grid::SetColumn(right, left != nullptr ? 1 : 0);
            if (left == nullptr)
                Grid::SetColumnSpan(right, 2);
            form.Children().Append(right);
            form_row++;
        };
        auto form_name_text = [this](std::wstring const &text) {
            TextBlock name = Wrapped(text);
            name.MaxWidth(170);
            name.HorizontalAlignment(HorizontalAlignment::Left);
            name.VerticalAlignment(VerticalAlignment::Center);
            return name;
        };
        auto detail_target = PaneTarget();
        FrameworkElement detail_editor = MakeEditor(info, detail_target);
        auto detail_field = made_field;
        TurnOffForScope(detail_editor, info);
        TextBlock editor_name = form_name_text(zs::ToWide(info.label));
        ToolTipService::SetToolTip(editor_name, box_value(PlainDoc(info.doc)));
        if (info.kind == ZS_SETTING_TEXT && info.multiline != 0)
        {
            form_add(nullptr, editor_name);
            form_add(nullptr, detail_editor);
        }
        else
        {
            if (info.kind == ZS_SETTING_BOOLEAN || info.kind == ZS_SETTING_CHOICE)
                detail_editor.HorizontalAlignment(HorizontalAlignment::Right);
            form_add(editor_name, detail_editor);
        }
        bool detail_number = (info.kind == ZS_SETTING_NUMBER || info.kind == ZS_SETTING_INTEGER) && !IsFilamentSetting(info.name);
        if (detail_number && detail_field != nullptr && ScopeEditable(info))
            AddScrub(editor_name, detail_field, info, detail_target);
        if (detail_number && detail_field != nullptr && info.slider_max > info.slider_min)
        {
            FrameworkElement slider = MakeFieldSlider(detail_field, info, detail_target, detail_target != nullptr ? detail_target->get(info.name) : model->GetSetting(info.name));
            if (!ScopeEditable(info))
            {
                slider.IsHitTestVisible(false);
                slider.Opacity(0.5);
            }
            form_add(nullptr, slider);
        }
        page.Children().Append(form);

        TextBlock source = Wrapped(L"", 12);
        source.Foreground(TokenBrush(Root(), L"ZsDim"));
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
        auto fill_source = [this, source, reset, key, per_layer = info.per_layer != 0, per_part = info.per_part != 0, default_value = std::string(info.default_value != nullptr ? info.default_value : "")]() mutable {
            if (model == nullptr)
                return;
            if (in_profile && !ScopeIsGlobal())
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
            if (ScopeIsGlobal())
            {
                bool print = key.rfind("project.", 0) == 0;
                source.Text(print ? L"Global: for all prints, under the quality profile. Default: " + DisplayValue(key.c_str(), default_value, true)
                                  : std::wstring(L"Printer and filament settings are in their profiles (the menus at the top)."));
                reset.IsEnabled(print);
                reset.Opacity(print ? 1 : 0);
                return;
            }
            if (settings_scope >= 0)
            {
                if (!per_part)
                {
                    source.Text(L"The same for all the parts of a print. Change it with \"Settings for: This print\".");
                    reset.IsEnabled(false);
                    reset.Opacity(0);
                    return;
                }
                std::string own;
                if (PartOwnValue(key, own))
                {
                    source.Text(L"Changed for this part. Reset gives the value of the print (" + DisplayValue(key.c_str(), model->GetSetting(key.c_str()), true) + L").");
                    reset.IsEnabled(true);
                    return;
                }
            }
            // Where the value comes from, and what a reset gives. A formula
            // of this print counts as a change of this print.
            ptrdiff_t part = settings_scope >= 0 ? (ptrdiff_t)settings_scope : -1;
            int level = ZS_LEVEL_DEFAULT;
            char profile[256] = "";
            if (part < 0 && !model->Formula(key.c_str()).empty())
                level = ZS_LEVEL_PRINT;
            else if (zs_app_setting_source(model->Active(), part, key.c_str(), &level, profile, sizeof profile) != ZS_OK)
                level = ZS_LEVEL_DEFAULT;
            std::wstring def = DisplayValue(key.c_str(), default_value, true);
            std::wstring from = zs::ToWide(profile);
            std::wstring text;
            switch (level)
            {
            case ZS_LEVEL_PRINT:
            {
                char const *quality = zs_app_quality_name(model->Active());
                text = L"Changed for this print. Reset gives " + DisplayValue(key.c_str(), model->BaseValue(key.c_str()), true) + L" (from " +
                       (quality != nullptr && quality[0] != 0 ? zs::ToWide(quality) : std::wstring(L"the default")) + L").";
                break;
            }
            case ZS_LEVEL_GLOBAL: text = L"From Global. Default: " + def; break;
            case ZS_LEVEL_MACHINE: text = L"From " + (from.empty() ? std::wstring(L"Printer") : from) + L". Default: " + def; break;
            case ZS_LEVEL_FILAMENT: text = L"From " + (from.empty() ? std::wstring(L"Filament") : from) + L". Default: " + def; break;
            case ZS_LEVEL_QUALITY: text = L"From " + (from.empty() ? std::wstring(L"Quality") : from) + L". Default: " + def; break;
            default: text = L"The default (" + def + L")"; break;
            }
            source.Text(text);
            // The button keeps its space, so the help text does not move.
            bool changed = level == ZS_LEVEL_PRINT || level == ZS_LEVEL_PART;
            reset.IsEnabled(changed);
            reset.Opacity(changed ? 1 : 0);
        };
        fill_source();
        setting_editors.push_back({ key, fill_source });
        reset.Click([this, key](auto &&, auto &&) {
            if (in_profile && !ScopeIsGlobal())
                ProfileClear(key);
            else if (ScopeReset(key))
                return;
            else if (model != nullptr)
                CommitSetting(key, model->BaseValue(key.c_str()));
        });

        // A formula makes the value follow other settings. It is for the
        // whole print, so a layer profile, a part, and Global have none.
        if (info.kind != ZS_SETTING_TEXT && PaneTarget() == nullptr)
        {
            TextBox formula;
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
            TextBlock formula_name = form_name_text(L"Formula");
            formula_name.Foreground(TokenBrush(Root(), L"ZsDim"));
            form_add(formula_name, formula);
        }

        // The help: the text in `backticks` is in a code font.
        {
            namespace Documents = Microsoft::UI::Xaml::Documents;
            TextBlock doc = Wrapped(L"");
            std::wstring all = zs::ToWide(info.doc != nullptr ? info.doc : "");
            bool code = false;
            size_t from = 0;
            while (from <= all.size())
            {
                size_t tick = all.find(L'`', from);
                std::wstring part = all.substr(from, tick == std::wstring::npos ? tick : tick - from);
                if (!part.empty())
                {
                    Documents::Run run;
                    run.Text(part);
                    if (code)
                        run.FontFamily(Media::FontFamily(L"Cascadia Mono, Consolas"));
                    doc.Inlines().Append(run);
                }
                if (tick == std::wstring::npos)
                    break;
                code = !code;
                from = tick + 1;
            }
            page.Children().Append(doc);
        }
        TextBlock project_heading = Wrapped(L"In your project");
        project_heading.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        page.Children().Append(project_heading);
        // The times of its lines come again with each slice (AfterScene).
        effect_box = StackPanel{};
        effect_box.Spacing(2);
        effect_key = key;
        FillEffect(effect_box, key);
        page.Children().Append(effect_box);
        SettingsList().Children().Append(page);
        zs_setting_effect shown_effect{};
        zs_setting_get_effect(info.name, &shown_effect);
        SetPaneFocus(shown_effect.features != 0 ? shown_effect.features : (1u << ZS_FEATURE_COUNT) - 1, shown_effect.first_layer_only != 0);
        NotePanePlace();
    }

    void MainWindow::SetFieldState(EditorField &field, int state, std::wstring const &tip)
    {
        field.state = state;
        if (field.mark != nullptr)
        {
            field.mark.Visibility(state == 0 ? Visibility::Collapsed : Visibility::Visible);
            field.mark.BorderBrush(Media::SolidColorBrush(state == 2 ? Windows::UI::Color{ 255, 0xE0, 0x1B, 0x24 } : Windows::UI::Color{ 255, 0xE5, 0xA5, 0x0A }));
        }
        ToolTipService::SetToolTip(field.box, box_value(tip));
    }

    // A value out of the usual range (the slider range) is valid, but the
    // field says that it is unusual.
    void MainWindow::ShowUnusual(EditorField &field, zs_setting_info const &info, std::string const &value)
    {
        if (field.mark == nullptr || field.state == 2 || !(info.slider_max > info.slider_min))
            return;
        double v = ParsesAsNumber(value) ? strtod(value.c_str(), nullptr) : info.slider_min;
        bool unusual = v < info.slider_min - 1e-9 || v > info.slider_max + 1e-9;
        if (unusual == (field.state == 1))
            return;
        SetFieldState(field, unusual ? 1 : 0, unusual ? L"An unusual value: most prints use " + RangeText(info, info.slider_min, info.slider_max) + L".\n\n" + field.doc : field.doc);
    }

    // Adds steps to the shown value. A step is one unit of its last decimal
    // place (0.44 steps by 0.01, 150 by 1), and 1 for an integer.
    void MainWindow::StepField(EditorField &field, zs_setting_info const &info, std::wstring const &base, double steps, bool fine, int delay_ms)
    {
        bool integer = info.kind == ZS_SETTING_INTEGER;
        size_t dot = base.find(L'.');
        int decimals = 0;
        if (!integer && dot != std::wstring::npos)
            for (size_t i = dot + 1; i < base.size() && iswdigit(base[i]); i++)
                decimals++;
        if (!integer && fine)
            decimals++;
        double v = wcstod(base.c_str(), nullptr) + steps * std::pow(10.0, -decimals);
        if (integer)
            v = std::max(0.0, std::round(v));
        wchar_t text[64];
        swprintf_s(text, L"%.*f", decimals, v);
        field.shown = text;
        field.box.Text(text);
        field.box.SelectionStart((int32_t)wcslen(text));
        if (field.state == 2)
            SetFieldState(field, 0, field.doc);
        field.live.Stop();
        field.live.Interval(std::chrono::milliseconds(delay_ms));
        field.live.Start();
    }

    // The slider of a number on the detail page: it snaps to its step, has
    // a tick at the default, and sends the value during a drag.
    FrameworkElement MainWindow::MakeFieldSlider(std::shared_ptr<EditorField> const &field, zs_setting_info const &info,
                                                 std::shared_ptr<EditorTarget> const &target, std::string const &now)
    {
        double k = info.unit != nullptr && strcmp(info.unit, "%") == 0 ? 100 : 1;
        double lo = info.slider_min * k, hi = info.slider_max * k;
        double step = info.kind == ZS_SETTING_INTEGER ? 1 : info.slider_step * k;
        if (!(step > 0))
            step = std::pow(10.0, std::floor(std::log10((hi - lo) / 100)));
        int decimals = step >= 1 ? 0 : (int)std::ceil(-std::log10(step) - 1e-9);
        Slider slider;
        slider.Minimum(lo);
        slider.Maximum(hi);
        slider.StepFrequency(step);
        slider.SmallChange(step);
        slider.IsThumbToolTipEnabled(false);
        slider.VerticalAlignment(VerticalAlignment::Center);
        ToolTipService::SetToolTip(slider, box_value(field->doc));
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(slider, zs::ToWide(info.label));
        auto syncing = std::make_shared<bool>(false), held = std::make_shared<bool>(false);
        field->follow = [slider, syncing, held, k](std::string const &value) mutable {
            if (*held || !ParsesAsNumber(value))
                return;
            *syncing = true;
            slider.Value(strtod(value.c_str(), nullptr) * k);
            *syncing = false;
        };
        field->follow(now);
        zs_setting_info copy = info;
        slider.ValueChanged([this, field, syncing, lo, step, decimals](auto &&, Primitives::RangeBaseValueChangedEventArgs const &e) {
            if (*syncing)
                return;
            double v = lo + std::round((e.NewValue() - lo) / step) * step;
            wchar_t text[64];
            swprintf_s(text, L"%.*f", decimals, v);
            if (std::wstring(field->box.Text()) == text)
                return;
            field->shown = text;
            field->box.Text(text);
            if (field->state == 2)
                SetFieldState(*field, 0, field->doc);
            // Each value starts a slice: at most one each 60 ms.
            if (!field->live.IsRunning())
            {
                field->live.Interval(std::chrono::milliseconds(60));
                field->live.Start();
            }
        });
        // A drag and the typing in the field are one edit of the history.
        std::string name = info.name;
        slider.GotFocus([this, name](auto &&, auto &&) {
            if (model != nullptr && model->HistoryFocus(name.c_str()))
                RefreshHistoryButtons();
        });
        slider.LostFocus([this](auto &&, auto &&) {
            if (model != nullptr && model->HistoryFocus(nullptr))
                RefreshHistoryButtons();
        });
        slider.AddHandler(UIElement::PointerPressedEvent(), box_value(Input::PointerEventHandler([held](auto &&, auto &&) { *held = true; })), true);
        auto let_go = [this, field, held, copy, target](auto &&, auto &&) {
            *held = false;
            if (field->live.IsRunning())
            {
                field->live.Stop();
                CommitSettingText(copy, std::wstring(field->box.Text()), target.get(), field.get(), true);
            }
        };
        slider.AddHandler(UIElement::PointerReleasedEvent(), box_value(Input::PointerEventHandler(let_go)), true);
        slider.AddHandler(UIElement::PointerCaptureLostEvent(), box_value(Input::PointerEventHandler(let_go)), true);

        Grid holder;
        holder.Children().Append(slider);
        if (info.default_value != nullptr && ParsesAsNumber(std::string(info.default_value)))
        {
            double d = strtod(info.default_value, nullptr) * k;
            if (d >= lo && d <= hi)
            {
                // A tick at the default, on the track under the thumb.
                Canvas marks;
                marks.IsHitTestVisible(false);
                marks.Height(5);
                marks.VerticalAlignment(VerticalAlignment::Bottom);
                Border tick;
                tick.Width(1.5);
                tick.Height(5);
                tick.Background(TokenBrush(Root(), L"ZsDim"));
                marks.Children().Append(tick);
                holder.Children().Append(marks);
                double at = (d - lo) / (hi - lo);
                holder.SizeChanged([tick, at](auto &&, SizeChangedEventArgs const &e) {
                    // The thumb is 18 points wide: its center stops 9 from each end.
                    Canvas::SetLeft(tick, 9 + at * (e.NewSize().Width - 18) - 0.75);
                });
            }
        }
        return holder;
    }

    void MainWindow::AddScrub(FrameworkElement const &label, std::shared_ptr<EditorField> const &field, zs_setting_info const &info,
                              std::shared_ptr<EditorTarget> const &target)
    {
        if (auto element = label.try_as<IUIElementProtected>())
            element.ProtectedCursor(Microsoft::UI::Input::InputSystemCursor::Create(Microsoft::UI::Input::InputSystemCursorShape::SizeWestEast));
        struct Drag
        {
            bool on = false;
            double from = 0;
            std::wstring base;
        };
        auto drag = std::make_shared<Drag>();
        zs_setting_info copy = info;
        label.PointerPressed([label, field, drag](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto point = e.GetCurrentPoint(nullptr);
            if (!point.Properties().IsLeftButtonPressed() || !field->box.IsEnabled())
                return;
            drag->on = true;
            drag->from = point.Position().X;
            drag->base = field->box.Text();
            label.CapturePointer(e.Pointer());
            e.Handled(true);
        });
        label.PointerMoved([this, field, drag, copy](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!drag->on || !ParsesAsNumber(drag->base))
                return;
            auto mods = static_cast<uint32_t>(e.KeyModifiers());
            double steps = std::trunc((e.GetCurrentPoint(nullptr).Position().X - drag->from) / 6);
            if ((mods & static_cast<uint32_t>(Windows::System::VirtualKeyModifiers::Shift)) != 0)
                steps *= 10;
            StepField(*field, copy, drag->base, steps, (mods & static_cast<uint32_t>(Windows::System::VirtualKeyModifiers::Control)) != 0, 60);
            e.Handled(true);
        });
        auto ended = [this, label, field, drag, copy, target](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!drag->on)
                return;
            drag->on = false;
            label.ReleasePointerCapture(e.Pointer());
            // The last value goes to the core at once.
            if (field->live.IsRunning())
            {
                field->live.Stop();
                CommitSettingText(copy, std::wstring(field->box.Text()), target.get(), field.get(), true);
            }
        };
        label.PointerReleased(ended);
        label.PointerCaptureLost(ended);
    }

    bool MainWindow::CommitSettingText(zs_setting_info const &info, std::wstring const &text, EditorTarget const *target, EditorField *field, bool quiet)
    {
        if (model == nullptr || filling_editor)
            return false;
        bool is_number = (info.kind == ZS_SETTING_NUMBER || info.kind == ZS_SETTING_INTEGER) && !IsFilamentSetting(info.name);
        std::wstring typed = info.kind == ZS_SETTING_TEXT ? WithLineFeeds(text) : text;
        std::string now = target != nullptr ? target->get(info.name) : model->GetSetting(info.name);
        auto fine = [&] {
            if (field != nullptr && field->state == 2)
            {
                SetFieldState(*field, 0, field->doc);
                ShowUnusual(*field, info, target != nullptr ? target->get(info.name) : model->GetSetting(info.name));
            }
            return true;
        };
        // The text that the field shows for the value now, such as "auto"
        // or "no limit": no change, and no step in the history.
        if (is_number && DisplayValue(info.name, now, false) == typed)
            return fine();
        // The core rules. A text that is not a number, such as a formula,
        // goes as it is, and the core takes it or says why.
        std::string utf8 = zs::ToUtf8(typed), value = utf8;
        size_t len = 0;
        if (zs_setting_parse(info.name, utf8.c_str(), nullptr, 0, &len) == ZS_OK)
        {
            value.assign(len + 1, '\0');
            zs_setting_parse(info.name, utf8.c_str(), value.data(), value.size(), &len);
            value.resize(len);
        }
        auto refuse = [&](std::wstring const &why) {
            if (quiet)
                return false;
            if (field != nullptr && field->mark != nullptr)
                SetFieldState(*field, 2, why);
            else
                ShowToast(zs::ToWide(info.label) + L": " + why);
            return false;
        };
        // Out of the hard limits: say what the limits are.
        if (is_number && info.limit_max > info.limit_min && ParsesAsNumber(value))
        {
            double v = strtod(value.c_str(), nullptr);
            if (v < info.limit_min - 1e-12 || v > info.limit_max + 1e-12)
                return refuse(L"Out of the limits: use " + RangeText(info, info.limit_min, info.limit_max) + L".");
        }
        bool same = now == value;
        if (!same && is_number && ParsesAsNumber(now) && ParsesAsNumber(value))
            same = strtod(now.c_str(), nullptr) == strtod(value.c_str(), nullptr);
        if (same)
            return fine();
        if (target != nullptr)
        {
            target->set(info.name, value);
        }
        else
        {
            std::string error;
            if (!model->SetSetting(info.name, value, error))
                return refuse(zs::ToWide(error));
            KeepEnginePref(info.name);
            NoteChange();
            // A formula can change other settings.
            RefreshSettingValues();
        }
        fine();
        if (field != nullptr)
            ShowUnusual(*field, info, target != nullptr ? target->get(info.name) : model->GetSetting(info.name));
        return true;
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
        ScopeRefresh();
        RefreshPartSettings();
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
        CancelFall();
        if (model != nullptr && (bits & ZS_HISTORY_MOVED) != 0)
        {
            // The marks moved: the row of a mark must not keep its index.
            line_mark = -1;
            LineMark().Visibility(Visibility::Collapsed);
            ShowPlateName();
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
