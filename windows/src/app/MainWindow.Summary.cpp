// The details of the print, over the print card of the bottom bar, as in
// web/app/app.js (updateSummaryCard, fillFacts, showRefineTips).
//
// The main settings are small buttons: a click opens the search on that
// setting. Under them are the filaments and the time of the slice. A warning
// says what can go wrong, with a button for the usual fix. The refinements
// are changes that the user made in at least two other prints (the store is
// refine.txt in the state folder, and the core reads it).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "zs_state.h"

#include <cmath>
#include <random>
#include <sstream>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Media = Microsoft::UI::Xaml::Media;
namespace state = zs::state;

namespace
{
    // The area in the air, in mm², that shows the hint to turn on support.
    double const overhang_hint_mm2 = 20;
    // A part under this size is likely in inches or in meters.
    double const tiny_mm = 3;
    double const pills_width = 296;

    Windows::UI::Color const warn_color{ 255, 0xB4, 0x23, 0x18 };
    Windows::UI::Color const hint_color{ 255, 0x8A, 0x5A, 0x00 };

    template <typename F>
    bool ReadCore(F read, std::string &out)
    {
        size_t len = 0;
        if (read(nullptr, 0, &len) != ZS_OK)
            return false;
        std::string text(len + 1, '\0');
        if (read(text.data(), text.size(), &len) != ZS_OK)
            return false;
        text.resize(len);
        out = std::move(text);
        return true;
    }

    std::vector<std::string> Split(std::string const &text, char mark)
    {
        std::vector<std::string> out;
        size_t at = 0;
        for (;;)
        {
            size_t end = text.find(mark, at);
            out.push_back(text.substr(at, end == std::string::npos ? end : end - at));
            if (end == std::string::npos)
                return out;
            at = end + 1;
        }
    }

    std::wstring Millimeters(double value)
    {
        wchar_t text[32];
        swprintf_s(text, L"%.3g mm", value);
        return text;
    }

    std::wstring Whole(double value)
    {
        return std::to_wstring((long long)std::llround(value));
    }

    Button SmallButton(std::wstring const &text)
    {
        Button b;
        b.Content(box_value(text));
        b.MinHeight(26);
        b.MinWidth(0);
        b.FontSize(12);
        b.Padding(ThicknessHelper::FromLengths(8, 2, 8, 2));
        b.CornerRadius(CornerRadiusHelper::FromUniformRadius(7));
        b.VerticalAlignment(VerticalAlignment::Center);
        return b;
    }

    std::wstring RefinePath()
    {
        return state::PathOf(L"refine.txt");
    }

    std::wstring RefineHiddenPath()
    {
        return state::PathOf(L"refine-hidden.txt");
    }

    std::vector<std::string> HiddenTips()
    {
        std::string text;
        if (!state::ReadBytes(RefineHiddenPath(), text))
            return {};
        return Split(text, '\n');
    }

    std::string NewRefineId()
    {
        std::random_device random;
        char text[24];
        snprintf(text, sizeof text, "%08x%08x", random(), random());
        return text;
    }
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    void MainWindow::WireSummary()
    {
        refine_timer = queue.CreateTimer();
        refine_timer.IsRepeating(false);
        refine_timer.Interval(std::chrono::milliseconds(800));
        refine_timer.Tick([this](auto &&, auto &&) { RefreshRefine(); });
    }

