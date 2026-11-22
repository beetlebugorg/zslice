// The filaments of the plate: the button of the top bar and its list, the
// round chips of the tools, and the filament, label, and paint rows of the
// part card. The behavior follows the GTK shell (linux/src/ui/filaments.c,
// setting-editor.c, and part-card.c).
//
// The chips change in the turn after their click, so a chip never goes away
// in its own click.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

#include "zs_label.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Shapes = Microsoft::UI::Xaml::Shapes;
using Media::SolidColorBrush;

namespace
{
    // The most filaments of a plate (src/app/filament_slots.zig), and the
    // most dots on the button.
    constexpr size_t max_filaments = 16;
    constexpr int max_dots = 8;
    constexpr double dot_size = 10;

    wchar_t const *const materials[] = { L"PLA", L"PETG", L"ABS", L"ASA", L"TPU", L"PA", L"PC", L"PVA" };

    Windows::UI::Color ColorOf(std::string const &text)
    {
        unsigned r = 0xd0, g = 0xd0, b = 0xcc;
        if (text.size() == 7 && text[0] == '#')
        {
            unsigned x, y, z;
            if (sscanf_s(text.c_str() + 1, "%02x%02x%02x", &x, &y, &z) == 3)
            {
                r = x;
                g = y;
                b = z;
            }
        }
        return Windows::UI::Color{ 255, (uint8_t)r, (uint8_t)g, (uint8_t)b };
    }

    std::string HexOf(Windows::UI::Color c)
    {
        char text[8];
        snprintf(text, sizeof text, "#%02x%02x%02x", c.R, c.G, c.B);
        return text;
    }

    SolidColorBrush Gray(uint8_t a)
    {
        return SolidColorBrush(Windows::UI::Color{ a, 0x1b, 0x1b, 0x1d });
    }

    TextBlock Heading(wchar_t const *text)
    {
        TextBlock t;
        t.Text(text);
        t.FontSize(12);
        t.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        return t;
    }
}

namespace winrt::ZSlice::implementation
{
    // The choices of the nozzle of a filament: "Main" and "2nd" for two
    // nozzles, else the tools T0 and on. A nozzle that the printer does not
    // have stays in the list, marked, so the value shows (the Check tells
    // it). As nozzleChoices in web/app/filaments.js.
    void FillNozzleChoices(ComboBox const &box, int nozzles, int current)
    {
        box.Items().Clear();
        auto add = [&](std::wstring const &label, int k) {
            ComboBoxItem item;
            item.Content(box_value(label));
            item.Tag(box_value(k));
            box.Items().Append(item);
        };
        for (int k = 0; k < nozzles; k++)
            add(nozzles == 2 ? std::wstring(k == 0 ? L"Main" : L"2nd") : L"T" + std::to_wstring(k), k);
        if (current >= nozzles)
            add(L"T" + std::to_wstring(current) + L" (none)", current);
        box.SelectedIndex(current >= nozzles ? nozzles : current);
    }

    // The changes and the waste of a slice, in one line: "3 changes, about
    // 2 min · waste 10.3 g (12 %)", and its parts for the tooltip. As
    // wasteText and wasteTip in web/app/filaments.js.
    void WasteWords(zs_app const *app, uint32_t changes, std::wstring &text, std::wstring &tip)
    {
        double chute = 0, tower = 0, total = 0, change_s = 0;
        if (zs_app_waste(app, &chute, &tower, &total, &change_s) != ZS_OK)
            chute = tower = total = change_s = 0;
        text = std::to_wstring(changes) + (changes == 1 ? L" change" : L" changes");
        wchar_t part[64];
        if (change_s >= 60)
        {
            swprintf_s(part, L", about %.0f min", std::round(change_s / 60));
            text += part;
        }
        else if (change_s > 0)
        {
            swprintf_s(part, L", about %.0f s", std::round(change_s));
            text += part;
        }
        double waste = chute + tower;
        if (waste >= 0.05)
        {
            swprintf_s(part, L" · waste %.1f g", waste);
            text += part;
            if (total > 0)
            {
                swprintf_s(part, L" (%.0f %%)", std::round(100 * waste / total));
                text += part;
            }
        }
        tip.clear();
        auto line = [&](wchar_t const *format, double value) {
            swprintf_s(part, format, value);
            tip += (tip.empty() ? L"" : L"\n") + std::wstring(part);
        };
        if (chute > 0.05)
            line(L"Flush out of the print: %.1f g", chute);
        if (tower > 0.05)
            line(L"Prime tower: %.1f g", tower);
        if (change_s > 0)
            line(L"Filament changes: %.0f s", std::round(change_s));
    }

