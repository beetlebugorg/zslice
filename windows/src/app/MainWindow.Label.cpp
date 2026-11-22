// The Label tool and its card. It follows the GTK shell
// (linux/src/ui/label-tool.c and label-card.c).
//
// The tool keeps a copy of the labels of one part, and reads them again
// after each slice, each undo or redo, and each switch of the plate. A
// change of the selected label goes into the copy at once: the decal and the
// card follow it. The change goes to the core 400 ms after the last edit, or
// at the end of a drag, so a drag, a turn with the wheel, or the keys of a
// word are one step of the history. A read of the labels during that pause
// keeps the label that waits.
//
// The outline of each label (zs_label_outline) is made again only when its
// shapes change. A move or a turn changes only its frame, and the core view
// keeps the fill of an outline that it had (zs_view_label_add).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>
#include <map>
#include <optional>

#include <winrt/Windows.Globalization.NumberFormatting.h>

#include "zs_label.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Primitives = Microsoft::UI::Xaml::Controls::Primitives;
namespace Formatting = Windows::Globalization::NumberFormatting;
namespace JsonNs = Windows::Data::Json;
using Windows::System::VirtualKey;

namespace
{
    // The lift of the decal out of the surface, mm (as the core view).
    constexpr double lift = 0.05;
    // The pause after the last change of a label before it goes to the core.
    constexpr int commit_ms = 400;
    // The margin around the box of a label that still hits it, mm.
    constexpr double hit_margin = 1.0;
    // The room for the handle around the box of a label on the screen.
    constexpr double handle_room = 12.0;
    constexpr double pi = 3.14159265358979323846;

    wchar_t const *const card_markup = LR"xaml(
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="340" Padding="12" Visibility="Collapsed"
        Background="#FAFFFFFF" BorderBrush="#DDE0E4" BorderThickness="1" CornerRadius="8">
  <StackPanel Spacing="6">
    <Grid x:Name="Head" Background="Transparent" ToolTipService.ToolTip="Drag to move the card">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" />
        <ColumnDefinition Width="Auto" />
      </Grid.ColumnDefinitions>
      <TextBlock x:Name="Title" FontWeight="Bold" VerticalAlignment="Center" TextWrapping="Wrap" />
      <Button x:Name="Close" Grid.Column="1" Background="Transparent" BorderThickness="0" Padding="6"
              AllowFocusOnInteraction="False" AutomationProperties.Name="Close the label card">
        <FontIcon Glyph="&#xE711;" FontSize="11" />
      </Button>
    </Grid>
    <ScrollViewer x:Name="Scroll" HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto" MaxHeight="600">
      <StackPanel Spacing="6" Padding="0,0,12,0">
        <StackPanel x:Name="Notice" Spacing="4" Visibility="Collapsed">
          <TextBlock x:Name="NoticeText" FontSize="12" Foreground="#B45309" TextWrapping="WrapWholeWords" />
          <Button x:Name="NoticeAdd" Content="Add a filament"
                  ToolTipService.ToolTip="Add a second filament to the plate, and print the label with it" />
        </StackPanel>
        <TextBlock x:Name="CurveNote" Visibility="Collapsed" FontSize="12" Foreground="#B45309" TextWrapping="WrapWholeWords" />
        <StackPanel x:Name="Items" Spacing="6" />
        <DropDownButton x:Name="AddShape" Content="+ Add a shape…"
                        ToolTipService.ToolTip="Add a shape to this label: it shares the place, the turn, and the filament. Ticks go around the center, under the text.">
          <DropDownButton.Flyout>
            <MenuFlyout x:Name="AddShapeMenu" Placement="BottomEdgeAlignedLeft" />
          </DropDownButton.Flyout>
        </DropDownButton>
        <Grid ColumnSpacing="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="116" />
            <ColumnDefinition Width="24" />
          </Grid.ColumnDefinitions>
          <TextBlock Text="Turn" VerticalAlignment="Center" />
          <NumberBox x:Name="Turn" Grid.Column="1" Minimum="-180" Maximum="180" SmallChange="1" SpinButtonPlacementMode="Compact"
                     AutomationProperties.Name="The turn of the label"
                     ToolTipService.ToolTip="The turn of the label on the face (0: level). The wheel over the label turns it 1° (Shift: 15°)." />
          <TextBlock Grid.Column="2" Text="°" Foreground="#5B6168" VerticalAlignment="Center" />
        </Grid>
        <TextBlock Text="Filament" FontSize="12" FontWeight="SemiBold" />
        <VariableSizedWrapGrid x:Name="Chips" Orientation="Horizontal" ItemWidth="30" ItemHeight="30" MaximumRowsOrColumns="10" />
        <StackPanel Spacing="4">
          <Grid ColumnSpacing="6">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="Auto" />
              <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBlock Text="Depth" VerticalAlignment="Center" />
            <ToggleButton x:Name="Depth1" Grid.Column="1" Content="1 line" AllowFocusOnInteraction="False"
                          ToolTipService.ToolTip="The color is one line deep (the outer wall)" />
            <ToggleButton x:Name="Depth2" Grid.Column="2" Content="2 lines" AllowFocusOnInteraction="False"
                          ToolTipService.ToolTip="The color is two lines deep: more color for a light filament over a dark part" />
          </Grid>
          <Grid ColumnSpacing="6">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*" />
              <ColumnDefinition Width="116" />
              <ColumnDefinition Width="24" />
            </Grid.ColumnDefinitions>
            <NumberBox x:Name="DepthMm" Grid.Column="1" Minimum="0" Maximum="10" SmallChange="0.01" SpinButtonPlacementMode="Compact"
                       AutomationProperties.Name="The depth of the color"
                       ToolTipService.ToolTip="The depth of the color from the surface, mm (0: one line)" />
            <TextBlock Grid.Column="2" Text="mm" FontSize="12" Foreground="#5B6168" VerticalAlignment="Center" />
          </Grid>
        </StackPanel>
        <TextBlock Text="Print" FontSize="12" FontWeight="SemiBold" />
        <StackPanel x:Name="Check" Spacing="4" />
        <StackPanel x:Name="Cost" Spacing="4" />
        <Button x:Name="Delete" Content="Delete the label" Foreground="#B91C1C" Margin="0,4,0,0"
                ToolTipService.ToolTip="Remove the label from the part (Delete)" />
      </StackPanel>
    </ScrollViewer>
  </StackPanel>
</Border>)xaml";

    struct Outline
    {
        std::string key;
        std::vector<float> pts;
        std::vector<uint32_t> ends;
        size_t n = 0;
        double box[4] = { 0, 0, 0, 0 };
    };

    // The outline of the shapes of a JSON (zs_label_outline).
    std::optional<Outline> OutlineOfJson(std::string const &key)
    {
        float const *pts = nullptr;
        uint32_t const *ends = nullptr;
        size_t n = 0;
        if (zs_label_outline(key.data(), key.size(), &pts, &ends, &n) != ZS_OK)
            return std::nullopt;
        Outline o;
        o.key = key;
        o.n = n;
        size_t count = n > 0 ? ends[n - 1] : 0;
        o.ends.assign(ends, ends + n);
        o.pts.assign(pts, pts + 2 * count);
        if (count > 0)
        {
            o.box[0] = o.box[1] = INFINITY;
            o.box[2] = o.box[3] = -INFINITY;
            for (size_t i = 0; i < count; i++)
            {
                o.box[0] = std::min<double>(o.box[0], o.pts[2 * i]);
                o.box[1] = std::min<double>(o.box[1], o.pts[2 * i + 1]);
                o.box[2] = std::max<double>(o.box[2], o.pts[2 * i]);
                o.box[3] = std::max<double>(o.box[3], o.pts[2 * i + 1]);
            }
        }
        return o;
    }

    double InfoNumber(JsonNs::JsonObject const &o, wchar_t const *key, double fallback = 0)
    {
        if (o == nullptr || !o.HasKey(key) || o.GetNamedValue(key).ValueType() != JsonNs::JsonValueType::Number)
            return fallback;
        return o.GetNamedNumber(key);
    }

    bool InfoFlag(JsonNs::JsonObject const &o, wchar_t const *key)
    {
        return o != nullptr && o.HasKey(key) && o.GetNamedValue(key).ValueType() == JsonNs::JsonValueType::Boolean && o.GetNamedBoolean(key);
    }

    std::wstring InfoText(JsonNs::JsonObject const &o, wchar_t const *key)
    {
        if (o == nullptr || !o.HasKey(key) || o.GetNamedValue(key).ValueType() != JsonNs::JsonValueType::String)
            return {};
        return std::wstring(o.GetNamedString(key));
    }

    TextBlock SmallText(std::wstring const &text, bool dim)
    {
        TextBlock t;
        t.Text(text);
        t.FontSize(12);
        t.TextWrapping(TextWrapping::WrapWholeWords);
        if (dim)
            t.Foreground(Media::SolidColorBrush(Windows::UI::Color{ 255, 0x5b, 0x61, 0x68 }));
        return t;
    }

    // A two-column grid of facts: a name and a value.
    Grid FactsGrid()
    {
        Grid g;
        g.ColumnSpacing(10);
        g.RowSpacing(2);
        ColumnDefinition a, b;
        a.Width(GridLengthHelper::Auto());
        b.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
        g.ColumnDefinitions().Append(a);
        g.ColumnDefinitions().Append(b);
        return g;
    }

    void Fact(Grid const &g, std::wstring const &name, std::wstring const &value, bool warn)
    {
        int row = (int)g.RowDefinitions().Size();
        RowDefinition def;
        def.Height(GridLengthHelper::Auto());
        g.RowDefinitions().Append(def);
        TextBlock k = SmallText(name, true);
        TextBlock v = SmallText(value, false);
        if (warn)
            v.Foreground(Media::SolidColorBrush(Windows::UI::Color{ 255, 0xb4, 0x53, 0x09 }));
        Grid::SetRow(k, row);
        Grid::SetRow(v, row);
        Grid::SetColumn(v, 1);
        g.Children().Append(k);
        g.Children().Append(v);
    }

    std::wstring Format(wchar_t const *format, double a)
    {
        wchar_t text[96];
        swprintf_s(text, format, a);
        return text;
    }

    NumberBox MakeNumber(double value, double min, double max, double step)
    {
        NumberBox box;
        box.Minimum(min);
        box.Maximum(max);
        box.SmallChange(step);
        box.SpinButtonPlacementMode(NumberBoxSpinButtonPlacementMode::Compact);
        Formatting::IncrementNumberRounder rounder;
        rounder.Increment(step >= 1 ? 0.1 : step >= 0.1 ? 0.01 : 0.001);
        Formatting::DecimalFormatter formatter;
        formatter.IntegerDigits(1);
        formatter.FractionDigits(0);
        formatter.NumberRounder(rounder);
        box.NumberFormatter(formatter);
        box.Value(value);
        return box;
    }

    void SetRounder(NumberBox const &box, double increment)
    {
        Formatting::IncrementNumberRounder rounder;
        rounder.Increment(increment);
        Formatting::DecimalFormatter formatter;
        formatter.IntegerDigits(1);
        formatter.FractionDigits(0);
        formatter.NumberRounder(rounder);
        box.NumberFormatter(formatter);
    }
}

