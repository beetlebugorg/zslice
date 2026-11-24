// The Inspector: one column of the window beside the view, with the tabs
// Inspector and Settings. The view gets the rest of the window, so no page
// of a selection can draw over it.
//
// The pages of a label, the Paint tool, the Support tool, a range of layers,
// a part, a line, and a gap all mount in one slot. The slot shows one: the
// most specific page that is on. With no page, the Inspector shows the
// summary of the plate. A selection changes only this content. It never
// opens, closes, or resizes the column, and the camera stays. In a window of
// 760 points or less, the column is a row under the view, and only the user
// opens it. The behavior follows web/app/dock.js.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

#include <cmath>
#include <limits>

#ifdef ZS_DEV_HOOKS
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#endif

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Automation = Microsoft::UI::Xaml::Automation;

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    namespace
    {
        constexpr double narrow_window = 760;
        constexpr double default_width = 380, least_width = 300, least_view = 360;
        // The most parts in the list of the plate.
        constexpr size_t most_listed = 60;
        // Below this rank, a page belongs to a tool or a range that the user
        // opened, so it shows the Inspector tab.
        constexpr int rank_of_part = 4;
    }

    bool MainWindow::NarrowWindow()
    {
        double width = Root().ActualWidth();
        return width > 0 && width <= narrow_window;
    }

    bool MainWindow::InspectorShown()
    {
        return NarrowWindow() ? sheet_open : inspector_open;
    }

    // Only the user calls this: N, the header button, or the × of the column.
    void MainWindow::SetInspectorOpen(bool open)
    {
        if (NarrowWindow())
            sheet_open = open;
        else
        {
            inspector_open = open;
            zs::Printers().SetPref("inspector_open", open ? "1" : "0");
        }
        ApplyInspector();
        if (open && inspector_settings)
        {
            RefreshSettingValues();
            RefreshSelectedPage();
        }
    }

    // A column beside the view, or a row under it.
    void MainWindow::ApplyInspector()
    {
        bool narrow = NarrowWindow(), shown = InspectorShown();
        auto pane = SettingsPane();
        Grid::SetColumn(pane, narrow ? 0 : 1);
        Grid::SetColumnSpan(pane, narrow ? 2 : 1);
        Grid::SetRow(pane, narrow ? 1 : 0);
        pane.BorderThickness(narrow ? ThicknessHelper::FromLengths(0, 1, 0, 0) : ThicknessHelper::FromLengths(1, 0, 0, 0));
        if (narrow)
        {
            double high = WorkArea().ActualHeight();
            pane.Width(std::numeric_limits<double>::quiet_NaN());
            pane.Height(std::clamp(high * 0.45, 180.0, std::max(180.0, high - 160)));
        }
        else
        {
            double room = Root().ActualWidth();
            double width = std::clamp(atof(zs::Printers().Pref("panel_width", "380").c_str()), least_width, 2000.0);
            if (room > 0)
                width = std::min(width, std::max(least_width, room - least_view));
            pane.Height(std::numeric_limits<double>::quiet_NaN());
            pane.Width(width);
        }
        auto state = shown ? Visibility::Visible : Visibility::Collapsed;
        if (pane.Visibility() != state)
            pane.Visibility(state);
        PaneSplitter().Visibility(shown && !narrow ? Visibility::Visible : Visibility::Collapsed);
        SettingsToggle().IsChecked(shown);
        InspectorDot().Visibility(inspector_now != nullptr && !shown ? Visibility::Visible : Visibility::Collapsed);
        ApplyPaneFocus();
    }

    void MainWindow::ShowInspectorTab(bool settings)
    {
        inspector_settings = settings;
        InspectorPage().Visibility(settings ? Visibility::Collapsed : Visibility::Visible);
        SettingsTabPage().Visibility(settings ? Visibility::Visible : Visibility::Collapsed);
        TabInspector().IsChecked(!settings);
        TabSettings().IsChecked(settings);
        if (settings && SettingsPane().Visibility() == Visibility::Visible)
        {
            RefreshSettingValues();
            RefreshSelectedPage();
        }
        ApplyPaneFocus();
    }

    bool MainWindow::SettingsTabShown()
    {
        return inspector_settings && SettingsPane().Visibility() == Visibility::Visible;
    }

    // A new selection shows the Inspector tab, unless the user types in a
    // setting. It does not open the column.
    void MainWindow::RevealSelection()
    {
        if (!inspector_settings)
            return;
        auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot()).try_as<DependencyObject>();
        for (auto at = focused; at != nullptr; at = Media::VisualTreeHelper::GetParent(at))
            if (at == SettingsTabPage())
                return;
        ShowInspectorTab(false);
    }

    // A page goes in the slot. A lower rank is more specific.
    void MainWindow::DockCard(FrameworkElement const &card, int rank)
    {
        // A page of the XAML file starts in the slot. FrameworkElement::Parent
        // is null until the window has its content.
        uint32_t at = 0;
        if (InspectorSlot().Children().IndexOf(card, at))
            InspectorSlot().Children().RemoveAt(at);
        card.Width(std::numeric_limits<double>::quiet_NaN());
        card.MaxWidth(std::numeric_limits<double>::infinity());
        card.MaxHeight(std::numeric_limits<double>::infinity());
        card.HorizontalAlignment(HorizontalAlignment::Stretch);
        card.Margin(ThicknessHelper::FromUniformLength(0));
        if (auto box = card.try_as<Border>())
        {
            box.Background(nullptr);
            box.BorderThickness(ThicknessHelper::FromUniformLength(0));
            box.CornerRadius(CornerRadiusHelper::FromUniformRadius(0));
            box.Padding(ThicknessHelper::FromLengths(12, 10, 12, 12));
        }
        Border host;
        host.Child(card);
        host.Visibility(Visibility::Collapsed);
        InspectorSlot().Children().Append(host);
        inspector_cards.push_back({ rank, card, host });
        std::stable_sort(inspector_cards.begin(), inspector_cards.end(), [](InspectorCard const &a, InspectorCard const &b) { return a.rank < b.rank; });
        card.RegisterPropertyChangedCallback(UIElement::VisibilityProperty(), [this](auto &&, auto &&) { InspectorChanged(); });
        InspectorChanged();
    }

    // A change of a page: once, after the handler that made it. A handler
    // often hides one page and shows another.
    void MainWindow::InspectorChanged()
    {
        if (inspector_queued)
            return;
        inspector_queued = true;
        queue.TryEnqueue([this] {
            inspector_queued = false;
            RefreshInspector();
        });
    }

    void MainWindow::RefreshInspector()
    {
        InspectorCard const *now = nullptr;
        for (auto const &entry : inspector_cards)
            if (entry.card.Visibility() == Visibility::Visible)
            {
                now = &entry;
                break;
            }
        for (auto const &entry : inspector_cards)
        {
            auto state = &entry == now ? Visibility::Visible : Visibility::Collapsed;
            if (entry.host.Visibility() != state)
                entry.host.Visibility(state);
        }
        FrameworkElement shown = now != nullptr ? now->card : FrameworkElement{ nullptr };
        bool changed = shown != inspector_now;
        inspector_now = shown;
        InspectorPlate().Visibility(now == nullptr ? Visibility::Visible : Visibility::Collapsed);
        if (now == nullptr)
            FillInspectorPlate();
        if (changed)
            InspectorPage().ChangeView(nullptr, box_value(0.0).as<Windows::Foundation::IReference<double>>(), nullptr, true);
        if (changed && now != nullptr && now->rank < rank_of_part)
            RevealSelection();
        InspectorDot().Visibility(now != nullptr && !InspectorShown() ? Visibility::Visible : Visibility::Collapsed);
    }

    void MainWindow::InspectorPlateChanged()
    {
        if (plate_queued)
            return;
        plate_queued = true;
        queue.TryEnqueue([this] {
            plate_queued = false;
            if (inspector_now == nullptr)
                FillInspectorPlate();
        });
    }

    // With no selection: the plate, its numbers, and its parts.
    void MainWindow::FillInspectorPlate()
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        size_t count = zs_app_part_count(app);
        std::wstring title = L"Plate " + std::to_wstring(model->ActivePlate() + 1) + L" of " + std::to_wstring(model->PlateCount());
        std::wstring facts = std::to_wstring(count) + (count == 1 ? L" part" : L" parts");
        if (zs_app_state(app) == ZS_STATE_DONE && !model->IsDraft())
            facts += L" · " + std::wstring(SummaryTime().Text()) + L" · " + std::wstring(SummaryDetail().Text());
        std::wstring signature = title + L"\n" + facts;
        struct Row
        {
            std::wstring name, size;
        };
        std::vector<Row> rows;
        for (size_t i = 0; i < std::min(count, most_listed); i++)
        {
            zs_part p{};
            if (zs_app_part_get(app, i, &p) != ZS_OK)
                continue;
            wchar_t size[64];
            swprintf_s(size, L"%.1f × %.1f × %.1f mm", p.size_x, p.size_y, p.size_z);
            rows.push_back({ p.name != nullptr && p.name[0] != 0 ? zs::ToWide(p.name) : L"Part " + std::to_wstring(i + 1), size });
            signature += L"\n" + rows.back().name + L"\t" + size;
        }
        // The same text keeps the rows, with their focus and their hover.
        if (signature == plate_signature)
            return;
        plate_signature = signature;
        auto box = InspectorPlate();
        box.Children().Clear();
        TextBlock head;
        head.Text(title);
        head.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
        head.TextWrapping(TextWrapping::WrapWholeWords);
        box.Children().Append(head);
        TextBlock numbers;
        numbers.Text(facts);
        numbers.FontSize(12);
        numbers.TextWrapping(TextWrapping::WrapWholeWords);
        numbers.Foreground(TokenBrush(Root(), L"ZsDim"));
        box.Children().Append(numbers);
        if (!rows.empty())
        {
            StackPanel list;
            list.Spacing(1);
            for (size_t i = 0; i < rows.size(); i++)
            {
                Button row;
                row.HorizontalAlignment(HorizontalAlignment::Stretch);
                row.HorizontalContentAlignment(HorizontalAlignment::Stretch);
                row.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
                row.BorderThickness(ThicknessHelper::FromUniformLength(0));
                row.Padding(ThicknessHelper::FromLengths(6, 4, 6, 4));
                row.AllowFocusOnInteraction(false);
                Grid line;
                line.ColumnSpacing(8);
                ColumnDefinition name_column, size_column;
                name_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                size_column.Width(GridLengthHelper::Auto());
                line.ColumnDefinitions().Append(name_column);
                line.ColumnDefinitions().Append(size_column);
                TextBlock name;
                name.Text(rows[i].name);
                name.FontSize(13);
                name.TextWrapping(TextWrapping::Wrap);
                line.Children().Append(name);
                TextBlock size;
                size.Text(rows[i].size);
                size.FontSize(11.5);
                size.VerticalAlignment(VerticalAlignment::Center);
                size.Foreground(TokenBrush(Root(), L"ZsDim"));
                Grid::SetColumn(size, 1);
                line.Children().Append(size);
                row.Content(line);
                ToolTipService::SetToolTip(row, box_value(L"Select this part"));
                Automation::AutomationProperties::SetName(row, L"Select " + rows[i].name);
                row.Click([this, i](auto &&, auto &&) {
                    if (model == nullptr || i >= zs_app_part_count(model->Active()))
                        return;
                    if (tool != Tool::Move)
                        SetTool(Tool::Move);
                    SelectPart((int64_t)i);
                    RequestDraw();
                });
                list.Children().Append(row);
            }
            box.Children().Append(MakeInspectorGroup(L"Parts", "parts", list));
            if (count > most_listed)
            {
                TextBlock more;
                more.Text(L"And " + std::to_wstring(count - most_listed) + L" more parts.");
                more.FontSize(12);
                more.Foreground(TokenBrush(Root(), L"ZsDim"));
                box.Children().Append(more);
            }
        }
        TextBlock hint;
        hint.Text(count > 0 ? L"Select a part or a line in the view to see it here." : L"Open a model to start.");
        hint.FontSize(12);
        hint.TextWrapping(TextWrapping::WrapWholeWords);
        hint.Foreground(TokenBrush(Root(), L"ZsDim"));
        box.Children().Append(hint);
    }

    // A group that the user can collapse. Its state stays for the next start.
    StackPanel MainWindow::MakeInspectorGroup(std::wstring const &title, char const *key, FrameworkElement const &body, bool remember)
    {
        std::string pref = std::string("inspector_group_") + key;
        bool open = zs::Printers().Pref(pref, "1") != "0";
        StackPanel group;
        group.Spacing(4);
        group.Margin(ThicknessHelper::FromLengths(0, 2, 0, 4));
        Button head;
        head.HorizontalAlignment(HorizontalAlignment::Stretch);
        head.HorizontalContentAlignment(HorizontalAlignment::Left);
        head.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        head.BorderThickness(ThicknessHelper::FromUniformLength(0));
        head.Padding(ThicknessHelper::FromLengths(0, 4, 0, 4));
        head.AllowFocusOnInteraction(false);
        StackPanel line;
        line.Orientation(Orientation::Horizontal);
        line.Spacing(6);
        FontIcon chevron;
        chevron.FontSize(9);
        chevron.Glyph(open ? L"\xE70D" : L"\xE76C");
        chevron.VerticalAlignment(VerticalAlignment::Center);
        line.Children().Append(chevron);
        TextBlock text;
        text.Text(title);
        text.FontSize(12.5);
        text.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        line.Children().Append(text);
        head.Content(line);
        Automation::AutomationProperties::SetName(head, title);
        auto show = [body, chevron, head](bool now) {
            body.Visibility(now ? Visibility::Visible : Visibility::Collapsed);
            chevron.Glyph(now ? L"\xE70D" : L"\xE76C");
            Automation::AutomationProperties::SetHelpText(head, now ? L"Open" : L"Collapsed");
        };
        show(open);
        head.Click([body, show, pref](auto &&, auto &&) {
            bool now = body.Visibility() != Visibility::Visible;
            show(now);
            zs::Printers().SetPref(pref, now ? "1" : "0");
        });
        // A group of the XAML page exists before the preferences load.
        if (remember)
            inspector_group_load.push_back([show, pref] { show(zs::Printers().Pref(pref, "1") != "0"); });
        group.Children().Append(head);
        group.Children().Append(body);
        return group;
    }

    // A panel of the XAML page becomes the body of a group, in its place.
    void MainWindow::WrapInspectorGroup(Panel const &parent, FrameworkElement const &body, std::wstring const &title, char const *key)
    {
        uint32_t at = 0;
        if (!parent.Children().IndexOf(body, at))
            return;
        parent.Children().RemoveAt(at);
        parent.Children().InsertAt(at, MakeInspectorGroup(title, key, body, true));
    }

    void MainWindow::WireInspector()
    {
        WrapInspectorGroup(PartSingle(), PartGroupPose(), L"Position and turn", "pose");
        WrapInspectorGroup(PartSingle(), PartGroupSize(), L"Size and mirror", "size");
        WrapInspectorGroup(PartSingle(), PartGroupFilament(), L"Filament", "filament");
        WrapInspectorGroup(PartBody(), PartGroupActions(), L"Actions", "actions");
        WrapInspectorGroup(PartBody(), PartGroupSettings(), L"Settings of this part", "settings");
        DockCard(PartCard(), rank_of_part);
        DockCard(LineCard(), rank_of_part + 1);
        DockCard(GapCard(), rank_of_part + 2);
        TabInspector().Click([this](auto &&, auto &&) { ShowInspectorTab(false); });
        TabSettings().Click([this](auto &&, auto &&) { ShowInspectorTab(true); });
        SettingsClose().Click([this](auto &&, auto &&) { SetInspectorOpen(false); });
        PaneSplitter().DoubleTapped([this](auto &&, auto &&) {
            zs::Printers().SetPref("panel_width", std::to_string((int)default_width));
            ApplyInspector();
        });
        ShowInspectorTab(false);
    }

    // The state of the last session. A first start shows the column.
    void MainWindow::ApplySavedPanel()
    {
        inspector_open = zs::Printers().Pref("inspector_open", "1") != "0";
        for (auto const &load_group : inspector_group_load)
            load_group();
        ApplyInspector();
        RefreshInspector();
    }

