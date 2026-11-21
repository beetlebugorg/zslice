// The features of the view: the colors of the lines, the print as it forms,
// the replay, the gaps, the check of the print, and the bed. The behavior
// follows the GTK shell (linux/src/ui/preview.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Primitives = Microsoft::UI::Xaml::Controls::Primitives;

namespace
{
    double const replay_speeds[] = { 1, 2, 3, 10, 30, 100 };

    wchar_t const *const color_names[] = {
        L"Filament: as the print will look",
        L"Feature: one color for each",
        L"Speed",
        L"Flow",
        L"Layer time (red: short layers, which cool badly)",
        L"Line width",
    };
    wchar_t const *const color_short[] = { L"Filament", L"Feature", L"Speed", L"Flow", L"Layer time", L"Line width" };

    // The legend glyph of the line colors: three short colored stripes.
    wchar_t const legend_glyph[] =
        L"<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='18' Height='18'>"
        L"<Rectangle Width='12' Height='2.6' RadiusX='1' RadiusY='1' Fill='#d9480f' Margin='0,3,0,0' VerticalAlignment='Top'/>"
        L"<Rectangle Width='12' Height='2.6' RadiusX='1' RadiusY='1' Fill='#f59f00' VerticalAlignment='Center'/>"
        L"<Rectangle Width='12' Height='2.6' RadiusX='1' RadiusY='1' Fill='#1c7ed6' Margin='0,0,0,3' VerticalAlignment='Bottom'/>"
        L"</Grid>";

    wchar_t const gaps_glyph[] =
        L"<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='18' Height='18'>"
        L"<Path Data='M2.5 2.5h5.5v5.5h-5.5zM10 10h5.5v5.5h-5.5z' Stroke='{ThemeResource TextFillColorPrimaryBrush}' StrokeThickness='1.4'/>"
        L"<Path Data='M10 2.5h5.5V8' Stroke='{ThemeResource TextFillColorPrimaryBrush}' StrokeThickness='1.4' StrokeDashArray='1.1 1.1'/>"
        L"</Grid>";

    wchar_t const check_glyph[] =
        L"<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Width='18' Height='18'>"
        L"<Path Data='M3.5 9.5l3.5 3.5 7.5-8.5' Stroke='{ThemeResource TextFillColorPrimaryBrush}' StrokeThickness='1.6' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'/>"
        L"</Grid>";
    wchar_t const check_tip[] = L"Check the print: overhangs with no support, bridges, shapes in the air, lines over the flow of the hot end, layers that cool too little, parts that can tip over";

    FrameworkElement LoadGlyph(wchar_t const *xaml)
    {
        return Markup::XamlReader::Load(xaml).as<FrameworkElement>();
    }

    template <typename B>
    void StyleStrip(B const &button, wchar_t const *name, wchar_t const *tip, wchar_t const *glyph)
    {
        button.Width(40);
        button.Height(40);
        button.CornerRadius(CornerRadiusHelper::FromUniformRadius(8));
        button.Padding(ThicknessHelper::FromUniformLength(0));
        Automation::AutomationProperties::SetName(button, name);
        ToolTipService::SetToolTip(button, box_value(tip));
        button.Content(LoadGlyph(glyph));
    }

    // The path of a layer with a point nearest to (x, y), or -1. With
    // feature >= 0, a path of that feature if the layer has one.
    int64_t NearestPath(zs_toolpaths const &tp, size_t layer, double x, double y, int feature)
    {
        if (layer >= tp.layer_count)
            return -1;
        size_t first = layer == 0 ? 0 : tp.layer_ends[layer - 1], last = tp.layer_ends[layer];
        bool has = false;
        if (feature >= 0)
            for (size_t path = first; path < last; path++)
                has = has || tp.path_features[path] == feature;
        int64_t best = -1;
        double best_d = 1e300;
        for (size_t path = first; path < last; path++)
        {
            if (has && tp.path_features[path] != feature)
                continue;
            uint32_t a = path == 0 ? 0 : tp.path_ends[path - 1], b = tp.path_ends[path];
            for (uint32_t k = a; k < b; k++)
            {
                double dx = tp.points[2 * k] - x, dy = tp.points[2 * k + 1] - y, d = dx * dx + dy * dy;
                if (d < best_d)
                {
                    best_d = d;
                    best = (int64_t)path;
                }
            }
        }
        return best;
    }
}