    // The nozzle of the choice, or -1 for none.
    int NozzleChoice(ComboBox const &box)
    {
        auto selected = box.SelectedItem();
        if (selected == nullptr)
            return -1;
        auto item = selected.try_as<ComboBoxItem>();
        return item != nullptr ? unbox_value_or<int>(item.Tag(), -1) : -1;
    }

    struct MainWindow::FilamentState
    {
        struct Row
        {
            size_t index = 0;
            Border swatch{ nullptr };
            Flyout color_flyout{ nullptr };
            ColorPicker picker{ nullptr };
            ComboBox material{ nullptr };
            ComboBox nozzle{ nullptr };
            TextBlock grams{ nullptr };
            std::string color;
            // What the nozzle list holds.
            int shown_nozzles = 0, shown_extra = -1;
        };

        explicit FilamentState(MainWindow &window) : w(window) {}

        MainWindow &w;
        Canvas dots{ nullptr };
        TextBlock name{ nullptr };
        TextBlock head{ nullptr };
        StackPanel list{ nullptr };
        Button add{ nullptr };
        TextBlock note{ nullptr };
        std::vector<Row> rows;
        int nozzles = 1;
        bool filling = false;
        // The rows of the part card.
        VariableSizedWrapGrid part_chips{ nullptr };
        StackPanel part_labels{ nullptr };
        StackPanel part_paint{ nullptr };
        std::string chips_key, labels_key, paint_key;

        template <typename F>
        void Later(F action)
        {
            auto weak = w.get_weak();
            w.queue.TryEnqueue([weak, action] {
                if (auto self = weak.get())
                    action();
            });
        }

        void Set(size_t i, char const *field, std::string const &value)
        {
            int rc = zs_app_filament_set(w.model->Active(), i, field, value.c_str());
            if (rc != ZS_OK)
            {
                w.ShowToast(L"The filament did not change: " + zs::ToWide(zs_status_message(rc)));
                return;
            }
            // Filament 0 is the filament of the settings.
            if (i == 0)
                w.RefreshSettingValues();
            w.FilamentsChanged();
            w.PlateEdited();
        }

        void UpdateButton()
        {
            zs_app *app = w.model->Active();
            size_t n = zs_app_filament_count(app);
            dots.Children().Clear();
            int shown = (int)std::min<size_t>(n, max_dots);
            for (int i = 0; i < shown; i++)
            {
                // The dots overlap a little, as on the web.
                Shapes::Ellipse dot;
                dot.Width(dot_size);
                dot.Height(dot_size);
                dot.Fill(SolidColorBrush(ColorOf(w.FilamentValue((size_t)i, "filament.color"))));
                dot.Stroke(Gray(0x66));
                dot.StrokeThickness(1);
                Canvas::SetLeft(dot, i * (dot_size - 3));
                Canvas::SetTop(dot, 0);
                dots.Children().Append(dot);
            }
            dots.Width(shown > 0 ? dot_size + (shown - 1) * (dot_size - 3) : 0);
            bool from = n > 0;
            for (size_t i = 0; i < n && from; i++)
                from = w.FilamentValue(i, "source.printer") == "1";
            std::wstring more = from ? L" · From the printer" : L"";
            std::wstring tip;
            if (n > 1)
            {
                name.Text(std::to_wstring(n) + L" filaments" + more);
                tip = L"The " + std::to_wstring(n) + L" filaments of the plate: click to change them";
                if (from)
                    tip += L". They are the spools in the printer.";
            }
            else
            {
                std::string own = w.model->GetSetting("filament.name");
                name.Text((own.empty() ? std::wstring(L"Filament") : zs::ToWide(own)) + more);
                tip = from ? L"The filament: the spool in the printer. Click to change it, or to add filaments"
                           : L"The filament: click to change it, or to add filaments";
            }
            ToolTipService::SetToolTip(w.FilamentButton(), box_value(tip));
        }