#ifdef ZS_DEV_HOOKS
    // The proof: each kind of selection, at each window size and camera. No
    // selection UI lies over the view, and the view and the camera stay.
    void MainWindow::StartInspectorProof()
    {
        struct Proof
        {
            std::vector<std::function<void()>> plan;
            size_t at = 0;
            int selections = 0, checks = 0, failures = 0, sizes = 0;
            double box[4] = {};
            float camera[8] = {};
            bool shown = false;
            std::string where;
        };
        auto p = std::make_shared<Proof>();
        auto add = [p](std::function<void()> step) { p->plan.push_back(std::move(step)); };
        auto wait = [add](int n) {
            for (int i = 0; i < n; i++)
                add([] {});
        };
        auto view_box = [this](double out[4]) {
            auto at = ViewPanel().TransformToVisual(Root()).TransformPoint({ 0, 0 });
            out[0] = at.X;
            out[1] = at.Y;
            out[2] = ViewPanel().ActualWidth();
            out[3] = ViewPanel().ActualHeight();
        };
        auto fail = [p](std::string const &why) {
            if (++p->failures <= 16)
                zs::Log("dev: insp FAIL %s: %s\n", p->where.c_str(), why.c_str());
        };
        auto base = [this, p, view_box] {
            view_box(p->box);
            zs_view_get_camera(view, p->camera);
            p->shown = InspectorShown();
        };
        // rank: the page that must show, or -1 for none.
        auto check = [this, p, view_box, fail](int rank) {
            p->checks++;
            double box[4];
            view_box(box);
            for (int k = 0; k < 4; k++)
                if (std::abs(box[k] - p->box[k]) > 0.6)
                {
                    fail("the view moved or changed size");
                    break;
                }
            float camera[8];
            zs_view_get_camera(view, camera);
            for (int k = 0; k < 8; k++)
                if (std::abs(camera[k] - p->camera[k]) > 1e-3f)
                {
                    fail("the camera moved");
                    break;
                }
            if (InspectorShown() != p->shown)
                fail("the selection opened or closed the column");
            for (auto const &child : CardLayer().Children())
                if (child.Visibility() == Visibility::Visible && child != SearchBox() && child != MeasureCard())
                    fail("a card is in the layer over the view");
            int now = -1;
            for (auto const &entry : inspector_cards)
            {
                if (entry.card != inspector_now)
                    continue;
                now = entry.rank;
                if (!p->shown || entry.host.ActualHeight() <= 0)
                    continue;
                auto at = entry.host.TransformToVisual(Root()).TransformPoint({ 0, 0 });
                bool over = at.X < box[0] + box[2] - 0.5 && at.X + entry.host.ActualWidth() > box[0] + 0.5 && at.Y < box[1] + box[3] - 0.5 && at.Y + entry.host.ActualHeight() > box[1] + 0.5;
                if (over)
                    fail("the page lies over the view");
            }
            if (now != rank)
                fail("page rank " + std::to_string(now) + ", wanted " + std::to_string(rank));
            bool dot = InspectorDot().Visibility() == Visibility::Visible;
            if (dot != (rank >= 0 && !p->shown))
                fail("the dot is wrong");
        };
        auto select_tool = [this](Tool want) {
            if (tool != want)
                SetTool(want);
        };
        auto pick_line = [this] { RunDialogStep(L"pickfeature", { L"1" }); };
        struct Kind
        {
            char const *name;
            int rank;
            std::function<void()> make;
        };
        std::vector<Kind> kinds = {
            { "part", 4, [this, select_tool] { select_tool(Tool::Move); SelectPart(0); } },
            { "many parts", 4, [this, select_tool] { select_tool(Tool::Move); SelectPart(0); TogglePart(1); } },
            { "line", 5, [select_tool, pick_line] { select_tool(Tool::Select); pick_line(); } },
            { "range", 3, [this, select_tool, pick_line] { select_tool(Tool::Select); pick_line(); RangeKey(1); } },
            { "label", 0, [this] { LabelDevOpen(); } },
            { "paint", 1, [select_tool] { select_tool(Tool::Paint); } },
            { "support", 2, [select_tool] { select_tool(Tool::Support); } },
        };
        auto clear = [this, select_tool] {
            RangeClose();
            select_tool(Tool::Select);
            ClearSelection();
        };
        add([this] { LabelDevAdd(); });
        wait(6);
        add(clear);
        wait(4);
        double const sizes[][2] = { { 1400, 900 }, { 1200, 800 }, { 1000, 700 }, { 800, 600 }, { 760, 700 }, { 600, 700 }, { 844, 390 } };
        float const turns[][2] = { { 0, 0 }, { 60, 25 }, { -130, -40 } };
        for (auto const &size : sizes)
        {
            double w = size[0], h = size[1];
            add([this, p, w, h] {
                p->sizes++;
                double s = Scale();
                AppWindow().ResizeClient({ (int32_t)(w * s), (int32_t)(h * s) });
            });
            wait(10);
            add([this, w, h] {
                zs::Log("dev: insp size asked %.0f x %.0f, window %.0f x %.0f, narrow %d, view %.0f x %.0f\n", w, h, Root().ActualWidth(), Root().ActualHeight(), NarrowWindow() ? 1 : 0, ViewPanel().ActualWidth(), ViewPanel().ActualHeight());
            });
            // A narrow window: the row closed, then open.
            int states = w <= narrow_window ? 2 : 1;
            for (int state = 0; state < states; state++)
            {
                bool open = states == 1 || state == 1;
                add([this, open] {
                    if (InspectorShown() != open)
                        SetInspectorOpen(open);
                });
                wait(6);
                for (auto const &turn : turns)
                {
                    float dx = turn[0], dy = turn[1];
                    add([this, dx, dy] {
                        zs_view_orbit(view, dx, dy);
                        RequestDraw();
                    });
                    wait(2);
                    for (auto const &kind : kinds)
                    {
                        std::string where = std::to_string((int)w) + "x" + std::to_string((int)h) + (open ? " open " : " closed ") + std::to_string((int)dx) + " " + kind.name;
                        add([p, where, base] {
                            p->where = where;
                            p->selections++;
                            base();
                        });
                        add(kind.make);
                        wait(4);
                        int rank = kind.rank;
                        add([check, rank] { check(rank); });
                        add(clear);
                        wait(3);
                        add([check] { check(-1); });
                    }
                }
            }
        }
        add([this, p] {
            zs::Log("dev: insp proof done: %d selections, %d checks, %d failures, %d sizes\n", p->selections, p->checks, p->failures, p->sizes);
            proof_timer.Stop();
        });
        proof_timer = queue.CreateTimer();
        proof_timer.Interval(std::chrono::milliseconds(50));
        proof_timer.Tick([p](auto &&, auto &&) {
            if (p->at < p->plan.size())
                p->plan[p->at++]();
        });
        proof_timer.Start();
    }

    bool MainWindow::RunInspectorStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        if (verb == L"insprun")
            StartInspectorProof();
        else if (verb == L"inspsize" && words.size() >= 2)
        {
            double s = Scale();
            AppWindow().ResizeClient({ (int32_t)(_wtof(words[0].c_str()) * s), (int32_t)(_wtof(words[1].c_str()) * s) });
        }
        else if (verb == L"inspselect")
        {
            if (tool != Tool::Move)
                SetTool(Tool::Move);
            SelectPart(words.empty() ? 0 : _wtoi(words[0].c_str()));
        }
        else if (verb == L"inspmirror")
            Automation::Peers::ButtonAutomationPeer(words.empty() || words[0] == L"x" ? PartMirrorX() : PartMirrorY()).as<Automation::Provider::IInvokeProvider>().Invoke();
        else if (verb == L"inspscale" && !words.empty())
        {
            zs_app *app = model->Active();
            scale_app = app;
            scale_part = zs_app_part_id(app, (size_t)PrimaryPart());
            PartScale().Text(words[0]);
            scale_edited = true;
            commit_part_scale();
            scale_part = 0;
            FillPartCard();
        }
        else if (verb == L"inspregion" && words.size() >= 4)
        {
            // A body of the selected line, on layers lo to hi, gets a value.
            float const *beads = nullptr;
            size_t n = 0;
            uint32_t id = 0;
            int rc = -1;
            if (SelectedPath() >= 0 && zs_view_connected_beads(view, (size_t)SelectedPath(), (size_t)_wtoi(words[0].c_str()), (size_t)_wtoi(words[1].c_str()), &beads, &n) == ZS_OK && n > 0)
                rc = zs_app_region_set(model->Active(), beads, n, 0, zs::ToUtf8(words[2]).c_str(), zs::ToUtf8(words[3]).c_str(), &id);
            zs::Log("dev: insp region rc %d id %u beads %zu\n", rc, id, n);
            if (rc == ZS_OK)
                PlateEdited();
        }
        else if (verb == L"inspgroup" && !words.empty())
        {
            // Presses the head of a group, or with "log" reads it.
            std::wstring want = words[0];
            std::replace(want.begin(), want.end(), L'_', L' ');
            bool press = words.size() < 2;
            std::function<bool(DependencyObject const &)> walk = [&](DependencyObject const &node) {
                if (auto button = node.try_as<Button>(); button != nullptr && std::wstring(Automation::AutomationProperties::GetName(button)) == want)
                {
                    if (press)
                        Automation::Peers::ButtonAutomationPeer(button).as<Automation::Provider::IInvokeProvider>().Invoke();
                    zs::Log("dev: insp group '%s' %s\n", zs::ToUtf8(want).c_str(), zs::ToUtf8(std::wstring(Automation::AutomationProperties::GetHelpText(button))).c_str());
                    return true;
                }
                for (int32_t i = 0, count = Media::VisualTreeHelper::GetChildrenCount(node); i < count; i++)
                    if (walk(Media::VisualTreeHelper::GetChild(node, i)))
                        return true;
                return false;
            };
            if (!walk(SettingsPane()))
                zs::Log("dev: insp group '%s' not found\n", zs::ToUtf8(want).c_str());
        }
        else if (verb == L"insppart")
        {
            zs_part part{};
            zs_app_part_get(model->Active(), (size_t)PrimaryPart(), &part);
            std::string file = zs::ToUtf8(std::wstring(PartFileText().Text()));
            std::replace(file.begin(), file.end(), '\n', '|');
            zs::Log("dev: insp part scale '%s' (%.3f %.3f %.3f) mirrored %d note '%s' own rows %u file shown %d '%s'\n", zs::ToUtf8(std::wstring(PartScale().Text())).c_str(), part.scale_x, part.scale_y, part.scale_z,
                    PartMirrored().Visibility() == Visibility::Visible ? 1 : 0, zs::ToUtf8(std::wstring(PartScaleNote().Text())).c_str(), PartOwnSettings().Children().Size(),
                    PartFileBox().Visibility() == Visibility::Visible ? 1 : 0, file.c_str());
        }
        else
            return false;
        return true;
    }
#endif
}
