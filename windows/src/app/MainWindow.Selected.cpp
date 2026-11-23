// The Selected page of the settings pane: what a clicked line, part, or gap
// is. A line has its speeds with the reason for each, its measurements, the
// settings that change it in sections, how its values come about at the
// foot of the page, and "Change for": this print, this
// layer, this layer and up, or this layer and down. A part has its place, its
// quality, and its placement. A gap has the settings that can close it.
//
// After a new slice of the same line the page changes its text in place, so
// the editor with the focus keeps it. The behavior and the words follow the
// GTK shell (linux/src/ui/inspector.c, part-page.c, and setting-row.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#include <winrt/Microsoft.UI.Xaml.Documents.h>

#include <algorithm>
#include <cmath>
#include <cwctype>
#include <map>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    namespace
    {
        wchar_t const *const stat_names[3] = { L"planned speed", L"real speed", L"flow" };
        char const *const feature_names[] = { "outer wall", "inner wall", "skin", "sparse infill", "ironing", "skirt or brim",
                                              "support", "support interface", "slope smoothing", "slope ironing" };

        std::wstring Lower(std::wstring text)
        {
            std::transform(text.begin(), text.end(), text.begin(), [](wchar_t c) { return (wchar_t)std::towlower(c); });
            return text;
        }

        TextBlock Text(std::wstring const &text, double size = 13, bool dim = false, bool bold = false)
        {
            TextBlock t;
            t.Text(text);
            t.FontSize(size);
            t.TextWrapping(TextWrapping::WrapWholeWords);
            if (dim)
                t.Opacity(0.7);
            if (bold)
                t.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
            return t;
        }

        Button SmallButton(wchar_t const *text, wchar_t const *tip = nullptr)
        {
            Button b;
            b.Content(box_value(text));
            b.FontSize(12.5);
            b.Padding(ThicknessHelper::FromLengths(9, 4, 9, 4));
            if (tip != nullptr)
                ToolTipService::SetToolTip(b, box_value(tip));
            return b;
        }

        bool Inside(DependencyObject at, DependencyObject const &box)
        {
            while (at != nullptr)
            {
                if (at == box)
                    return true;
                at = Media::VisualTreeHelper::GetParent(at);
            }
            return false;
        }
    }

    struct MainWindow::SelectedPage
    {
        enum class Kind
        {
            Hint,
            Line,
            Part,
            Gap,
        } kind = Kind::Hint;
        std::string signature;
        StackPanel root{ nullptr };
        // The line.
        TextBlock title{ nullptr }, note{ nullptr }, measure{ nullptr };
        StackPanel foot{ nullptr };
        std::wstring foot_shown;
        TextBlock stats[3] = { nullptr, nullptr, nullptr };
        std::wstring why[3];
        double z = 0;
        struct Row
        {
            std::string name;
            std::wstring needle;
            StackPanel box{ nullptr };
            TextBlock label{ nullptr }, why{ nullptr };
            Button reset{ nullptr };
            StackPanel under{ nullptr };
            FrameworkElement editor{ nullptr };
            Control focus{ nullptr };
            bool open = false;
        };
        std::vector<std::shared_ptr<Row>> rows;
        std::vector<Expander> sections;
        std::shared_ptr<EditorTarget> target;
        // The part.
        uint64_t part = 0;
        bool filling = false;
        TextBlock part_title{ nullptr }, part_size{ nullptr }, part_file{ nullptr }, part_file_head{ nullptr };
        NumberBox x{ nullptr }, y{ nullptr }, turn{ nullptr }, scale{ nullptr };
        ComboBox quality{ nullptr };
    };

    // ---- where the page shows ----

    // A click on a line, a part, or a gap: the page, now or at the next
    // open of the panel.
    void MainWindow::GoToSelected()
    {
        if (SettingsPane().Visibility() == Visibility::Visible)
            ShowSelected();
        else
            selected_wanted = true;
    }

    void MainWindow::ShowBrowserRows(bool show)
    {
        auto state = show ? Visibility::Visible : Visibility::Collapsed;
        SettingsScopeRow().Visibility(state);
        SettingsSearch().Visibility(state);
    }

    std::wstring MainWindow::SelectedTitle()
    {
        if (page_gap)
            return L"Selected gap";
        return PrimaryPart() >= 0 ? L"Selected part" : L"Selected line";
    }

    std::string MainWindow::SelectedSignature()
    {
        if (model == nullptr)
            return {};
        if (page_gap)
            return "gap:" + std::to_string(gap_selected_layer) + ":" + std::to_string(gap_selected) + ":" + std::to_string(page_gap_serial);
        zs_app *app = model->Active();
        int64_t part = PrimaryPart();
        if (part >= 0)
            return "part:" + std::to_string(zs_app_part_id(app, (size_t)part));
        int64_t path = SelectedPath();
        zs_inspect info{};
        if (path >= 0 && zs_app_inspect(app, (size_t)path, &info) == ZS_OK)
            return std::string("line:") + info.title + "\n" + info.settings;
        return {};
    }

    void MainWindow::ShowSelected()
    {
        if (model == nullptr)
            return;
        if (settings_page != SettingsPage::Selected)
            selected_from = pane_now;
        ClearSettingsList();
        selected_wanted = false;
        settings_page = SettingsPage::Selected;
        ShowBrowserRows(false);
        SettingsBack().Visibility(Visibility::Visible);
        auto page = std::make_shared<SelectedPage>();
        selected_page = page;
        page->signature = SelectedSignature();
        page->root = StackPanel();
        page->root.Spacing(7);
        page->root.Padding(ThicknessHelper::FromLengths(4, 2, 0, 12));
        if (page_gap)
            BuildGapPage(*page);
        else if (PrimaryPart() >= 0)
            BuildPartPage(*page);
        else if (!page->signature.empty())
            BuildLinePage(*page);
        else
            page->root.Children().Append(Text(L"Click a line in the preview (2D or 3D) to see what it is, its real values, and the settings that change it.", 13, true));
        SettingsList().Children().Append(page->root);
        NotePanePlace();
        UpdateSelectedText();
    }

    // After each change of the selection, and after each slice.
    void MainWindow::RefreshSelectedPage()
    {
        if (settings_page != SettingsPage::Selected || selected_page == nullptr)
            return;
        if (SettingsPane().Visibility() != Visibility::Visible)
        {
            selected_wanted = true;
            return;
        }
        // A value under a slider can remove the line for this slice: the
        // page stays, dimmed, so the slider stays under the pointer.
        if (line_lost && selected_page->kind == SelectedPage::Kind::Line)
        {
            selected_page->root.Opacity(0.5);
            return;
        }
        if (SelectedSignature() == selected_page->signature)
        {
            UpdateSelectedText();
            return;
        }
        // The event can come from an element of this page.
        if (selected_rebuild)
            return;
        selected_rebuild = true;
        queue.TryEnqueue([weak = get_weak()] {
            auto self = weak.get();
            if (self == nullptr)
                return;
            self->selected_rebuild = false;
            if (self->settings_page == SettingsPage::Selected)
                self->ShowSelected();
        });
    }

    // While a slice runs, the numbers are old.
    void MainWindow::SelectedStale(bool stale)
    {
        if (settings_page == SettingsPage::Selected && selected_page != nullptr && !line_lost)
            selected_page->root.Opacity(stale ? 0.65 : 1);
    }

    // A new slice with a gap selected: the same gap by its place, or the
    // news that it is closed.
    void MainWindow::RefindSelectedGap()
    {
        if (!page_gap || page_gap_closed || model == nullptr)
            return;
        zs_gap const *gaps = nullptr;
        size_t n = 0;
        int64_t found = -1;
        double best = 1.0;
        if (zs_app_layer_gaps(model->Active(), gap_selected_layer, &gaps, &n, nullptr, nullptr) == ZS_OK)
            for (size_t i = 0; i < n; i++)
            {
                double d = std::hypot(gaps[i].x - page_gap_x, gaps[i].y - page_gap_y);
                if (d < best)
                {
                    best = d;
                    found = (int64_t)i;
                }
            }
        if (found >= 0)
            gap_selected = found;
        else
            page_gap_closed = true;
        page_gap_serial++;
    }

    // ---- the line ----

    double MainWindow::SelectedLow() const
    {
        return selected_scope == 1 || selected_scope == 2 ? selected_page->z : -1e6;
    }

    double MainWindow::SelectedHigh() const
    {
        return selected_scope == 1 || selected_scope == 3 ? selected_page->z : 1e6;
    }

    void MainWindow::SelectedSet(std::string const &name, std::string const &value)
    {
        zs_setting_info info{};
        bool per_layer = false;
        for (size_t i = 0, n = zs_setting_count(); i < n; i++)
            if (zs_setting_get_info(i, &info) == ZS_OK && name == info.name)
            {
                per_layer = info.per_layer != 0;
                break;
            }
        if (!per_layer)
        {
            CommitSetting(name, value);
        }
        else
        {
            // A multiple selection: the scope covers the layers of all its
            // lines. This layer is each of their layers. And up, and down,
            // go from the lowest or to the highest of them.
            zs_app *app = model->Active();
            double lo = SelectedLow(), hi = SelectedHigh();
            bool up = hi > 1e5, down = lo < -1e5;
            int rc = ZS_OK;
            if (line_more.empty() || (up && down))
            {
                rc = zs_app_override_set(app, lo, hi, name.c_str(), value.c_str());
            }
            else if (up || down)
            {
                double zmin = selected_page->z, zmax = selected_page->z;
                for (MoreLine const &line : line_more)
                {
                    zmin = std::min(zmin, line.z);
                    zmax = std::max(zmax, line.z);
                }
                rc = zs_app_override_set(app, up ? zmin - 1e-3 : lo, down ? zmax + 1e-3 : hi, name.c_str(), value.c_str());
            }
            else
            {
                rc = zs_app_override_set(app, lo, hi, name.c_str(), value.c_str());
                for (MoreLine const &line : line_more)
                    if (rc == ZS_OK)
                        rc = zs_app_override_set(app, line.z - 1e-3, line.z + 1e-3, name.c_str(), value.c_str());
            }
            if (rc != ZS_OK)
            {
                ShowToast(zs::ToWide(zs_status_message(rc)));
                return;
            }
            model->RequestSlice();
            NoteChange();
            ProfilesRefresh();
        }
        DrawSelectedRows();
    }

    // A setting that the scope cannot have is off. A change of these layers
    // has the accent color and a reset button.
    void MainWindow::DrawSelectedRows()
    {
        if (selected_page == nullptr || model == nullptr)
            return;
        zs_app *app = model->Active();
        bool whole = selected_scope == 0;
        for (auto const &row : selected_page->rows)
        {
            zs_setting_info info{};
            bool known = false;
            for (size_t i = 0, n = zs_setting_count(); i < n && !known; i++)
                known = zs_setting_get_info(i, &info) == ZS_OK && row->name == info.name;
            if (!known)
                continue;
            bool usable = whole ? strcmp(info.group, "project") == 0 || strcmp(info.group, "filament") == 0 : info.per_layer != 0;
            if (auto control = row->editor.try_as<Control>())
                control.IsEnabled(usable);
            else
                row->editor.IsHitTestVisible(usable);
            row->editor.Opacity(usable ? 1 : 0.5);
            row->label.Opacity(usable ? 1 : 0.5);
            if (!usable)
                ToolTipService::SetToolTip(row->editor, box_value(whole ? L"A printer setting: change it in the Settings page."
                                                                        : L"A setting for the whole part: it cannot change for some layers. Set \"Change for\" to this print."));
            bool over = zs_app_override_at(app, selected_page->z, row->name.c_str()) != 0;
            row->label.Foreground(TokenBrush(Root(), over ? L"ZsAccentText" : L"ZsFg"));
            row->reset.Opacity(over ? 1 : 0);
            row->reset.IsEnabled(over);
        }
    }

    // What the setting of a focused row does to the selected line.
    std::wstring MainWindow::SelectedWhy(std::string const &key)
    {
        zs_app *app = model->Active();
        int64_t path = SelectedPath();
        zs_inspect info{};
        if (path < 0 || zs_app_inspect(app, (size_t)path, &info) != ZS_OK)
            return {};
        zs_setting_effect e{};
        zs_setting_get_effect(key.c_str(), &e);
        bool known = info.feature >= 0 && info.feature < ZS_FEATURE_COUNT;
        bool mine = known && ((e.features >> info.feature) & 1) != 0 && !(e.first_layer_only != 0 && info.layer > 0);
        std::wstring kind = known ? Lower(zs::ToWide(info.title)) : L"this";
        wchar_t t[240] = L"";
        double base = 0;
        if (zs_app_ratio_speed(app, key.c_str(), "1", &base) == ZS_OK)
        {
            double ratio = atof(selected_page->target->get(key).c_str());
            if (mine)
            {
                int used = swprintf_s(t, L"This line: %.0f %% of %.0f mm/s = %.0f mm/s planned.", ratio * 100, base, info.planned_speed);
                if (info.speed < info.planned_speed - 0.5 && used > 0)
                    swprintf_s(t + used, std::size(t) - used, L" It prints at %.0f mm/s: the layer is short, and it slows to cool.", info.speed);
            }
            else
            {
                swprintf_s(t, L"Not this line: this %s line has its own speed (%.0f mm/s planned).", kind.c_str(), info.planned_speed);
            }
        }
        else if (key == "project.line_width" || key == "project.first_layer_line_width")
        {
            if (mine)
                swprintf_s(t, L"This line: %.2f mm planned; the bead is %.2f mm wide.", info.line_width, info.bead_width);
        }
        else if (key == "project.layer_height" || key == "project.first_layer_height")
        {
            swprintf_s(t, L"This layer: %.2f mm high, at z %.2f mm.", info.height, info.z);
        }
        else if (key == "filament.max_flow" || key == "filament.flow_ratio")
        {
            swprintf_s(t, L"This line: %.1f mm³/s of plastic at %.0f mm/s.", info.flow, info.speed);
        }
        else if (key == "filament.min_layer_time" || key == "filament.min_speed")
        {
            if (info.speed < info.planned_speed - 0.5)
                swprintf_s(t, L"This layer is short: the line slows from %.0f to %.0f mm/s to cool.", info.planned_speed, info.speed);
            else
                swprintf_s(t, L"This layer is long enough: no slow-down.");
        }
        if (t[0] != 0)
            return t;
        if (mine)
            return L"It changes this line, and all " + kind + L" lines. The view shows the lines that it changes.";
        if (e.features == 0)
            return e.note != nullptr && e.note[0] != 0 ? zs::ToWide(e.note) : std::wstring(L"It changes no line in the view.");
        return L"It does not change this " + kind + L" line. The view shows the lines that it changes.";
    }

    void MainWindow::AddSelectedRow(StackPanel const &into, zs_setting_info const &info)
    {
        auto page = selected_page;
        auto row = std::make_shared<SelectedPage::Row>();
        row->name = info.name;
        row->needle = Lower(zs::ToWide(info.label));
        row->box = StackPanel();
        row->box.Spacing(2);
        Grid line;
        line.ColumnSpacing(6);
        ColumnDefinition a, b, c;
        a.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        b.Width(GridLengthHelper::FromValueAndType(150, GridUnitType::Pixel));
        c.Width(GridLengthHelper::Auto());
        line.ColumnDefinitions().Append(a);
        line.ColumnDefinitions().Append(b);
        line.ColumnDefinitions().Append(c);
        row->label = Text(zs::ToWide(info.label));
        row->label.VerticalAlignment(VerticalAlignment::Center);
        ToolTipService::SetToolTip(row->label, box_value(zs::ToWide(info.label) + L" (" + zs::ToWide(info.group) + L" setting)\n\n" + SettingDocText(info.doc)));
        line.Children().Append(row->label);
        row->editor = MakeEditor(info, page->target);
        auto field = made_field;
        if (field != nullptr)
        {
            row->focus = field->box;
            AddScrub(row->label, field, info, page->target);
        }
        Grid::SetColumn(row->editor, 1);
        line.Children().Append(row->editor);
        row->reset = Button();
        row->reset.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        row->reset.BorderThickness(ThicknessHelper::FromUniformLength(0));
        row->reset.Padding(ThicknessHelper::FromUniformLength(5));
        FontIcon undo;
        undo.Glyph(L"\xE7A7");
        undo.FontSize(12);
        row->reset.Content(undo);
        Automation::AutomationProperties::SetName(row->reset, L"Remove the change for these layers");
        ToolTipService::SetToolTip(row->reset, box_value(L"Remove the change for these layers: use the value for all layers."));
        std::string name = info.name;
        row->reset.Click([this, name](auto &&, auto &&) {
            if (selected_page == nullptr || model == nullptr)
                return;
            zs_app *app = model->Active();
            if (!zs_app_override_remove(app, SelectedLow(), SelectedHigh(), name.c_str()) &&
                zs_app_override_clear_at(app, selected_page->z, name.c_str()) == 0)
                return;
            model->RequestSlice();
            NoteChange();
            ProfilesRefresh();
            for (auto const &editor : setting_editors)
                editor.refresh();
            DrawSelectedRows();
        });
        Grid::SetColumn(row->reset, 2);
        line.Children().Append(row->reset);
        row->box.Children().Append(line);

        // Under the row while it has the focus: its slider, and what this
        // setting does to the selected line.
        row->under = StackPanel();
        row->under.Spacing(2);
        row->under.Visibility(Visibility::Collapsed);
        if (field != nullptr && info.slider_max > info.slider_min)
            row->under.Children().Append(MakeFieldSlider(field, info, page->target, page->target->get(name)));
        row->why = Text(L"", 12, true);
        row->under.Children().Append(row->why);
        row->box.Children().Append(row->under);
        auto open = [this, row](bool on) {
            if (row->open == on || selected_page == nullptr)
                return;
            row->open = on;
            row->under.Visibility(on ? Visibility::Visible : Visibility::Collapsed);
            if (!on)
            {
                SetPaneFocus(0, false);
                return;
            }
            row->why.Text(SelectedWhy(row->name));
            zs_setting_effect e{};
            zs_setting_get_effect(row->name.c_str(), &e);
            SetPaneFocus(e.features, e.first_layer_only != 0);
        };
        row->box.GotFocus([open](auto &&, auto &&) { open(true); });
        // After the focus moves: a click from the field on the slider keeps
        // the row open.
        row->box.LostFocus([this, row, open](auto &&, auto &&) {
            queue.TryEnqueue([this, row, open] {
                if (Content() == nullptr || Content().XamlRoot() == nullptr)
                    return;
                auto now = Input::FocusManager::GetFocusedElement(Content().XamlRoot()).try_as<DependencyObject>();
                if (now == nullptr || !Inside(now, row->box))
                    open(false);
            });
        });
        page->rows.push_back(row);
        into.Children().Append(row->box);
    }

    void MainWindow::ShowWhyFlyout(int index, Button const &button)
    {
        if (selected_page == nullptr || selected_page->why[index].empty())
            return;
        TextBlock text;
        text.TextWrapping(TextWrapping::Wrap);
        text.MaxWidth(340);
        text.FontSize(13);
        Flyout flyout;
        AppendLinkedText(text, selected_page->why[index], [flyout] { flyout.Hide(); });
        flyout.Content(text);
        flyout.ShowAt(button);
    }

    // A text of the core: each {{name}} is a link to that setting.
    void MainWindow::AppendLinkedText(TextBlock const &text, std::wstring const &why, std::function<void()> const &before)
    {
        namespace Documents = Microsoft::UI::Xaml::Documents;
        size_t at = 0;
        while (at < why.size())
        {
            size_t open = why.find(L"{{", at);
            size_t close = open == std::wstring::npos ? open : why.find(L"}}", open + 2);
            if (close == std::wstring::npos)
            {
                Documents::Run tail;
                tail.Text(why.substr(at));
                text.Inlines().Append(tail);
                break;
            }
            if (open > at)
            {
                Documents::Run run;
                run.Text(why.substr(at, open - at));
                text.Inlines().Append(run);
            }
            std::string name = zs::ToUtf8(why.substr(open + 2, close - open - 2));
            std::wstring label = zs::ToWide(name);
            for (size_t i = 0, n = zs_setting_count(); i < n; i++)
            {
                zs_setting_info info{};
                if (zs_setting_get_info(i, &info) == ZS_OK && name == info.name)
                {
                    label = zs::ToWide(info.label);
                    break;
                }
            }
            Documents::Run run;
            run.Text(label);
            Documents::Hyperlink link;
            link.Inlines().Append(run);
            link.Click([this, name, before](auto &&, auto &&) {
                if (before)
                    before();
                queue.TryEnqueue([this, name] { OpenSelectedLink(name); });
            });
            text.Inlines().Append(link);
            at = close + 2;
        }
    }

    // How the values of the line come about: the facts that the line card
    // leaves out. The rows change only when a text changes, so the page
    // keeps its place after a slice.
    void MainWindow::FillSelectedFoot(zs_inspect const &info)
    {
        SelectedPage &page = *selected_page;
        std::vector<std::pair<std::wstring, std::wstring>> facts;
        wchar_t head[64];
        swprintf_s(head, L"Planned speed %.0f mm/s", info.planned_speed);
        facts.push_back({ head, zs::ToWide(info.why_planned != nullptr ? info.why_planned : "") });
        swprintf_s(head, L"Real speed %.0f mm/s", info.speed);
        facts.push_back({ head, zs::ToWide(info.why_real != nullptr ? info.why_real : "") });
        swprintf_s(head, L"Flow %.1f mm³/s", info.flow);
        facts.push_back({ head, zs::ToWide(info.why_flow != nullptr ? info.why_flow : "") });
        facts.push_back({ L"Slower than planned", zs::ToWide(info.slow_text != nullptr ? info.slow_text : "") });
        if (info.flow_limited != 0 && info.max_flow > 0)
        {
            wchar_t limit[96];
            swprintf_s(limit, L"The flow limit (%.0f mm³/s) sets the speed of this line, not the printer.", info.max_flow);
            facts.push_back({ L"Flow limit", limit });
        }
        zs_pick picks[4];
        size_t n = 0;
        if (zs_app_inspect_picks(model->Active(), (size_t)SelectedPath(), picks, std::size(picks), &n) != ZS_OK)
            n = 0;
        for (size_t i = 0; i < std::min(n, std::size(picks)); i++)
        {
            std::wstring label = zs::ToWide(picks[i].name);
            for (size_t k = 0, all = zs_setting_count(); k < all; k++)
            {
                zs_setting_info s{};
                if (zs_setting_get_info(k, &s) == ZS_OK && strcmp(s.name, picks[i].name) == 0)
                {
                    label = zs::ToWide(s.label);
                    break;
                }
            }
            facts.push_back({ label, zs::ToWide(picks[i].why != nullptr ? picks[i].why : "") });
        }
        facts.push_back({ L"", zs::ToWide(info.explain != nullptr ? info.explain : "") });
        std::wstring key;
        for (auto const &fact : facts)
            key += fact.first + L"\n" + fact.second + L"\n";
        if (key == page.foot_shown)
            return;
        page.foot_shown = key;
        page.foot.Children().Clear();
        for (auto const &fact : facts)
        {
            if (fact.second.empty())
                continue;
            StackPanel item;
            item.Spacing(2);
            if (!fact.first.empty())
                item.Children().Append(Text(fact.first, 12.5, false, true));
            TextBlock body;
            body.TextWrapping(TextWrapping::WrapWholeWords);
            body.FontSize(12.5);
            body.Foreground(TokenBrush(Root(), L"ZsDim"));
            AppendLinkedText(body, fact.second, nullptr);
            item.Children().Append(body);
            page.foot.Children().Append(item);
        }
    }

    // A link in a "why" text: the field of that setting on this page, or
    // the setting in the Settings page.
    void MainWindow::OpenSelectedLink(std::string const &name)
    {
        if (selected_page != nullptr)
            for (auto const &row : selected_page->rows)
                if (row->name == name && row->focus != nullptr && row->box.ActualHeight() > 0)
                {
                    row->focus.Focus(FocusState::Programmatic);
                    return;
                }
        detail_from = SettingsPage::Sections;
        ShowDetail(name.c_str());
    }

    void MainWindow::BuildLinePage(SelectedPage &page)
    {
        page.kind = SelectedPage::Kind::Line;
        zs_app *app = model->Active();
        zs_inspect info{};
        if (zs_app_inspect(app, (size_t)SelectedPath(), &info) != ZS_OK)
            return;
        page.z = info.z;
        page.target = std::make_shared<EditorTarget>();
        page.target->get = [this](std::string const &name) {
            if (model == nullptr || selected_page == nullptr)
                return std::string();
            zs_app *now = model->Active();
            size_t len = 0;
            if (zs_app_setting_get_at(now, selected_page->z, name.c_str(), nullptr, 0, &len) != ZS_OK)
                return model->GetSetting(name.c_str());
            std::string text(len + 1, '\0');
            zs_app_setting_get_at(now, selected_page->z, name.c_str(), text.data(), text.size(), &len);
            text.resize(len);
            return text;
        };
        page.target->set = [this](std::string const &name, std::string const &value) { SelectedSet(name, value); };

        page.title = Text(L"", 16, false, true);
        page.root.Children().Append(page.title);
        Grid stats;
        stats.ColumnSpacing(6);
        for (int i = 0; i < 3; i++)
        {
            ColumnDefinition column;
            column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            stats.ColumnDefinitions().Append(column);
            Button button;
            button.HorizontalAlignment(HorizontalAlignment::Stretch);
            button.HorizontalContentAlignment(HorizontalAlignment::Center);
            button.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            button.Padding(ThicknessHelper::FromLengths(3, 4, 3, 4));
            ToolTipService::SetToolTip(button, box_value(L"Why this value? Click for the numbers and the settings that change it."));
            StackPanel box;
            page.stats[i] = Text(L"", 15, false, true);
            page.stats[i].TextAlignment(TextAlignment::Center);
            auto caption = Text(stat_names[i], 11, true);
            caption.TextAlignment(TextAlignment::Center);
            box.Children().Append(page.stats[i]);
            box.Children().Append(caption);
            button.Content(box);
            button.Click([this, i, button](auto &&, auto &&) { ShowWhyFlyout(i, button); });
            Grid::SetColumn(button, i);
            stats.Children().Append(button);
        }
        page.root.Children().Append(stats);
        page.note = Text(L"", 12);
        page.note.Foreground(TokenBrush(Root(), L"ZsWarning"));
        page.note.Visibility(Visibility::Collapsed);
        page.root.Children().Append(page.note);
        page.measure = Text(L"", 12);
        ToolTipService::SetToolTip(page.measure, box_value(L"The measurements of the selected segment: its length, the straight edge that it is a part of, the whole line, and the radius of a circle or an arc."));
        page.root.Children().Append(page.measure);
        AddSelectedMark(page);

        // Change for: all layers, or the layers of the selection.
        Grid change;
        change.ColumnSpacing(8);
        change.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
        ColumnDefinition c0, c1;
        c0.Width(GridLengthHelper::Auto());
        c1.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        change.ColumnDefinitions().Append(c0);
        change.ColumnDefinitions().Append(c1);
        auto change_label = Text(L"Change for", 13, true);
        change_label.VerticalAlignment(VerticalAlignment::Center);
        change.Children().Append(change_label);
        ComboBox scope;
        scope.HorizontalAlignment(HorizontalAlignment::Stretch);
        for (wchar_t const *item : { L"This print (all layers)", L"This layer", L"This layer and up", L"This layer and down" })
            scope.Items().Append(box_value(item));
        scope.SelectedIndex(selected_scope);
        Automation::AutomationProperties::SetName(scope, L"Change for");
        ToolTipService::SetToolTip(scope, box_value(L"Changes here are for this print: for all its layers, or only for the layers of the selected line. A changed setting shows in the accent color, with a button to remove the change. For one part of the plate: Settings, then Settings for: the part."));
        scope.SelectionChanged([this, scope](auto &&, auto &&) {
            if (scope.SelectedIndex() < 0 || selected_page == nullptr)
                return;
            selected_scope = scope.SelectedIndex();
            for (auto const &editor : setting_editors)
                editor.refresh();
            DrawSelectedRows();
        });
        Grid::SetColumn(scope, 1);
        change.Children().Append(scope);
        page.root.Children().Append(change);
        page.root.Children().Append(Text(L"Changes here are for this print. Settings has the settings of one part, and your profiles.", 11.5, true));

        TextBox filter;
        filter.PlaceholderText(L"Filter settings");
        Automation::AutomationProperties::SetName(filter, L"Filter settings");
        filter.TextChanged([this, filter](auto &&, auto &&) {
            if (selected_page == nullptr)
                return;
            std::wstring needle = Lower(std::wstring(filter.Text()));
            for (auto const &row : selected_page->rows)
                row->box.Visibility(needle.empty() || row->needle.find(needle) != std::wstring::npos ? Visibility::Visible : Visibility::Collapsed);
            for (auto const &section : selected_page->sections)
            {
                selected_filtering = true;
                section.IsExpanded(!needle.empty() || SelectedSectionOpen(std::wstring(unbox_value<hstring>(section.Tag()))));
                selected_filtering = false;
            }
        });
        page.root.Children().Append(filter);

        // Each "# Name" line of the core starts a section.
        StackPanel into = page.root;
        std::string names = info.settings != nullptr ? info.settings : "";
        size_t at = 0;
        while (at <= names.size())
        {
            size_t end = names.find('\n', at);
            if (end == std::string::npos)
                end = names.size();
            std::string name = names.substr(at, end - at);
            at = end + 1;
            if (name.empty())
                continue;
            if (name.rfind("# ", 0) == 0)
            {
                std::wstring title = zs::ToWide(name.substr(2));
                Expander section;
                section.HorizontalAlignment(HorizontalAlignment::Stretch);
                section.HorizontalContentAlignment(HorizontalAlignment::Stretch);
                section.Header(Text(title, 13, false, true));
                section.Tag(box_value(title));
                section.IsExpanded(SelectedSectionOpen(title));
                section.Expanding([this, title](auto &&, auto &&) {
                    if (!selected_filtering)
                        selected_sections[title] = true;
                });
                section.Collapsed([this, title](auto &&, auto &&) {
                    if (!selected_filtering)
                        selected_sections[title] = false;
                });
                StackPanel body;
                body.Spacing(4);
                section.Content(body);
                page.root.Children().Append(section);
                page.sections.push_back(section);
                into = body;
                continue;
            }
            for (size_t i = 0, n = zs_setting_count(); i < n; i++)
            {
                zs_setting_info s{};
                if (zs_setting_get_info(i, &s) == ZS_OK && name == s.name)
                {
                    AddSelectedRow(into, s);
                    break;
                }
            }
        }

        // At the foot of the page: the line card does not show this.
        auto foot_head = Text(L"How these values come about", 14, false, true);
        foot_head.Margin(ThicknessHelper::FromLengths(0, 12, 0, 2));
        page.root.Children().Append(foot_head);
        page.foot = StackPanel();
        page.foot.Spacing(8);
        page.root.Children().Append(page.foot);
        DrawSelectedRows();
    }

    bool MainWindow::SelectedSectionOpen(std::wstring const &title)
    {
        auto it = selected_sections.find(title);
        return it != selected_sections.end() ? it->second : title != L"Material";
    }

    // "Support you added": the kind and the size of the mark, and Remove.
    void MainWindow::AddSelectedMark(SelectedPage &page)
    {
        int64_t mark = MarkOfSelection();
        double radius = 3;
        int kind = 0;
        if (mark < 0 || zs_app_mark_get(model->Active(), (size_t)mark, nullptr, nullptr, nullptr, &radius, &kind) != ZS_OK)
            return;
        auto head = Text(L"Support you added", 13, false, true);
        head.Margin(ThicknessHelper::FromLengths(0, 8, 0, 0));
        page.root.Children().Append(head);
        StackPanel row;
        row.Orientation(Orientation::Horizontal);
        row.Spacing(6);
        ComboBox kinds;
        for (wchar_t const *item : { L"Grid", L"Tree", L"Bridge pad", L"Block (no support)" })
            kinds.Items().Append(box_value(item));
        kinds.SelectedIndex(kind);
        Automation::AutomationProperties::SetName(kinds, L"The kind of the support");
        NumberBox size;
        size.Minimum(0.5);
        size.Maximum(30);
        size.SmallChange(0.5);
        size.Value(radius);
        size.SpinButtonPlacementMode(NumberBoxSpinButtonPlacementMode::Compact);
        Automation::AutomationProperties::SetName(size, L"The radius of the area of the mark, mm");
        ToolTipService::SetToolTip(size, box_value(L"The radius of the area of the mark, mm"));
        auto write = [this, mark, kinds, size] {
            if (model == nullptr || kinds.SelectedIndex() < 0 || std::isnan(size.Value()))
                return;
            if (zs_app_mark_set(model->Active(), (size_t)mark, kinds.SelectedIndex(), size.Value()) == ZS_OK)
                SupportEdited();
        };
        kinds.SelectionChanged([write](auto &&, auto &&) { write(); });
        size.ValueChanged([write](auto &&, auto &&) { write(); });
        Button remove = SmallButton(L"Remove");
        remove.Foreground(Media::SolidColorBrush(Windows::UI::Color{ 255, 192, 28, 40 }));
        remove.Click([this, mark](auto &&, auto &&) {
            if (model == nullptr)
                return;
            zs_app_mark_remove(model->Active(), (size_t)mark);
            SupportEdited();
            if (selected_page != nullptr)
                queue.TryEnqueue([this] {
                    if (settings_page == SettingsPage::Selected)
                        ShowSelected();
                });
        });
        row.Children().Append(kinds);
        row.Children().Append(size);
        auto unit = Text(L"mm", 12, true);
        unit.VerticalAlignment(VerticalAlignment::Center);
        row.Children().Append(unit);
        row.Children().Append(remove);
        page.root.Children().Append(row);
    }

    // The text of the page, in place: the rows and the focus stay.
    void MainWindow::UpdateSelectedText()
    {
        if (selected_page == nullptr || model == nullptr)
            return;
        SelectedPage &page = *selected_page;
        if (!line_lost)
            page.root.Opacity(1);
        zs_app *app = model->Active();
        if (page.kind == SelectedPage::Kind::Part)
        {
            FillSelectedPart();
            return;
        }
        if (page.kind != SelectedPage::Kind::Line || SelectedPath() < 0)
            return;
        zs_inspect info{};
        if (zs_app_inspect(app, (size_t)SelectedPath(), &info) != ZS_OK)
            return;
        page.z = info.z;
        // A multiple selection: the first line, and how many more.
        std::wstring more_text;
        if (!line_more.empty())
            more_text = L", and " + std::to_wstring(line_more.size()) + (line_more.size() == 1 ? L" more line" : L" more lines");
        page.title.Text(zs::ToWide(info.title) + L" · layer " + std::to_wstring(info.layer + 1) + more_text);
        wchar_t text[48];
        swprintf_s(text, L"%.0f mm/s", info.planned_speed);
        page.stats[0].Text(text);
        swprintf_s(text, L"%.0f mm/s", info.speed);
        page.stats[1].Text(text);
        swprintf_s(text, L"%.1f mm³/s", info.flow);
        page.stats[2].Text(text);
        page.stats[1].Foreground(TokenBrush(Root(), info.slow_reason != 0 ? L"ZsWarning" : L"ZsFg"));
        page.note.Text(info.slow_reason == 1 ? L"This layer is short, so it prints slower to cool (filament minimum layer time). Click the real speed for more."
                                             : L"The segments are short: the head does not reach the full speed between the corners (acceleration). Click the real speed for more.");
        page.note.Visibility(info.slow_reason != 0 ? Visibility::Visible : Visibility::Collapsed);
        page.why[0] = zs::ToWide(info.why_planned != nullptr ? info.why_planned : "");
        page.why[1] = zs::ToWide(info.why_real != nullptr ? info.why_real : "");
        page.why[2] = zs::ToWide(info.why_flow != nullptr ? info.why_flow : "");
        FillSelectedFoot(info);
        int64_t segment = SelectedSegment();
        zs_measure m{};
        if (zs_app_measure(app, (size_t)SelectedPath(), segment < 0 ? 0 : (size_t)segment, &m) == ZS_OK)
        {
            wchar_t line[96];
            std::wstring all;
            if (m.shape == 1)
            {
                swprintf_s(line, L"Circle  radius %.2f mm · diameter %.2f mm\n", m.radius, 2 * m.radius);
                all += line;
            }
            else if (m.shape == 2)
            {
                swprintf_s(line, L"Arc  radius %.2f mm · %.0f°\n", m.radius, m.angle);
                all += line;
            }
            swprintf_s(line, L"Segment  %.2f mm", m.segment_length);
            all += line;
            if (m.edge_length > m.segment_length + 0.01)
            {
                swprintf_s(line, L" · edge %.2f mm", m.edge_length);
                all += line;
            }
            swprintf_s(line, L"\n%s  %.2f mm · %.2f × %.2f mm", m.closed ? L"Loop" : L"Path", m.path_length, m.size_x, m.size_y);
            all += line;
            page.measure.Text(all);
            page.measure.Visibility(Visibility::Visible);
        }
        else
        {
            page.measure.Visibility(Visibility::Collapsed);
        }
        for (auto const &editor : setting_editors)
            editor.refresh();
        for (auto const &row : page.rows)
            if (row->open)
                row->why.Text(SelectedWhy(row->name));
        DrawSelectedRows();
    }

    // ---- the part ----

    void MainWindow::BuildPartPage(SelectedPage &page)
    {
        page.kind = SelectedPage::Kind::Part;
        zs_app *app = model->Active();
        page.part = zs_app_part_id(app, (size_t)PrimaryPart());
        page.part_title = Text(L"", 16, false, true);
        page.root.Children().Append(page.part_title);
        page.part_size = Text(L"", 13, true);
        page.root.Children().Append(page.part_size);
        Grid grid;
        grid.ColumnSpacing(6);
        grid.RowSpacing(4);
        ColumnDefinition a, b, c;
        a.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        b.Width(GridLengthHelper::FromValueAndType(150, GridUnitType::Pixel));
        c.Width(GridLengthHelper::Auto());
        grid.ColumnDefinitions().Append(a);
        grid.ColumnDefinitions().Append(b);
        grid.ColumnDefinitions().Append(c);
        wchar_t const *names[] = { L"X (center)", L"Y (center)", L"Turn", L"Scale" };
        wchar_t const *units[] = { L"mm", L"mm", L"°", L"%" };
        double lows[] = { -1000, -1000, -720, 1 }, highs[] = { 3000, 3000, 720, 1000 }, steps[] = { 1, 1, 15, 5 };
        NumberBox *boxes[] = { &page.x, &page.y, &page.turn, &page.scale };
        for (int k = 0; k < 4; k++)
        {
            RowDefinition definition;
            definition.Height(GridLengthHelper::Auto());
            grid.RowDefinitions().Append(definition);
            auto label = Text(names[k]);
            label.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetRow(label, k);
            grid.Children().Append(label);
            NumberBox box;
            box.Minimum(lows[k]);
            box.Maximum(highs[k]);
            box.SmallChange(steps[k]);
            box.SpinButtonPlacementMode(NumberBoxSpinButtonPlacementMode::Compact);
            Automation::AutomationProperties::SetName(box, names[k]);
            box.ValueChanged([this, k](auto &&, NumberBoxValueChangedEventArgs const &e) { SelectedPartValue(k, e.NewValue()); });
            Grid::SetRow(box, k);
            Grid::SetColumn(box, 1);
            grid.Children().Append(box);
            *boxes[k] = box;
            auto unit = Text(units[k], 12, true);
            unit.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetRow(unit, k);
            Grid::SetColumn(unit, 2);
            grid.Children().Append(unit);
        }
        page.root.Children().Append(grid);

        auto edit = [this](auto action) {
            return [this, action](auto &&, auto &&) {
                if (model == nullptr || selected_page == nullptr)
                    return;
                zs_app *now = model->Active();
                ptrdiff_t i = zs_app_part_index(now, selected_page->part);
                if (i >= 0 && action(now, (size_t)i) == ZS_OK)
                    PlateEdited();
            };
        };
        StackPanel buttons;
        buttons.Orientation(Orientation::Horizontal);
        buttons.Spacing(6);
        buttons.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
        Button turn90 = SmallButton(L"Turn 90°");
        turn90.Click(edit([](zs_app *a, size_t i) {
            zs_part p{};
            return zs_app_part_get(a, i, &p) == ZS_OK ? zs_app_part_rotate(a, i, p.rotation + 90) : (int)ZS_INVALID_ARGUMENT;
        }));
        Button arrange = SmallButton(L"Arrange the plate");
        arrange.Click([this](auto &&, auto &&) {
            if (model == nullptr)
                return;
            if (!zs_app_plate_arrange(model->Active()))
                ShowPlaceFailed();
            PlateEdited();
        });
        Button remove = SmallButton(L"Remove");
        remove.Foreground(Media::SolidColorBrush(Windows::UI::Color{ 255, 192, 28, 40 }));
        remove.Click(edit([](zs_app *a, size_t i) { return zs_app_part_remove(a, i); }));
        buttons.Children().Append(turn90);
        buttons.Children().Append(arrange);
        buttons.Children().Append(remove);
        page.root.Children().Append(buttons);

        // The quality of the part: "As the print", or a built-in profile.
        Grid quality_row;
        quality_row.ColumnSpacing(6);
        quality_row.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
        ColumnDefinition q0, q1;
        q0.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        q1.Width(GridLengthHelper::FromValueAndType(180, GridUnitType::Pixel));
        quality_row.ColumnDefinitions().Append(q0);
        quality_row.ColumnDefinitions().Append(q1);
        auto quality_label = Text(L"Quality");
        quality_label.VerticalAlignment(VerticalAlignment::Center);
        quality_row.Children().Append(quality_label);
        page.quality = ComboBox();
        page.quality.HorizontalAlignment(HorizontalAlignment::Stretch);
        Automation::AutomationProperties::SetName(page.quality, L"Quality");
        ToolTipService::SetToolTip(page.quality, box_value(L"The quality profile of this part. Its layer height can differ from the other parts: zslice merges the layers of all parts by height."));
        page.quality.Items().Append(box_value(L"As the print"));
        for (size_t k = 0, n = zs_builtin_profile_count(ZS_GROUP_PROJECT); k < n; k++)
            page.quality.Items().Append(box_value(zs::ToWide(zs_builtin_profile_name(ZS_GROUP_PROJECT, k))));
        page.quality.SelectionChanged([this](auto &&, auto &&) {
            if (model == nullptr || selected_page == nullptr || selected_page->filling)
                return;
            int at = selected_page->quality.SelectedIndex();
            zs_app *now = model->Active();
            ptrdiff_t i = zs_app_part_index(now, selected_page->part);
            if (at < 0 || i < 0)
                return;
            char const *name = at == 0 ? nullptr : zs_builtin_profile_name(ZS_GROUP_PROJECT, (size_t)at - 1);
            if (zs_app_part_setting_set(now, (size_t)i, "quality", name) == ZS_OK)
                PlateEdited();
        });
        Grid::SetColumn(page.quality, 1);
        quality_row.Children().Append(page.quality);
        page.root.Children().Append(quality_row);

        Button edit_settings = SmallButton(L"Edit settings for this part", L"Opens the settings for this part: a change there is for this part only, on top of the values of the print.");
        edit_settings.HorizontalAlignment(HorizontalAlignment::Stretch);
        edit_settings.Style(Application::Current().Resources().Lookup(box_value(L"AccentButtonStyle")).as<Microsoft::UI::Xaml::Style>());
        edit_settings.Click([this](auto &&, auto &&) {
            if (model == nullptr || selected_page == nullptr)
                return;
            ptrdiff_t i = zs_app_part_index(model->Active(), selected_page->part);
            if (i < 0)
                return;
            queue.TryEnqueue([this, i] {
                ClearSettingsList();
                settings_page = SettingsPage::Sections;
                SetSettingsScope(i);
                ShowSections();
            });
        });
        page.root.Children().Append(edit_settings);

        auto head = Text(L"Placement", 13, false, true);
        head.Margin(ThicknessHelper::FromLengths(0, 10, 0, 0));
        page.root.Children().Append(head);
        StackPanel place;
        place.Orientation(Orientation::Horizontal);
        place.Spacing(6);
        Button smart = SmallButton(L"Smart placement", L"Turns the part for the least support, the most area on the bed, and a low height.");
        smart.Click(edit([](zs_app *a, size_t i) { return zs_app_part_place(a, i, ZS_PLACE_SMART, 0); }));
        Button less = SmallButton(L"Less support", L"Turns the part for the least support only.");
        less.Click(edit([](zs_app *a, size_t i) { return zs_app_part_place(a, i, ZS_PLACE_LESS_SUPPORT, 0); }));
        DropDownButton strong;
        strong.Content(box_value(L"Strong along"));
        strong.FontSize(12.5);
        ToolTipService::SetToolTip(strong, box_value(L"Which way does the load go (the axes of the file)? The part turns so that this axis lies in the layers (a print is weakest across its layers), with the least support."));
        MenuFlyout axes;
        wchar_t const *axis_items[] = { L"Along X of the part", L"Along Y of the part", L"Along Z of the part" };
        for (int axis = 0; axis < 3; axis++)
        {
            MenuFlyoutItem item;
            item.Text(axis_items[axis]);
            item.Click(edit([axis](zs_app *a, size_t i) { return zs_app_part_place(a, i, ZS_PLACE_STRENGTH, axis); }));
            axes.Items().Append(item);
        }
        strong.Flyout(axes);
        place.Children().Append(smart);
        place.Children().Append(less);
        place.Children().Append(strong);
        page.root.Children().Append(place);
        StackPanel turns;
        turns.Orientation(Orientation::Horizontal);
        turns.Spacing(6);
        Button turn_x = SmallButton(L"Turn 90° about X");
        turn_x.Click(edit([](zs_app *a, size_t i) { return zs_app_part_turn(a, i, 0, 90); }));
        Button turn_y = SmallButton(L"Turn 90° about Y");
        turn_y.Click(edit([](zs_app *a, size_t i) { return zs_app_part_turn(a, i, 1, 90); }));
        Button reset = SmallButton(L"Reset", L"Reset: the orientation and the size of the file.");
        reset.Click(edit([](zs_app *a, size_t i) { return zs_app_part_reset(a, i); }));
        turns.Children().Append(turn_x);
        turns.Children().Append(turn_y);
        turns.Children().Append(reset);
        page.root.Children().Append(turns);

        page.part_file_head = Text(L"Settings of this part", 13, false, true);
        page.part_file_head.Margin(ThicknessHelper::FromLengths(0, 10, 0, 0));
        page.root.Children().Append(page.part_file_head);
        page.part_file = Text(L"", 12);
        page.part_file.FontFamily(Media::FontFamily(L"Cascadia Mono, Consolas"));
        page.part_file.IsTextSelectionEnabled(true);
        page.root.Children().Append(page.part_file);
        auto hint = Text(L"Ctrl+drag the part in the 3D view to move it, and Ctrl+wheel to turn it. Click a line to see its settings.", 12, true);
        hint.Margin(ThicknessHelper::FromLengths(0, 8, 0, 0));
        page.root.Children().Append(hint);
    }

    void MainWindow::SelectedPartValue(int field, double value)
    {
        if (model == nullptr || selected_page == nullptr || selected_page->filling || std::isnan(value))
            return;
        zs_app *app = model->Active();
        ptrdiff_t i = zs_app_part_index(app, selected_page->part);
        zs_part p{};
        if (i < 0 || zs_app_part_get(app, (size_t)i, &p) != ZS_OK)
            return;
        int rc = ZS_OK;
        if (field == 0)
            rc = zs_app_part_move(app, (size_t)i, value, p.y);
        else if (field == 1)
            rc = zs_app_part_move(app, (size_t)i, p.x, value);
        else if (field == 2)
            rc = zs_app_part_rotate(app, (size_t)i, value);
        else
            rc = zs_app_part_scale(app, (size_t)i, value / 100, value / 100, value / 100);
        if (rc == ZS_OK)
            PlateEdited();
    }

    void MainWindow::FillSelectedPart()
    {
        SelectedPage &page = *selected_page;
        zs_app *app = model->Active();
        ptrdiff_t i = zs_app_part_index(app, page.part);
        zs_part p{};
        if (i < 0 || zs_app_part_get(app, (size_t)i, &p) != ZS_OK)
            return;
        page.filling = true;
        page.part_title.Text(p.name != nullptr && p.name[0] != 0 ? zs::ToWide(p.name) : L"Part");
        wchar_t size[64];
        swprintf_s(size, L"%.1f × %.1f × %.1f mm", p.size_x, p.size_y, p.size_z);
        page.part_size.Text(size);
        auto show = [](NumberBox const &box, double v) {
            double shown = std::round(v * 10) / 10;
            if (box.Value() != shown)
                box.Value(shown);
        };
        show(page.x, p.x);
        show(page.y, p.y);
        show(page.turn, p.rotation);
        show(page.scale, p.scale_x * 100);
        std::string quality;
        size_t len = 0;
        if (zs_app_part_setting_get(app, (size_t)i, "quality", nullptr, 0, &len) == ZS_OK)
        {
            quality.assign(len + 1, '\0');
            zs_app_part_setting_get(app, (size_t)i, "quality", quality.data(), quality.size(), &len);
            quality.resize(len);
        }
        int at = 0;
        for (size_t k = 0, n = zs_builtin_profile_count(ZS_GROUP_PROJECT); k < n; k++)
            if (quality == zs_builtin_profile_name(ZS_GROUP_PROJECT, k))
                at = (int)k + 1;
        page.quality.SelectedIndex(at);
        std::string file;
        if (zs_app_part_settings(app, (size_t)i, nullptr, 0, &len) == ZS_OK && len > 0)
        {
            file.assign(len + 1, '\0');
            zs_app_part_settings(app, (size_t)i, file.data(), file.size(), nullptr);
            file.resize(len);
        }
        page.part_file.Text(zs::ToWide(file));
        auto has_file = file.empty() ? Visibility::Collapsed : Visibility::Visible;
        page.part_file.Visibility(has_file);
        page.part_file_head.Visibility(has_file);
        page.filling = false;
    }

    // ---- the gap ----

    void MainWindow::BuildGapPage(SelectedPage &page)
    {
        page.kind = SelectedPage::Kind::Gap;
        zs_app *app = model->Active();
        if (page_gap_closed)
        {
            page.root.Children().Append(Text(L"The gap is closed", 16, false, true));
            wchar_t text[120];
            swprintf_s(text, L"Layer %zu has no gap at %.1f, %.1f mm after this change.", gap_selected_layer + 1, page_gap_x, page_gap_y);
            page.root.Children().Append(Text(text));
            return;
        }
        zs_gap const *gaps = nullptr;
        size_t n = 0;
        if (zs_app_layer_gaps(app, gap_selected_layer, &gaps, &n, nullptr, nullptr) != ZS_OK || gap_selected < 0 || (size_t)gap_selected >= n)
        {
            page.root.Children().Append(Text(L"The gap is gone: the layer has changed.", 13, false, true));
            return;
        }
        zs_gap const g = gaps[gap_selected];
        page_gap_x = g.x;
        page_gap_y = g.y;
        page.root.Children().Append(Text(L"Gap · layer " + std::to_wstring(gap_selected_layer + 1), 16, false, true));
        std::wstring next;
        for (size_t f = 0; f < std::size(feature_names); f++)
        {
            if ((g.features & (1u << f)) == 0)
                continue;
            if (!next.empty())
                next += L", ";
            next += zs::ToWide(feature_names[f]);
        }
        wchar_t facts[120];
        swprintf_s(facts, L"%.3f mm², %.2f mm wide, at %.1f, %.1f mm. Next to: ", g.area, g.width, g.x, g.y);
        page.root.Children().Append(Text(facts + (next.empty() ? std::wstring(L"no bead") : next) + L"." +
                                         (g.at_edge ? L" It touches the edge of the solid area (the outline, or the sparse infill)." : L"")));
        double z = 0;
        zs_toolpaths tp{};
        if (zs_app_toolpaths(app, &tp) == ZS_OK && gap_selected_layer < tp.layer_count)
            z = tp.layer_z[gap_selected_layer];
        auto head = Text(L"Settings that can close it", 13, false, true);
        head.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
        page.root.Children().Append(head);
        zs_gap_step steps[8];
        size_t count = 0;
        if (zs_app_gap_advice(app, gap_selected_layer, (size_t)gap_selected, steps, std::size(steps), &count) != ZS_OK)
            count = 0;
        for (size_t i = 0; i < std::min(count, std::size(steps)); i++)
        {
            std::string name(steps[i].name, steps[i].name_len), value(steps[i].value, steps[i].value_len), why(steps[i].why, steps[i].why_len);
            zs_setting_info info{};
            bool known = false;
            for (size_t k = 0, all = zs_setting_count(); k < all && !known; k++)
                known = zs_setting_get_info(k, &info) == ZS_OK && name == info.name;
            auto with_unit = [&](std::string const &v) {
                size_t len = 0;
                if (!known || zs_setting_display(name.c_str(), v.c_str(), 1, nullptr, 0, &len) != ZS_OK)
                    return zs::ToWide(v);
                std::string out(len + 1, '\0');
                zs_setting_display(name.c_str(), v.c_str(), 1, out.data(), out.size(), &len);
                out.resize(len);
                return zs::ToWide(out);
            };
            std::wstring label = known ? zs::ToWide(info.label) : zs::ToWide(name);
            auto title = Text(label + L": " + with_unit(model->GetSetting(name.c_str())) + L" → " + with_unit(value), 13, false, true);
            title.Margin(ThicknessHelper::FromLengths(0, 6, 0, 0));
            page.root.Children().Append(title);
            page.root.Children().Append(Text(zs::ToWide(why), 12.5, true));
            StackPanel buttons;
            buttons.Orientation(Orientation::Horizontal);
            buttons.Spacing(6);
            Button all = SmallButton(L"Apply", L"Change the setting for all prints, and slice again.");
            all.Click([this, name, value](auto &&, auto &&) { CommitSetting(name, value); });
            buttons.Children().Append(all);
            if (known && info.per_layer != 0)
            {
                Button layer = SmallButton(L"This layer", L"Change the setting only for this layer of this part, and slice again.");
                layer.Click([this, name, value, z](auto &&, auto &&) {
                    if (model == nullptr || zs_app_override_set(model->Active(), z, z, name.c_str(), value.c_str()) != ZS_OK)
                        return;
                    model->RequestSlice();
                    NoteChange();
                    ProfilesRefresh();
                });
                buttons.Children().Append(layer);
            }
            page.root.Children().Append(buttons);
        }
    }