    // The main settings of the print, as buttons in rows.
    void MainWindow::FillFacts()
    {
        struct Fact
        {
            std::wstring text, query, title;
        };
        auto number = [this](char const *name) { return atof(model->GetSetting(name).c_str()); };
        std::vector<Fact> facts;
        double height = number("project.layer_height"), first = number("project.first_layer_height");
        if (height > 0)
            facts.push_back({ Millimeters(height) + L" layers" + (first > 0 && std::abs(first - height) > 1e-6 ? L" (first " + Millimeters(first) + L")" : L""),
                              L"layer height", L"The layer height, and the height of the first layer" });
        double walls = number("project.wall_count");
        if (walls > 0)
            facts.push_back({ Whole(walls) + L" walls", L"wall count", L"The number of walls" });
        double density = number("project.infill_density");
        facts.push_back({ density > 0 ? Whole(density * 100) + L" % " + zs::ToWide(model->GetSetting("project.infill_pattern")) : L"no infill",
                          L"infill density", L"The infill density and pattern" });
        std::string support = model->GetSetting("project.support");
        std::wstring support_text = L"no support";
        if (!support.empty() && support != "off")
        {
            support_text = L"support: " + (support == "buildplate" ? std::wstring(L"on the bed") : zs::ToWide(support));
            if (model->GetSetting("project.support_style") == "tree")
                support_text += L", tree";
        }
        facts.push_back({ support_text, L"support", L"Support under overhangs" });
        double brim = number("project.brim_width"), skirt = number("project.skirt_loops");
        facts.push_back({ brim > 0 ? L"brim " + Millimeters(brim) : skirt > 0 ? L"skirt " + Whole(skirt) : L"no skirt",
                          brim > 0 ? L"brim width" : L"skirt loops", L"The brim, or the skirt" });
        double nozzle = number("filament.nozzle_temp"), bed = number("filament.bed_temp");
        if (nozzle > 0)
            facts.push_back({ Whole(nozzle) + L" °C" + (bed > 0 ? L" / bed " + Whole(bed) + L" °C" : L""), L"nozzle temperature",
                              L"The temperatures of the nozzle and the bed" });
        double diameter = number("machine.nozzle_diameter");
        if (diameter > 0)
            facts.push_back({ Millimeters(diameter) + L" nozzle", L"nozzle diameter", L"The diameter of the nozzle (printer settings)" });

        SummaryFacts().Children().Clear();
        StackPanel row{ nullptr };
        double used = 0;
        for (auto const &fact : facts)
        {
            TextBlock probe;
            probe.Text(fact.text);
            probe.FontSize(11.5);
            probe.Measure(Windows::Foundation::Size{ 1000, 40 });
            double width = probe.DesiredSize().Width + 18;
            if (row == nullptr || used + width > pills_width)
            {
                row = StackPanel{};
                row.Orientation(Orientation::Horizontal);
                row.Spacing(4);
                SummaryFacts().Children().Append(row);
                used = 0;
            }
            used += width + 4;
            Button pill;
            pill.Content(box_value(fact.text));
            pill.FontSize(11.5);
            pill.MinHeight(0);
            pill.MinWidth(0);
            pill.Padding(ThicknessHelper::FromLengths(8, 2, 8, 2));
            pill.CornerRadius(CornerRadiusHelper::FromUniformRadius(11));
            ToolTipService::SetToolTip(pill, box_value(fact.title + L". Click to change it."));
            pill.Click([this, query = fact.query](auto &&, auto &&) {
                SummaryFlyout().Hide();
                SearchFor(query);
            });
            row.Children().Append(pill);
        }
    }

    // The warning of the card, with a button for the usual fix. It returns
    // true if it shows.
    bool MainWindow::FillSummaryWarn()
    {
        zs_app *app = model->Active();
        SummaryWarnButtons().Children().Clear();
        auto show = [this](std::wstring const &text, Windows::UI::Color color) {
            SummaryWarn().Text(text);
            SummaryWarnBox().Background(Media::SolidColorBrush(color));
            SummaryWarnBox().Visibility(Visibility::Visible);
            return true;
        };
        auto support_button = [this] {
            Button on = SmallButton(L"Turn on support");
            on.Foreground(Media::SolidColorBrush(Microsoft::UI::Colors::White()));
            on.Click([this](auto &&, auto &&) {
                SummaryFlyout().Hide();
                CommitSetting("project.support", "everywhere");
            });
            SummaryWarnButtons().Children().Append(on);
        };
        if (zs_app_plate_fits(app) != 1)
            return show(L"A part is off the bed or on another part. Move it, turn it, scale it, or cut it (the part card) before you print.", warn_color);

        // A file in inches or in meters: offer the scale.
        std::vector<size_t> tiny;
        std::wstring tiny_text;
        size_t parts = zs_app_part_count(app);
        for (size_t i = 0; i < parts && tiny.size() < 8; i++)
        {
            zs_part p{};
            if (zs_app_part_get(app, i, &p) != ZS_OK)
                continue;
            double size = std::max({ p.size_x, p.size_y, p.size_z });
            if (size >= tiny_mm)
                continue;
            if (tiny.empty())
            {
                wchar_t mm[32];
                swprintf_s(mm, L"%.2f", size);
                std::wstring name = p.name != nullptr && p.name[0] != 0 ? zs::ToWide(p.name) : L"The part";
                tiny_text = name + L" is only " + mm + L" mm. Was the file in inches or in meters?";
            }
            tiny.push_back(i);
        }
        if (!tiny.empty())
        {
            auto scale_button = [this, &tiny](wchar_t const *label, double k) {
                Button b = SmallButton(label);
                b.Foreground(Media::SolidColorBrush(Microsoft::UI::Colors::White()));
                b.Click([this, tiny, k](auto &&, auto &&) {
                    SummaryFlyout().Hide();
                    zs_app *now = model->Active();
                    for (size_t index : tiny)
                    {
                        zs_part p{};
                        if (zs_app_part_get(now, index, &p) == ZS_OK)
                            zs_app_part_scale(now, index, p.scale_x * k, p.scale_y * k, p.scale_z * k);
                    }
                    PlateEdited();
                });
                SummaryWarnButtons().Children().Append(b);
            };
            scale_button(L"Inches (×25.4)", 25.4);
            scale_button(L"Meters (×1000)", 1000);
            return show(tiny_text, hint_color);
        }

        bool support_off = model->GetSetting("project.support") == "off" || model->GetSetting("project.support").empty();
        // The simulated print replaces the estimate from the area in the air.
        zs_print_sim_stats sim{};
        bool has_sim = zs_app_sim_stats(app, &sim) == ZS_OK && sim.masses > 0;
        if (has_sim)
        {
            std::wstring as = sim.material_exact != 0 ? L"" : L" (simulated as " + zs::ToWide(sim.material) + L": the simulation has no data for this plastic)";
            std::wstring text;
            wchar_t drop[32];
            swprintf_s(drop, L"%.1f", sim.max_drop);
            if (sim.failed > 0 && sim.first_failed_layer >= 0)
                text = L"The print fails at layer " + std::to_wstring(sim.first_failed_layer + 1) + L": the plastic over air falls" + as + L". ";
            else if (sim.max_drop > 0.5f)
                text = std::wstring(L"The plastic droops up to ") + drop + L" mm where nothing holds it" + as + L". ";
            if (!text.empty())
            {
                if (support_off)
                    support_button();
                return show(text + (support_off ? L"Turn on support or turn the part." : L"Turn the part, or add support there."), hint_color);
            }
            return false;
        }

        // Support is off, and a large area faces down in the air.
        if (support_off && zs_app_support_area_count(app) == 0)
        {
            zs_issue const *issues = nullptr;
            size_t n = 0;
            char const *words = nullptr;
            double overhang = 0;
            if (zs_app_checks(app, &issues, &n, &words) == ZS_OK)
                for (size_t i = 0; i < n; i++)
                    if ((issues[i].kind == ZS_ISSUE_OVERHANG || issues[i].kind == ZS_ISSUE_ISLAND) && issues[i].severity >= 1)
                        overhang += issues[i].value;
            if (overhang >= overhang_hint_mm2)
            {
                support_button();
                return show(L"About " + Whole(overhang) + L" mm² of the part hangs in the air with no support. It can droop or fail.", hint_color);
            }
        }
        return false;
    }

