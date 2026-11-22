// The card of a range of layers, as in web/app/rangecard.js and
// linux/src/ui/range-card.c.
//
// A left drag of the Select tool that starts on a printed line lights the
// body of that line on the layers from its layer to the layer under the
// pointer. Shift+K and Shift+J grow a range from the layer of the selected
// line, or from the top layer that shows. The card opens beside the lit
// layers.
//
// The card shows the settings that can change for some layers. An edit is an
// override of the z range from the top of the first layer to the top of the
// last (zs_app_override_set), and slices at once. The editors show the value
// at the first layer. "+ Add a setting" opens the search with a scope of the
// settings that have per_layer.
//
// A lit body has a row "This body": a chip paints the mesh of the part under
// the lines of the body (zs_app_paint_body), and the body shows in the color
// of that filament at once.
//
// Esc, a click elsewhere in the view, a change of the tool, or × closes the
// card and ends the light. The card does no work for a frame except its
// place: 8 projections.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Markup = Microsoft::UI::Xaml::Markup;
namespace Media = Microsoft::UI::Xaml::Media;
namespace Automation = Microsoft::UI::Xaml::Automation;

namespace
{
    // The settings that the card shows first, in this order, when the
    // setting can change for some layers (RANGE_SETTINGS of rangecard.js).
    char const *const range_settings[] = {
        "project.filament", "project.infill_density", "project.infill_pattern", "project.wall_count", "project.top_thickness",
        "project.outer_wall_speed", "project.infill_speed", "filament.fan_speed", "filament.nozzle_temp",
    };

    // The most filaments of a plate (src/app/filament_slots.zig).
    constexpr size_t max_filaments = 16;

    wchar_t const *const card_xaml =
        L"<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' "
        L"Width='300' Visibility='Collapsed' Padding='14,10,12,10' CornerRadius='12' BorderThickness='1' "
        L"Background='{ThemeResource ZsPopover}' BorderBrush='{ThemeResource ZsPopoverBorder}' AutomationProperties.Name='The selected layers'>"
        L"<StackPanel Spacing='8'>"
        L"<Grid x:Name='RcHead' Background='Transparent' ToolTipService.ToolTip='Drag to move the card'>"
        L"<Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>"
        L"<TextBlock x:Name='RcTitle' FontWeight='Bold' VerticalAlignment='Center' TextWrapping='Wrap' Foreground='{ThemeResource ZsFg}'/>"
        L"<Button x:Name='RcClose' Grid.Column='1' Background='Transparent' BorderThickness='0' Padding='6' "
        L"AutomationProperties.Name='Close the layers card' ToolTipService.ToolTip='Close (Esc)'><FontIcon Glyph='&#xE711;' FontSize='11'/></Button>"
        L"</Grid>"
        L"<TextBlock x:Name='RcFacts' FontSize='12' TextWrapping='WrapWholeWords' Foreground='{ThemeResource ZsDim}'/>"
        L"<TextBlock Text='Changes here are for these layers of this print.' FontSize='11.5' TextWrapping='WrapWholeWords' Foreground='{ThemeResource ZsDim}'/>"
        L"<Border BorderThickness='0,1,0,0' BorderBrush='{ThemeResource ZsLine}' Padding='0,8,0,0'>"
        L"<StackPanel x:Name='RcRows' Spacing='4'/>"
        L"</Border>"
        L"<Button x:Name='RcAdd' Content='+ Add a setting for these layers' Background='Transparent' BorderThickness='0' "
        L"Foreground='{ThemeResource ZsAccentText}' FontSize='12' Padding='0,2' MinHeight='24' "
        L"ToolTipService.ToolTip='Search the settings that can change for some layers'/>"
        L"</StackPanel></Border>";

    bool FindSetting(char const *name, zs_setting_info &out)
    {
        size_t n = zs_setting_count();
        for (size_t i = 0; i < n; i++)
            if (zs_setting_get_info(i, &out) == ZS_OK && strcmp(out.name, name) == 0)
                return true;
        return false;
    }

    std::wstring PlainDoc(char const *doc)
    {
        std::wstring text = zs::ToWide(doc != nullptr ? doc : "");
        text.erase(std::remove(text.begin(), text.end(), L'`'), text.end());
        return text;
    }
}

namespace winrt::ZSlice::implementation
{
    struct MainWindow::RangeState
    {
        struct Row
        {
            std::string name;
            TextBlock label{ nullptr };
            Button reset{ nullptr };
            // project.filament has chips in place of an editor.
            VariableSizedWrapGrid chips{ nullptr };
            std::string chips_key;
            std::vector<SettingEditor> editors;
        };