namespace winrt::ZSlice::implementation
{
    struct MainWindow::LabelState
    {
        // A field that follows the label: an item and a field of it ("at:0"
        // and "at:1" for the offset, "turn", "depth").
        struct InputField
        {
            FrameworkElement widget{ nullptr };
            int item = -1;
            std::string field;
        };

        explicit LabelState(MainWindow &window) : w(window) {}

        MainWindow &w;
        bool on = false;
        // The part of the labels, its filament (from 1), and its plate.
        int64_t index = -1;
        int base = 1;
        zs_app *core = nullptr;
        std::vector<zs::Label> labels;
        int64_t sel = -1;
        double curve = 0;
        JsonNs::JsonObject info{ nullptr };
        std::map<uint32_t, Outline> outlines;
        // A drag of a label: the point of the press in its plane, the label
        // at the press, and the pointer of the press.
        bool dragging = false, moved = false;
        uint32_t drag_id = 0;
        double drag_dx = 0, drag_dy = 0, press_x = 0, press_y = 0;
        std::optional<zs::Label> drag_start;
        // A drag of the handle.
        bool scaling = false;
        std::optional<zs::Label> scale_start;
        double scale_c[2] = {}, scale_d0 = 0;
        // A free line that draws: its item and its points.
        int drawing = -1;
        std::vector<double> drawn;
        Microsoft::UI::Dispatching::DispatcherQueueTimer timer{ nullptr };
        int64_t pending = -1;

        Border card{ nullptr }, handle{ nullptr };
        TextBlock title{ nullptr }, notice_text{ nullptr }, curve_note{ nullptr };
        StackPanel notice{ nullptr }, items{ nullptr }, check{ nullptr }, cost{ nullptr };
        Button notice_add{ nullptr };
        ScrollViewer scroll{ nullptr };
        NumberBox turn{ nullptr }, depth_mm{ nullptr };
        Primitives::ToggleButton depth1{ nullptr }, depth2{ nullptr };
        VariableSizedWrapGrid chips{ nullptr };
        std::vector<InputField> inputs;
        std::string key, chips_key;
        bool updating = false, card_queued = false, focus_text = false, card_moved = false;
        double last_box[4] = { 0, 0, 0, 0 };
        bool has_last_box = false;

        // ---- the labels ----

        zs::Label *LabelById(int64_t id)
        {
            if (id < 0)
                return nullptr;
            for (auto &l : labels)
                if (l.id == (uint32_t)id)
                    return &l;
            return nullptr;
        }

        zs::Label *Selected()
        {
            return LabelById(sel);
        }

        bool Live() const
        {
            return on && w.view != nullptr;
        }

        // The outline of a label, made again only when its shapes change.
        Outline *OutlineFor(zs::Label const &l)
        {
            std::string shapes = zs::LabelJson(l, true);
            auto found = outlines.find(l.id);
            if (found != outlines.end() && found->second.key == shapes)
                return &found->second;
            auto made = OutlineOfJson(shapes);
            if (!made.has_value())
                return found != outlines.end() ? &found->second : nullptr;
            auto &slot = outlines[l.id];
            slot = std::move(*made);
            return &slot;
        }

        // The decals of the labels of the part to the core view.
        void Redraw()
        {
            if (w.view == nullptr)
                return;
            zs_view_labels_clear(w.view);
            if (on)
            {
                for (auto const &l : labels)
                {
                    Outline *o = OutlineFor(l);
                    if (o == nullptr || o->n == 0)
                        continue;
                    double frame[9];
                    std::copy_n(l.origin, 3, frame);
                    std::copy_n(l.normal, 3, frame + 3);
                    std::copy_n(l.right, 3, frame + 6);
                    zs_view_label_add(w.view, frame, o->pts.data(), o->ends.data(), o->n, w.FilamentRgb(l.filament), l.id == (uint32_t)sel ? 1 : 0);
                }
            }
            w.RequestDraw();
        }

        // ---- the picks ----

        bool Ray(double x, double y, float r[6], double o[3], double d[3])
        {
            double s = w.Scale();
            if (w.view == nullptr || !zs_view_ray(w.view, (float)(x * s), (float)(y * s), r))
                return false;
            for (int k = 0; k < 3; k++)
            {
                o[k] = r[k];
                d[k] = r[3 + k];
            }
            return true;
        }

        zs_paint *Session(int64_t part)
        {
            zs::PartMesh *e = w.model != nullptr ? w.meshes.Get(w.model->Active(), part) : nullptr;
            return e != nullptr ? e->session : nullptr;
        }

        bool PlaceAt(int64_t part, double x, double y, double out[10])
        {
            float r[6];
            double o[3], d[3];
            zs_paint *s = Session(part);
            return s != nullptr && Ray(x, y, r, o, d) && zs_label_place(s, r, 5, out) == 1;
        }

        // The label under x, y (the selected label first), and the point in
        // its plane.
        zs::Label *LabelAt(double x, double y, double *lx, double *ly)
        {
            float r[6];
            double o[3], d[3];
            if (!Live() || !Ray(x, y, r, o, d))
                return nullptr;
            for (int pass = 0; pass < 2; pass++)
            {
                for (auto &l : labels)
                {
                    if ((pass == 0) != (l.id == (uint32_t)sel))
                        continue;
                    Outline *ol = OutlineFor(l);
                    double p[3], px, py;
                    if (ol == nullptr || !zs::LabelPlaneHit(l, o, d, p, &px, &py))
                        continue;
                    if (px >= ol->box[0] - hit_margin && px <= ol->box[2] + hit_margin && py >= ol->box[1] - hit_margin && py <= ol->box[3] + hit_margin)
                    {
                        if (lx != nullptr)
                            *lx = px;
                        if (ly != nullptr)
                            *ly = py;
                        return &l;
                    }
                }
            }
            return nullptr;
        }

        // A point of the plane of a label on the screen (points of the view).
        bool ScreenOf(zs::Label const &l, double x, double y, double out[2])
        {
            double p[3];
            float qx, qy;
            zs::LabelToBed(l, x, y, lift, p);
            if (w.view == nullptr || !zs_view_pixel_of(w.view, p[0], p[1], p[2], &qx, &qy))
                return false;
            double s = w.Scale();
            out[0] = qx / s;
            out[1] = qy / s;
            return true;
        }