        void AddRow(size_t i)
        {
            Row row;
            row.index = i;
            StackPanel line;
            line.Orientation(Orientation::Horizontal);
            line.Spacing(6);

            std::wstring number = std::to_wstring(i + 1);
            Button color;
            color.Padding(ThicknessHelper::FromUniformLength(3));
            color.VerticalAlignment(VerticalAlignment::Center);
            Automation::AutomationProperties::SetName(color, L"The color of filament " + number);
            ToolTipService::SetToolTip(color, box_value(L"The color of filament " + number));
            Border swatch;
            swatch.Width(22);
            swatch.Height(22);
            swatch.CornerRadius(CornerRadiusHelper::FromUniformRadius(11));
            swatch.BorderBrush(Gray(0x59));
            swatch.BorderThickness(ThicknessHelper::FromUniformLength(1));
            color.Content(swatch);
            row.swatch = swatch;
            Flyout fly;
            ColorPicker picker;
            picker.IsAlphaEnabled(false);
            picker.IsHexInputVisible(true);
            picker.IsMoreButtonVisible(false);
            fly.Content(picker);
            color.Flyout(fly);
            row.color_flyout = fly;
            row.picker = picker;
            fly.Opening([this, i](auto &&, auto &&) {
                if (i < rows.size())
                    rows[i].picker.Color(ColorOf(w.FilamentValue(i, "filament.color")));
            });
            // The color goes to the core when the picker closes: one slice
            // and one step of the history.
            fly.Closed([this, i](auto &&, auto &&) {
                if (i >= rows.size() || w.model == nullptr)
                    return;
                std::string hex = HexOf(rows[i].picker.Color());
                if (hex != rows[i].color)
                    Set(i, "filament.color", hex);
            });
            line.Children().Append(color);

            TextBlock label;
            label.Text(number);
            label.Width(18);
            label.TextAlignment(TextAlignment::Center);
            label.VerticalAlignment(VerticalAlignment::Center);
            line.Children().Append(label);

            ComboBox material;
            material.Width(104);
            material.VerticalAlignment(VerticalAlignment::Center);
            Automation::AutomationProperties::SetName(material, L"The material of filament " + number);
            ToolTipService::SetToolTip(material, box_value(L"The material of filament " + number));
            for (auto m : materials)
                material.Items().Append(box_value(m));
            material.SelectionChanged([this, i](auto &&, auto &&) {
                if (filling || i >= rows.size())
                    return;
                auto item = rows[i].material.SelectedItem();
                if (item == nullptr)
                    return;
                std::string value = zs::ToUtf8(std::wstring(unbox_value<hstring>(item)));
                if (value != w.FilamentValue(i, "filament.material"))
                    Set(i, "filament.material", value);
            });
            line.Children().Append(material);
            row.material = material;

            if (nozzles >= 2)
            {
                ComboBox nozzle;
                nozzle.MinWidth(84);
                nozzle.VerticalAlignment(VerticalAlignment::Center);
                Automation::AutomationProperties::SetName(nozzle, L"The nozzle of filament " + number);
                std::wstring tip = L"The nozzle of filament " + number;
                if (nozzles == 2)
                    tip += L": the main nozzle (fed by the AMS on the X2D), or the second nozzle (fed by the external spool)";
                else
                    tip += L": the tool that prints it (T0 to T" + std::to_wstring(nozzles - 1) + L")";
                ToolTipService::SetToolTip(nozzle, box_value(tip));
                nozzle.SelectionChanged([this, i](auto &&, auto &&) {
                    if (filling || i >= rows.size())
                        return;
                    int want = NozzleChoice(rows[i].nozzle);
                    if (want >= 0 && want != atoi(w.FilamentValue(i, "filament.nozzle").c_str()))
                        Set(i, "filament.nozzle", std::to_string(want));
                });
                line.Children().Append(nozzle);
                row.nozzle = nozzle;
            }

            TextBlock grams;
            grams.Width(62);
            grams.FontSize(12);
            grams.Opacity(0.7);
            grams.TextAlignment(TextAlignment::Right);
            grams.VerticalAlignment(VerticalAlignment::Center);
            line.Children().Append(grams);
            row.grams = grams;

            if (i > 0)
            {
                Button remove;
                remove.Content(box_value(L"×"));
                remove.Background(SolidColorBrush(Microsoft::UI::Colors::Transparent()));
                remove.BorderThickness(ThicknessHelper::FromUniformLength(0));
                remove.VerticalAlignment(VerticalAlignment::Center);
                Automation::AutomationProperties::SetName(remove, L"Remove filament " + number);
                ToolTipService::SetToolTip(remove, box_value(L"Remove filament " + number + L". Its parts and layers print with filament 1."));
                remove.Click([this, i](auto &&, auto &&) {
                    Later([this, i] {
                        if (w.model == nullptr || zs_app_filament_remove(w.model->Active(), i) != ZS_OK)
                            return;
                        w.RefreshSettingValues();
                        w.FilamentsChanged();
                        w.PlateEdited();
                    });
                });
                line.Children().Append(remove);
            }
            list.Children().Append(line);
            rows.push_back(std::move(row));
        }