        explicit RangeState(MainWindow &owner) : w(owner) {}

        MainWindow &w;
        Border card{ nullptr };
        TextBlock title{ nullptr }, facts{ nullptr };
        StackPanel rows_box{ nullptr };
        Grid body_row{ nullptr };
        VariableSizedWrapGrid body_chips{ nullptr };
        std::string body_key;
        int body_value = 0;
        std::vector<Row> rows;
        std::shared_ptr<EditorTarget> target;

        bool open = false;
        bool moved = false;
        bool place_queued = false;
        size_t lo = 0, hi = 0;
        double z_top_lo = 0, z_top_hi = 0, z_bottom = 0;
        double last_box[4] = { 1e9, 1e9, -1e9, -1e9 };

        // The light. light_path -1: all the lines of the layers.
        bool light_on = false, light_pt = false;
        int64_t light_path = -1;
        ptrdiff_t light_layer = -1;
        double light_x = 0, light_y = 0;
        int32_t light_rgb = -1;
        size_t light_lo = 0, light_hi = 0;

        // Shift+K and Shift+J: the fixed end, the end that moves, the line.
        bool key_on = false;
        size_t key_a = 0, key_b = 0;
        int64_t key_path = -1;

        // A drag of the Select tool that started on a line.
        bool drag_on = false, drag_moved = false, drag_lit = false;
        size_t drag_path = 0, drag_layer = 0, drag_cur = 0;
        double drag_pt[2] = {};

        // The chips change in the turn after their click, so a chip never
        // goes away in its own click.
        template <typename F>
        void Later(F f)
        {
            w.queue.TryEnqueue([f] { f(); });
        }

        // The top and the bottom of a layer, mm.
        bool LayerZ(size_t layer, double &top, double &bottom)
        {
            zs_toolpaths tp{};
            if (w.model == nullptr || zs_app_toolpaths(w.model->Active(), &tp) != ZS_OK || tp.layer_count == 0)
                return false;
            size_t l = std::min(layer, tp.layer_count - 1);
            top = tp.layer_z[l];
            bottom = l > 0 ? tp.layer_z[l - 1] : tp.layer_z[0] - (tp.layer_height != nullptr ? tp.layer_height[0] : 0);
            return true;
        }

        // Reads the heights of the range. A running slice has no toolpaths,
        // so the card keeps the heights of the last slice.
        bool UpdateZ()
        {
            double t0, b0, t1, b1;
            if (!LayerZ(lo, t0, b0) || !LayerZ(hi, t1, b1))
                return false;
            z_top_lo = t0;
            z_top_hi = t1;
            z_bottom = b0;
            return true;
        }

        // The z range of the edits: the tops of the first and the last layer.
        bool ZRange(double &z0, double &z1)
        {
            z0 = z_top_lo;
            z1 = z_top_hi;
            return open;
        }

        std::string ValueAt(double z, char const *name)
        {
            zs_app *app = w.model->Active();
            size_t len = 0;
            if (zs_app_setting_get_at(app, z, name, nullptr, 0, &len) != ZS_OK)
                return {};
            std::string text(len + 1, '\0');
            if (zs_app_setting_get_at(app, z, name, text.data(), text.size(), &len) != ZS_OK)
                return {};
            text.resize(len);
            return text;
        }

        std::string Value(std::string const &name)
        {
            double z0, z1;
            if (w.model == nullptr || !open || !ZRange(z0, z1))
                return {};
            return ValueAt(z0, name.c_str());
        }

        void SetValue(std::string const &name, std::string const &value)
        {
            double z0, z1;
            if (w.model == nullptr || !open || !ZRange(z0, z1))
                return;
            int rc = zs_app_override_set(w.model->Active(), z0, z1, name.c_str(), value.c_str());
            if (rc != ZS_OK)
            {
                w.ShowToast(zs::ToWide(name) + L": " + zs::ToWide(zs_status_message(rc)));
                w.RefreshSettingValues();
                return;
            }
            w.model->RequestSlice();
            w.NoteChange();
            w.RefreshSettingValues();
        }