        // The box of the selected label on the screen, with the room of its
        // handle.
        bool ScreenBox(double box[4])
        {
            zs::Label *l = Selected();
            Outline *o = l != nullptr ? OutlineFor(*l) : nullptr;
            if (o == nullptr)
                return false;
            box[0] = box[1] = INFINITY;
            box[2] = box[3] = -INFINITY;
            for (int k = 0; k < 4; k++)
            {
                double q[2];
                if (!ScreenOf(*l, k & 1 ? o->box[2] + hit_margin : o->box[0] - hit_margin, k & 2 ? o->box[3] + hit_margin : o->box[1] - hit_margin, q))
                    continue;
                box[0] = std::min(box[0], q[0]);
                box[1] = std::min(box[1], q[1]);
                box[2] = std::max(box[2], q[0]);
                box[3] = std::max(box[3], q[1]);
            }
            if (!(box[0] <= box[2]))
                return false;
            box[0] -= handle_room;
            box[1] -= handle_room;
            box[2] += handle_room;
            box[3] += handle_room;
            return true;
        }

        bool ScreenCenter(double c[2])
        {
            zs::Label *l = Selected();
            Outline *o = l != nullptr ? OutlineFor(*l) : nullptr;
            return o != nullptr && ScreenOf(*l, (o->box[0] + o->box[2]) / 2, (o->box[1] + o->box[3]) / 2, c);
        }

        // ---- the labels of the core ----

        std::string LabelsJson(int64_t part)
        {
            zs_app *app = w.model->Active();
            size_t len = 0;
            if (zs_app_part_labels_get(app, (size_t)part, nullptr, 0, &len) != ZS_OK)
                return {};
            std::string text(len + 1, '\0');
            if (zs_app_part_labels_get(app, (size_t)part, text.data(), text.size(), &len) != ZS_OK)
                return {};
            text.resize(len);
            return text;
        }

        // The labels of a part from the core. id: the label to select (-1:
        // keep the selection if the label is still there).
        void Load(int64_t part, int64_t id)
        {
            zs_app *app = w.model->Active();
            if (part < 0 || (size_t)part >= zs_app_part_count(app))
            {
                index = -1;
                labels.clear();
                Select(-1);
                Redraw();
                return;
            }
            if (part != index)
                Select(-1);
            std::vector<zs::Label> list;
            std::string json = LabelsJson(part);
            if (json.empty() || !zs::LabelsParse(json, list))
                list.clear();
            // A change that waits for its pause keeps its values.
            zs::Label *keep = part == index && pending >= 0 ? LabelById(pending) : nullptr;
            if (keep != nullptr)
            {
                for (auto &l : list)
                    if (l.id == keep->id)
                        l = *keep;
            }
            labels = std::move(list);
            index = part;
            core = app;
            base = w.PartFilament(part);
            if (id >= 0)
                Select(id);
            else if (Selected() == nullptr)
                Select(-1);
            else
                ShowCard();
            Redraw();
        }

        void Reload()
        {
            if (!on || dragging || scaling || w.model == nullptr)
                return;
            w.meshes.CheckAll();
            if (core != w.model->Active())
            {
                // Another plate: its labels are on other parts.
                timer.Stop();
                pending = -1;
                index = -1;
                core = w.model->Active();
            }
            if (index >= 0)
                Load(index, -1);
            else
            {
                labels.clear();
                Select(-1);
                Redraw();
            }
            LoadInfo();
        }

        void LoadInfo()
        {
            zs::Label *l = Selected();
            info = nullptr;
            if (l != nullptr && w.model != nullptr && index >= 0)
            {
                zs_app *app = w.model->Active();
                size_t len = 0;
                if (zs_app_label_info(app, (size_t)index, l->id, nullptr, 0, &len) == ZS_OK)
                {
                    std::string text(len + 1, '\0');
                    if (zs_app_label_info(app, (size_t)index, l->id, text.data(), text.size(), &len) == ZS_OK)
                    {
                        text.resize(len);
                        JsonNs::JsonObject parsed{ nullptr };
                        if (JsonNs::JsonObject::TryParse(zs::ToWide(text), parsed))
                            info = parsed;
                    }
                }
            }
            ShowInfo();
        }

        // ---- the selection ----

        void Select(int64_t id)
        {
            if (id != sel)
            {
                Flush();
                drawing = -1;
            }
            sel = id;
            if (Selected() == nullptr)
            {
                sel = -1;
                info = nullptr;
                curve = 0;
                ShowCard();
                handle.Visibility(Visibility::Collapsed);
                Redraw();
                return;
            }
            ShowCard();
            Redraw();
            LoadInfo();
            Place();
        }

        // ---- the changes ----

        // The selected label becomes `next`: the decal and the card at
        // once, and the core after a pause (commit: at once). False for a
        // bad shape: the label stays.
        bool Change(zs::Label next, bool commit)
        {
            zs::Label *l = Selected();
            if (l == nullptr)
                return false;
            std::string a = zs::LabelJson(*l, true), b = zs::LabelJson(next, true);
            if (a != b && !OutlineOfJson(b).has_value())
                return false;
            next.id = l->id;
            *l = std::move(next);
            Redraw();
            ShowCard();
            timer.Stop();
            pending = l->id;
            // A drag sends the label at its end (one step of the history).
            if (commit)
                Flush();
            else if (!dragging && !scaling)
                timer.Start();
            return true;
        }

        std::optional<zs::Label> EditCopy()
        {
            zs::Label *l = Selected();
            if (l == nullptr)
                return std::nullopt;
            zs::Label c = *l;
            zs::LabelOwnItems(c);
            return c;
        }

        void LabelsChanged()
        {
            w.model->RequestSlice();
            if (w.model->HistoryCommit())
                w.RefreshHistoryButtons();
            w.FillPartExtras();
        }

        // Sends the change that waits to the core.
        void Flush()
        {
            if (timer != nullptr)
                timer.Stop();
            int64_t id = pending;
            pending = -1;
            zs::Label *l = LabelById(id);
            if (l == nullptr || index < 0 || w.model == nullptr)
                return;
            std::string json = zs::LabelJson(*l, false);
            if (zs_app_label_update(w.model->Active(), (size_t)index, l->id, json.data(), json.size()) != ZS_OK)
                w.ShowToast(L"The label did not change: a value is out of range.");
            else
                LabelsChanged();
            LoadInfo();
        }

        bool EditNumber(size_t item, char const *field, double v)
        {
            auto c = EditCopy();
            if (!c.has_value() || !std::isfinite(v))
                return false;
            auto it = zs::LabelItem(*c, item);
            if (it == nullptr)
                return false;
            zs::LabelItemSetNumber(it, field, v);
            return Change(std::move(*c), false);
        }

        bool EditText(size_t item, std::wstring const &text)
        {
            auto c = EditCopy();
            if (!c.has_value())
                return false;
            auto it = zs::LabelItem(*c, item);
            if (it == nullptr)
                return false;
            zs::LabelItemSetText(it, text);
            return Change(std::move(*c), false);
        }

        bool EditFlag(size_t item, char const *field, bool value)
        {
            auto c = EditCopy();
            if (!c.has_value())
                return false;
            auto it = zs::LabelItem(*c, item);
            if (it == nullptr)
                return false;
            zs::LabelItemSetFlag(it, field, value);
            return Change(std::move(*c), false);
        }

        bool EditAt(size_t item, double x, double y)
        {
            auto c = EditCopy();
            if (!c.has_value() || !std::isfinite(x) || !std::isfinite(y))
                return false;
            auto it = zs::LabelItem(*c, item);
            if (it == nullptr)
                return false;
            zs::LabelItemSetAt(it, x, y);
            return Change(std::move(*c), false);
        }

        void SetShape(size_t item, std::string const &kind)
        {
            auto c = EditCopy();
            if (!c.has_value())
                return;
            auto it = zs::LabelItem(*c, item);
            if (it == nullptr)
                return;
            c->items.SetAt((uint32_t)item, zs::LabelChangeShape(it, kind));
            if (drawing == (int)item)
                drawing = -1;
            Change(std::move(*c), true);
        }

        // A new item in the label: under the items that are there. Ticks and
        // rings go around the center, under the text.
        void AddItem(std::string const &kind)
        {
            zs::Label *l = Selected();
            if (l == nullptr)
                return;
            Outline *o = OutlineFor(*l);
            double size = 5;
            for (size_t i = 0; i < zs::LabelItemCount(*l); i++)
            {
                auto it = zs::LabelItem(*l, i);
                if (zs::LabelItemKind(it) == "text")
                {
                    size = zs::LabelItemNumber(it, "size", 5);
                    break;
                }
            }
            auto it = zs::LabelNewItem(kind, size);
            double at_y = NAN;
            if (kind == "ticks" || kind == "ring")
            {
                double r = kind == "ticks" ? zs::LabelItemNumber(it, "radius", 0) + zs::LabelItemNumber(it, "length_end", 0)
                                           : zs::LabelItemNumber(it, "outer", 0);
                at_y = (o != nullptr ? o->box[1] : 0) - r - 1;
            }
            else if (o != nullptr && zs::LabelItemCount(*l) > 0)
            {
                at_y = o->box[1] - size;
            }
            if (!std::isnan(at_y))
                zs::LabelItemSetAt(it, 0, at_y);
            auto c = EditCopy();
            c->items.Append(it);
            Change(std::move(*c), true);
        }