namespace winrt::ZSlice::implementation
{
    void MainWindow::WireView()
    {
        ToolStrip().Children().Append(Markup::XamlReader::Load(L"<Rectangle xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Height='1' Margin='6,3' Fill='{ThemeResource ZsTrough}'/>").as<UIElement>());

        // The colors of the lines.
        Button colors;
        StyleStrip(colors, L"The colors of the lines", L"The colors of the lines", legend_glyph);
        MenuFlyout menu;
        menu.Placement(Primitives::FlyoutPlacementMode::RightEdgeAlignedTop);
        for (int i = 0; i < 6; i++)
        {
            RadioMenuFlyoutItem item;
            item.Text(color_names[i]);
            item.GroupName(L"colors");
            item.IsChecked(i == 0);
            item.Click([this, i](auto &&, auto &&) { SetColorMode(i); });
            color_items.push_back(item);
            menu.Items().Append(item);
        }
        menu.Items().Append(MenuFlyoutSeparator{});
        sim_item = ToggleMenuFlyoutItem{};
        sim_item.Text(L"Show the print as it forms");
        ToolTipService::SetToolTip(sim_item, box_value(L"The plastic of the slice as it would form: it sags and droops where nothing holds it. It shows after each slice; this item switches between it and the plan."));
        sim_item.Click([this](auto &&, auto &&) { ToggleSimulated(); });
        menu.Items().Append(sim_item);
        colors.Flyout(menu);
        ToolStrip().Children().Append(colors);

        // The gaps of the top layer.
        gaps_button = Primitives::ToggleButton{};
        StyleStrip(gaps_button, L"Gaps", L"Gaps: show the gaps of the top layer in red: areas that should be solid that no line covers. Click a gap for the settings that can close it.", gaps_glyph);
        gaps_button.Click([this](auto &&, auto &&) { SetGaps(gaps_button.IsChecked().GetBoolean()); });
        ToolStrip().Children().Append(gaps_button);
        GapClose().Click([this](auto &&, auto &&) { GapCard().Visibility(Visibility::Collapsed); });

        // The check of the print.
        Button check;
        check_button = check;
        StyleStrip(check, L"Check the print", check_tip, check_glyph);
        check_flyout = Flyout{};
        check_flyout.Placement(Primitives::FlyoutPlacementMode::RightEdgeAlignedTop);
        ScrollViewer scroll;
        scroll.MaxHeight(420);
        scroll.Width(380);
        check_list = StackPanel{};
        check_list.Spacing(2);
        scroll.Content(check_list);
        check_flyout.Content(scroll);
        check_flyout.Opening([this](auto &&, auto &&) { FillCheck(); });
        check.Flyout(check_flyout);
        // The count of the problems, on the corner of the button.
        Grid check_host;
        check_host.Children().Append(check);
        check_count = Border{};
        check_count.HorizontalAlignment(HorizontalAlignment::Right);
        check_count.VerticalAlignment(VerticalAlignment::Top);
        check_count.Margin(ThicknessHelper::FromLengths(0, 2, 2, 0));
        check_count.MinWidth(14);
        check_count.Height(14);
        check_count.Padding(ThicknessHelper::FromLengths(3, 0, 3, 0));
        check_count.CornerRadius(CornerRadiusHelper::FromUniformRadius(7));
        check_count.Background(Media::SolidColorBrush(Windows::UI::Color{ 255, 0xD9, 0x77, 0x06 }));
        check_count.IsHitTestVisible(false);
        check_count.Visibility(Visibility::Collapsed);
        check_count_text = TextBlock{};
        check_count_text.FontSize(10);
        check_count_text.LineHeight(14);
        check_count_text.TextAlignment(TextAlignment::Center);
        check_count_text.VerticalAlignment(VerticalAlignment::Center);
        check_count_text.Foreground(Media::SolidColorBrush(Microsoft::UI::Colors::White()));
        check_count.Child(check_count_text);
        check_host.Children().Append(check_count);
        ToolStrip().Children().Append(check_host);

        // The replay.
        replay_timer = queue.CreateTimer();
        replay_timer.Interval(std::chrono::milliseconds(16));
        replay_timer.Tick([this](auto &&, auto &&) { ReplayTick(); });
        for (double speed : replay_speeds)
            SpeedBox().Items().Append(box_value(std::to_wstring((int)speed) + L"×"));
        SpeedBox().SelectedIndex(3);
        PlayButton().Click([this](auto &&, auto &&) { TogglePlay(); });
        ScrubSlider().ValueChanged([this](auto &&, Primitives::RangeBaseValueChangedEventArgs const &e) {
            if (!scrub_quiet)
                OnScrub(e.NewValue());
        });
    }