    // The badge of the card: the problems of the Check, a warning of the
    // card, or the refinements.
    void MainWindow::UpdateSummaryBadge(bool warn)
    {
        size_t tips = refine_tips.size();
        bool hot = warn || check_problems > 0;
        SummaryBadge().Background(hot ? Media::Brush(Media::SolidColorBrush(warn_color)) : TokenBrush(Root(), L"ZsAccent"));
        SummaryBadge().Visibility(hot || tips > 0 ? Visibility::Visible : Visibility::Collapsed);
        if (check_problems > 0)
            SummaryBadgeText().Text(std::to_wstring(check_problems) + L" to check");
        else if (warn)
            SummaryBadgeText().Text(L"Check");
        else
            SummaryBadgeText().Text(tips == 1 ? std::wstring(L"1 refinement") : std::to_wstring(tips) + L" refinements");
    }

    // The changes of this plate go in the store, and the changes that the
    // user made in other prints come back as tips.
    void MainWindow::RefreshRefine()
    {
        if (model == nullptr || zs_app_state(model->Active()) != ZS_STATE_DONE)
            return;
        zs_app *app = model->Active();
        size_t plate = model->ActivePlate();
        if (refine_ids.size() <= plate)
            refine_ids.resize(plate + 1);
        if (refine_ids[plate].empty())
        {
            refine_ids[plate] = NewRefineId();
            SessionSoon();
        }
        std::string const &project = refine_ids[plate];
        std::string store, records, merged, text;
        state::ReadBytes(RefinePath(), store);
        if (!ReadCore([&](char *b, size_t c, size_t *l) { return zs_app_refine_records(app, b, c, l); }, records))
            return;
        if (!ReadCore([&](char *b, size_t c, size_t *l) { return zs_refine_merge(store.c_str(), store.size(), project.c_str(), records.c_str(), records.size(), b, c, l); }, merged))
            merged = store;
        if (merged != store)
            state::WriteBytes(RefinePath(), merged);
        if (!ReadCore([&](char *b, size_t c, size_t *l) { return zs_app_refine_suggest(app, merged.c_str(), merged.size(), project.c_str(), b, c, l); }, text))
            text.clear();

        auto hidden = HiddenTips();
        std::vector<RefineTip> tips;
        for (auto const &line : Split(text, '\n'))
        {
            auto f = Split(line, '\t');
            if (f.size() < 7 || std::find(hidden.begin(), hidden.end(), line) != hidden.end())
                continue;
            std::string scope = f[0] == "layers" ? "layers:" + f[5] + ":" + f[6] : f[0] == "part" ? "part:each part" : "print";
            std::string change = scope + "\t" + f[2] + "\t\t" + f[3] + "\n";
            std::string words;
            ReadCore([&](char *b, size_t c, size_t *l) { return zs_app_history_describe(app, change.c_str(), change.size(), b, c, l); }, words);
            while (!words.empty() && (words.back() == '\n' || words.back() == '\r'))
                words.pop_back();
            auto parts = Split(words, '\t');
            RefineTip tip;
            tip.line = line;
            tip.where = zs::ToWide(parts[0]);
            tip.what = zs::ToWide(parts.size() > 1 ? parts[1] : f[2]);
            tip.count = atoi(f[4].c_str());
            tips.push_back(std::move(tip));
        }
        refine_tips = std::move(tips);
        ShowRefineTips();
    }