        void RemoveItem(size_t item)
        {
            zs::Label *l = Selected();
            if (l == nullptr || zs::LabelItemCount(*l) <= 1 || item >= zs::LabelItemCount(*l))
                return;
            auto c = EditCopy();
            c->items.RemoveAt((uint32_t)item);
            if (drawing == (int)item)
                drawing = -1;
            else if (drawing > (int)item)
                drawing--;
            Change(std::move(*c), true);
        }

        void SetAngle(double degrees)
        {
            auto c = EditCopy();
            if (!c.has_value())
                return;
            zs::LabelSetAngle(*c, degrees);
            Change(std::move(*c), false);
        }

        void Turn(double degrees)
        {
            auto c = EditCopy();
            if (!c.has_value())
                return;
            zs::LabelTurn(*c, degrees);
            Change(std::move(*c), false);
        }

        void SetFilament(int value)
        {
            zs::Label *now = Selected();
            if (now != nullptr && now->filament == value)
            {
                ShowCard();
                return;
            }
            auto c = EditCopy();
            if (!c.has_value())
                return;
            c->filament = value;
            Change(std::move(*c), true);
        }

        void AddFilament()
        {
            int64_t i = w.AddFilament();
            if (i >= 0)
                SetFilament((int)i + 1);
            ShowCard();
        }

        void SetDepth(double mm)
        {
            // A click on the depth that the label has only sets the buttons
            // again.
            zs::Label *now = Selected();
            if (now != nullptr && now->depth == std::clamp(mm, 0.0, 10.0))
            {
                ShowCard();
                return;
            }
            auto c = EditCopy();
            if (!c.has_value())
                return;
            c->depth = std::clamp(mm, 0.0, 10.0);
            Change(std::move(*c), true);
        }

        void Remove()
        {
            zs::Label *l = Selected();
            if (l == nullptr || index < 0)
                return;
            timer.Stop();
            pending = -1;
            uint32_t id = l->id;
            if (zs_app_label_remove(w.model->Active(), (size_t)index, id) == ZS_OK)
                LabelsChanged();
            outlines.erase(id);
            sel = -1;
            Load(index, -1);
        }

        void DrawPoints(int item)
        {
            drawing = item;
            drawn.clear();
            if (item < 0)
                Flush();
            ShowCard();
        }

        // A point of a free line at x, y, into the item that draws.
        void DrawPoint(double x, double y)
        {
            zs::Label *l = Selected();
            auto it = l != nullptr ? zs::LabelItem(*l, (size_t)drawing) : nullptr;
            float r[6];
            double o[3], d[3], p[3], hx, hy;
            if (it == nullptr || zs::LabelItemKind(it) != "polyline" || !Ray(x, y, r, o, d) || !zs::LabelPlaneHit(*l, o, d, p, &hx, &hy))
                return;
            double ang = -zs::LabelItemNumber(it, "angle", 0) * pi / 180;
            double px = hx - zs::LabelItemAt(it, 0), py = hy - zs::LabelItemAt(it, 1);
            drawn.push_back(px * std::cos(ang) - py * std::sin(ang));
            drawn.push_back(px * std::sin(ang) + py * std::cos(ang));
            if (drawn.size() < 4)
                return;
            auto c = EditCopy();
            auto ci = zs::LabelItem(*c, (size_t)drawing);
            zs::LabelItemSetPoints(ci, drawn);
            Change(std::move(*c), false);
        }

        // ---- a new label ----

        void AddAt(double x, double y)
        {
            int64_t part = w.PartAt(x, y, nullptr, nullptr);
            if (part < 0)
            {
                Select(-1);
                return;
            }
            if (part != index)
                Load(part, -1);
            double at[10];
            if (!PlaceAt(part, x, y, at))
            {
                w.ShowToast(L"Click a face of the part to put a label there.");
                return;
            }
            zs::Label l;
            std::copy_n(at, 3, l.origin);
            std::copy_n(at + 3, 3, l.normal);
            std::copy_n(at + 6, 3, l.right);
            l.filament = zs::LabelNextFilament(base, (int)zs_app_filament_count(w.model->Active()));
            l.items.Append(zs::LabelNewItem("text", 5));
            std::string json = zs::LabelJson(l, false);
            Flush();
            uint32_t id = 0;
            if (zs_app_label_add(w.model->Active(), (size_t)part, json.data(), json.size(), &id) != ZS_OK)
            {
                w.ShowToast(L"The label does not fit here.");
                return;
            }
            LabelsChanged();
            curve = at[9];
            Load(part, id);
            curve_note.Visibility(curve > zs::label_curve_limit ? Visibility::Visible : Visibility::Collapsed);
            // The text field gets the keys at once.
            focus_text = true;
            ShowCard();
        }

        // ---- the pointer ----

        bool Press(double x, double y)
        {
            if (!Live() || drawing >= 0)
                return false;
            double lx, ly;
            zs::Label *l = LabelAt(x, y, &lx, &ly);
            if (l == nullptr)
                return false;
            uint32_t id = l->id;
            if ((int64_t)id != sel)
                Select(id);
            Flush();
            l = LabelById(id);
            if (l == nullptr)
                return false;
            dragging = true;
            moved = false;
            drag_id = id;
            drag_dx = lx;
            drag_dy = ly;
            press_x = x;
            press_y = y;
            drag_start = *l;
            // The mesh for the pick, before the first move.
            Session(index);
            return true;
        }

        // The selected label under the pointer while it drags: on the
        // surface, or in its plane with Shift.
        void MoveTo(double x, double y, bool keep_plane)
        {
            if (!drag_start.has_value())
                return;
            zs::Label const &s = *drag_start;
            if (keep_plane)
            {
                float r[6];
                double o[3], d[3], p[3], hx, hy, up[3];
                if (!Ray(x, y, r, o, d) || !zs::LabelPlaneHit(s, o, d, p, &hx, &hy))
                    return;
                zs::LabelUp(s, up);
                auto c = EditCopy();
                if (!c.has_value())
                    return;
                for (int k = 0; k < 3; k++)
                {
                    c->origin[k] = p[k] - drag_dx * s.right[k] - drag_dy * up[k];
                    c->normal[k] = s.normal[k];
                    c->right[k] = s.right[k];
                }
                Change(std::move(*c), false);
                return;
            }
            double at[10];
            if (!PlaceAt(index, x, y, at))
                return;
            auto c = EditCopy();
            if (!c.has_value())
                return;
            zs::LabelMove(*c, at, at + 3);
            double up[3];
            zs::LabelUp(*c, up);
            for (int k = 0; k < 3; k++)
                c->origin[k] -= drag_dx * c->right[k] + drag_dy * up[k];
            Change(std::move(*c), false);
            if (std::abs(at[9] - curve) > 1e-6)
            {
                curve = at[9];
                curve_note.Visibility(curve > zs::label_curve_limit ? Visibility::Visible : Visibility::Collapsed);
            }
        }

        void Drag(double x, double y, bool shift)
        {
            if (!dragging)
                return;
            if (!moved && std::hypot(x - press_x, y - press_y) < 3)
                return;
            moved = true;
            MoveTo(x, y, shift);
        }

        void Release()
        {
            if (!dragging)
                return;
            dragging = false;
            drag_start.reset();
            if (moved)
                Flush();
            moved = false;
        }

        void Click(double x, double y)
        {
            if (!Live())
                return;
            if (drawing >= 0)
            {
                DrawPoint(x, y);
                return;
            }
            zs::Label *l = LabelAt(x, y, nullptr, nullptr);
            if (l != nullptr)
            {
                if ((int64_t)l->id != sel)
                    Select(l->id);
                return;
            }
            AddAt(x, y);
        }

        bool Wheel(double x, double y, int delta, bool shift)
        {
            if (!Live() || sel < 0)
                return false;
            zs::Label *l = LabelAt(x, y, nullptr, nullptr);
            if (l == nullptr || (int64_t)l->id != sel)
                return false;
            if (delta != 0)
                Turn((delta > 0 ? 1 : -1) * (shift ? 15 : 1));
            return true;
        }

        bool Key(VirtualKey k)
        {
            if (!on)
                return false;
            if (k == VirtualKey::Delete || k == VirtualKey::Back)
            {
                if (sel < 0)
                    return false;
                Remove();
                return true;
            }
            if (k == VirtualKey::Escape)
            {
                if (drawing >= 0)
                    DrawPoints(-1);
                else if (sel >= 0)
                    Select(-1);
                else
                    w.SetTool(Tool::Select);
                return true;
            }
            return false;
        }

        // ---- the handle: a drag scales the label ----