        void FillRow(Row &row, double const *grams, size_t n_grams)
        {
            row.color = w.FilamentValue(row.index, "filament.color");
            row.swatch.Background(SolidColorBrush(ColorOf(row.color)));
            // A material that is not in the list goes first.
            std::string own = w.FilamentValue(row.index, "filament.material");
            std::wstring mat = own.empty() ? L"PLA" : zs::ToWide(own);
            int at = -1;
            auto items = row.material.Items();
            for (uint32_t k = 0; k < items.Size(); k++)
                if (unbox_value<hstring>(items.GetAt(k)) == mat)
                    at = (int)k;
            if (at < 0)
            {
                if (items.Size() > std::size(materials))
                    items.RemoveAt(0);
                items.InsertAt(0, box_value(mat));
                at = 0;
            }
            if (row.material.SelectedIndex() != at)
                row.material.SelectedIndex(at);
            if (row.nozzle != nullptr)
            {
                int current = std::max(0, atoi(w.FilamentValue(row.index, "filament.nozzle").c_str()));
                int extra = current >= nozzles ? current : -1;
                if (row.shown_nozzles != nozzles || row.shown_extra != extra)
                {
                    FillNozzleChoices(row.nozzle, nozzles, current);
                    row.shown_nozzles = nozzles;
                    row.shown_extra = extra;
                }
                else if (extra < 0 && row.nozzle.SelectedIndex() != current)
                {
                    row.nozzle.SelectedIndex(current);
                }
            }
            bool printer = w.FilamentValue(row.index, "source.printer") == "1";
            std::string slot = w.FilamentValue(row.index, "source.slot");
            std::wstring text = printer ? (slot.empty() ? std::wstring(L"Printer") : zs::ToWide(slot)) : L"";
            if (row.index < n_grams && grams[row.index] > 0)
            {
                wchar_t g[32];
                swprintf_s(g, L"%s%.1f g", text.empty() ? L"" : L" · ", grams[row.index]);
                text += g;
            }
            row.grams.Text(text);
            if (printer)
                ToolTipService::SetToolTip(row.grams, box_value(slot.empty() ? std::wstring(L"From the printer: its spool")
                                                                             : L"From the printer: the spool in " + zs::ToWide(slot)));
            else if (w.FilamentValue(row.index, "source.hand") == "1")
                ToolTipService::SetToolTip(row.grams, box_value(L"You set this filament. It stays when the printer has other spools."));
            else
                ToolTipService::SetToolTip(row.grams, nullptr);
        }

        void UpdateList()
        {
            zs_app *app = w.model->Active();
            size_t n = zs_app_filament_count(app);
            int nozzles_now = w.NozzleCount();
            filling = true;
            if (n != rows.size() || nozzles_now != nozzles)
            {
                list.Children().Clear();
                rows.clear();
                nozzles = nozzles_now;
                for (size_t i = 0; i < n; i++)
                    AddRow(i);
            }
            double grams[max_filaments] = {};
            uint32_t changes = 0;
            double flush = 0;
            size_t n_grams = zs_app_filament_stats(app, grams, max_filaments, &changes, &flush) == ZS_OK ? max_filaments : 0;
            for (auto &row : rows)
                FillRow(row, grams, n_grams);
            filling = false;

            std::wstring title = n > 1 ? std::to_wstring(n) + L" filaments" : L"Filament";
            std::wstring tip;
            if (n_grams > 0 && changes > 0)
            {
                std::wstring words;
                WasteWords(app, changes, words, tip);
                title += L" · " + words;
            }
            head.Text(title);
            head.TextWrapping(TextWrapping::WrapWholeWords);
            if (tip.empty())
                ToolTipService::SetToolTip(head, nullptr);
            else
                ToolTipService::SetToolTip(head, box_value(tip));
            add.Visibility(n < max_filaments ? Visibility::Visible : Visibility::Collapsed);
            if (w.model->GetSetting("machine.filament_change") == "tool")
            {
                std::string printer = w.model->GetSetting("machine.name");
                note.Text((printer.empty() ? std::wstring(L"The printer") : zs::ToWide(printer)) +
                          L" changes the filament by itself. Add the filaments it has, then give a part or layers a filament.");
            }
            else
            {
                note.Text(L"Add a filament to print in more colors: the print pauses at each change.");
            }
        }