#ifdef ZS_DEV_HOOKS
    // selectedshow, selectedlog, selectedscope n, selectedset name value,
    // selectedreset name, selectedfocus name, selectedfilter text, selectedwhy i.
    bool MainWindow::RunSelectedStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        if (verb.rfind(L"selected", 0) != 0 || model == nullptr)
            return false;
        if (verb == L"selectedlost")
        {
            bool page = settings_page == SettingsPage::Selected && selected_page != nullptr;
            zs::Log("dev: lost %d path %lld draft %d state %d page %d kind %d opacity %.2f card %d\n", line_lost ? 1 : 0, (long long)SelectedPath(), zs_app_is_draft(model->Active()),
                    (int)zs_app_state(model->Active()), page ? 1 : 0, page ? (int)selected_page->kind : -1, page ? selected_page->root.Opacity() : 0.0,
                    LineCard().Visibility() == Visibility::Visible ? 1 : 0);
            return true;
        }
        if (verb == L"selectedshow")
        {
            ShowSettingsPane(true);
            ShowSelected();
        }
        else if (verb == L"selectedlog")
        {
            std::string rows;
            size_t shown = 0;
            if (selected_page != nullptr)
                for (auto const &row : selected_page->rows)
                    if (row->box.Visibility() == Visibility::Visible)
                        {
                            shown++;
                            if (shown <= 7)
                                rows += row->name + " ";
                        }
            int kind = selected_page != nullptr ? (int)selected_page->kind : -1;
            std::string title;
            if (selected_page != nullptr && selected_page->title != nullptr)
                title = zs::ToUtf8(std::wstring(selected_page->title.Text()));
            zs::Log("dev: selected page %d kind %d title '%s' top '%s' rows %zu shown %zu sections %zu scope %d z %.2f overrides %zu stats '%s' opacity %.2f\n",
                    settings_page == SettingsPage::Selected ? 1 : 0, kind, title.c_str(), zs::ToUtf8(SelectedTitle()).c_str(), selected_page != nullptr ? selected_page->rows.size() : 0, shown,
                    selected_page != nullptr ? selected_page->sections.size() : 0, selected_scope, selected_page != nullptr ? selected_page->z : 0, zs_app_override_count(model->Active()),
                    selected_page != nullptr && selected_page->stats[0] != nullptr ? zs::ToUtf8(std::wstring(selected_page->stats[0].Text()) + L" / " + std::wstring(selected_page->stats[1].Text())).c_str() : "",
                    selected_page != nullptr ? selected_page->root.Opacity() : 0, rows.c_str());
        }
        else if (verb == L"selectedscope" && !words.empty())
        {
            selected_scope = _wtoi(words[0].c_str());
            for (auto const &editor : setting_editors)
                editor.refresh();
            DrawSelectedRows();
        }
        else if (verb == L"selectedset" && words.size() >= 2)
        {
            SelectedSet(zs::ToUtf8(words[0]), zs::ToUtf8(words[1]));
        }
        else if (verb == L"selectedreset" && !words.empty() && selected_page != nullptr)
        {
            std::string name = zs::ToUtf8(words[0]);
            for (auto const &row : selected_page->rows)
                if (row->name == name)
                    Automation::Peers::ButtonAutomationPeer(row->reset).Invoke();
        }
        else if (verb == L"selectedfocus" && !words.empty() && selected_page != nullptr)
        {
            std::string name = zs::ToUtf8(words[0]);
            for (auto const &row : selected_page->rows)
                if (row->name == name && row->focus != nullptr)
                {
                    row->focus.Focus(FocusState::Programmatic);
                    zs::Log("dev: selected why '%s'\n", zs::ToUtf8(SelectedWhy(name)).c_str());
                }
        }
        else if (verb == L"selectedfoot" && selected_page != nullptr && selected_page->foot != nullptr)
        {
            zs::Log("dev: selected foot %u items\n", selected_page->foot.Children().Size());
            for (auto const &child : selected_page->foot.Children())
            {
                auto item = child.as<StackPanel>();
                std::string line;
                for (auto const &part : item.Children())
                {
                    auto block = part.as<TextBlock>();
                    std::wstring words{ block.Text() };
                    line += zs::ToUtf8(words) + " | ";
                }
                zs::Log("dev: foot %s\n", line.c_str());
            }
        }
        else if (verb == L"selectedgap")
        {
            // A click on the first gap of the layer that shows.
            size_t layer = (size_t)LayerSlider().Value() - 1;
            zs_gap const *gaps = nullptr;
            size_t n = 0;
            zs_toolpaths tp{};
            float px = 0, py = 0;
            bool took = false;
            if (zs_app_layer_gaps(model->Active(), layer, &gaps, &n, nullptr, nullptr) == ZS_OK && n > 0 && zs_app_toolpaths(model->Active(), &tp) == ZS_OK &&
                zs_view_pixel_of(view, gaps[0].x, gaps[0].y, tp.layer_z[layer], &px, &py))
                took = GapClick(px / Scale(), py / Scale());
            zs::Log("dev: selected gap click %d of %zu on layer %zu, page gap %d\n", took ? 1 : 0, n, layer + 1, page_gap ? 1 : 0);
        }
        else if (verb == L"selectedwhy" && !words.empty() && selected_page != nullptr)
        {
            zs::Log("dev: selected reason '%s'\n", zs::ToUtf8(selected_page->why[_wtoi(words[0].c_str()) & 3 % 3]).c_str());
        }
        else
        {
            return false;
        }
        return true;
    }
#endif
}