        void ScaleBegin(double x, double y)
        {
            zs::Label *l = Selected();
            double c[2];
            if (l == nullptr || !ScreenCenter(c))
                return;
            Flush();
            l = Selected();
            if (l == nullptr)
                return;
            scaling = true;
            scale_start = *l;
            scale_c[0] = c[0];
            scale_c[1] = c[1];
            scale_d0 = std::max(4.0, std::hypot(x - c[0], y - c[1]));
        }

        void ScaleTo(double x, double y)
        {
            if (!scaling || !scale_start.has_value())
                return;
            double k = std::max(0.05, std::hypot(x - scale_c[0], y - scale_c[1]) / scale_d0);
            zs::Label c = *scale_start;
            zs::LabelScale(c, k);
            Change(std::move(c), false);
        }

        void ScaleEnd()
        {
            if (!scaling)
                return;
            scaling = false;
            scale_start.reset();
            Flush();
        }

        // After each frame: the handle at the upper right corner of the
        // label, and the card beside the label.
        void Place()
        {
            zs::Label *l = on && sel >= 0 ? Selected() : nullptr;
            Outline *o = l != nullptr ? OutlineFor(*l) : nullptr;
            double q[2];
            bool at = o != nullptr && ScreenOf(*l, o->box[2] + 0.5, o->box[3] + 0.5, q);
            handle.Visibility(at ? Visibility::Visible : Visibility::Collapsed);
            if (at)
            {
                Canvas::SetLeft(handle, q[0] - 7);
                Canvas::SetTop(handle, q[1] - 7);
            }
            if (l == nullptr || card.Visibility() != Visibility::Visible)
                return;
            double room = std::max(160.0, w.CardLayer().ActualHeight() - 150);
            if (scroll.MaxHeight() != room)
                scroll.MaxHeight(room);
            if (card_moved)
                return;
            double box[4];
            if (!ScreenBox(box))
                return;
            bool same = has_last_box;
            for (int k = 0; same && k < 4; k++)
                same = std::abs(box[k] - last_box[k]) < 0.5;
            if (same)
                return;
            std::copy_n(box, 4, last_box);
            has_last_box = true;
            w.PlaceCard(card, box);
        }

        // ---- the card ----

        void ShowCard()
        {
            if (!on || Selected() == nullptr)
            {
                // Hidden at once: no card of a label that went.
                card.Visibility(Visibility::Collapsed);
                key.clear();
                card_moved = false;
                has_last_box = false;
                return;
            }
            if (card_queued)
                return;
            card_queued = true;
            auto weak = w.get_weak();
            w.queue.TryEnqueue([weak, this] {
                if (auto self = weak.get())
                {
                    card_queued = false;
                    ApplyCard();
                }
            });
        }

        bool FocusWithin(FrameworkElement const &widget)
        {
            auto root = w.Content().XamlRoot();
            if (root == nullptr)
                return false;
            auto focused = Input::FocusManager::GetFocusedElement(root).try_as<DependencyObject>();
            for (auto at = focused; at != nullptr; at = Media::VisualTreeHelper::GetParent(at))
                if (at == widget)
                    return true;
            return false;
        }

        void ApplyCard()
        {
            zs::Label *l = on ? Selected() : nullptr;
            if (l == nullptr)
            {
                ShowCard();
                return;
            }
            std::string next = std::to_string(l->id) + ":" + std::to_string(drawing) + ":";
            for (size_t i = 0; i < zs::LabelItemCount(*l); i++)
                next += zs::LabelItemKind(zs::LabelItem(*l, i)) + ",";
            // Another label: the card goes back beside it.
            if (key.empty() || strtoul(key.c_str(), nullptr, 10) != l->id)
            {
                card_moved = false;
                has_last_box = false;
            }
            if (next != key)
            {
                key = next;
                // A field with the focus goes away: the keys go to the view,
                // not to the next button of the card.
                bool had_focus = FocusWithin(items);
                updating = true;
                BuildItems(*l);
                updating = false;
                if (had_focus)
                    w.ViewPanel().Focus(FocusState::Programmatic);
            }
            UpdateValues(*l);
            curve_note.Visibility(curve > zs::label_curve_limit ? Visibility::Visible : Visibility::Collapsed);
            ShowInfo();
            bool was_hidden = card.Visibility() != Visibility::Visible;
            card.Visibility(Visibility::Visible);
            if (was_hidden)
            {
                has_last_box = false;
                card.UpdateLayout();
            }
            Place();
            if (focus_text)
            {
                focus_text = false;
                for (auto const &in : inputs)
                {
                    if (in.field != "text")
                        continue;
                    auto box = in.widget.as<TextBox>();
                    box.Focus(FocusState::Programmatic);
                    box.SelectAll();
                    break;
                }
            }
        }

        void AddInput(FrameworkElement const &widget, int item, std::string const &field)
        {
            InputField in;
            in.widget = widget;
            in.item = item;
            in.field = field;
            inputs.push_back(std::move(in));
        }

        // The value of a number field in label l, as the field shows it.
        double InputValue(zs::Label const &l, int item, std::string const &field)
        {
            if (field == "turn")
                return std::round(zs::LabelAngle(l) * 10) / 10;
            if (field == "depth")
                return l.depth;
            auto it = zs::LabelItem(l, (size_t)std::max(item, 0));
            if (field == "at:0")
                return zs::LabelItemAt(it, 0);
            if (field == "at:1")
                return zs::LabelItemAt(it, 1);
            return zs::LabelItemNumber(it, field.c_str(), 0);
        }

        // tolerance: a field rounds what it shows, so a value within half
        // of its last digit is no edit.
        void OnNumber(int item, std::string const &field, double v, double tolerance)
        {
            if (updating || std::isnan(v))
                return;
            zs::Label *current = Selected();
            if (current == nullptr || std::abs(InputValue(*current, item, field) - v) <= tolerance)
                return;
            if (field == "turn")
                SetAngle(v);
            else if (field == "depth")
                SetDepth(v);
            else if (field.rfind("at:", 0) == 0)
            {
                zs::Label *l = Selected();
                auto it = l != nullptr ? zs::LabelItem(*l, (size_t)item) : nullptr;
                double x = field[3] == '0' ? v : zs::LabelItemAt(it, 0), y = field[3] == '1' ? v : zs::LabelItemAt(it, 1);
                EditAt((size_t)item, x, y);
            }
            else
                EditNumber((size_t)item, field.c_str(), v);
        }

        NumberBox NumberField(double value, double min, double max, double step, int item, std::string const &field, std::wstring const &tip)
        {
            NumberBox box = MakeNumber(value, min, max, step);
            if (!tip.empty())
                ToolTipService::SetToolTip(box, box_value(tip));
            AddInput(box, item, field);
            double tolerance = (step >= 1 ? 0.1 : step >= 0.1 ? 0.01 : 0.001) / 2;
            box.ValueChanged([this, item, field, tolerance](NumberBox const &, NumberBoxValueChangedEventArgs const &e) {
                OnNumber(item, field, e.NewValue(), tolerance);
            });
            return box;
        }