        // ---- the part card ----

        void FillChips(int64_t part)
        {
            zs_app *app = w.model->Active();
            size_t n = zs_app_filament_count(app);
            int value = w.PartFilament(part);
            std::string key = std::to_string(part) + ":" + std::to_string(value);
            for (size_t i = 0; i < n; i++)
                key += " " + w.FilamentValue(i, "filament.color") + w.FilamentValue(i, "filament.material");
            if (key == chips_key)
                return;
            chips_key = key;
            part_chips.Children().Clear();
            for (size_t i = 0; i < n; i++)
            {
                int k = (int)i + 1;
                std::string mat = w.FilamentValue(i, "filament.material");
                std::string color = w.FilamentValue(i, "filament.color");
                Button chip = w.MakeFilamentChip(color, std::to_wstring(k), k == value);
                std::wstring tip = L"Filament " + std::to_wstring(k) + L" · " + (mat.empty() ? std::wstring(L"filament") : zs::ToWide(mat)) +
                                   L" (" + zs::ToWide(color) + L")";
                ToolTipService::SetToolTip(chip, box_value(tip));
                Automation::AutomationProperties::SetName(chip, L"Filament " + std::to_wstring(k));
                chip.Click([this, part, k](auto &&, auto &&) { Later([this, part, k] { SetPartFilament(part, k); }); });
                part_chips.Children().Append(chip);
            }
            if (n < max_filaments)
            {
                Button plus = w.MakeFilamentChip({}, L"+", false);
                ToolTipService::SetToolTip(plus, box_value(L"Add a filament to the plate"));
                Automation::AutomationProperties::SetName(plus, L"Add a filament to the plate");
                plus.Click([this, part](auto &&, auto &&) {
                    Later([this, part] {
                        int64_t added = w.AddFilament();
                        if (added >= 0)
                            SetPartFilament(part, (int)added + 1);
                    });
                });
                part_chips.Children().Append(plus);
            }
        }

        void SetPartFilament(int64_t part, int k)
        {
            if (w.model == nullptr || part < 0 || w.PartFilament(part) == k)
                return;
            if (zs_app_part_setting_set(w.model->Active(), (size_t)part, "project.filament", std::to_string(k).c_str()) != ZS_OK)
                return;
            w.FilamentsChanged();
            w.PlateEdited();
        }

        void FillLabels(int64_t part)
        {
            zs_app *app = w.model->Active();
            size_t len = 0;
            std::string json;
            if (zs_app_part_labels_get(app, (size_t)part, nullptr, 0, &len) == ZS_OK && len > 0)
            {
                json.resize(len + 1);
                if (zs_app_part_labels_get(app, (size_t)part, json.data(), json.size(), &len) == ZS_OK)
                    json.resize(len);
                else
                    json.clear();
            }
            std::string key = std::to_string(part) + ":" + json;
            if (key == labels_key)
                return;
            labels_key = key;
            part_labels.Children().Clear();
            std::vector<zs::Label> list;
            if (json.size() <= 2 || !zs::LabelsParse(json, list) || list.empty())
            {
                part_labels.Visibility(Visibility::Collapsed);
                return;
            }
            part_labels.Visibility(Visibility::Visible);
            part_labels.Children().Append(Heading(L"Labels"));
            for (auto const &l : list)
            {
                Button b;
                TextBlock text;
                text.Text(zs::LabelTitle(l) + L" · filament " + std::to_wstring(l.filament));
                text.TextWrapping(TextWrapping::Wrap);
                b.Content(text);
                b.HorizontalAlignment(HorizontalAlignment::Stretch);
                b.HorizontalContentAlignment(HorizontalAlignment::Left);
                b.Background(SolidColorBrush(Microsoft::UI::Colors::Transparent()));
                b.BorderThickness(ThicknessHelper::FromUniformLength(0));
                b.Padding(ThicknessHelper::FromLengths(4, 2, 4, 2));
                ToolTipService::SetToolTip(b, box_value(L"Select this label in the Label tool (E)"));
                uint32_t id = l.id;
                b.Click([this, part, id](auto &&, auto &&) { Later([this, part, id] { w.LabelOpen(part, id); }); });
                part_labels.Children().Append(b);
            }
        }