    void MainWindow::SetColorMode(int mode)
    {
        color_mode = mode;
        for (size_t i = 0; i < color_items.size(); i++)
            color_items[i].IsChecked((int)i == mode);
        if (view == nullptr || model == nullptr)
            return;
        if (zs_app_state(model->Active()) == ZS_STATE_DONE)
            ShowSlice();
        else
            zs_view_set_mode(view, mode);
        ShowLegend();
        RequestDraw();
    }

    void MainWindow::ShowLegend()
    {
        double lo = 0, hi = 0;
        std::wstring text;
        if (view != nullptr && color_mode >= 2 && zs_view_legend(view, &lo, &hi))
        {
            wchar_t line[96];
            if (color_mode == 2)
                swprintf_s(line, L"%.0f–%.0f mm/s", lo, hi);
            else if (color_mode == 3)
                swprintf_s(line, L"%.0f–%.0f mm³/s", lo, hi);
            else if (color_mode == 4)
                swprintf_s(line, L"%.0f–%.0f s (red: short)", lo, hi);
            else
                swprintf_s(line, L"%.2f–%.2f mm", lo, hi);
            text = std::wstring(color_short[color_mode]) + L": " + line;
        }
        if (gaps_on && model != nullptr && zs_app_state(model->Active()) == ZS_STATE_DONE && layer_count > 0)
        {
            zs_gap const *gaps = nullptr;
            size_t n = 0;
            size_t layer = (size_t)LayerSlider().Value() - 1;
            if (zs_app_layer_gaps(model->Active(), layer, &gaps, &n, nullptr, nullptr) == ZS_OK)
            {
                double area = 0;
                for (size_t i = 0; i < n; i++)
                    area += gaps[i].area;
                wchar_t line[64];
                if (n == 0)
                    swprintf_s(line, L"No gaps");
                else
                    swprintf_s(line, L"%zu gap%s · %.2f mm²", n, n == 1 ? L"" : L"s", area);
                text += (text.empty() ? L"" : L"   ·   ") + std::wstring(line);
            }
        }
        LegendText().Text(text);
        LegendCard().Visibility(text.empty() ? Visibility::Collapsed : Visibility::Visible);
    }

    // ---- the print as it forms ----

    // The simulation of the slice is ready: the view shows it.
    void MainWindow::OnSimulated()
    {
        if (model == nullptr || !zs_app_sim_adopt(model->Active()))
            return;
        simulated = true;
        sim_item.IsChecked(true);
        ShowSlice();
        if (sim_asked)
            RefreshSummary();
        sim_asked = false;
    }