        FrameworkElement ItemBox(zs::Label const &l, size_t i)
        {
            auto it = zs::LabelItem(l, i);
            std::string kind = zs::LabelItemKind(it);
            StackPanel box;
            box.Spacing(6);

            Grid head;
            head.ColumnSpacing(4);
            ColumnDefinition chips_column, close_column;
            chips_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            close_column.Width(GridLengthHelper::Auto());
            head.ColumnDefinitions().Append(chips_column);
            head.ColumnDefinitions().Append(close_column);
            Grid row;
            for (size_t k = 0; k < zs::label_kind_count; k++)
            {
                ColumnDefinition c;
                c.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                row.ColumnDefinitions().Append(c);
                Primitives::ToggleButton b;
                b.Content(box_value(zs::label_kind_names[k]));
                b.FontSize(12);
                b.Padding(ThicknessHelper::FromLengths(2, 3, 2, 3));
                b.MinWidth(0);
                b.HorizontalAlignment(HorizontalAlignment::Stretch);
                b.AllowFocusOnInteraction(false);
                b.IsChecked(kind == zs::label_kinds[k]);
                std::wstring tip = std::strcmp(zs::label_kinds[k], "polyline") == 0
                                       ? std::wstring(L"A free line: click points on the face")
                                       : L"Make this shape a " + zs::ToWide(zs::label_kinds[k]);
                ToolTipService::SetToolTip(b, box_value(tip));
                Automation::AutomationProperties::SetName(b, zs::label_kind_names[k]);
                std::string to = zs::label_kinds[k];
                b.Click([this, i, to](IInspectable const &sender, auto &&) {
                    // The chips act as a radio group: the chip of the shape
                    // stays on.
                    sender.as<Primitives::ToggleButton>().IsChecked(true);
                    zs::Label *now = Selected();
                    if (now == nullptr || zs::LabelItemKind(zs::LabelItem(*now, i)) == to)
                        return;
                    auto weak = w.get_weak();
                    w.queue.TryEnqueue([weak, this, i, to] {
                        if (auto self = weak.get())
                            SetShape(i, to);
                    });
                });
                Grid::SetColumn(b, (int32_t)k);
                row.Children().Append(b);
            }
            head.Children().Append(row);
            if (zs::LabelItemCount(l) > 1)
            {
                Button x;
                FontIcon glyph;
                glyph.Glyph(L"\xE711");
                glyph.FontSize(10);
                x.Content(glyph);
                x.Padding(ThicknessHelper::FromUniformLength(6));
                x.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
                x.BorderThickness(ThicknessHelper::FromUniformLength(0));
                x.AllowFocusOnInteraction(false);
                x.VerticalAlignment(VerticalAlignment::Center);
                Automation::AutomationProperties::SetName(x, L"Remove this shape from the label");
                ToolTipService::SetToolTip(x, box_value(L"Remove this shape from the label"));
                x.Click([this, i](auto &&, auto &&) {
                    auto weak = w.get_weak();
                    w.queue.TryEnqueue([weak, this, i] {
                        if (auto self = weak.get())
                            RemoveItem(i);
                    });
                });
                Grid::SetColumn(x, 1);
                head.Children().Append(x);
            }
            box.Children().Append(head);

            if (kind == "text")
            {
                TextBox t;
                t.MaxLength(256);
                t.PlaceholderText(L"Text");
                t.Text(zs::LabelItemText(it));
                Automation::AutomationProperties::SetName(t, L"The text of the label");
                ToolTipService::SetToolTip(t, box_value(L"The text of the label"));
                AddInput(t, (int)i, "text");
                // TextChanged comes after the turn that set the text, so the
                // text of the label tells whether this is an edit.
                t.TextChanged([this, i](IInspectable const &sender, auto &&) {
                    zs::Label *now = Selected();
                    std::wstring value{ sender.as<TextBox>().Text() };
                    if (!updating && now != nullptr && zs::LabelItemText(zs::LabelItem(*now, i)) != value)
                        EditText(i, value);
                });
                box.Children().Append(t);
            }

            // The number fields, one to a row.
            size_t n = 0;
            zs::LabelField const *f = zs::LabelFields(kind, n);
            for (size_t k = 0; k < n; k++)
            {
                std::wstring tip = f[k].tip != nullptr ? f[k].tip : f[k].name;
                Grid line;
                line.ColumnSpacing(6);
                ColumnDefinition a, b, c;
                a.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                b.Width(GridLengthHelper::FromValueAndType(116, GridUnitType::Pixel));
                c.Width(GridLengthHelper::FromValueAndType(24, GridUnitType::Pixel));
                line.ColumnDefinitions().Append(a);
                line.ColumnDefinitions().Append(b);
                line.ColumnDefinitions().Append(c);
                TextBlock name;
                name.Text(f[k].name);
                name.VerticalAlignment(VerticalAlignment::Center);
                ToolTipService::SetToolTip(name, box_value(tip));
                line.Children().Append(name);
                NumberBox number = NumberField(zs::LabelItemNumber(it, f[k].field, 0), f[k].min, f[k].max, f[k].step, (int)i, f[k].field, tip);
                Automation::AutomationProperties::SetName(number, f[k].name);
                Grid::SetColumn(number, 1);
                line.Children().Append(number);
                TextBlock unit = SmallText(f[k].unit, true);
                unit.VerticalAlignment(VerticalAlignment::Center);
                Grid::SetColumn(unit, 2);
                line.Children().Append(unit);
                box.Children().Append(line);
            }

            if (kind == "polyline")
            {
                StackPanel flags;
                flags.Orientation(Orientation::Horizontal);
                flags.Spacing(12);
                char const *const fields[2] = { "closed", "filled" };
                wchar_t const *const names[2] = { L"Closed", L"Filled" };
                for (int k = 0; k < 2; k++)
                {
                    CheckBox b;
                    b.Content(box_value(names[k]));
                    b.IsChecked(zs::LabelItemFlag(it, fields[k]));
                    b.AllowFocusOnInteraction(false);
                    AddInput(b, (int)i, fields[k]);
                    std::string field = fields[k];
                    b.Click([this, i, field](IInspectable const &sender, auto &&) {
                        if (updating)
                            return;
                        auto check_box = sender.as<CheckBox>();
                        bool value = check_box.IsChecked() != nullptr && check_box.IsChecked().Value();
                        if (!EditFlag(i, field.c_str(), value))
                            check_box.IsChecked(!value);
                    });
                    flags.Children().Append(b);
                }
                box.Children().Append(flags);
                bool now = drawing == (int)i;
                Button draw;
                draw.Content(box_value(now ? L"Done" : L"Draw points"));
                draw.AllowFocusOnInteraction(false);
                ToolTipService::SetToolTip(draw, box_value(now ? L"Stop: the line keeps its points" : L"Click points on the face, one after the other"));
                draw.Click([this, i](auto &&, auto &&) {
                    auto weak = w.get_weak();
                    w.queue.TryEnqueue([weak, this, i] {
                        if (auto self = weak.get())
                            DrawPoints(drawing == (int)i ? -1 : (int)i);
                    });
                });
                box.Children().Append(draw);
                if (now)
                    box.Children().Append(SmallText(L"Click points on the face. Click Done at the end.", true));
            }

            // The place of the shape in the label.
            Grid at;
            at.ColumnSpacing(6);
            ColumnDefinition at_a, at_b, at_c, at_d;
            at_a.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            at_b.Width(GridLengthHelper::FromValueAndType(96, GridUnitType::Pixel));
            at_c.Width(GridLengthHelper::FromValueAndType(96, GridUnitType::Pixel));
            at_d.Width(GridLengthHelper::FromValueAndType(24, GridUnitType::Pixel));
            at.ColumnDefinitions().Append(at_a);
            at.ColumnDefinitions().Append(at_b);
            at.ColumnDefinitions().Append(at_c);
            at.ColumnDefinitions().Append(at_d);
            TextBlock offset;
            offset.Text(L"Offset");
            offset.VerticalAlignment(VerticalAlignment::Center);
            at.Children().Append(offset);
            for (int k = 0; k < 2; k++)
            {
                NumberBox number = NumberField(zs::LabelItemAt(it, k), -500, 500, 0.1, (int)i, k == 0 ? "at:0" : "at:1",
                                               k == 0 ? L"Right of the center of the label, mm" : L"Up from the center of the label, mm");
                Automation::AutomationProperties::SetName(number, k == 0 ? L"Offset to the right" : L"Offset up");
                Grid::SetColumn(number, k + 1);
                at.Children().Append(number);
            }
            TextBlock mm = SmallText(L"mm", true);
            mm.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(mm, 3);
            at.Children().Append(mm);
            box.Children().Append(at);
            return box;
        }

        void BuildItems(zs::Label const &l)
        {
            // The inputs of the items go. Turn and depth stay (the first two).
            inputs.resize(std::min<size_t>(inputs.size(), 2));
            items.Children().Clear();
            for (size_t i = 0; i < zs::LabelItemCount(l); i++)
            {
                if (i > 0)
                {
                    Border rule;
                    rule.Height(1);
                    rule.Background(Media::SolidColorBrush(Windows::UI::Color{ 255, 0xdd, 0xe0, 0xe4 }));
                    items.Children().Append(rule);
                }
                items.Children().Append(ItemBox(l, i));
            }
        }

        void DrawChips(zs::Label const &l)
        {
            size_t n = zs_app_filament_count(w.model->Active());
            std::string next = std::to_string(l.filament) + " " + std::to_string(base);
            for (size_t i = 0; i < n; i++)
                next += " " + w.FilamentValue(i, "filament.color") + " " + w.FilamentValue(i, "filament.material");
            if (next != chips_key)
            {
                chips_key = next;
                chips.Children().Clear();
                for (size_t i = 0; i < n; i++)
                {
                    int k = (int)i + 1;
                    std::string color = w.FilamentValue(i, "filament.color");
                    std::string mat = w.FilamentValue(i, "filament.material");
                    Button chip = w.MakeFilamentChip(color, std::to_wstring(k), k == l.filament);
                    std::wstring tip = L"Filament " + std::to_wstring(k) + L" (" + (mat.empty() ? std::wstring(L"filament") : zs::ToWide(mat)) + L", " +
                                       zs::ToWide(color) + L")" + (k == base ? L": the filament of the part" : L"");
                    ToolTipService::SetToolTip(chip, box_value(tip));
                    Automation::AutomationProperties::SetName(chip, L"Label filament " + std::to_wstring(k));
                    chip.Click([this, k](auto &&, auto &&) {
                        auto weak = w.get_weak();
                        w.queue.TryEnqueue([weak, this, k] {
                            if (auto self = weak.get())
                                SetFilament(k);
                        });
                    });
                    chips.Children().Append(chip);
                }
                Button plus = w.MakeFilamentChip({}, L"+", false);
                ToolTipService::SetToolTip(plus, box_value(L"Add a filament to the plate, for this label"));
                Automation::AutomationProperties::SetName(plus, L"Add a filament to the plate, for this label");
                plus.Click([this](auto &&, auto &&) {
                    auto weak = w.get_weak();
                    w.queue.TryEnqueue([weak, this] {
                        if (auto self = weak.get())
                            AddFilament();
                    });
                });
                chips.Children().Append(plus);
            }
            // A label in the filament of the part does not show.
            bool same = l.filament == base;
            notice.Visibility(same ? Visibility::Visible : Visibility::Collapsed);
            notice_add.Visibility(same && n <= 1 ? Visibility::Visible : Visibility::Collapsed);
            notice_text.Text(n <= 1 ? L"The plate has one filament, so this label does not show."
                                    : L"The label has the filament of the part, so it does not show. Pick another filament.");
        }

