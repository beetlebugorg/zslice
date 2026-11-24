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
// A lit body has a row "This part of the layers": a chip paints the mesh of
// the part under the lines of the body (zs_app_paint_body), and the body
// shows in the color of that filament at once. The row of project.filament
// then reads "Whole layers".
//
// With a lit body, each other row has a switch: "This part" (the default) or
// "Whole layers". A change for this part goes to the region of the body
// (zs_app_region_set: a modifier volume of the part). A setting that a region
// cannot have (zs_setting_region_note) stays for the whole layers, and a line
// under its row says why.
//
// The Filament row of the line card (FillLineFilament) gives the body of a
// line its own filament on its layer. Then the card offers the layers above
// and below where the body goes on (zs_view_connected_layers), with the beads
// that the pick took before the slice numbered the lines again.
//
// Esc, a click elsewhere in the view, a change of the tool, or × closes the
// card and ends the light. The card does no work for a frame except its
// place: 8 projections.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>
#include <map>

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

    wchar_t const *const card_xaml =
        L"<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' "
        L"Width='300' Visibility='Collapsed' Padding='14,10,12,10' CornerRadius='12' BorderThickness='1' "
        L"Background='{ThemeResource ZsPopover}' BorderBrush='{ThemeResource ZsPopoverBorder}' AutomationProperties.Name='The selected layers'>"
        L"<Grid RowSpacing='8'>"
        L"<Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='*'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>"
        L"<Grid x:Name='RcHead' Background='Transparent' ToolTipService.ToolTip='Drag to move the card'>"
        L"<Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>"
        L"<TextBlock x:Name='RcTitle' FontWeight='Bold' VerticalAlignment='Center' TextWrapping='Wrap' Foreground='{ThemeResource ZsFg}'/>"
        L"<Button x:Name='RcClose' Grid.Column='1' Background='Transparent' BorderThickness='0' Padding='6' "
        L"AutomationProperties.Name='Close the layers card' ToolTipService.ToolTip='Close (Esc)'><FontIcon Glyph='&#xE711;' FontSize='11'/></Button>"
        L"</Grid>"
        L"<TextBlock x:Name='RcFacts' Grid.Row='1' FontSize='12' TextWrapping='WrapWholeWords' Foreground='{ThemeResource ZsDim}'/>"
        L"<TextBlock Grid.Row='2' Text='Changes here are for these layers of this print.' FontSize='11.5' TextWrapping='WrapWholeWords' Foreground='{ThemeResource ZsDim}'/>"
        L"<Border Grid.Row='3' BorderThickness='0,1,0,0' BorderBrush='{ThemeResource ZsLine}' Padding='0,8,0,0'>"
        L"<ScrollViewer VerticalScrollBarVisibility='Auto' HorizontalScrollBarVisibility='Disabled' HorizontalScrollMode='Disabled' ZoomMode='Disabled'>"
        L"<StackPanel x:Name='RcRows' Spacing='4' Padding='0,0,10,0'/>"
        L"</ScrollViewer></Border>"
        L"<Button x:Name='RcAdd' Grid.Row='4' Content='+ Add a setting for these layers' Background='Transparent' BorderThickness='0' "
        L"Foreground='{ThemeResource ZsAccentText}' FontSize='12' Padding='0,2' MinHeight='24' "
        L"ToolTipService.ToolTip='Search the settings that can change for some layers'/>"
        L"</Grid></Border>";

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
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);

    struct MainWindow::RangeState
    {
        struct Row
        {
            std::string name;
            std::wstring text;
            TextBlock label{ nullptr }, sub{ nullptr }, note{ nullptr };
            Button reset{ nullptr }, scope{ nullptr };
            ColumnDefinition editor_column{ nullptr };
            // With a lit body: this part of the layers, or the whole layers.
            bool part = true;
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
        // The region of the lit body (0: none yet), and its own values.
        uint32_t region = 0;
        std::map<std::string, std::string> region_values;
        std::vector<Row> rows;
        std::shared_ptr<EditorTarget> target;
        // The chips of the lit body in the search of these layers.
        std::function<void()> body_search_fill;

        bool open = false;
        size_t lo = 0, hi = 0;
        double z_top_lo = 0, z_top_hi = 0, z_bottom = 0;

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
            if (PartScope(name))
            {
                RegionSet(name, nullptr);
                return;
            }
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

        // ---- the region of the lit body ----

        static bool Regional(char const *name)
        {
            return strcmp(name, "project.filament") != 0 && zs_setting_region_note(name) == nullptr;
        }

        Row *FindRow(std::string const &name)
        {
            for (auto &row : rows)
                if (row.name == name)
                    return &row;
            return nullptr;
        }

        // True if an edit of the setting changes the region of the lit body.
        bool PartScope(std::string const &name)
        {
            if (!BodyLit() || !Regional(name.c_str()))
                return false;
            Row const *row = FindRow(name);
            return row == nullptr || row->part;
        }

        uint32_t FindRegion()
        {
            if (!BodyLit())
                return 0;
            float const *beads = nullptr;
            size_t n = 0;
            if (zs_view_connected_beads(w.view, (size_t)light_path, light_lo, light_hi, &beads, &n) != ZS_OK || n == 0)
                return 0;
            uint32_t id = 0;
            zs_app_region_find(w.model->Active(), beads, n, &id);
            return id;
        }

        // The values of the region. An undo can take the region away.
        void ReadRegion()
        {
            region_values.clear();
            if (region == 0 || w.model == nullptr)
                return;
            zs_app *app = w.model->Active();
            size_t len = 0;
            if (zs_app_region_settings(app, region, nullptr, 0, &len) == ZS_OK && len > 0)
            {
                std::string text(len + 1, '\0');
                if (zs_app_region_settings(app, region, text.data(), text.size(), &len) == ZS_OK)
                {
                    text.resize(len);
                    size_t at = 0;
                    while (at < text.size())
                    {
                        size_t end = std::min(text.find('\n', at), text.size());
                        size_t tab = text.find('\t', at);
                        if (tab != std::string::npos && tab < end)
                            region_values[text.substr(at, tab - at)] = text.substr(tab + 1, end - tab - 1);
                        at = end + 1;
                    }
                }
            }
            if (region_values.empty())
                region = 0;
        }

        // value nullptr: the region has no value of its own.
        bool RegionSet(std::string const &name, char const *value)
        {
            if (!open || w.model == nullptr)
                return false;
            float const *beads = nullptr;
            size_t n = 0;
            if (BodyLit())
                zs_view_connected_beads(w.view, (size_t)light_path, light_lo, light_hi, &beads, &n);
            if (n == 0 && region == 0)
                return false;
            uint32_t out = 0;
            int rc = zs_app_region_set(w.model->Active(), beads, n, region, name.c_str(), value, &out);
            if (rc != ZS_OK)
            {
                w.ShowToast(zs::ToWide(name) + L": " + zs::ToWide(zs_status_message(rc)));
                w.RefreshSettingValues();
                return false;
            }
            region = out;
            w.model->RequestSlice();
            if (w.model->HistoryCommit())
                w.RefreshHistoryButtons();
            w.RefreshSettingValues();
            return true;
        }

        // The value of an editor: of the region when it has its own, else
        // of the layers.
        std::string EditValue(std::string const &name)
        {
            if (PartScope(name))
            {
                auto at = region_values.find(name);
                if (at != region_values.end())
                    return at->second;
            }
            return Value(name);
        }

        void EditSet(std::string const &name, std::string const &value)
        {
            if (PartScope(name))
                RegionSet(name, value.c_str());
            else
                SetValue(name, value);
        }

        void ToggleScope(std::string const &name)
        {
            Row *row = FindRow(name);
            if (row == nullptr)
                return;
            row->part = !row->part;
            DrawScope(*row);
            Refresh();
        }

        // The switch, the name, and the note of a row.
        void DrawScope(Row &row)
        {
            bool body = BodyLit();
            bool filament = row.name == "project.filament";
            bool can = Regional(row.name.c_str());
            bool part = body && can && row.part;
            row.scope.Visibility(body && can ? Visibility::Visible : Visibility::Collapsed);
            // One width of the editors, so that the switches line up.
            row.editor_column.MinWidth(body ? 172 : 0);
            row.scope.Content(box_value(part ? L"This part" : L"Whole layers"));
            row.scope.Background(part ? TokenBrush(w.Root(), L"ZsAccent") : Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()).as<Media::Brush>());
            row.scope.Foreground(part ? Media::SolidColorBrush(Microsoft::UI::Colors::White()).as<Media::Brush>() : TokenBrush(w.Root(), L"ZsFg"));
            ToolTipService::SetToolTip(row.scope, box_value(part ? L"The change is for the lit part of these layers only. Click for the whole layers."
                                                                 : L"The change is for the whole layers. Click for the lit part only."));
            Automation::AutomationProperties::SetName(row.scope, row.text + (part ? L": this part of the layers" : L": the whole layers"));
            row.label.Text(filament && body ? std::wstring(L"Whole layers") : row.text);
            row.sub.Visibility(filament && body ? Visibility::Visible : Visibility::Collapsed);
            char const *why = zs_setting_region_note(row.name.c_str());
            bool noted = body && !can && !filament && why != nullptr;
            row.note.Text(noted ? L"Whole layers only. " + zs::ToWide(why) : std::wstring());
            row.note.Visibility(noted ? Visibility::Visible : Visibility::Collapsed);
            wchar_t const *reset = part ? L"Remove the change for this part of the layers" : L"Remove the change for these layers";
            ToolTipService::SetToolTip(row.reset, box_value(reset));
            Automation::AutomationProperties::SetName(row.reset, row.text + L": " + (part ? L"remove the change for this part of the layers" : L"remove the change for these layers"));
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
            w.DockCard(card, 3);

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
            StackPanel body_labels;
            body_labels.VerticalAlignment(VerticalAlignment::Center);
            body_labels.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            ToolTipService::SetToolTip(body_labels, box_value(L"The filament of the lit part of these layers only. The paint of the part keeps it."));
            TextBlock body_name;
            body_name.Text(L"This part of the layers");
            body_name.FontSize(13);
            body_name.TextWrapping(TextWrapping::WrapWholeWords);
            body_labels.Children().Append(body_name);
            body_labels.Children().Append(SmallText(L"Filament"));
            body_row.Children().Append(body_labels);
            body_chips = MakeChipPanel();
            Grid::SetColumn(body_chips, 1);
            body_row.Children().Append(body_chips);
            body_row.Visibility(Visibility::Collapsed);

            target = std::make_shared<EditorTarget>();
            target->no_hint = true;
            target->get = [this](std::string const &name) { return EditValue(name); };
            target->set = [this](std::string const &name, std::string const &value) { EditSet(name, value); };
        }

        static TextBlock SmallText(wchar_t const *text)
        {
            TextBlock line;
            line.Text(text);
            line.FontSize(11);
            line.Opacity(0.7);
            line.TextWrapping(TextWrapping::WrapWholeWords);
            return line;
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
            ColumnDefinition label_column, scope_column, editor_column, reset_column;
            label_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            scope_column.Width(GridLengthHelper::Auto());
            editor_column.Width(GridLengthHelper::Auto());
            reset_column.Width(GridLengthHelper::FromPixels(22));
            grid.ColumnDefinitions().Append(label_column);
            grid.ColumnDefinitions().Append(scope_column);
            grid.ColumnDefinitions().Append(editor_column);
            grid.ColumnDefinitions().Append(reset_column);
            row.editor_column = editor_column;

            row.text = zs::ToWide(info.label);
            StackPanel labels;
            labels.VerticalAlignment(VerticalAlignment::Center);
            labels.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            ToolTipService::SetToolTip(labels, box_value(PlainDoc(info.doc)));
            row.label = TextBlock();
            row.label.Text(row.text);
            row.label.FontSize(13);
            row.label.TextWrapping(TextWrapping::WrapWholeWords);
            labels.Children().Append(row.label);
            row.sub = SmallText(L"Filament");
            row.sub.Visibility(Visibility::Collapsed);
            labels.Children().Append(row.sub);
            grid.Children().Append(labels);

            row.scope = Button();
            row.scope.FontSize(11);
            row.scope.MinWidth(0);
            row.scope.MinHeight(22);
            row.scope.Padding(ThicknessHelper::FromLengths(6, 1, 6, 1));
            row.scope.BorderThickness(ThicknessHelper::FromUniformLength(0));
            row.scope.CornerRadius(CornerRadiusHelper::FromUniformRadius(10));
            row.scope.VerticalAlignment(VerticalAlignment::Center);
            std::string scope_name = info.name;
            row.scope.Click([this, scope_name](auto &&, auto &&) { Later([this, scope_name] { ToggleScope(scope_name); }); });
            Grid::SetColumn(row.scope, 1);
            grid.Children().Append(row.scope);

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
                if (IsFilamentSetting(info.name))
                {
                }
                else if (info.kind == ZS_SETTING_NUMBER || info.kind == ZS_SETTING_INTEGER)
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
            Grid::SetColumn(editor, 2);
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
            std::string name = info.name;
            row.reset.Click([this, name](auto &&, auto &&) { Later([this, name] { ResetValue(name); }); });
            Grid::SetColumn(row.reset, 3);
            grid.Children().Append(row.reset);

            row.note = SmallText(L"");
            row.note.Visibility(Visibility::Collapsed);
            rows_box.Children().Append(grid);
            rows_box.Children().Append(row.note);
            rows.push_back(std::move(row));
            DrawScope(rows.back());
        }

        // The chips of the filament of the layers, or of the lit body.
        void FillChips(VariableSizedWrapGrid const &panel, std::string &key_store, int value, bool body)
        {
            w.FillFilamentChips(panel, key_store, value, body ? L"This part of the layers" : L"", [this, body](int k) {
                if (!body)
                {
                    SetValue("project.filament", std::to_string(k));
                }
                else if (PaintBody(k))
                {
                    body_value = k;
                    Refresh();
                }
            });
        }

        // The values at the first layer, and the ↺ of each changed setting.
        void Refresh()
        {
            double z0, z1;
            if (!open || w.model == nullptr || !ZRange(z0, z1))
                return;
            zs_app *app = w.model->Active();
            ReadRegion();
            if (body_search_fill)
                body_search_fill();
            int filament = std::max(atoi(ValueAt(z0, "project.filament").c_str()), 1);
            for (auto &row : rows)
            {
                for (auto &editor : row.editors)
                    editor.refresh();
                if (row.chips != nullptr)
                    FillChips(row.chips, row.chips_key, filament, false);
                // The ↺ of the row removes the value of its own scope.
                bool part = PartScope(row.name);
                bool over = part ? region_values.count(row.name) != 0 : zs_app_override_at(app, z0, row.name.c_str()) == 1;
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
                body_key.clear();
                BuildRows();
                card.Visibility(Visibility::Visible);
            }
            body_value = 0;
            ShowHead();
            bool body = BodyLit();
            body_row.Visibility(body ? Visibility::Visible : Visibility::Collapsed);
            // A lit body has the switch in each row.
            card.Width(body ? 384 : 300);
            region = FindRegion();
            for (auto &row : rows)
            {
                row.part = true;
                DrawScope(row);
            }
            Refresh();
        }

        // The search scope of these layers: the settings that can change
        // for some layers. A setting that the user sets there gets a row.
        void OpenScope()
        {
            auto scope = std::make_shared<SearchScope>();
            scope->label = ScopeLabel() + (BodyLit() ? L", this part" : L"");
            scope->only = [](zs_setting_info const &info) { return info.per_layer != 0; };
            scope->source = [this](std::string const &name) -> std::wstring {
                double z0, z1;
                if (open && PartScope(name) && region_values.count(name) != 0)
                    return L"This part";
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
                    // With a lit body, a setting that a region can have goes
                    // to this part of the layers.
                    if (Row *row = FindRow(name); row != nullptr && Regional(name.c_str()))
                    {
                        row->part = true;
                        DrawScope(*row);
                    }
                    Refresh();
                }
                EditSet(name, value);
            };
            // With a lit body: what each row changes. The filament row has
            // chips for the whole layers and for this part of them.
            scope->decorate = [this](zs_setting_info const &info, StackPanel const &label) {
                if (!open || !BodyLit())
                    return;
                if (strcmp(info.name, "project.filament") == 0)
                {
                    label.Children().Append(SmallText(L"Whole layers: the chips at the right"));
                    StackPanel sub;
                    sub.Spacing(2);
                    sub.Children().Append(SmallText(L"This part of the layers:"));
                    auto chips = MakeChipPanel();
                    chips.HorizontalAlignment(HorizontalAlignment::Left);
                    auto key = std::make_shared<std::string>();
                    body_search_fill = [this, chips, key] {
                        w.FillFilamentChips(chips, *key, body_value, L"This part of the layers", [this](int k) {
                            if (PaintBody(k))
                            {
                                body_value = k;
                                Refresh();
                            }
                        });
                    };
                    body_search_fill();
                    sub.Children().Append(chips);
                    label.Children().Append(sub);
                    return;
                }
                char const *note = zs_setting_region_note(info.name);
                std::wstring text = Regional(info.name) ? std::wstring(L"This part of the layers") : L"Whole layers only. " + zs::ToWide(note != nullptr ? note : "");
                label.Children().Append(SmallText(text.c_str()));
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
        r.region = 0;
        r.region_values.clear();
        r.body_search_fill = nullptr;
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
            ptrdiff_t l = SelectedPath() >= 0 ? zs_app_path_layer(app, (size_t)SelectedPath()) : -1;
            size_t top = (size_t)std::max<int64_t>(std::lround(LayerSlider().Value()) - 1, 0);
            r.key_a = r.key_b = l >= 0 ? (size_t)l : std::min(top, tp.layer_count - 1);
            r.key_path = l >= 0 ? SelectedPath() : -1;
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
            if (SelectedPath() >= 0)
            {
                SetSelectedLine(-1, -1);
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
        if (r.region == 0)
            r.region = r.FindRegion();
        r.Refresh();
    }

    void MainWindow::RangeRefresh()
    {
        if (range != nullptr)
            range->Refresh();
        if (model != nullptr && LineCard().Visibility() == Visibility::Visible)
            DrawLineChips();
    }

    // ---- the filament of the body of a line ----

    void MainWindow::ClearLineExtend()
    {
        line_body = {};
        LineExtend().Children().Clear();
        LineExtend().Visibility(Visibility::Collapsed);
    }

    void MainWindow::DrawLineChips()
    {
        FillFilamentChips(LineFilamentChips(), line_chips_key, line_filament, L"This part of the layer", [this](int k) { PickLineFilament(k); });
    }

    void MainWindow::FillLineFilament()
    {
        if (model == nullptr || SelectedPath() < 0)
            return;
        int f = (int)zs_app_path_filament(model->Active(), (size_t)SelectedPath());
        if (f > 0)
            line_filament = f;
        DrawLineChips();
    }

    // Lights the body in the color of the filament until the slice comes
    // back. A lit range keeps its own light.
    void MainWindow::LightLine(int64_t path, size_t lo, size_t hi, int filament)
    {
        if (range != nullptr && range->light_on)
            return;
        line_lit = true;
        zs_view_light_color(view, (int32_t)FilamentRgb(filament));
        zs_view_light_connected(view, (size_t)path, lo, hi, nullptr);
        RequestDraw();
    }

    // The slice of a filament of the line card: its lines have the color.
    void MainWindow::LineLightAfterSlice()
    {
        if (!line_lit || (range != nullptr && range->light_on))
            return;
        line_lit = false;
        zs_view_light_color(view, -1);
        zs_view_light_connected(view, (size_t)-1, 0, 0, nullptr);
        ApplySelection();
    }

    bool MainWindow::PaintBeads(std::vector<float> const &beads, int filament)
    {
        size_t changed = 0;
        if (beads.empty() || zs_app_paint_body(model->Active(), beads.data(), beads.size(), (uint32_t)filament, &changed) != ZS_OK)
            return false;
        if (changed > 0)
        {
            model->RequestSlice();
            if (model->HistoryCommit())
                RefreshHistoryButtons();
        }
        return true;
    }

    // A chip of the Filament row: the body of the line on its layer gets the
    // filament, and the buttons of the layers where it goes on show.
    void MainWindow::PickLineFilament(int filament)
    {
        if (filament < 1 || SelectedPath() < 0 || view == nullptr || model == nullptr)
            return;
        ClearLineExtend();
        size_t path = (size_t)SelectedPath();
        ptrdiff_t at = zs_app_path_layer(model->Active(), path);
        if (at < 0)
            return;
        size_t layer = (size_t)at;
        auto copy = [&](size_t lo, size_t hi) {
            std::vector<float> out;
            float const *beads = nullptr;
            size_t n = 0;
            if (zs_view_connected_beads(view, path, lo, hi, &beads, &n) == ZS_OK && n > 0)
                out.assign(beads, beads + n);
            return out;
        };
        std::vector<float> beads = copy(layer, layer);
        if (beads.empty())
            return;
        size_t lo = layer, hi = layer;
        zs_view_connected_layers(view, path, &lo, &hi);
        // The beads above and below now: the slice numbers the lines again.
        LineBody body;
        if (hi > layer)
            body.above = copy(layer + 1, hi);
        if (lo < layer)
            body.below = copy(lo, layer - 1);
        LightLine(SelectedPath(), layer, layer, filament);
        if (!PaintBeads(beads, filament))
            return;
        line_filament = filament;
        body.filament = filament;
        auto button = [&](int direction, std::wstring const &text, std::wstring const &tip) {
            Button b;
            b.Content(box_value(text));
            b.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
            b.BorderThickness(ThicknessHelper::FromUniformLength(0));
            b.FontSize(12);
            b.Padding(ThicknessHelper::FromLengths(6, 4, 6, 4));
            ToolTipService::SetToolTip(b, box_value(tip));
            b.Click([this, direction](auto &&, auto &&) { ExtendLineFilament(direction); });
            LineExtend().Children().Append(b);
            return b;
        };
        if (!body.above.empty())
            body.above_button = button(1, L"Also the layers above, to " + std::to_wstring(hi + 1),
                                       L"The same filament for this body on layers " + std::to_wstring(layer + 2) + L" to " + std::to_wstring(hi + 1) + L", where it goes on");
        if (!body.below.empty())
            body.below_button = button(-1, L"Also the layers below, from " + std::to_wstring(lo + 1),
                                       L"The same filament for this body on layers " + std::to_wstring(lo + 1) + L" to " + std::to_wstring(layer) + L", where it goes on");
        bool more = !body.above.empty() || !body.below.empty();
        line_body = std::move(body);
        LineExtend().Visibility(more ? Visibility::Visible : Visibility::Collapsed);
        DrawLineChips();
    }

    // "Also the layers above" (1) and "below" (-1).
    void MainWindow::ExtendLineFilament(int direction)
    {
        std::vector<float> const &beads = direction > 0 ? line_body.above : line_body.below;
        Button b = direction > 0 ? line_body.above_button : line_body.below_button;
        int filament = line_body.filament;
        if (beads.empty() || b == nullptr || filament < 1 || view == nullptr || model == nullptr)
            return;
        if (SelectedPath() >= 0)
        {
            size_t lo = (size_t)-1, hi = 0;
            for (size_t k = 1; k < beads.size(); k += 9)
            {
                lo = std::min(lo, (size_t)beads[k]);
                hi = std::max(hi, (size_t)beads[k]);
            }
            ptrdiff_t layer = zs_app_path_layer(model->Active(), (size_t)SelectedPath());
            if (layer >= 0)
                LightLine(SelectedPath(), std::min(lo, (size_t)layer), std::max(hi, (size_t)layer), filament);
        }
        if (PaintBeads(beads, filament))
            b.Visibility(Visibility::Collapsed);
    }

    // The changes of these layers. The last change of a setting wins.
    std::vector<std::pair<std::string, std::string>> MainWindow::RangeChangesNow()
    {
        std::vector<std::pair<std::string, std::string>> out;
        double z0 = 0, z1 = 0;
        if (!RangeOpen() || model == nullptr || !range->ZRange(z0, z1))
            return out;
        zs_app *app = model->Active();
        for (size_t i = 0, n = zs_app_override_count(app); i < n; i++)
        {
            zs_override o{};
            if (zs_app_override_get(app, i, &o) != ZS_OK || o.z_min > z0 + 1e-4 || o.z_max < z0 - 1e-4)
                continue;
            std::string name(o.name, o.name_len), value(o.value, o.value_len);
            auto same = std::find_if(out.begin(), out.end(), [&](auto const &c) { return c.first == name; });
            if (same != out.end())
                same->second = value;
            else
                out.emplace_back(std::move(name), std::move(value));
        }
        return out;
    }

    void MainWindow::RangePaste(std::vector<std::pair<std::string, std::string>> const &changes)
    {
        double z0 = 0, z1 = 0;
        if (!RangeOpen() || model == nullptr || !range->ZRange(z0, z1))
            return;
        size_t done = 0;
        for (auto const &c : changes)
            if (zs_app_override_set(model->Active(), z0, z1, c.first.c_str(), c.second.c_str()) == ZS_OK)
                done++;
        if (done == 0)
            return;
        model->RequestSlice();
        NoteChange();
        RefreshSettingValues();
        range->Refresh();
        ProfilesRefresh();
    }

    void MainWindow::RangeClearChanges(std::vector<std::pair<std::string, std::string>> const &changes)
    {
        double z0 = 0, z1 = 0;
        if (!RangeOpen() || model == nullptr || !range->ZRange(z0, z1))
            return;
        zs_app *app = model->Active();
        size_t done = 0;
        for (auto const &c : changes)
            if (zs_app_override_remove(app, z0, z1, c.first.c_str()) == 1 || zs_app_override_clear_at(app, z0, c.first.c_str()) > 0)
                done++;
        if (done == 0)
            return;
        model->RequestSlice();
        NoteChange();
        RefreshSettingValues();
        range->Refresh();
        ProfilesRefresh();
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
        else if (verb == L"rangehints")
        {
            // A row with a speed hint would have a third column.
            size_t with_hint = 0, wrapped = 0;
            for (auto const &row : r.rows)
                if (row.label != nullptr && row.label.ActualHeight() > 24)
                    wrapped++;
            std::function<void(Microsoft::UI::Xaml::DependencyObject const &)> walk = [&](Microsoft::UI::Xaml::DependencyObject const &at) {
                if (auto text = at.try_as<TextBlock>(); text != nullptr && std::wstring(text.Text()).find(L"mm/s") != std::wstring::npos && std::wstring(text.Text()).find(L"≈") != std::wstring::npos)
                    with_hint++;
                for (int32_t i = 0, n = Media::VisualTreeHelper::GetChildrenCount(at); i < n; i++)
                    walk(Media::VisualTreeHelper::GetChild(at, i));
            };
            walk(r.card);
            zs::Log("dev: range hints %zu, wrapped labels %zu of %zu rows, card %.0f wide\n", with_hint, wrapped, r.rows.size(), r.card.ActualWidth());
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
        else if (verb == L"rangescope" && !words.empty())
        {
            r.ToggleScope(zs::ToUtf8(words[0]));
        }
        else if (verb == L"linefil" && !words.empty())
        {
            PickLineFilament(_wtoi(words[0].c_str()));
            zs::Log("dev: line filament %d, path %lld, above %zu below %zu\n", line_filament, (long long)SelectedPath(), line_body.above.size() / 9, line_body.below.size() / 9);
        }
        else if (verb == L"lineext" && !words.empty())
        {
            ExtendLineFilament(_wtoi(words[0].c_str()));
        }
        else if (verb == L"linefillog")
        {
            int f = SelectedPath() >= 0 ? (int)zs_app_path_filament(model->Active(), (size_t)SelectedPath()) : 0;
            zs_toolpaths tp{};
            size_t by[3] = {}, on_layer[3] = {};
            ptrdiff_t at = SelectedPath() >= 0 ? zs_app_path_layer(model->Active(), (size_t)SelectedPath()) : -1;
            if (zs_app_toolpaths(model->Active(), &tp) == ZS_OK)
                for (size_t i = 0; i < tp.path_count; i++)
                {
                    size_t k = std::min<size_t>(zs_app_path_filament(model->Active(), i), 2);
                    by[k]++;
                    if (zs_app_path_layer(model->Active(), i) == at)
                        on_layer[k]++;
                }
            zs::Log("dev: line path %lld layer %lld filament %d chip %d chips %u extend %u lit %d, paths f1 %zu f2 %zu, on its layer f1 %zu f2 %zu\n", (long long)SelectedPath(), (long long)at, f,
                    line_filament, LineFilamentChips().Children().Size(), LineExtend().Children().Size(), line_lit ? 1 : 0, by[1], by[2], on_layer[1], on_layer[2]);
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
                    zs::Log("dev: range row %s = %s shown %s over %d reset %.1f scope '%s' note '%s'\n", row.name.c_str(), r.ValueAt(z0, row.name.c_str()).c_str(), r.EditValue(row.name).c_str(),
                            zs_app_override_at(model->Active(), z0, row.name.c_str()), row.reset.Opacity(),
                            row.scope.Visibility() == Visibility::Visible ? zs::ToUtf8(std::wstring(unbox_value<hstring>(row.scope.Content()))).c_str() : "",
                            zs::ToUtf8(std::wstring(row.note.Text())).c_str());
                zs::Log("dev: range region %u values %zu\n", r.region, r.region_values.size());
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