        void ResetValue(std::string const &name)
        {
            double z0, z1;
            if (w.model == nullptr || !open || !ZRange(z0, z1))
                return;
            zs_app *app = w.model->Active();
            if (zs_app_override_remove(app, z0, z1, name.c_str()) != 1 && zs_app_override_clear_at(app, z0, name.c_str()) == 0)
                return;
            w.model->RequestSlice();
            w.NoteChange();
            w.RefreshSettingValues();
        }

        // ---- the light ----

        bool PathPoint(int64_t path, double &x, double &y)
        {
            zs_toolpaths tp{};
            if (zs_app_toolpaths(w.model->Active(), &tp) != ZS_OK || path < 0 || (size_t)path >= tp.path_count)
                return false;
            uint32_t start = path == 0 ? 0 : tp.path_ends[path - 1];
            x = tp.points[2 * start];
            y = tp.points[2 * start + 1];
            return true;
        }

        // Lights layers a to b: from line `path`, its body of its part on
        // them. With no line (-1), all their lines.
        void LightRange(int64_t path, size_t a, size_t b)
        {
            zs_view_light_layers(w.view, 1, 0);
            light_on = true;
            light_pt = path >= 0 && PathPoint(path, light_x, light_y);
            light_rgb = -1;
            zs_view_light_color(w.view, -1);
            light_path = path;
            light_layer = path >= 0 ? zs_app_path_layer(w.model->Active(), (size_t)path) : -1;
            light_lo = std::min(a, b);
            light_hi = std::max(a, b);
            if (path < 0 || zs_view_light_connected(w.view, (size_t)path, light_lo, light_hi, nullptr) != ZS_OK)
            {
                zs_view_highlight_more(w.view, nullptr, 0);
                zs_view_light_layers(w.view, light_lo, light_hi);
            }
        }

        // After a new load: the lit range again, from its start line if that
        // line is still on its layer, else all the lines of the layers.
        void Relight()
        {
            if (!light_on || !open)
                return;
            int64_t path = light_path;
            if (path >= 0 && light_pt && light_layer >= 0)
            {
                size_t segment = 0;
                size_t found = zs_view_pick_layer(w.view, (size_t)light_layer, light_x, light_y, &segment);
                if (found != (size_t)-1)
                    path = light_path = (int64_t)found;
            }
            zs_view_light_color(w.view, light_rgb);
            zs_view_light_layers(w.view, 1, 0);
            if (path >= 0 && zs_app_path_layer(w.model->Active(), (size_t)path) != light_layer)
                path = -1;
            if (path < 0 || zs_view_light_connected(w.view, (size_t)path, light_lo, light_hi, nullptr) != ZS_OK)
            {
                zs_view_highlight_more(w.view, nullptr, 0);
                zs_view_light_layers(w.view, light_lo, light_hi);
            }
        }

        bool BodyLit() const
        {
            return light_on && light_path >= 0;
        }

        bool PaintBody(int filament)
        {
            if (!open || !BodyLit() || filament < 1)
                return false;
            float const *beads = nullptr;
            size_t n = 0;
            if (zs_view_connected_beads(w.view, (size_t)light_path, light_lo, light_hi, &beads, &n) != ZS_OK || n == 0)
                return false;
            // The body in the color of the filament at once. The slice
            // follows.
            light_rgb = (int32_t)w.FilamentRgb(filament);
            zs_view_light_color(w.view, light_rgb);
            w.RequestDraw();
            size_t changed = 0;
            if (zs_app_paint_body(w.model->Active(), beads, n, (uint32_t)filament, &changed) != ZS_OK)
                return false;
            if (changed > 0)
            {
                w.model->RequestSlice();
                if (w.model->HistoryCommit())
                    w.RefreshHistoryButtons();
            }
            return true;
        }