        void FillPaint(int64_t part)
        {
            uint32_t used = 0;
            if (zs_app_part_paint_used(w.model->Active(), (size_t)part, &used) != ZS_OK)
                used = 0;
            // Bit 0 is the filament of the part: no paint.
            used &= ~1u;
            std::string key = std::to_string(part) + ":" + std::to_string(used);
            for (int k = 1; k < 32; k++)
                if (used & (1u << k))
                    key += " " + w.FilamentValue((size_t)(k - 1), "filament.color");
            if (key == paint_key)
                return;
            paint_key = key;
            part_paint.Children().Clear();
            part_paint.Visibility(used != 0 ? Visibility::Visible : Visibility::Collapsed);
            if (used == 0)
                return;
            part_paint.Children().Append(Heading(L"Paint"));
            Grid row;
            row.ColumnSpacing(4);
            ColumnDefinition chips_column, text_column, open_column;
            chips_column.Width(GridLengthHelper::Auto());
            text_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            open_column.Width(GridLengthHelper::Auto());
            row.ColumnDefinitions().Append(chips_column);
            row.ColumnDefinitions().Append(text_column);
            row.ColumnDefinitions().Append(open_column);
            StackPanel chips;
            chips.Orientation(Orientation::Horizontal);
            chips.Spacing(2);
            std::wstring names;
            int count = 0;
            for (int k = 1; k < 32; k++)
            {
                if (!(used & (1u << k)))
                    continue;
                Button chip = w.MakeFilamentChip(w.FilamentValue((size_t)(k - 1), "filament.color"), std::to_wstring(k), false);
                chip.IsHitTestVisible(false);
                chip.IsTabStop(false);
                chips.Children().Append(chip);
                names += (count > 0 ? L", " : L"") + std::to_wstring(k);
                count++;
            }
            row.Children().Append(chips);
            TextBlock text;
            text.Text((count == 1 ? L"Painted with filament " : L"Painted with filaments ") + names);
            text.FontSize(12);
            text.Opacity(0.7);
            text.TextWrapping(TextWrapping::WrapWholeWords);
            text.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(text, 1);
            row.Children().Append(text);
            Button open;
            open.Content(box_value(L"Paint"));
            ToolTipService::SetToolTip(open, box_value(L"Open the Paint tool on this part (P)"));
            open.Click([this](auto &&, auto &&) { Later([this] { w.SetTool(Tool::Paint); }); });
            Grid::SetColumn(open, 2);
            row.Children().Append(open);
            part_paint.Children().Append(row);
        }
    };