    void MainWindow::ShowRefineTips()
    {
        auto panel = SummaryRefine();
        panel.Children().Clear();
        panel.Visibility(refine_tips.empty() ? Visibility::Collapsed : Visibility::Visible);
        UpdateSummaryBadge(SummaryWarnBox().Visibility() == Visibility::Visible);
        if (refine_tips.empty())
            return;
        Grid head;
        ColumnDefinition title_column, all_column;
        title_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        all_column.Width(GridLengthHelper::Auto());
        head.ColumnDefinitions().Append(title_column);
        head.ColumnDefinitions().Append(all_column);
        TextBlock title;
        title.Text(refine_tips.size() == 1 ? std::wstring(L"Your usual refinement") : L"Your usual refinements: " + std::to_wstring(refine_tips.size()));
        title.FontSize(12);
        title.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        title.VerticalAlignment(VerticalAlignment::Center);
        head.Children().Append(title);
        if (refine_tips.size() > 1)
        {
            Button all = SmallButton(L"Apply all");
            ToolTipService::SetToolTip(all, box_value(L"Apply each refinement (one undo step each)"));
            all.Click([this](auto &&, auto &&) {
                auto tips = refine_tips;
                for (auto const &tip : tips)
                    ApplyRefine(tip);
            });
            Grid::SetColumn(all, 1);
            head.Children().Append(all);
        }
        panel.Children().Append(head);
        for (auto const &tip : refine_tips)
        {
            Grid row;
            row.ColumnSpacing(6);
            for (int i = 0; i < 3; i++)
            {
                ColumnDefinition column;
                column.Width(i == 0 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                row.ColumnDefinitions().Append(column);
            }
            StackPanel text;
            TextBlock what;
            what.Text(tip.where + L": " + tip.what);
            what.FontSize(12);
            what.TextWrapping(TextWrapping::Wrap);
            TextBlock count;
            count.Text(L"You made this change in " + std::to_wstring(tip.count) + L" other prints.");
            count.FontSize(11);
            count.TextWrapping(TextWrapping::WrapWholeWords);
            count.Foreground(TokenBrush(Root(), L"ZsDim"));
            text.Children().Append(what);
            text.Children().Append(count);
            row.Children().Append(text);
            Button apply = SmallButton(L"Apply");
            apply.Click([this, tip](auto &&, auto &&) { ApplyRefine(tip); });
            Grid::SetColumn(apply, 1);
            row.Children().Append(apply);
            Button hide = SmallButton(L"×");
            ToolTipService::SetToolTip(hide, box_value(L"Do not offer this again"));
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(hide, L"Do not offer this again");
            hide.Click([this, line = tip.line](auto &&, auto &&) {
                std::string hidden;
                state::ReadBytes(RefineHiddenPath(), hidden);
                state::WriteBytes(RefineHiddenPath(), hidden + line + "\n");
                refine_tips.erase(std::remove_if(refine_tips.begin(), refine_tips.end(), [&](RefineTip const &t) { return t.line == line; }), refine_tips.end());
                ShowRefineTips();
            });
            Grid::SetColumn(hide, 2);
            row.Children().Append(hide);
            panel.Children().Append(row);
        }
    }

    void MainWindow::ApplyRefine(RefineTip const &tip)
    {
        if (model == nullptr)
            return;
        int rc = zs_app_refine_apply(model->Active(), tip.line.data(), tip.line.size());
        if (rc != ZS_OK)
        {
            ShowToast(zs::ToWide(zs_status_message(rc)));
            return;
        }
        model->RequestSlice();
        NoteChange();
        RefreshSettingValues();
        ShowToast(L"Applied: " + tip.what + L". Undo removes it.");
    }
}