        // The layer under the pointer in a drag: the pointer goes to the
        // nearest point of the line on the screen from the bed to the top
        // layer shown, up through the point of the press. A view from above
        // (a short line) picks the line under the pointer.
        bool LayerAt(double x, double y, size_t &out)
        {
            zs_toolpaths tp{};
            if (zs_app_toolpaths(w.model->Active(), &tp) != ZS_OK || tp.layer_count == 0)
                return false;
            double s = w.Scale();
            size_t top = (size_t)std::max<int64_t>(std::lround(w.LayerSlider().Value()) - 1, 0);
            size_t low = std::min(w.layer_lo, tp.layer_count - 1), high = std::min(top, tp.layer_count - 1);
            float ax, ay, bx, by;
            bool ok = zs_view_pixel_of(w.view, drag_pt[0], drag_pt[1], 0, &ax, &ay) &&
                      zs_view_pixel_of(w.view, drag_pt[0], drag_pt[1], tp.layer_z[high], &bx, &by);
            double len2 = ok ? (bx - ax) * (bx - ax) + (by - ay) * (by - ay) : 0;
            double px = x * s, py = y * s;
            if (len2 < 24.0 * s * 24.0 * s)
            {
                size_t path = zs_view_pick(w.view, (float)px, (float)py);
                if (path == (size_t)-1)
                    return false;
                out = zs_view_path_layer(w.view, path);
                return true;
            }
            double t = ((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / len2;
            double want = std::clamp(t, 0.0, 1.0) * tp.layer_z[high];
            // The first layer with its top at or over the height.
            size_t l = low, h = high;
            while (l < h)
            {
                size_t m = (l + h) / 2;
                if (tp.layer_z[m] < want)
                    l = m + 1;
                else
                    h = m;
            }
            out = l;
            return true;
        }

        // ---- the card ----

        void Build()
        {
            card = Markup::XamlReader::Load(card_xaml).as<Border>();
            title = card.FindName(L"RcTitle").as<TextBlock>();
            facts = card.FindName(L"RcFacts").as<TextBlock>();
            rows_box = card.FindName(L"RcRows").as<StackPanel>();
            card.FindName(L"RcClose").as<Button>().Click([this](auto &&, auto &&) { w.RangeClose(); });
            card.FindName(L"RcAdd").as<Button>().Click([this](auto &&, auto &&) { OpenScope(); });
            w.MakeCardMovable(card, card.FindName(L"RcHead").as<FrameworkElement>(), &moved);
            // A new row changes the height: the card goes beside the layers
            // again after its layout.
            card.SizeChanged([this](auto &&, auto &&) {
                if (place_queued)
                    return;
                place_queued = true;
                Later([this] {
                    place_queued = false;
                    Place(true);
                });
            });
            w.CardLayer().Children().Append(card);

            body_row = Grid();
            body_row.ColumnSpacing(8);
            // The columns of a setting row, so that the chips line up.
            ColumnDefinition name_column, chips_column, reset_column;
            name_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            chips_column.Width(GridLengthHelper::Auto());
            reset_column.Width(GridLengthHelper::FromPixels(22));
            body_row.ColumnDefinitions().Append(name_column);
            body_row.ColumnDefinitions().Append(chips_column);
            body_row.ColumnDefinitions().Append(reset_column);
            TextBlock body_name;
            body_name.Text(L"This body");
            body_name.FontSize(13);
            body_name.TextWrapping(TextWrapping::WrapWholeWords);
            body_name.VerticalAlignment(VerticalAlignment::Center);
            ToolTipService::SetToolTip(body_name, box_value(L"The filament of the lit body only, on these layers. The paint of the part keeps it."));
            body_row.Children().Append(body_name);
            body_chips = MakeChipPanel();
            Grid::SetColumn(body_chips, 1);
            body_row.Children().Append(body_chips);
            body_row.Visibility(Visibility::Collapsed);

            target = std::make_shared<EditorTarget>();
            target->get = [this](std::string const &name) { return Value(name); };
            target->set = [this](std::string const &name, std::string const &value) { SetValue(name, value); };
        }

        VariableSizedWrapGrid MakeChipPanel()
        {
            VariableSizedWrapGrid panel;
            panel.Orientation(Orientation::Horizontal);
            panel.ItemWidth(30);
            panel.ItemHeight(30);
            panel.MaximumRowsOrColumns(5);
            panel.HorizontalAlignment(HorizontalAlignment::Right);
            panel.VerticalAlignment(VerticalAlignment::Center);
            return panel;
        }

        void BuildRows()
        {
            rows.clear();
            rows_box.Children().Clear();
            rows_box.Children().Append(body_row);
            for (char const *name : range_settings)
            {
                zs_setting_info info{};
                if (FindSetting(name, info) && info.per_layer != 0)
                    AddRow(info);
            }
        }

        void AddRow(zs_setting_info const &info)
        {
            for (auto const &row : rows)
                if (row.name == info.name)
                    return;
            Row row;
            row.name = info.name;

            Grid grid;
            grid.ColumnSpacing(8);
            ColumnDefinition label_column, editor_column, reset_column;
            label_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            editor_column.Width(GridLengthHelper::Auto());
            reset_column.Width(GridLengthHelper::FromPixels(22));
            grid.ColumnDefinitions().Append(label_column);
            grid.ColumnDefinitions().Append(editor_column);
            grid.ColumnDefinitions().Append(reset_column);

            row.label = TextBlock();
            row.label.Text(zs::ToWide(info.label));
            row.label.FontSize(13);
            row.label.TextWrapping(TextWrapping::WrapWholeWords);
            row.label.VerticalAlignment(VerticalAlignment::Center);
            ToolTipService::SetToolTip(row.label, box_value(PlainDoc(info.doc)));
            grid.Children().Append(row.label);

            FrameworkElement editor{ nullptr };
            if (strcmp(info.name, "project.filament") == 0)
            {
                row.chips = MakeChipPanel();
                editor = row.chips;
            }
            else
            {
                size_t before = w.setting_editors.size();
                editor = w.MakeEditor(info, target);
                for (size_t i = before; i < w.setting_editors.size(); i++)
                    row.editors.push_back(std::move(w.setting_editors[i]));
                w.setting_editors.resize(before);
                if (info.kind == ZS_SETTING_NUMBER || info.kind == ZS_SETTING_INTEGER)
                {
                    // The units have one width, so the entries line up.
                    auto with_unit = editor.try_as<Grid>();
                    (with_unit != nullptr ? with_unit.Children().GetAt(0).as<FrameworkElement>() : editor).Width(64);
                    if (with_unit != nullptr)
                        with_unit.ColumnDefinitions().GetAt(1).MinWidth(40);
                }
                else if (info.kind == ZS_SETTING_TEXT)
                {
                    editor.Width(120);
                }
            }
            editor.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(editor, 1);
            grid.Children().Append(editor);

            row.reset = Button();
            row.reset.Width(22);
            row.reset.Height(22);
            row.reset.MinWidth(0);
            row.reset.MinHeight(0);
            row.reset.Padding(ThicknessHelper::FromUniformLength(0));
            row.reset.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            row.reset.Content(box_value(L"↺"));
            row.reset.VerticalAlignment(VerticalAlignment::Center);
            ToolTipService::SetToolTip(row.reset, box_value(L"Remove the change for these layers"));
            Automation::AutomationProperties::SetName(row.reset, zs::ToWide(info.label) + L": remove the change for these layers");
            std::string name = info.name;
            row.reset.Click([this, name](auto &&, auto &&) { Later([this, name] { ResetValue(name); }); });
            Grid::SetColumn(row.reset, 2);
            grid.Children().Append(row.reset);

            rows_box.Children().Append(grid);
            rows.push_back(std::move(row));
        }

        // One chip for each filament of the plate, and "+".
        void FillChips(VariableSizedWrapGrid const &panel, std::string &key_store, int value, bool body)
        {
            zs_app *app = w.model->Active();
            size_t n = zs_app_filament_count(app);
            std::string key = std::to_string(value);
            for (size_t i = 0; i < n; i++)
                key += " " + w.FilamentValue(i, "filament.color") + w.FilamentValue(i, "filament.material");
            if (key == key_store)
                return;
            key_store = key;
            panel.Children().Clear();
            auto pick = [this, body](int k) {
                if (body)
                {
                    if (PaintBody(k))
                    {
                        body_value = k;
                        Refresh();
                    }
                }
                else
                {
                    SetValue("project.filament", std::to_string(k));
                }
            };
            for (size_t i = 0; i < n; i++)
            {
                int k = (int)i + 1;
                std::string mat = w.FilamentValue(i, "filament.material");
                std::string color = w.FilamentValue(i, "filament.color");
                Button chip = w.MakeFilamentChip(color, std::to_wstring(k), k == value);
                std::wstring tip = std::wstring(body ? L"This body: filament " : L"Filament ") + std::to_wstring(k) + L" · " +
                                   (mat.empty() ? std::wstring(L"filament") : zs::ToWide(mat)) + L" (" + zs::ToWide(color) + L")";
                ToolTipService::SetToolTip(chip, box_value(tip));
                Automation::AutomationProperties::SetName(chip, std::wstring(body ? L"This body: filament " : L"Filament ") + std::to_wstring(k));
                chip.Click([this, pick, k](auto &&, auto &&) { Later([pick, k] { pick(k); }); });
                panel.Children().Append(chip);
            }
            if (n < max_filaments)
            {
                Button plus = w.MakeFilamentChip({}, L"+", false);
                wchar_t const *tip = body ? L"Add a filament to the plate, for this body" : L"Add a filament to the plate";
                ToolTipService::SetToolTip(plus, box_value(tip));
                Automation::AutomationProperties::SetName(plus, tip);
                plus.Click([this, pick](auto &&, auto &&) {
                    Later([this, pick] {
                        int64_t added = w.AddFilament();
                        if (added >= 0)
                            pick((int)added + 1);
                    });
                });
                panel.Children().Append(plus);
            }
        }

        // The values at the first layer, and the ↺ of each changed setting.
        void Refresh()
        {
            double z0, z1;
            if (!open || w.model == nullptr || !ZRange(z0, z1))
                return;
            zs_app *app = w.model->Active();
            int filament = std::max(atoi(ValueAt(z0, "project.filament").c_str()), 1);
            for (auto &row : rows)
            {
                for (auto &editor : row.editors)
                    editor.refresh();
                if (row.chips != nullptr)
                    FillChips(row.chips, row.chips_key, filament, false);
                bool over = zs_app_override_at(app, z0, row.name.c_str()) == 1;
                row.reset.Opacity(over ? 0.7 : 0);
                row.reset.IsHitTestVisible(over);
                row.reset.IsTabStop(over);
            }
            if (BodyLit())
                FillChips(body_chips, body_key, body_value > 0 ? body_value : filament, true);
        }

        void ShowHead()
        {
            title.Text(ScopeLabel());
            size_t n = hi - lo + 1;
            wchar_t text[96];
            swprintf_s(text, L"z %.2f to %.2f mm · %zu %s", z_bottom, z_top_hi, n, n == 1 ? L"layer" : L"layers");
            facts.Text(text);
        }

        std::wstring ScopeLabel() const
        {
            if (lo == hi)
                return L"Layer " + std::to_wstring(lo + 1);
            return L"Layers " + std::to_wstring(lo + 1) + L"–" + std::to_wstring(hi + 1);
        }

        void Show(size_t a, size_t b)
        {
            lo = std::min(a, b);
            hi = std::max(a, b);
            if (!UpdateZ())
                return;
            if (!open)
            {
                open = true;
                moved = false;
                body_key.clear();
                BuildRows();
                card.Visibility(Visibility::Visible);
            }
            body_value = 0;
            ShowHead();
            bool body = BodyLit();
            body_row.Visibility(body ? Visibility::Visible : Visibility::Collapsed);
            zs_setting_info info{};
            for (auto &row : rows)
                if (row.name == "project.filament" && FindSetting("project.filament", info))
                    row.label.Text(body ? std::wstring(L"All of these layers") : zs::ToWide(info.label));
            Refresh();
            Place(true);
        }

        // Beside the lit layers: the box of the print from the bottom of the
        // first layer to the top of the last, on the screen.
        void Place(bool force)
        {
            if (!open || moved || w.view == nullptr)
                return;
            double b[4];
            if (zs_view_bounds(w.view, b) != ZS_OK)
                return;
            double s = w.Scale();
            double box[4] = { 1e9, 1e9, -1e9, -1e9 };
            for (int k = 0; k < 8; k++)
            {
                float qx, qy;
                if (!zs_view_pixel_of(w.view, k & 1 ? b[2] : b[0], k & 2 ? b[3] : b[1], k & 4 ? z_top_hi : z_bottom, &qx, &qy))
                    continue;
                box[0] = std::min(box[0], qx / s);
                box[1] = std::min(box[1], qy / s);
                box[2] = std::max(box[2], qx / s);
                box[3] = std::max(box[3], qy / s);
            }
            if (box[0] > box[2])
                return;
            // The card of the selected line stays in view too.
            if (w.LineCard().Visibility() == Visibility::Visible)
            {
                double x = Canvas::GetLeft(w.LineCard()), y = Canvas::GetTop(w.LineCard());
                box[0] = std::min(box[0], x);
                box[1] = std::min(box[1], y);
                box[2] = std::max(box[2], x + w.LineCard().ActualWidth());
                box[3] = std::max(box[3], y + w.LineCard().ActualHeight());
            }
            bool same = true;
            for (int i = 0; i < 4; i++)
                same = same && std::abs(box[i] - last_box[i]) < 0.5;
            if (same && !force)
                return;
            std::copy(box, box + 4, last_box);
            w.PlaceCard(card, box);
        }

        // The search scope of these layers: the settings that can change
        // for some layers. A setting that the user sets there gets a row.
        void OpenScope()
        {
            auto scope = std::make_shared<SearchScope>();
            scope->label = ScopeLabel();
            scope->only = [](zs_setting_info const &info) { return info.per_layer != 0; };
            scope->source = [this](std::string const &name) -> std::wstring {
                double z0, z1;
                if (open && ZRange(z0, z1) && zs_app_override_at(w.model->Active(), z0, name.c_str()) == 1)
                    return L"These layers";
                return zs::ToWide(w.model->SourceTag(name.c_str()));
            };
            scope->target = std::make_shared<EditorTarget>();
            scope->target->get = target->get;
            scope->target->set = [this](std::string const &name, std::string const &value) {
                zs_setting_info info{};
                if (open && FindSetting(name.c_str(), info))
                {
                    AddRow(info);
                    Refresh();
                }
                SetValue(name, value);
            };
            w.OpenScopedSearch(scope);
        }
    };

    void MainWindow::WireRange()
    {
        range = std::make_shared<RangeState>(*this);
        range->Build();
    }

    bool MainWindow::RangeOpen()
    {
        return range != nullptr && range->open;
    }

    void MainWindow::RangeClose()
    {
        if (!RangeOpen())
            return;
        auto &r = *range;
        r.open = false;
        r.key_on = false;
        r.light_on = false;
        r.light_rgb = -1;
        r.moved = false;
        r.card.Visibility(Visibility::Collapsed);
        r.rows.clear();
        r.rows_box.Children().Clear();
        if (view != nullptr)
        {
            zs_view_light_color(view, -1);
            zs_view_light_layers(view, 1, 0);
            zs_view_highlight_more(view, nullptr, 0);
            RequestDraw();
        }
        // The search of these layers ends with the card.
        if (search_open && search_scope != nullptr)
            CloseSearch();
    }

    // Shift+K (1) and Shift+J (-1): a range that grows from the layer of the
    // selected line, or from the top layer that shows.
    void MainWindow::RangeKey(int direction)
    {
        if (view == nullptr || model == nullptr || range == nullptr)
            return;
        auto &r = *range;
        zs_app *app = model->Active();
        zs_toolpaths tp{};
        if (zs_app_toolpaths(app, &tp) != ZS_OK || tp.layer_count == 0)
            return;
        Set2D(false);
        if (!r.key_on || !r.open)
        {
            ptrdiff_t l = selected_path >= 0 ? zs_app_path_layer(app, (size_t)selected_path) : -1;
            size_t top = (size_t)std::max<int64_t>(std::lround(LayerSlider().Value()) - 1, 0);
            r.key_a = r.key_b = l >= 0 ? (size_t)l : std::min(top, tp.layer_count - 1);
            r.key_path = l >= 0 ? selected_path : -1;
        }
        r.key_b = (size_t)std::clamp<int64_t>((int64_t)r.key_b + direction, 0, (int64_t)tp.layer_count - 1);
        size_t lo = std::min(r.key_a, r.key_b), hi = std::max(r.key_a, r.key_b);
        // The light first: the card shows the row of a lit body.
        r.LightRange(r.key_path, lo, hi);
        r.Show(lo, hi);
        r.key_on = true;
        RequestDraw();
    }

    // A press of the Select tool on a printed line starts a drag over layers.
    bool MainWindow::RangePress(double x, double y)
    {
        if (range == nullptr || view == nullptr || show_2d)
            return false;
        auto &r = *range;
        r.drag_on = r.drag_moved = r.drag_lit = false;
        float px = (float)(x * Scale()), py = (float)(y * Scale());
        size_t path = zs_view_pick(view, px, py);
        double p[3];
        if (path == (size_t)-1 || !zs_view_surface_point(view, px, py, 0, p))
            return false;
        r.drag_on = true;
        r.drag_path = path;
        r.drag_layer = r.drag_cur = zs_view_path_layer(view, path);
        r.drag_pt[0] = p[0];
        r.drag_pt[1] = p[1];
        return true;
    }

    bool MainWindow::RangeDragging()
    {
        return range != nullptr && range->drag_on;
    }

    bool MainWindow::RangeDragLit()
    {
        return RangeDragging() && range->drag_lit;
    }

    void MainWindow::RangeDrag(double x, double y)
    {
        auto &r = *range;
        if (!r.drag_moved && std::hypot(x - press_x, y - press_y) <= 4)
            return;
        r.drag_moved = true;
        size_t layer = 0;
        if (!r.LayerAt(x, y, layer) || (r.drag_lit && layer == r.drag_cur))
            return;
        if (!r.drag_lit)
        {
            // The drag is for the layers: no line, no support, and no card
            // of an old range.
            if (selected_path >= 0)
            {
                selected_path = selected_segment = -1;
                line_anchored = false;
                ApplySelection();
                FillLineCard();
            }
            SupportClearPick();
            RangeClose();
        }
        r.drag_lit = true;
        r.drag_cur = layer;
        r.LightRange((int64_t)r.drag_path, r.drag_layer, layer);
        RequestDraw();
    }

    void MainWindow::RangeRelease()
    {
        if (!RangeDragging())
            return;
        auto &r = *range;
        bool lit = r.drag_lit;
        r.drag_on = r.drag_moved = r.drag_lit = false;
        if (lit)
            r.Show(r.drag_layer, r.drag_cur);
    }

    // A new scene: the light again, and the values of the new slice.
    void MainWindow::RangeScene()
    {
        if (!RangeOpen())
            return;
        auto &r = *range;
        size_t count = zs_app_layer_count(model->Active());
        if (count == 0 || r.lo >= count)
        {
            RangeClose();
            return;
        }
        if (r.hi >= count)
        {
            r.hi = count - 1;
            r.light_hi = std::min(r.light_hi, r.hi);
        }
        r.UpdateZ();
        r.ShowHead();
        r.Relight();
        r.Refresh();
        r.Place(true);
    }

    void MainWindow::RangeRefresh()
    {
        if (range != nullptr)
            range->Refresh();
    }

    void MainWindow::RangePlace()
    {
        if (range != nullptr)
            range->Place(false);
    }

#ifdef ZS_DEV_HOOKS
    Microsoft::UI::Xaml::UIElement MainWindow::RangeDevRoot()
    {
        return range->card;
    }

    // rangelog, rangeclose, rangeadd, rangeset name value, rangereset name,
    // rangechip k (the filament of the layers), rangebody k (of the body).
    bool MainWindow::RunRangeStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        auto &r = *range;
        if (verb == L"rangeclose")
        {
            RangeClose();
        }
        else if (verb == L"rangeadd")
        {
            if (r.open)
                r.OpenScope();
        }
        else if (verb == L"rangeset" && words.size() >= 2)
        {
            if (r.open)
                r.target->set(zs::ToUtf8(words[0]), zs::ToUtf8(words[1]));
        }
        else if (verb == L"rangereset" && !words.empty())
        {
            r.ResetValue(zs::ToUtf8(words[0]));
        }
        else if (verb == L"rangechip" && !words.empty())
        {
            r.SetValue("project.filament", zs::ToUtf8(words[0]));
        }
        else if (verb == L"rangebody" && !words.empty())
        {
            int k = _wtoi(words[0].c_str());
            bool painted = r.PaintBody(k);
            if (painted)
            {
                r.body_value = k;
                r.Refresh();
            }
            zs::Log("dev: range body filament %d painted %d\n", k, painted ? 1 : 0);
        }
        else if (verb == L"rangelog")
        {
            zs::Log("dev: range open %d lo %zu hi %zu title '%s' facts '%s' rows %zu body %d light path %lld rgb %d key %d card %.0f,%.0f %.0fx%.0f\n", r.open ? 1 : 0, r.lo, r.hi,
                    zs::ToUtf8(std::wstring(r.title.Text())).c_str(), zs::ToUtf8(std::wstring(r.facts.Text())).c_str(), r.rows.size(), r.BodyLit() ? 1 : 0,
                    (long long)r.light_path, (int)r.light_rgb, r.key_on ? 1 : 0, Canvas::GetLeft(r.card), Canvas::GetTop(r.card), r.card.ActualWidth(), r.card.ActualHeight());
            double z0 = 0, z1 = 0;
            if (r.open && r.ZRange(z0, z1))
            {
                zs::Log("dev: range z %.3f to %.3f, overrides %zu, print wall_count %s\n", z0, z1, zs_app_override_count(model->Active()), model->GetSetting("project.wall_count").c_str());
                for (auto const &row : r.rows)
                    zs::Log("dev: range row %s = %s over %d reset %.1f\n", row.name.c_str(), r.ValueAt(z0, row.name.c_str()).c_str(),
                            zs_app_override_at(model->Active(), z0, row.name.c_str()), row.reset.Opacity());
            }
            zs::Log("dev: search scope %d\n", search_scope != nullptr ? 1 : 0);
        }
        else
        {
            return false;
        }
        return true;
    }
#endif
}