    void MainWindow::WireFilaments()
    {
        filaments = std::make_shared<FilamentState>(*this);
        auto &f = *filaments;

        StackPanel face;
        face.Orientation(Orientation::Horizontal);
        face.Spacing(6);
        f.dots = Canvas();
        f.dots.Height(dot_size);
        f.dots.VerticalAlignment(VerticalAlignment::Center);
        f.name = TextBlock();
        f.name.Text(L"Filament");
        f.name.VerticalAlignment(VerticalAlignment::Center);
        face.Children().Append(f.dots);
        face.Children().Append(f.name);
        FilamentButton().Content(face);

        StackPanel box;
        box.Spacing(8);
        f.head = Heading(L"Filament");
        f.list = StackPanel();
        f.list.Spacing(4);
        f.add = Button();
        f.add.Content(box_value(L"+ Add a filament"));
        f.add.Background(SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        f.add.BorderThickness(ThicknessHelper::FromUniformLength(0));
        ToolTipService::SetToolTip(f.add, box_value(L"Add a filament to the plate. A part or a range of layers can then print with it."));
        f.add.Click([this](auto &&, auto &&) {
            filaments->Later([this] { AddFilament(); });
        });
        f.note = TextBlock();
        f.note.FontSize(12);
        f.note.Opacity(0.7);
        f.note.MaxWidth(320);
        f.note.TextWrapping(TextWrapping::WrapWholeWords);
        box.Children().Append(f.head);
        box.Children().Append(f.list);
        box.Children().Append(f.add);
        box.Children().Append(f.note);
        // The list is in the details of the print, as in the other apps.
        SummaryFilaments().Child(box);
        SummaryFlyout().Opening([this](auto &&, auto &&) {
            if (model != nullptr)
                filaments->UpdateList();
        });

        // The rows of the part card: the filament under the size, the labels
        // and the paint at the end.
        Grid row;
        row.ColumnSpacing(8);
        ColumnDefinition name_column, chips_column;
        name_column.Width(GridLengthHelper::Auto());
        chips_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        row.ColumnDefinitions().Append(name_column);
        row.ColumnDefinitions().Append(chips_column);
        TextBlock label;
        label.Text(L"Filament");
        label.VerticalAlignment(VerticalAlignment::Center);
        row.Children().Append(label);
        f.part_chips = VariableSizedWrapGrid();
        f.part_chips.Orientation(Orientation::Horizontal);
        f.part_chips.ItemWidth(30);
        f.part_chips.ItemHeight(30);
        f.part_chips.MaximumRowsOrColumns(7);
        f.part_chips.HorizontalAlignment(HorizontalAlignment::Right);
        Grid::SetColumn(f.part_chips, 1);
        row.Children().Append(f.part_chips);
        PartSingle().Children().InsertAt(0, row);
        f.part_labels = StackPanel();
        f.part_labels.Spacing(2);
        f.part_labels.Visibility(Visibility::Collapsed);
        PartSingle().Children().Append(f.part_labels);
        f.part_paint = StackPanel();
        f.part_paint.Spacing(2);
        f.part_paint.Visibility(Visibility::Collapsed);
        PartSingle().Children().Append(f.part_paint);
    }

    std::string MainWindow::FilamentValue(size_t i, char const *name)
    {
        if (model == nullptr)
            return {};
        zs_app *app = model->Active();
        size_t len = 0;
        if (zs_app_filament_get(app, i, name, nullptr, 0, &len) != ZS_OK)
            return {};
        std::string text(len + 1, '\0');
        if (zs_app_filament_get(app, i, name, text.data(), text.size(), &len) != ZS_OK)
            return {};
        text.resize(len);
        return text;
    }

    uint32_t MainWindow::FilamentRgb(int filament)
    {
        std::string text = FilamentValue((size_t)std::max(filament - 1, 0), "filament.color");
        if (text.empty())
            text = FilamentValue(0, "filament.color");
        auto c = ColorOf(text);
        return ((uint32_t)c.R << 16) | ((uint32_t)c.G << 8) | c.B;
    }

    int MainWindow::PartFilament(int64_t part)
    {
        if (model == nullptr)
            return 1;
        char own[32] = "";
        size_t len = 0;
        std::string value;
        if (part >= 0 && zs_app_part_setting_get(model->Active(), (size_t)part, "project.filament", own, sizeof own, &len) == ZS_OK && len < sizeof own)
            value.assign(own, len);
        else
            value = model->GetSetting("project.filament");
        int f = atoi(value.c_str());
        return f > 0 ? f : 1;
    }

    Button MainWindow::MakeFilamentChip(std::string const &color, std::wstring const &text, bool selected)
    {
        Button b;
        b.Width(30);
        b.Height(30);
        b.MinWidth(0);
        b.MinHeight(0);
        b.Padding(ThicknessHelper::FromUniformLength(0));
        b.Background(SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        b.BorderThickness(ThicknessHelper::FromUniformLength(0));
        b.AllowFocusOnInteraction(false);
        Grid g;
        g.Width(28);
        g.Height(28);
        TextBlock t;
        t.Text(text);
        t.HorizontalAlignment(HorizontalAlignment::Center);
        t.VerticalAlignment(VerticalAlignment::Center);
        if (!color.empty())
        {
            auto c = ColorOf(color);
            Shapes::Ellipse disk;
            disk.Width(22);
            disk.Height(22);
            disk.Fill(SolidColorBrush(c));
            // A thin edge, so that a white filament shows on a light theme.
            disk.Stroke(Gray(0x59));
            disk.StrokeThickness(1);
            g.Children().Append(disk);
            if (selected)
            {
                Shapes::Ellipse ring;
                ring.Width(28);
                ring.Height(28);
                ring.Stroke(Gray(0xff));
                ring.StrokeThickness(2);
                g.Children().Append(ring);
            }
            // Black or white text on the color.
            double lum = (0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B) / 255;
            uint8_t ink = lum > 0.55 ? 0x12 : 0xff;
            t.Foreground(SolidColorBrush(Windows::UI::Color{ 255, ink, ink, ink }));
            t.FontSize(11);
        }
        else
        {
            t.FontSize(15);
        }
        g.Children().Append(t);
        b.Content(g);
        return b;
    }

    int64_t MainWindow::AddFilament()
    {
        if (model == nullptr)
            return -1;
        size_t index = 0;
        if (zs_app_filament_add(model->Active(), &index) != ZS_OK)
        {
            ShowToast(L"The plate has the most filaments it can have.");
            return -1;
        }
        FilamentsChanged();
        PlateEdited();
        return (int64_t)index;
    }

    // A new color, material, or list of filaments.
    void MainWindow::FilamentsChanged()
    {
        if (model == nullptr || filaments == nullptr)
            return;
        filaments->UpdateButton();
        if (SummaryFlyout().IsOpen())
            filaments->UpdateList();
        PaintFilamentsChanged();
        LabelFilamentsChanged();
    }

    // After a slice, an undo, or a switch of the plate.
    void MainWindow::RefreshFilamentTools()
    {
        if (model == nullptr || filaments == nullptr)
            return;
        filaments->UpdateButton();
        if (SummaryFlyout().IsOpen())
            filaments->UpdateList();
        PaintReload();
        LabelReload();
    }

    void MainWindow::FillPartExtras()
    {
        if (model == nullptr || filaments == nullptr || selected_parts.size() != 1)
            return;
        int64_t part = selected_parts[0];
        filaments->FillChips(part);
        filaments->FillLabels(part);
        filaments->FillPaint(part);
    }

#ifdef ZS_DEV_HOOKS
    // The steps of the filament list. See MainWindow.DevHooks.cpp.
    bool MainWindow::RunFilamentStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        auto &f = *filaments;
        size_t i = !words.empty() ? (size_t)_wtoi(words[0].c_str()) : 0;
        if (verb == L"fopen")
            SummaryFlyout().ShowAt(SummaryButton());
        else if (verb == L"fclose")
            SummaryFlyout().Hide();
        else if (verb == L"fmaterial" && words.size() >= 2 && i < f.rows.size())
            f.rows[i].material.SelectedItem(box_value(words[1]));
        else if (verb == L"fcoloropen" && i < f.rows.size())
            f.rows[i].color_flyout.ShowAt(f.rows[i].swatch);
        else if (verb == L"fcolorset" && words.size() >= 2 && i < f.rows.size())
        {
            f.rows[i].picker.Color(ColorOf(zs::ToUtf8(words[1])));
            f.rows[i].color_flyout.Hide();
        }
        else if (verb != L"flog")
            return false;
        zs_app *app = model->Active();
        size_t n = zs_app_filament_count(app);
        zs::Log("dev: filaments: %zu, list open %d, rows %zu:", n, SummaryFlyout().IsOpen() ? 1 : 0, f.rows.size());
        for (size_t k = 0; k < n; k++)
            zs::Log(" [%zu %s %s]", k + 1, FilamentValue(k, "filament.color").c_str(), FilamentValue(k, "filament.material").c_str());
        if (!selected_parts.empty())
            zs::Log(" part filament %d", PartFilament(selected_parts[0]));
        zs::Log("\n");
        return true;
    }
#endif

#ifdef ZS_DEV_HOOKS
    // The choices of each filament's nozzle list, for the test hooks.
    std::string MainWindow::FilamentNozzleLog()
    {
        if (filaments == nullptr)
            return {};
        filaments->UpdateList();
        std::string out;
        for (auto const &row : filaments->rows)
        {
            if (row.nozzle == nullptr)
            {
                out += "[none] ";
                continue;
            }
            out += "[";
            for (auto const &item : row.nozzle.Items())
                out += to_string(unbox_value<hstring>(item.as<ComboBoxItem>().Content())) + " ";
            out += "sel " + std::to_string(NozzleChoice(row.nozzle)) + "] ";
        }
        out += "head '" + to_string(filaments->head.Text()) + "' tip '";
        if (auto tip = ToolTipService::GetToolTip(filaments->head))
            out += to_string(unbox_value_or<hstring>(tip, L""));
        out += "'";
        return out;
    }
#endif
}