    void MainWindow::ToggleSimulated()
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        if (zs_app_state(app) != ZS_STATE_DONE)
        {
            ShowToast(L"Slice first: the simulation needs a slice.");
            simulated = false;
            sim_item.IsChecked(false);
            return;
        }
        simulated = !simulated;
        sim_item.IsChecked(simulated);
        if (!simulated)
        {
            sim_asked = false;
            zs_app_show_simulated(app, 0);
            ShowSlice();
            return;
        }
        // The simulation after the slice, if it is done. Else it runs on
        // the thread of the core, and ZS_EVENT_SIMULATED shows it.
        if (zs_app_show_simulated(app, 1) == ZS_OK)
        {
            ShowSlice();
            return;
        }
        if (zs_app_sim_request(app) != ZS_OK)
        {
            ShowToast(L"Slice first: the simulation needs a slice.");
            simulated = false;
            sim_item.IsChecked(false);
            return;
        }
        sim_asked = true;
        ShowBusy(L"Simulating the plastic of the print…");
    }

    // ---- the replay ----

    void MainWindow::StopReplay()
    {
        playing = false;
        if (replay_timer != nullptr)
            replay_timer.Stop();
        PlayIcon().Glyph(L"");
    }

    bool MainWindow::LayerTimes(size_t layer, double &t0, double &t1)
    {
        zs_toolpaths tp{};
        if (model == nullptr || zs_app_toolpaths(model->Active(), &tp) != ZS_OK || layer >= tp.layer_count)
            return false;
        uint32_t last = tp.layer_ends[layer];
        uint32_t prev = layer > 0 ? tp.layer_ends[layer - 1] : 0;
        t0 = prev > 0 ? tp.path_end_time[prev - 1] : 0;
        t1 = last > 0 ? tp.path_end_time[last - 1] : t0;
        return true;
    }

    void MainWindow::ShowScrub(size_t layer, double t)
    {
        double t0 = 0, t1 = 0;
        if (!LayerTimes(layer, t0, t1))
        {
            ScrubText().Text(L"");
            return;
        }
        double f = t1 > t0 ? std::clamp((t - t0) / (t1 - t0), 0.0, 1.0) : 1;
        scrub_quiet = true;
        ScrubSlider().Value(f);
        scrub_quiet = false;
        double in = std::clamp(t - t0, 0.0, t1 - t0), len = t1 - t0;
        wchar_t text[64];
        swprintf_s(text, L"Layer %zu · %d:%02d / %d:%02d", layer + 1, (int)in / 60, (int)in % 60, (int)len / 60, (int)len % 60);
        ScrubText().Text(text);
    }

    // A drag of the scrub bar: the nozzle goes to that time in the top
    // layer, and a replay pauses.
    void MainWindow::OnScrub(double fraction)
    {
        if (view == nullptr || layer_count == 0)
            return;
        size_t layer = (size_t)LayerSlider().Value() - 1;
        double t0, t1;
        if (!LayerTimes(layer, t0, t1))
            return;
        StopReplay();
        replay_time = t0 + fraction * (t1 - t0);
        // At the end of the layer: whole layers again.
        if (fraction >= 1)
            zs_view_set_layer(view, layer);
        else
            zs_view_set_time(view, replay_time);
        ShowScrub(layer, replay_time);
        RequestDraw();
    }

    void MainWindow::TogglePlay()
    {
        if (playing)
        {
            StopReplay();
            return;
        }
        if (view == nullptr || model == nullptr || zs_app_state(model->Active()) != ZS_STATE_DONE)
            return;
        double total = zs_view_duration(view);
        if (total <= 0)
            return;
        if (replay_time >= total)
            replay_time = 0;
        // After a move of the slider: from the start of the top layer.
        if (replay_time <= 0 && (size_t)LayerSlider().Value() < layer_count)
        {
            double t0, t1;
            if (LayerTimes((size_t)LayerSlider().Value() - 1, t0, t1))
                replay_time = t0;
        }
        playing = true;
        replay_last = std::chrono::steady_clock::now();
        PlayIcon().Glyph(L"");
        replay_timer.Start();
    }

    void MainWindow::ReplayTick()
    {
        if (view == nullptr)
        {
            StopReplay();
            return;
        }
        auto now = std::chrono::steady_clock::now();
        double dt = std::chrono::duration<double>(now - replay_last).count();
        replay_last = now;
        int32_t k = SpeedBox().SelectedIndex();
        replay_time += dt * replay_speeds[k >= 0 && k < (int32_t)std::size(replay_speeds) ? k : 0];
        double total = zs_view_duration(view);
        if (replay_time >= total)
            replay_time = total;
        zs_view_set_time(view, replay_time);
        size_t layer = zs_view_layer_at_time(view, replay_time);
        setting_layer = true;
        LayerSlider().Value((double)layer + 1);
        setting_layer = false;
        LayerText().Text(to_hstring(layer + 1));
        ShowScrub(layer, replay_time);
        RequestDraw();
        if (replay_time >= total)
            StopReplay();
    }

    // ---- gaps ----

    void MainWindow::SetGaps(bool on)
    {
        gaps_on = on;
        gaps_button.IsChecked(on);
        if (!on)
            GapCard().Visibility(Visibility::Collapsed);
        ShowGaps();
    }

    void MainWindow::ShowGaps()
    {
        if (view == nullptr || model == nullptr)
            return;
        bool show = gaps_on && layer_count > 0 && zs_app_state(model->Active()) == ZS_STATE_DONE;
        zs_view_show_gaps(view, model->Active(), show ? (int64_t)LayerSlider().Value() - 1 : -1);
        ShowLegend();
        RequestDraw();
    }

    // A click on a gap: the settings that can close it. True if it hit one.
    bool MainWindow::GapClick(double x, double y)
    {
        if (!gaps_on || view == nullptr || layer_count == 0)
            return false;
        zs_app *app = model->Active();
        int64_t gap = zs_view_gap_at(view, app, (float)(x * Scale()), (float)(y * Scale()));
        if (gap < 0)
        {
            GapCard().Visibility(Visibility::Collapsed);
            return false;
        }
        size_t layer = (size_t)LayerSlider().Value() - 1;
        zs_gap const *gaps = nullptr;
        size_t n = 0;
        if (zs_app_layer_gaps(app, layer, &gaps, &n, nullptr, nullptr) != ZS_OK || (size_t)gap >= n)
            return false;
        zs_gap const &g = gaps[gap];
        GapTitle().Text(L"A gap · layer " + std::to_wstring(layer + 1));
        wchar_t facts[96];
        swprintf_s(facts, L"%.3f mm², %.2f mm wide%s", g.area, g.width, g.at_edge ? L", at the edge of the part" : L"");
        GapFacts().Text(facts);
        GapAdvice().Children().Clear();
        zs_gap_step steps[6];
        size_t count = 0;
        if (zs_app_gap_advice(app, layer, (size_t)gap, steps, std::size(steps), &count) == ZS_OK)
        {
            for (size_t i = 0; i < count; i++)
            {
                std::string name(steps[i].name, steps[i].name_len), value(steps[i].value, steps[i].value_len), why(steps[i].why, steps[i].why_len);
                Grid row;
                row.ColumnSpacing(6);
                ColumnDefinition text_column, button_column;
                text_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                button_column.Width(GridLengthHelper::Auto());
                row.ColumnDefinitions().Append(text_column);
                row.ColumnDefinitions().Append(button_column);
                TextBlock text;
                text.Text(zs::ToWide(why));
                text.TextWrapping(TextWrapping::WrapWholeWords);
                text.FontSize(12);
                row.Children().Append(text);
                Button apply;
                apply.Content(box_value(L"Try"));
                apply.VerticalAlignment(VerticalAlignment::Center);
                ToolTipService::SetToolTip(apply, box_value(zs::ToWide(name + " = " + value)));
                apply.Click([this, name, value](auto &&, auto &&) { CommitSetting(name, value); });
                Grid::SetColumn(apply, 1);
                row.Children().Append(apply);
                GapAdvice().Children().Append(row);
            }
        }
        HideCards();
        GapCard().Visibility(Visibility::Visible);
        double box[4] = { x - 12, y - 12, x + 12, y + 12 };
        PlaceCard(GapCard(), box);
        return true;
    }

    // ---- the check ----

    // The Check button and the badge of the print card show this count.
    void MainWindow::ShowCheckCount(size_t count)
    {
        check_count_text.Text(std::to_wstring(count));
        check_count.Visibility(count > 0 ? Visibility::Visible : Visibility::Collapsed);
        std::wstring tip = count > 0 ? L"Check the print: " + std::to_wstring(count) + (count == 1 ? L" problem" : L" problems") + L" to look at"
                                     : std::wstring(check_tip);
        ToolTipService::SetToolTip(check_button, box_value(tip));
    }

    void MainWindow::FillCheck()
    {
        check_list.Children().Clear();
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        zs_issue const *issues = nullptr;
        size_t n = 0;
        char const *text = nullptr;
        wchar_t const *empty = nullptr;
        if (zs_app_state(app) != ZS_STATE_DONE)
            empty = L"Slice the plate first.";
        else
        {
            int rc = zs_app_checks(app, &issues, &n, &text);
            if (rc == ZS_BUSY)
                empty = L"Checking the print…";
            else if (rc != ZS_OK)
                empty = L"The check failed.";
        }
        if (empty == nullptr && n == 0)
            empty = L"No issues found.";
        if (empty != nullptr)
        {
            TextBlock line;
            line.Text(empty);
            line.Margin(ThicknessHelper::FromLengths(6, 10, 6, 10));
            check_list.Children().Append(line);
            return;
        }
        for (size_t i = 0; i < n; i++)
        {
            zs_issue const issue = issues[i];
            Button row;
            row.HorizontalAlignment(HorizontalAlignment::Stretch);
            row.HorizontalContentAlignment(HorizontalAlignment::Left);
            row.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            row.BorderThickness(ThicknessHelper::FromUniformLength(0));
            Grid content;
            content.ColumnSpacing(8);
            ColumnDefinition icon_column, text_column;
            icon_column.Width(GridLengthHelper::Auto());
            text_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            content.ColumnDefinitions().Append(icon_column);
            content.ColumnDefinitions().Append(text_column);
            FontIcon icon;
            int severity = std::min<int>(issue.severity, 2);
            icon.Glyph(severity == 2 ? L"" : severity == 1 ? L"" : L"");
            icon.FontSize(14);
            icon.VerticalAlignment(VerticalAlignment::Top);
            icon.Foreground(Media::SolidColorBrush(severity == 2 ? Windows::UI::Color{ 255, 0xC0, 0x1C, 0x28 }
                                                   : severity == 1 ? Windows::UI::Color{ 255, 0xB4, 0x53, 0x09 }
                                                                   : Windows::UI::Color{ 255, 0x5B, 0x61, 0x68 }));
            content.Children().Append(icon);
            TextBlock line;
            line.Text(zs::ToWide(std::string(text + issue.text_start, issue.text_len)));
            line.TextWrapping(TextWrapping::WrapWholeWords);
            line.FontSize(13);
            Grid::SetColumn(line, 1);
            content.Children().Append(line);
            row.Content(content);
            row.Click([this, issue](auto &&, auto &&) { GoToIssue(issue); });
            check_list.Children().Append(row);
        }
    }

    // A click on an issue shows its layer, and selects its line.
    void MainWindow::GoToIssue(zs_issue const &issue)
    {
        check_flyout.Hide();
        if (model == nullptr || issue.layer >= layer_count)
            return;
        StopReplay();
        LayerSlider().Value((double)issue.layer + 1);
        zs_toolpaths tp{};
        if (zs_app_toolpaths(model->Active(), &tp) != ZS_OK)
            return;
        int feature = issue.kind == ZS_ISSUE_BRIDGE ? ZS_FEATURE_BRIDGE : issue.kind == ZS_ISSUE_OVERHANG ? ZS_FEATURE_SKIN : -1;
        int64_t path = issue.path != ZS_NO_PATH ? (int64_t)issue.path : NearestPath(tp, issue.layer, issue.x, issue.y, feature);
        if (path < 0)
            return;
        float rect[4];
        if (zs_view_path_rect(view, (size_t)path, rect))
        {
            click_x = (rect[0] + rect[2]) / 2 / Scale();
            click_y = (rect[1] + rect[3]) / 2 / Scale();
        }
        SelectLine(path, -1);
    }

    void MainWindow::ToggleBed()
    {
        if (view == nullptr)
            return;
        bed_hidden = !bed_hidden;
        zs_view_set_bed_hidden(view, bed_hidden ? 1 : 0);
        RequestDraw();
    }
}