        void UpdateValues(zs::Label const &l)
        {
            title.Text(L"Label " + zs::LabelTitle(l));
            updating = true;
            for (auto const &in : inputs)
            {
                // The field with the focus keeps what the user types.
                if (FocusWithin(in.widget))
                    continue;
                if (auto number = in.widget.try_as<NumberBox>())
                {
                    double v = InputValue(l, in.item, in.field);
                    if (!(std::abs(number.Value() - v) <= 1e-9))
                        number.Value(v);
                }
                else if (auto flag = in.widget.try_as<CheckBox>())
                {
                    flag.IsChecked(zs::LabelItemFlag(zs::LabelItem(l, (size_t)in.item), in.field.c_str()));
                }
                else if (auto text = in.widget.try_as<TextBox>())
                {
                    std::wstring want = zs::LabelItemText(zs::LabelItem(l, (size_t)in.item));
                    if (std::wstring(text.Text()) != want)
                        text.Text(want);
                }
            }
            double lw = InfoNumber(info, L"line_width", 0.42);
            depth1.IsChecked(!(l.depth > 0));
            depth2.IsChecked(std::abs(l.depth - 2 * lw) < 1e-6);
            updating = false;
            DrawChips(l);
        }

        void ShowInfo()
        {
            check.Children().Clear();
            cost.Children().Clear();
            if (info == nullptr)
                return;
            double lw = InfoNumber(info, L"line_width", 0.42);
            Grid stats = FactsGrid();
            if (InfoNumber(info, L"thinnest") > 0)
                Fact(stats, L"Thinnest stroke", Format(L"%.2f mm", InfoNumber(info, L"thinnest")), InfoNumber(info, L"thinnest") < 2 * lw);
            if (InfoNumber(info, L"clean_size") > 0)
            {
                wchar_t text[96];
                swprintf_s(text, L"clean from %.1f mm, fair from %.1f mm", InfoNumber(info, L"clean_size"), InfoNumber(info, L"fair_size"));
                Fact(stats, L"Text size", text, false);
            }
            check.Children().Append(stats);
            std::wstring advice = InfoText(info, L"advice");
            if (!advice.empty())
                check.Children().Append(SmallText(advice, false));
            if (InfoFlag(info, L"same_filament"))
                return;
            bool sliced = InfoFlag(info, L"sliced");
            int n = (int)std::lround(InfoNumber(info, sliced ? L"changes" : L"estimate_changes"));
            Grid facts = FactsGrid();
            Fact(facts, sliced ? L"Adds" : L"Adds about", std::to_wstring(n) + (n == 1 ? L" filament change" : L" filament changes"), false);
            Fact(facts, L"Time", std::to_wstring(std::lround(InfoNumber(info, L"minutes"))) + L" min", false);
            Fact(facts, L"Flush", Format(L"%.1f g", InfoNumber(info, L"grams")), false);
            if (InfoNumber(info, L"layers") > 0)
            {
                wchar_t text[64];
                swprintf_s(text, L"%ld (%.1f to %.1f mm)", std::lround(InfoNumber(info, L"layers")), InfoNumber(info, L"z_min"), InfoNumber(info, L"z_max"));
                Fact(facts, L"Layers", text, false);
            }
            cost.Children().Append(facts);
            if (!sliced)
                cost.Children().Append(SmallText(L"An estimate. The slice gives the count.", true));
            int top = (int)std::lround(InfoNumber(info, L"top_changes", -1));
            if (InfoText(info, L"kind") == L"side" && n > 10 && top >= 0)
                cost.Children().Append(SmallText(L"On the top face, this label costs " + std::to_wstring(top) + (top == 1 ? L" change." : L" changes."), false));
        }

        void CloseTool()
        {
            Flush();
            Release();
            ScaleEnd();
            w.meshes.CheckAll();
            labels.clear();
            outlines.clear();
            index = -1;
            drawing = -1;
            Select(-1);
            if (w.view != nullptr)
            {
                zs_view_labels_clear(w.view);
                w.RequestDraw();
            }
        }
    };

    void MainWindow::WireLabel()
    {
        label = std::make_shared<LabelState>(*this);
        auto &l = *label;
        l.timer = queue.CreateTimer();
        l.timer.IsRepeating(false);
        l.timer.Interval(std::chrono::milliseconds(commit_ms));
        l.timer.Tick([this](auto &&, auto &&) { label->Flush(); });

        l.card = Markup::XamlReader::Load(card_markup).as<Border>();
        auto find = [&](wchar_t const *name) { return l.card.FindName(name); };
        l.title = find(L"Title").as<TextBlock>();
        l.notice = find(L"Notice").as<StackPanel>();
        l.notice_text = find(L"NoticeText").as<TextBlock>();
        l.notice_add = find(L"NoticeAdd").as<Button>();
        l.curve_note = find(L"CurveNote").as<TextBlock>();
        l.curve_note.Text(zs::label_curve_text);
        l.items = find(L"Items").as<StackPanel>();
        l.scroll = find(L"Scroll").as<ScrollViewer>();
        l.turn = find(L"Turn").as<NumberBox>();
        l.depth_mm = find(L"DepthMm").as<NumberBox>();
        l.depth1 = find(L"Depth1").as<Primitives::ToggleButton>();
        l.depth2 = find(L"Depth2").as<Primitives::ToggleButton>();
        l.chips = find(L"Chips").as<VariableSizedWrapGrid>();
        l.check = find(L"Check").as<StackPanel>();
        l.cost = find(L"Cost").as<StackPanel>();
        SetRounder(l.turn, 0.1);
        SetRounder(l.depth_mm, 0.001);
        CardLayer().Children().Append(l.card);

        // The turn and the depth are the first two inputs.
        l.AddInput(l.turn, -1, "turn");
        l.AddInput(l.depth_mm, -1, "depth");
        l.turn.ValueChanged([this](NumberBox const &, NumberBoxValueChangedEventArgs const &e) { label->OnNumber(-1, "turn", e.NewValue(), 0.05); });
        l.depth_mm.ValueChanged([this](NumberBox const &, NumberBoxValueChangedEventArgs const &e) { label->OnNumber(-1, "depth", e.NewValue(), 0.0005); });

        auto on_depth = [this](bool two) {
            auto &s = *label;
            if (s.updating)
                return;
            double lw = InfoNumber(s.info, L"line_width", 0.42);
            s.SetDepth(two ? 2 * lw : 0);
        };
        l.depth1.Click([on_depth](auto &&, auto &&) { on_depth(false); });
        l.depth2.Click([on_depth](auto &&, auto &&) { on_depth(true); });
        find(L"Close").as<Button>().Click([this](auto &&, auto &&) { label->Select(-1); });
        find(L"Delete").as<Button>().Click([this](auto &&, auto &&) { label->Remove(); });
        l.notice_add.Click([this](auto &&, auto &&) { label->AddFilament(); });

        auto menu = find(L"AddShapeMenu").as<MenuFlyout>();
        for (size_t k = 0; k < zs::label_kind_count; k++)
        {
            MenuFlyoutItem item;
            item.Text(zs::label_kind_names[k]);
            std::string kind = zs::label_kinds[k];
            item.Click([this, kind](auto &&, auto &&) { label->AddItem(kind); });
            menu.Items().Append(item);
        }

        MakeCardMovable(l.card, find(L"Head").as<FrameworkElement>(), &l.card_moved);

        // Esc: in a field, the keys go back to the view. Else the card
        // closes, and the label stays.
        l.card.KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() != VirtualKey::Escape)
                return;
            auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot());
            bool in_field = focused.try_as<TextBox>() != nullptr || focused.try_as<NumberBox>() != nullptr;
            if (!in_field)
                label->Select(-1);
            ViewPanel().Focus(FocusState::Programmatic);
            e.Handled(true);
        });

        // The handle at the corner: a drag scales the label.
        l.handle = Border();
        l.handle.Width(14);
        l.handle.Height(14);
        l.handle.Background(Media::SolidColorBrush(Windows::UI::Color{ 255, 0xf5, 0xc2, 0x11 }));
        l.handle.BorderBrush(Media::SolidColorBrush(Windows::UI::Color{ 255, 0x1b, 0x1b, 0x1d }));
        l.handle.BorderThickness(ThicknessHelper::FromUniformLength(1.5));
        l.handle.Visibility(Visibility::Collapsed);
        ToolTipService::SetToolTip(l.handle, box_value(L"Drag to make the label larger or smaller"));
        l.handle.PointerPressed([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto at = e.GetCurrentPoint(ViewPanel()).Position();
            label->ScaleBegin(at.X, at.Y);
            if (label->scaling)
                label->handle.CapturePointer(e.Pointer());
            e.Handled(true);
        });
        l.handle.PointerMoved([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!label->scaling)
                return;
            auto at = e.GetCurrentPoint(ViewPanel()).Position();
            label->ScaleTo(at.X, at.Y);
            e.Handled(true);
        });
        auto end = [this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!label->scaling)
                return;
            label->ScaleEnd();
            label->handle.ReleasePointerCapture(e.Pointer());
            e.Handled(true);
        };
        l.handle.PointerReleased(end);
        l.handle.PointerCaptureLost(end);
        CardLayer().Children().Append(l.handle);
    }

    void MainWindow::LabelTool(bool on)
    {
        auto &l = *label;
        if (on == l.on)
            return;
        if (!on)
        {
            l.CloseTool();
            l.on = false;
            l.ShowCard();
            l.handle.Visibility(Visibility::Collapsed);
            return;
        }
        l.on = true;
        l.core = model != nullptr ? model->Active() : nullptr;
        if (model != nullptr && !selected_parts.empty())
            l.Load(selected_parts[0], -1);
        ShowToast(L"Click a face of a part to put a label there. Drag a label to move it; the wheel turns it.");
        ViewPanel().Focus(FocusState::Programmatic);
    }

    bool MainWindow::LabelPress(double x, double y)
    {
        return label->Press(x, y);
    }

    bool MainWindow::LabelDragging()
    {
        return label->dragging;
    }

    void MainWindow::LabelDrag(double x, double y, bool shift)
    {
        label->Drag(x, y, shift);
    }

    void MainWindow::LabelRelease()
    {
        label->Release();
    }

    void MainWindow::LabelClick(double x, double y)
    {
        label->Click(x, y);
    }

    bool MainWindow::LabelWheel(double x, double y, int delta, bool shift)
    {
        return label->Wheel(x, y, delta, shift);
    }

    bool MainWindow::LabelKey(VirtualKey key)
    {
        return label->Key(key);
    }

    void MainWindow::LabelReload()
    {
        label->Reload();
    }

    void MainWindow::LabelPlace()
    {
        if (label != nullptr && label->on && label->sel >= 0)
            label->Place();
    }

    void MainWindow::LabelOpen(int64_t part, uint32_t id)
    {
        if (tool != Tool::Label)
            SetTool(Tool::Label);
        label->Load(part, id);
    }

    // A new color of a filament: the decals again.
    void MainWindow::LabelFilamentsChanged()
    {
        auto &l = *label;
        if (!l.on)
            return;
        l.base = PartFilament(l.index);
        l.Redraw();
        if (l.Selected() != nullptr)
            l.ShowCard();
    }

#ifdef ZS_DEV_HOOKS
    // The steps of the Label tool. See MainWindow.DevHooks.cpp.
    bool MainWindow::RunLabelStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        auto &l = *label;
        auto number = [&](size_t i) { return i < words.size() ? _wtof(words[i].c_str()) : 0.0; };
        auto narrow = [&](size_t i) { return i < words.size() ? zs::ToUtf8(words[i]) : std::string(); };
        double c[2];
        if (verb == L"lface")
        {
            // A click on the front face (-Y) of part 0.
            zs_part part{};
            float qx, qy;
            if (zs_app_part_get(model->Active(), 0, &part) == ZS_OK &&
                zs_view_pixel_of(view, part.x + number(0), part.y - part.size_y / 2, part.size_z / 2 + number(1), &qx, &qy))
                l.Click(qx / Scale(), qy / Scale());
            else
                zs::Log("dev: no front face\n");
        }
        else if (verb == L"ltext")
        {
            std::wstring text;
            for (auto const &word : words)
                text += (text.empty() ? L"" : L" ") + word;
            std::replace(text.begin(), text.end(), L'_', L' ');
            // As after a click on the view: the field shows the text.
            ViewPanel().Focus(FocusState::Programmatic);
            l.EditText(0, text);
        }
        else if (verb == L"lset")
            l.EditNumber((size_t)number(0), narrow(1).c_str(), number(2));
        else if (verb == L"lshape")
            l.SetShape((size_t)number(0), narrow(1));
        else if (verb == L"ladd")
            l.AddItem(narrow(0));
        else if (verb == L"lremove")
            l.RemoveItem((size_t)number(0));
        else if (verb == L"lfilament")
            l.SetFilament((int)number(0));
        else if (verb == L"laddfilament")
            l.AddFilament();
        else if (verb == L"ldepth")
            l.SetDepth(number(0));
        else if (verb == L"lturn")
            l.SetAngle(number(0));
        else if (verb == L"lwheel" || verb == L"lswheel")
        {
            if (l.ScreenCenter(c))
                for (int k = 0; k < (int)std::abs(number(0)); k++)
                    l.Wheel(c[0], c[1], number(0) > 0 ? 120 : -120, verb == L"lswheel");
        }
        else if (verb == L"ldrag" || verb == L"lsdrag")
        {
            // A drag of the selected label from its center, on the tool
            // routes of the pointer.
            if (l.ScreenCenter(c) && ToolPress(c[0], c[1], false))
            {
                for (int k = 1; k <= 10; k++)
                    ToolDrag(c[0] + number(0) * k / 10, c[1] + number(1) * k / 10, verb == L"lsdrag");
                ToolRelease();
            }
            else
                zs::Log("dev: no label to drag\n");
        }
        else if (verb == L"lscale")
        {
            zs::Label *s = l.Selected();
            Outline *o = s != nullptr ? l.OutlineFor(*s) : nullptr;
            double q[2];
            if (o != nullptr && l.ScreenCenter(c) && l.ScreenOf(*s, o->box[2] + 0.5, o->box[3] + 0.5, q))
            {
                l.ScaleBegin(q[0], q[1]);
                for (int k = 1; k <= 10; k++)
                {
                    double kk = 1 + (number(0) - 1) * k / 10;
                    l.ScaleTo(c[0] + (q[0] - c[0]) * kk, c[1] + (q[1] - c[1]) * kk);
                }
                l.ScaleEnd();
            }
            else
                zs::Log("dev: no handle\n");
        }
        else if (verb == L"ldraw")
            l.DrawPoints((int)number(0));
        else if (verb == L"linfo")
            l.LoadInfo();
        else if (verb == L"lflush")
            l.Flush();
        else if (verb != L"llog")
            return false;
        zs::Log("dev: label: tool %s, part %lld, %zu labels, sel %lld, pending %lld, drawing %d, curve %.0f, card %s, handle %s, history %zu of %zu\n", l.on ? "on" : "off",
                (long long)l.index, l.labels.size(), (long long)l.sel, (long long)l.pending, l.drawing, l.curve,
                l.card.Visibility() == Visibility::Visible ? "shown" : "hidden", l.handle.Visibility() == Visibility::Visible ? "shown" : "hidden",
                zs_app_history_current(model->Active()) + 1, zs_app_history_count(model->Active()));
        for (auto const &x : l.labels)
        {
            zs::Log("dev: label %u %s: %zu items, filament %d, depth %.2f, at %.2f %.2f %.2f, normal %.2f %.2f %.2f, turn %.1f, size %.2f%s\n", x.id,
                    zs::ToUtf8(zs::LabelTitle(x)).c_str(), zs::LabelItemCount(x), x.filament, x.depth, x.origin[0], x.origin[1], x.origin[2], x.normal[0],
                    x.normal[1], x.normal[2], zs::LabelAngle(x), zs::LabelItemCount(x) > 0 ? zs::LabelItemSize(zs::LabelItem(x, 0)) : 0.0,
                    x.id == (uint32_t)l.sel ? ", selected" : "");
        }
        if (l.info != nullptr)
            zs::Log("dev: label info: %s changes %.0f (estimate %.0f), %.0f min, %.1f g, thinnest %.2f\n", InfoFlag(l.info, L"sliced") ? "sliced" : "not sliced",
                    InfoNumber(l.info, L"changes", -1), InfoNumber(l.info, L"estimate_changes", -1), InfoNumber(l.info, L"minutes", -1),
                    InfoNumber(l.info, L"grams", -1), InfoNumber(l.info, L"thinnest", -1));
        return true;
    }
#endif
}
