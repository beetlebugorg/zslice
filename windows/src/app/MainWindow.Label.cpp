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
// The selected label has handles on the surface: a frame, a square at each
// corner (a drag resizes it, Shift frees the aspect), and a round handle
// over it (a drag turns it, Shift gives steps of 15 degrees). They are
// decals in the plane of the label, with sizes in points of the screen. A
// move or a resize snaps to the smart guides of the core (zs_label_face,
// zs_label_snap). Alt moves free. The guides show as thin lines.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <chrono>
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
using Microsoft::UI::Input::InputSystemCursor;
using Microsoft::UI::Input::InputSystemCursorShape;
using Windows::System::VirtualKey;

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);
}

namespace
{
    // The lift of the decal out of the surface, mm (as the core view).
    constexpr double lift = 0.05;
    // The pause after the last change of a label before it goes to the core.
    constexpr int commit_ms = 400;
    // The margin around the box of a label that still hits it, mm.
    constexpr double hit_margin = 1.0;
    // The room around the handles of a label on the screen, points.
    constexpr double handle_room = 8.0;
    // The gap between the card and the edges of the free area, points.
    constexpr double card_margin = 10.0;
    // The colors of the handles and the guides (as the GTK shell).
    constexpr uint32_t handle_accent = 0x2980ffu;
    constexpr uint32_t handle_fill = 0xffffffu;
    constexpr uint32_t guide_color = 0xf2339au;
    // The longest SVG file that the tool reads. The core reads 512 KiB.
    constexpr DWORD svg_file_limit = 1u << 20;
    constexpr double pi = 3.14159265358979323846;

    wchar_t const *const card_markup = LR"xaml(
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="340" Padding="12" Visibility="Collapsed"
        Background="{ThemeResource ZsPopover}" BorderBrush="{ThemeResource ZsPopoverBorder}" BorderThickness="1" CornerRadius="8">
  <!-- A chip that is on has the accent colors of App.xaml, as in the web app. -->
  <Border.Resources>
    <ResourceDictionary>
      <ResourceDictionary.ThemeDictionaries>
        <ResourceDictionary x:Key="Light">
          <SolidColorBrush x:Key="ToggleButtonBackgroundChecked" Color="#1C71D8" />
          <SolidColorBrush x:Key="ToggleButtonBackgroundCheckedPointerOver" Color="#1B66C4" />
          <SolidColorBrush x:Key="ToggleButtonBackgroundCheckedPressed" Color="#185AAD" />
          <SolidColorBrush x:Key="ToggleButtonForegroundChecked" Color="#FFFFFF" />
          <SolidColorBrush x:Key="ToggleButtonForegroundCheckedPointerOver" Color="#FFFFFF" />
          <SolidColorBrush x:Key="ToggleButtonForegroundCheckedPressed" Color="#FFFFFF" />
        </ResourceDictionary>
        <ResourceDictionary x:Key="Dark">
          <SolidColorBrush x:Key="ToggleButtonBackgroundChecked" Color="#1C5FB0" />
          <SolidColorBrush x:Key="ToggleButtonBackgroundCheckedPointerOver" Color="#2468BD" />
          <SolidColorBrush x:Key="ToggleButtonBackgroundCheckedPressed" Color="#18528F" />
          <SolidColorBrush x:Key="ToggleButtonForegroundChecked" Color="#FFFFFF" />
          <SolidColorBrush x:Key="ToggleButtonForegroundCheckedPointerOver" Color="#FFFFFF" />
          <SolidColorBrush x:Key="ToggleButtonForegroundCheckedPressed" Color="#FFFFFF" />
        </ResourceDictionary>
      </ResourceDictionary.ThemeDictionaries>
    </ResourceDictionary>
  </Border.Resources>
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
          <TextBlock x:Name="NoticeText" FontSize="12" Foreground="{ThemeResource ZsWarning}" TextWrapping="WrapWholeWords" />
          <Button x:Name="NoticeAdd" Content="Add a filament"
                  ToolTipService.ToolTip="Add a second filament to the plate, and print the label with it" />
        </StackPanel>
        <TextBlock x:Name="CurveNote" Visibility="Collapsed" FontSize="12" Foreground="{ThemeResource ZsWarning}" TextWrapping="WrapWholeWords" />
        <StackPanel x:Name="Items" Spacing="6" />
        <StackPanel Orientation="Horizontal" Spacing="6">
          <DropDownButton x:Name="AddShape" Content="+ Add a shape…"
                          ToolTipService.ToolTip="Add a shape to this label: it shares the place, the turn, and the filament. Ticks go around the center, under the text.">
            <DropDownButton.Flyout>
              <MenuFlyout x:Name="AddShapeMenu" Placement="BottomEdgeAlignedLeft" />
            </DropDownButton.Flyout>
          </DropDownButton>
          <Button x:Name="PlaceSvg" Content="Place an SVG…"
                  ToolTipService.ToolTip="Put the filled shapes of an SVG file on the label. You can also drop an SVG file on a part." />
        </StackPanel>
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
          <TextBlock Grid.Column="2" Text="°" Foreground="{ThemeResource ZsDim}" VerticalAlignment="Center" />
        </Grid>
        <Grid ColumnSpacing="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
          </Grid.ColumnDefinitions>
          <TextBlock Text="Print" VerticalAlignment="Center" />
          <StackPanel Grid.Column="1" Orientation="Horizontal">
            <ToggleButton x:Name="Mode0" Content="Ink" CornerRadius="6,0,0,6" AllowFocusOnInteraction="False"
                          ToolTipService.ToolTip="Flush with the surface, in the filament of the label" />
            <ToggleButton x:Name="Mode1" Content="Raised" CornerRadius="0" AllowFocusOnInteraction="False"
                          ToolTipService.ToolTip="Out of the surface by the relief" />
            <ToggleButton x:Name="Mode2" Content="Cut in" CornerRadius="0,6,6,0" AllowFocusOnInteraction="False"
                          ToolTipService.ToolTip="Cut into the surface by the relief" />
          </StackPanel>
        </Grid>
        <Grid x:Name="ReliefRow" ColumnSpacing="6" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="116" />
            <ColumnDefinition Width="24" />
          </Grid.ColumnDefinitions>
          <TextBlock Text="Relief" VerticalAlignment="Center" />
          <NumberBox x:Name="Relief" Grid.Column="1" Minimum="0.1" Maximum="10" SmallChange="0.1" SpinButtonPlacementMode="Compact"
                     AutomationProperties.Name="The relief of the label"
                     ToolTipService.ToolTip="The height of a raised label, or the depth of a cut, mm" />
          <TextBlock Grid.Column="2" Text="mm" FontSize="12" Foreground="{ThemeResource ZsDim}" VerticalAlignment="Center" />
        </Grid>
        <TextBlock Text="Filament" FontSize="12" FontWeight="SemiBold" />
        <VariableSizedWrapGrid x:Name="Chips" Orientation="Horizontal" ItemWidth="30" ItemHeight="30" MaximumRowsOrColumns="10" />
        <Grid ColumnSpacing="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*" />
            <ColumnDefinition Width="Auto" />
            <ColumnDefinition Width="88" />
            <ColumnDefinition Width="Auto" />
          </Grid.ColumnDefinitions>
          <TextBlock Text="Depth" VerticalAlignment="Center" />
          <StackPanel Grid.Column="1" Orientation="Horizontal">
            <ToggleButton x:Name="Depth1" Content="1 line" Padding="8,5" CornerRadius="6,0,0,6" AllowFocusOnInteraction="False"
                          ToolTipService.ToolTip="The color is one line deep (the outer wall)" />
            <ToggleButton x:Name="Depth2" Content="2 lines" Padding="8,5" CornerRadius="0,6,6,0" AllowFocusOnInteraction="False"
                          ToolTipService.ToolTip="The color is two lines deep: more color for a light filament over a dark part" />
          </StackPanel>
          <NumberBox x:Name="DepthMm" Grid.Column="2" Minimum="0" Maximum="10" SmallChange="0.01" SpinButtonPlacementMode="Compact"
                     AutomationProperties.Name="The depth of the color"
                     ToolTipService.ToolTip="The depth of the color from the surface, mm (0: one line)" />
          <TextBlock Grid.Column="3" Text="mm" FontSize="12" Foreground="{ThemeResource ZsDim}" VerticalAlignment="Center" />
        </Grid>
        <TextBlock Text="Print" FontSize="12" FontWeight="SemiBold" />
        <StackPanel x:Name="Check" Spacing="4" />
        <StackPanel x:Name="Cost" Spacing="4" />
        <Button x:Name="Delete" Content="Delete the label" Foreground="{ThemeResource ZsError}" Margin="0,4,0,0"
                ToolTipService.ToolTip="Remove the label from the part (Delete)" />
      </StackPanel>
    </ScrollViewer>
  </StackPanel>
</Border>)xaml";

    struct Outline
    {
        std::string key;
        // The items and the stretch of the key. A drag shares the items, so
        // an SVG source is not written to text again at each step.
        JsonNs::JsonArray items{ nullptr };
        bool has_stretch = false;
        double stretch[2] = { 1, 1 };
        std::vector<float> pts;
        std::vector<uint32_t> ends;
        size_t n = 0;
        double box[4] = { 0, 0, 0, 0 };
    };

    bool SameShapes(zs::Label const &a, zs::Label const &b)
    {
        return a.items == b.items && a.has_stretch == b.has_stretch && (!a.has_stretch || (a.stretch[0] == b.stretch[0] && a.stretch[1] == b.stretch[1]));
    }

    // The text of an SVG file, in UTF-8 with or without a mark. A file over
    // the limit gives an empty text, which has no shape.
    bool ReadSvgFile(std::wstring const &path, std::wstring &out)
    {
        out.clear();
        WIN32_FILE_ATTRIBUTE_DATA info{};
        if (!::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info))
            return false;
        if (info.nFileSizeHigh != 0 || info.nFileSizeLow > svg_file_limit)
            return true;
        std::string bytes;
        if (!zs::Model::ReadFile(path, bytes))
            return false;
        if (bytes.rfind("\xEF\xBB\xBF", 0) == 0)
            bytes.erase(0, 3);
        out = zs::ToWide(bytes);
        return true;
    }

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

    TextBlock SmallText(FrameworkElement const &theme, std::wstring const &text, bool dim)
    {
        TextBlock t;
        t.Text(text);
        t.FontSize(12);
        t.TextWrapping(TextWrapping::WrapWholeWords);
        if (dim)
            t.Foreground(winrt::ZSlice::implementation::TokenBrush(theme, L"ZsDim"));
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

    void Fact(FrameworkElement const &theme, Grid const &g, std::wstring const &name, std::wstring const &value, bool warn)
    {
        int row = (int)g.RowDefinitions().Size();
        RowDefinition def;
        def.Height(GridLengthHelper::Auto());
        g.RowDefinitions().Append(def);
        TextBlock k = SmallText(theme, name, true);
        TextBlock v = SmallText(theme, value, false);
        if (warn)
            v.Foreground(winrt::ZSlice::implementation::TokenBrush(theme, L"ZsWarning"));
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
        // A value out of range is refused, and not clamped and saved.
        box.ValidationMode(NumberBoxValidationMode::Disabled);
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
        // What the drag does. A resize: the corner, the box at the press,
        // and the offset from the pointer to the corner. A turn: the center
        // of the label on the screen and in its plane, the angle of the
        // press, the way the label turns on the screen, and its angle.
        enum DragMode { drag_move, drag_resize, drag_turn };
        int drag_mode = drag_move;
        int corner[2] = { 1, 1 };
        double box0[4] = {}, grab[2] = {};
        double turn_c[2] = {}, turn_center[2] = {}, turn_a0 = 0, turn_sign = 1, turn_base = 0;
        // The guide lines of the snap (s0, t0, s1, t1 each), the features of
        // the face and the plane they are of, and the mm in one point of the
        // handles that show.
        std::vector<double> guides;
        std::string face_json;
        int64_t face_index = -1;
        std::chrono::steady_clock::time_point face_time{};
        double face_origin[3] = {}, face_normal[3] = {};
        double handle_mpp = 0;
        bool picking = false;
        // A free line that draws: its item and its points.
        int drawing = -1;
        std::vector<double> drawn;
        Microsoft::UI::Dispatching::DispatcherQueueTimer timer{ nullptr };
        int64_t pending = -1;

        Border card{ nullptr };
        TextBlock title{ nullptr }, notice_text{ nullptr }, curve_note{ nullptr };
        StackPanel notice{ nullptr }, items{ nullptr }, check{ nullptr }, cost{ nullptr };
        Button notice_add{ nullptr };
        ScrollViewer scroll{ nullptr };
        NumberBox turn{ nullptr }, relief{ nullptr }, depth_mm{ nullptr };
        Grid relief_row{ nullptr };
        Primitives::ToggleButton depth1{ nullptr }, depth2{ nullptr };
        Primitives::ToggleButton mode_buttons[zs::label_mode_count]{ nullptr, nullptr, nullptr };
        VariableSizedWrapGrid chips{ nullptr };
        std::vector<InputField> inputs;
        std::string key, chips_key;
        bool updating = false, card_queued = false, focus_text = false, card_moved = false;
        double last_box[4] = { 0, 0, 0, 0 }, last_height = 0;
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
            auto found = outlines.find(l.id);
            auto same = [&](Outline const &o) {
                return o.items != nullptr && o.items == l.items && o.has_stretch == l.has_stretch &&
                       (!l.has_stretch || (o.stretch[0] == l.stretch[0] && o.stretch[1] == l.stretch[1]));
            };
            if (found != outlines.end() && same(found->second))
                return &found->second;
            auto keep = [&](Outline &o) {
                o.items = l.items;
                o.has_stretch = l.has_stretch;
                o.stretch[0] = l.stretch[0];
                o.stretch[1] = l.stretch[1];
            };
            std::string shapes = zs::LabelJson(l, true);
            if (found != outlines.end() && found->second.key == shapes)
            {
                keep(found->second);
                return &found->second;
            }
            auto made = OutlineOfJson(shapes);
            if (!made.has_value())
                return found != outlines.end() ? &found->second : nullptr;
            auto &slot = outlines[l.id];
            slot = std::move(*made);
            keep(slot);
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
                if (zs::Label *s = Selected())
                    DrawHandles(*s);
            }
            w.RequestDraw();
        }

        // ---- the handles and the smart guides ----

        // The mm of the plane of label l in one point of the view, at its
        // center.
        double MmPerPoint(zs::Label const &l)
        {
            Outline *o = OutlineFor(l);
            if (o == nullptr)
                return 0.1;
            double cx = (o->box[0] + o->box[2]) / 2, cy = (o->box[1] + o->box[3]) / 2, p0[2], pr[2], pu[2];
            if (!ScreenOf(l, cx, cy, p0) || !ScreenOf(l, cx + 1, cy, pr) || !ScreenOf(l, cx, cy + 1, pu))
                return 0.1;
            double d = std::max(std::hypot(pr[0] - p0[0], pr[1] - p0[1]), std::hypot(pu[0] - p0[0], pu[1] - p0[1]));
            return d > 1e-6 ? 1 / d : 0.1;
        }

        bool HandlesOf(zs::Label const &l, zs::LabelHandles &g)
        {
            Outline *o = OutlineFor(l);
            if (o == nullptr)
                return false;
            zs::LabelHandlesOf(o->box, MmPerPoint(l), g);
            return true;
        }

        // The handle of the selected label at x, y: as LabelHandleHit.
        int HandleAt(double x, double y, int out[2])
        {
            zs::Label *l = Selected();
            zs::LabelHandles g;
            float r[6];
            double o[3], d[3], p[3], px, py;
            if (l == nullptr || !Live() || !HandlesOf(*l, g) || !Ray(x, y, r, o, d) || !zs::LabelPlaneHit(*l, o, d, p, &px, &py))
                return 0;
            return zs::LabelHandleHit(g, px, py, out);
        }

        // A decal of polygons (x, y pairs) in the plane of l.
        void AddDecal(zs::Label const &l, float const *pts, uint32_t const *ends, size_t n, uint32_t rgb, int edge)
        {
            double frame[9];
            std::copy_n(l.origin, 3, frame);
            std::copy_n(l.normal, 3, frame + 3);
            std::copy_n(l.right, 3, frame + 6);
            zs_view_label_add(w.view, frame, pts, ends, n, rgb, edge);
        }

        void AddRect(zs::Label const &l, double x0, double y0, double x1, double y1, uint32_t rgb, int edge)
        {
            float const pts[8] = { (float)x0, (float)y0, (float)x1, (float)y0, (float)x1, (float)y1, (float)x0, (float)y1 };
            uint32_t const ends[1] = { 4 };
            AddDecal(l, pts, ends, 1, rgb, edge);
        }

        // The decals of the handles and the guides of the selected label.
        void DrawHandles(zs::Label const &l)
        {
            double mpp = MmPerPoint(l);
            handle_mpp = mpp;
            Outline *o = OutlineFor(l);
            if (o == nullptr)
                return;
            zs::LabelHandles g;
            zs::LabelHandlesOf(o->box, mpp, g);
            double const lw = 1.5 * mpp;
            double const *b = g.box;
            // The frame: a ring of the width of a line. The inner path turns
            // the other way, so it is a hole.
            float const ring[16] = {
                (float)(b[0] - lw / 2), (float)(b[1] - lw / 2), (float)(b[2] + lw / 2), (float)(b[1] - lw / 2),
                (float)(b[2] + lw / 2), (float)(b[3] + lw / 2), (float)(b[0] - lw / 2), (float)(b[3] + lw / 2),
                (float)(b[0] + lw / 2), (float)(b[1] + lw / 2), (float)(b[0] + lw / 2), (float)(b[3] - lw / 2),
                (float)(b[2] - lw / 2), (float)(b[3] - lw / 2), (float)(b[2] - lw / 2), (float)(b[1] + lw / 2),
            };
            uint32_t const ring_ends[2] = { 4, 8 };
            AddDecal(l, ring, ring_ends, 2, handle_accent, 0);
            // The stem and the turn handle.
            double mx = (b[0] + b[2]) / 2;
            AddRect(l, mx - lw / 2, b[3], mx + lw / 2, g.turn[1] - g.r, handle_accent, 0);
            float circle[48];
            for (int k = 0; k < 24; k++)
            {
                circle[2 * k] = (float)(g.turn[0] + g.r * std::cos(2 * pi * k / 24));
                circle[2 * k + 1] = (float)(g.turn[1] + g.r * std::sin(2 * pi * k / 24));
            }
            uint32_t const circle_end[1] = { 24 };
            AddDecal(l, circle, circle_end, 1, handle_fill, 1);
            // The corners.
            for (int k = 0; k < 4; k++)
            {
                double x = (k == 1 || k == 2) ? b[2] : b[0], y = k >= 2 ? b[3] : b[1];
                AddRect(l, x - g.hs, y - g.hs, x + g.hs, y + g.hs, handle_fill, 1);
            }
            // The guides: thin rectangles along each line.
            double const gw = 1.2 * mpp;
            for (size_t i = 0; i + 3 < guides.size(); i += 4)
            {
                double const *s = &guides[i];
                double dx = s[2] - s[0], dy = s[3] - s[1], len = std::hypot(dx, dy);
                if (!(len > 1e-9))
                    continue;
                double nx = -dy / len * gw / 2, ny = dx / len * gw / 2;
                float const pts[8] = { (float)(s[0] - nx), (float)(s[1] - ny), (float)(s[2] - nx), (float)(s[3] - ny),
                                       (float)(s[2] + nx), (float)(s[3] + ny), (float)(s[0] + nx), (float)(s[1] + ny) };
                uint32_t const ends[1] = { 4 };
                AddDecal(l, pts, ends, 1, guide_color, 0);
            }
        }

        // The features of the face under label l (zs_label_face), kept while
        // the label stays in its plane. Null with no face or no mesh.
        std::string const *FaceAt(zs::Label const &l)
        {
            zs_paint *s = Session(index);
            if (s == nullptr)
                return nullptr;
            if (face_index == index && zs::LabelSamePlane(face_origin, face_normal, l))
                return face_json.empty() ? nullptr : &face_json;
            // A curved face changes the plane at each step: a new face at
            // most each 150 ms there.
            auto now = std::chrono::steady_clock::now();
            if (face_index == index && now - face_time < std::chrono::milliseconds(150))
                return nullptr;
            double frame[9];
            std::copy_n(l.origin, 3, frame);
            std::copy_n(l.normal, 3, frame + 3);
            std::copy_n(l.right, 3, frame + 6);
            face_json.clear();
            size_t len = 0;
            if (zs_label_face(s, frame, nullptr, 0, &len) == ZS_OK)
            {
                std::string text(len + 1, '\0');
                if (zs_label_face(s, frame, text.data(), text.size(), nullptr) == ZS_OK)
                {
                    text.resize(len);
                    if (text != "null")
                        face_json = std::move(text);
                }
            }
            face_index = index;
            face_time = now;
            std::copy_n(l.origin, 3, face_origin);
            std::copy_n(l.normal, 3, face_normal);
            return face_json.empty() ? nullptr : &face_json;
        }

        // The snap of a box of label l (zs_label_snap): out_box gets the
        // box, d the move, and guides the lines. False: no snap.
        bool SnapBox(zs::Label const &l, double const box[4], char const *op, int const *at_corner, bool aspect, double out_box[4], double d[2])
        {
            std::vector<zs::LabelSnapOther> others;
            for (auto const &x : labels)
            {
                if (x.id == l.id)
                    continue;
                Outline *o = OutlineFor(x);
                if (o == nullptr || o->n == 0)
                    continue;
                zs::LabelSnapOther other{ &x, {} };
                std::copy_n(o->box, 4, other.box);
                others.push_back(other);
            }
            std::string const *face = FaceAt(l);
            std::string json = zs::LabelSnapJson(l, box, op, at_corner, aspect, zs::label_snap_px * MmPerPoint(l), others, face);
            guides.clear();
            size_t len = 0;
            if (zs_label_snap(json.data(), json.size(), nullptr, 0, &len) != ZS_OK)
                return false;
            std::string text(len + 1, '\0');
            if (zs_label_snap(json.data(), json.size(), text.data(), text.size(), nullptr) != ZS_OK)
                return false;
            text.resize(len);
            return zs::LabelSnapParse(text, out_box, d, guides);
        }

        // The shape of the pointer over the view.
        int CursorAt(double x, double y)
        {
            int at[2];
            int h = drawing < 0 ? HandleAt(x, y, at) : 0;
            if (h == 1)
                return (int)(at[0] == at[1] ? InputSystemCursorShape::SizeNortheastSouthwest : InputSystemCursorShape::SizeNorthwestSoutheast);
            if (h == 2 || (drawing < 0 && LabelAt(x, y, nullptr, nullptr) != nullptr))
                return (int)InputSystemCursorShape::Hand;
            return (int)InputSystemCursorShape::Cross;
        }

        // The Support tool sets the same cursor of the panel, so this reads
        // the shape that the panel has.
        void SetCursor(int shape)
        {
            auto panel = w.ViewPanel().try_as<IUIElementProtected>();
            if (panel == nullptr)
                return;
            auto now = panel.ProtectedCursor().try_as<InputSystemCursor>();
            if ((now != nullptr ? (int)now.CursorShape() : -1) == shape)
                return;
            if (shape < 0)
                panel.ProtectedCursor(nullptr);
            else
                panel.ProtectedCursor(InputSystemCursor::Create(static_cast<InputSystemCursorShape>(shape)));
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

        // The box of the selected label on the screen, with its handles.
        bool ScreenBox(double box[4])
        {
            zs::Label *l = Selected();
            zs::LabelHandles g;
            if (l == nullptr || !HandlesOf(*l, g))
                return false;
            box[0] = box[1] = INFINITY;
            box[2] = box[3] = -INFINITY;
            double const pts[5][2] = { { g.box[0], g.box[1] }, { g.box[2], g.box[1] }, { g.box[2], g.box[3] }, { g.box[0], g.box[3] }, { g.turn[0], g.turn[1] + g.r } };
            for (int k = 0; k < 5; k++)
            {
                double q[2];
                if (!ScreenOf(*l, pts[k][0], pts[k][1], q))
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
            if (!on || dragging || w.model == nullptr)
                return;
            w.meshes.CheckAll();
            // The mesh can be another one: the next snap reads its face.
            face_index = -1;
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
                guides.clear();
                ShowCard();
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
            // A move or a turn shares the items: its shapes are the same.
            if (!SameShapes(*l, next))
            {
                std::string a = zs::LabelJson(*l, true), b = zs::LabelJson(next, true);
                if (a != b && !OutlineOfJson(b).has_value())
                    return false;
            }
            next.id = l->id;
            *l = std::move(next);
            Redraw();
            ShowCard();
            timer.Stop();
            pending = l->id;
            // A drag sends the label at its end (one step of the history).
            if (commit)
                Flush();
            else if (!dragging)
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

        void SetMode(int mode)
        {
            int next = std::clamp(mode, 0, zs::label_mode_count - 1);
            zs::Label *now = Selected();
            if (now != nullptr && now->mode == next)
            {
                ShowCard();
                return;
            }
            auto c = EditCopy();
            if (!c.has_value())
                return;
            c->mode = next;
            if (next != zs::label_ink && !(c->relief > 0))
                c->relief = zs::label_default_relief;
            Change(std::move(*c), true);
        }

        void SetRelief(double mm)
        {
            double next = std::clamp(mm, 0.0, 10.0);
            zs::Label *now = Selected();
            if (now != nullptr && now->relief == next)
            {
                ShowCard();
                return;
            }
            auto c = EditCopy();
            if (!c.has_value())
                return;
            c->relief = next;
            Change(std::move(*c), true);
        }

        // ---- SVG pictures ----

        // An SVG source has a shape that the core reads.
        static bool SvgOk(std::wstring const &svg)
        {
            zs::Label l;
            l.items.Append(zs::LabelSvgItem(svg));
            auto o = OutlineOfJson(zs::LabelJson(l, true));
            return o.has_value() && o->n > 0;
        }

        bool PlaceSvg(std::wstring const &svg, std::wstring const &path)
        {
            if (!SvgOk(svg))
            {
                w.ShowToast(L"The SVG has no filled shape to place.");
                return false;
            }
            zs::Label *l = Selected();
            Outline *o = l != nullptr ? OutlineFor(*l) : nullptr;
            auto c = EditCopy();
            if (!c.has_value())
                return false;
            bool fresh = c->name.empty();
            zs::LabelAddSvg(*c, svg, o != nullptr ? o->box : nullptr);
            if (fresh && zs::LabelItemCount(*c) == 1)
                c->name = zs::LabelSvgName(path);
            bool ok = Change(std::move(*c), true);
            ShowCard();
            return ok;
        }

        void PlaceSvgFile(std::wstring const &path)
        {
            std::wstring svg;
            if (ReadSvgFile(path, svg))
                PlaceSvg(svg, path);
        }

        // "Place an SVG…": a file dialog for an SVG file.
        void PickSvg()
        {
            if (picking)
                return;
            picking = true;
            std::wstring path;
            com_ptr<IFileOpenDialog> dialog;
            if (SUCCEEDED(::CoCreateInstance(__uuidof(FileOpenDialog), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(dialog.put()))))
            {
                COMDLG_FILTERSPEC filter{ L"SVG pictures", L"*.svg" };
                dialog->SetFileTypes(1, &filter);
                dialog->SetTitle(L"Place an SVG");
                DWORD options = 0;
                if (SUCCEEDED(dialog->GetOptions(&options)))
                    dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST);
                com_ptr<IShellItem> item;
                if (SUCCEEDED(dialog->Show(w.hwnd)) && SUCCEEDED(dialog->GetResult(item.put())))
                {
                    PWSTR name = nullptr;
                    if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &name)))
                    {
                        path = name;
                        ::CoTaskMemFree(name);
                    }
                }
            }
            picking = false;
            if (!path.empty())
                PlaceSvgFile(path);
        }

        // The 3D view is the top element at x, y (points of the view): no
        // card or pane covers it there.
        bool OverView(double x, double y)
        {
            auto at = w.ViewPanel().TransformToVisual(w.Root()).TransformPoint({ (float)x, (float)y });
            for (auto const &element : Media::VisualTreeHelper::FindElementsInHostCoordinates(at, w.Root()))
                return element == w.ViewPanel();
            return false;
        }

        // An SVG file dropped at x, y: a new label of it on the part there.
        void DropSvg(std::wstring const &svg, std::wstring const &path, double x, double y, bool over_view)
        {
            if (!SvgOk(svg))
            {
                w.ShowToast(L"The SVG has no filled shape to place.");
                return;
            }
            if (w.model == nullptr || w.view == nullptr)
            {
                w.ShowToast(L"Drop the SVG on a part.");
                return;
            }
            if (w.tool != Tool::Label)
                w.SetTool(Tool::Label);
            int64_t part = over_view ? w.PartAt(x, y, nullptr, nullptr) : -1;
            if (part < 0)
            {
                w.ShowToast(L"Drop the SVG on a part.");
                return;
            }
            if (part != index)
                Load(part, -1);
            double at[10];
            if (!PlaceAt(part, x, y, at))
            {
                w.ShowToast(L"Drop the SVG on a face of the part.");
                return;
            }
            zs::Label l;
            std::copy_n(at, 3, l.origin);
            std::copy_n(at + 3, 3, l.normal);
            std::copy_n(at + 6, 3, l.right);
            l.filament = zs::LabelNextFilament(base, (int)zs_app_filament_count(w.model->Active()));
            l.name = zs::LabelSvgName(path);
            // The picture is centered on the point of the drop, as in the
            // web app.
            l.items.Append(zs::LabelSvgItem(svg));
            std::string json = zs::LabelJson(l, false);
            Flush();
            uint32_t id = 0;
            if (zs_app_label_add(w.model->Active(), (size_t)part, json.data(), json.size(), &id) != ZS_OK)
            {
                w.ShowToast(L"The SVG does not fit here.");
                return;
            }
            LabelsChanged();
            curve = at[9];
            Load(part, id);
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

        // ---- copy and paste (MainWindow.ContextMenu.cpp) ----

        std::string CopyJson()
        {
            if (Selected() == nullptr)
                return {};
            Flush();
            zs::Label *l = Selected();
            return l != nullptr ? zs::LabelJson(*l, false) : std::string{};
        }

        // On the face under the pointer with the same turn. Else under the
        // label of the copy (its height and 1 mm lower), or over it, on the
        // surface again. Only a face over the bed takes it.
        bool Paste(std::string const &json, bool at_point, double x, double y)
        {
            std::vector<zs::Label> list;
            if (json.empty() || !zs::LabelsParse(json, list) || list.empty())
                return false;
            zs::Label l = list[0];
            if (w.tool != Tool::Label)
                w.SetTool(Tool::Label);
            zs_app *app = w.model->Active();
            int64_t target = index;
            double at[10];
            bool placed = false;
            if (at_point)
            {
                int64_t hit = w.PartAt(x, y, nullptr, nullptr);
                if (hit >= 0)
                {
                    target = hit;
                    placed = PlaceAt(hit, x, y, at);
                }
            }
            if (target < 0 || (size_t)target >= zs_app_part_count(app))
            {
                w.ShowToast(L"Point at a part to paste the label there.");
                return false;
            }
            if (target != index)
                Load(target, -1);
            if (placed)
            {
                double degrees = zs::LabelAngle(l);
                std::copy_n(at, 3, l.origin);
                std::copy_n(at + 3, 3, l.normal);
                std::copy_n(at + 6, 3, l.right);
                zs::LabelSetAngle(l, degrees);
                curve = at[9];
            }
            else
            {
                auto shape = OutlineOfJson(zs::LabelJson(l, true));
                double height = shape.has_value() ? shape->box[3] - shape->box[1] : 5;
                double up[3];
                zs::LabelUp(l, up);
                zs_paint *session = Session(target);
                bool found = false;
                for (int side = 0; side < 2 && !found && session != nullptr; side++)
                {
                    double k = side == 0 ? -(height + 1) : height + 1;
                    double start[3], from[3];
                    for (int i = 0; i < 3; i++)
                    {
                        start[i] = l.origin[i] + up[i] * k;
                        from[i] = start[i] + 5 * l.normal[i];
                    }
                    float ray[6] = { (float)from[0], (float)from[1], (float)from[2], (float)-l.normal[0], (float)-l.normal[1], (float)-l.normal[2] };
                    double out[10];
                    if (zs_label_place(session, ray, 5, out) == 1 && out[2] >= 0)
                    {
                        std::copy_n(start, 3, l.origin);
                        zs::LabelMove(l, out, out + 3);
                        found = true;
                    }
                }
                if (!found)
                {
                    w.ShowToast(L"The label does not fit here. Point at a face of the part, then paste.");
                    return false;
                }
            }
            std::string text = zs::LabelJson(l, false);
            Flush();
            uint32_t id = 0;
            if (zs_app_label_add(app, (size_t)target, text.data(), text.size(), &id) != ZS_OK)
            {
                w.ShowToast(L"The label does not fit here.");
                return false;
            }
            LabelsChanged();
            Load(target, id);
            return true;
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

        // A press on a handle of the selected label: a resize or a turn.
        bool PressHandle(double x, double y)
        {
            int at[2];
            int h = HandleAt(x, y, at);
            zs::Label *l = Selected();
            Outline *o = l != nullptr ? OutlineFor(*l) : nullptr;
            if (h == 0 || o == nullptr)
                return false;
            Flush();
            l = Selected();
            o = l != nullptr ? OutlineFor(*l) : nullptr;
            if (o == nullptr)
                return false;
            dragging = true;
            moved = false;
            drag_id = l->id;
            press_x = x;
            press_y = y;
            drag_start = *l;
            std::copy_n(o->box, 4, box0);
            Session(index);
            if (h == 1)
            {
                drag_mode = drag_resize;
                corner[0] = at[0];
                corner[1] = at[1];
                // The first move of the drag starts at a scale of 1, with
                // no jump: the handle is on the frame, outside the box.
                grab[0] = grab[1] = 0;
                float r[6];
                double ro[3], rd[3], rp[3], hx, hy;
                if (Ray(x, y, r, ro, rd) && zs::LabelPlaneHit(*l, ro, rd, rp, &hx, &hy))
                {
                    grab[0] = hx - (at[0] > 0 ? o->box[2] : o->box[0]);
                    grab[1] = hy - (at[1] > 0 ? o->box[3] : o->box[1]);
                }
                return true;
            }
            drag_mode = drag_turn;
            double cx = (o->box[0] + o->box[2]) / 2, cy = (o->box[1] + o->box[3]) / 2, p0[2], pr[2], pu[2];
            if (!ScreenOf(*l, cx, cy, p0))
            {
                dragging = false;
                drag_start.reset();
                return false;
            }
            // The way the label turns on the screen: its right and up axes
            // as the screen shows them.
            double cr = ScreenOf(*l, cx + 1, cy, pr) && ScreenOf(*l, cx, cy + 1, pu) ? (pr[0] - p0[0]) * (pu[1] - p0[1]) - (pr[1] - p0[1]) * (pu[0] - p0[0]) : -1;
            turn_c[0] = p0[0];
            turn_c[1] = p0[1];
            turn_center[0] = cx;
            turn_center[1] = cy;
            turn_a0 = std::atan2(y - p0[1], x - p0[0]);
            turn_sign = cr < 0 ? -1 : 1;
            turn_base = zs::LabelAngle(*l);
            return true;
        }

        bool Press(double x, double y)
        {
            if (!Live() || drawing >= 0)
                return false;
            if (PressHandle(x, y))
            {
                SetCursor((int)InputSystemCursorShape::SizeAll);
                return true;
            }
            drag_mode = drag_move;
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
            SetCursor((int)InputSystemCursorShape::SizeAll);
            return true;
        }

        // The snap of the label c that moves (free: none). Its origin moves
        // to the guides.
        void SnapMove(zs::Label &c, bool free)
        {
            guides.clear();
            Outline *o = OutlineFor(c);
            double box[4], d[2], up[3];
            if (free || o == nullptr || !SnapBox(c, o->box, "move", nullptr, true, box, d))
                return;
            zs::LabelUp(c, up);
            for (int k = 0; k < 3; k++)
                c.origin[k] += d[0] * c.right[k] + d[1] * up[k];
        }

        // The selected label under the pointer while it drags: on the
        // surface, or in its plane with Shift. It snaps to the guides (Alt:
        // free). The copy shares the items, because the shapes stay.
        void MoveTo(double x, double y, bool keep_plane, bool free)
        {
            zs::Label *now = Selected();
            if (!drag_start.has_value() || now == nullptr)
                return;
            zs::Label const &s = *drag_start;
            if (keep_plane)
            {
                float r[6];
                double o[3], d[3], p[3], hx, hy, up[3];
                if (!Ray(x, y, r, o, d) || !zs::LabelPlaneHit(s, o, d, p, &hx, &hy))
                    return;
                zs::LabelUp(s, up);
                zs::Label c = *now;
                for (int k = 0; k < 3; k++)
                {
                    c.origin[k] = p[k] - drag_dx * s.right[k] - drag_dy * up[k];
                    c.normal[k] = s.normal[k];
                    c.right[k] = s.right[k];
                }
                SnapMove(c, free);
                Change(std::move(c), false);
                return;
            }
            double at[10];
            if (!PlaceAt(index, x, y, at))
                return;
            zs::Label c = *now;
            zs::LabelMove(c, at, at + 3);
            double up[3];
            zs::LabelUp(c, up);
            for (int k = 0; k < 3; k++)
                c.origin[k] -= drag_dx * c.right[k] + drag_dy * up[k];
            SnapMove(c, free);
            Change(std::move(c), false);
            if (std::abs(at[9] - curve) > 1e-6)
            {
                curve = at[9];
                curve_note.Visibility(curve > zs::label_curve_limit ? Visibility::Visible : Visibility::Collapsed);
            }
        }

        // A corner handle under the pointer: the opposite corner stays.
        // Shift: each axis on its own. It snaps to the guides (Alt: free).
        void ResizeTo(double x, double y, bool free_aspect, bool free)
        {
            if (!drag_start.has_value())
                return;
            zs::Label const &s = *drag_start;
            float r[6];
            double o[3], d[3], p[3], hp[2];
            if (!Ray(x, y, r, o, d) || !zs::LabelPlaneHit(s, o, d, p, &hp[0], &hp[1]))
                return;
            double box[4], anchor[2], k[2], snapped[4], dd[2];
            hp[0] -= grab[0];
            hp[1] -= grab[1];
            zs::LabelResizeBox(box0, corner, hp, free_aspect, box, anchor, k);
            guides.clear();
            if (!free && SnapBox(s, box, "resize", corner, !free_aspect, snapped, dd))
            {
                k[0] = (snapped[2] - snapped[0]) / std::max(1e-12, box0[2] - box0[0]);
                k[1] = free_aspect ? (snapped[3] - snapped[1]) / std::max(1e-12, box0[3] - box0[1]) : k[0];
            }
            zs::Label c = s;
            zs::LabelOwnItems(c);
            zs::LabelResize(c, anchor, k, free_aspect);
            Change(std::move(c), false);
        }

        // The turn handle under the pointer: the label turns about the
        // center of its box. Shift: steps of 15 degrees.
        void TurnTo(double x, double y, bool steps)
        {
            if (!drag_start.has_value())
                return;
            zs::Label const &s = *drag_start;
            double deg = turn_sign * (std::atan2(y - turn_c[1], x - turn_c[0]) - turn_a0) * 180 / pi;
            if (steps)
                deg = std::round((turn_base + deg) / 15) * 15 - turn_base;
            zs::Label c = s;
            zs::LabelTurnAbout(c, deg, turn_center);
            Change(std::move(c), false);
        }

        void Drag(double x, double y, bool shift)
        {
            if (!dragging)
                return;
            if (!moved && std::hypot(x - press_x, y - press_y) < 3)
                return;
            moved = true;
            bool alt = w.pointer_alt;
            if (drag_mode == drag_resize)
                ResizeTo(x, y, shift, alt);
            else if (drag_mode == drag_turn)
                TurnTo(x, y, shift);
            else
                MoveTo(x, y, shift, alt);
        }

        void Release()
        {
            if (!dragging)
                return;
            dragging = false;
            drag_start.reset();
            guides.clear();
            Redraw();
            if (moved)
                Flush();
            moved = false;
            if (on)
                SetCursor(CursorAt(w.pointer_x, w.pointer_y));
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
            // A click on a handle is a drag that did not move, as in the
            // web app.
            int at_corner[2];
            if (HandleAt(x, y, at_corner) != 0)
                return;
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

        // After each frame: the handles keep their size on the screen (a
        // zoom draws them again), and the card goes beside the label.
        void Place()
        {
            zs::Label *l = on && sel >= 0 ? Selected() : nullptr;
            if (l != nullptr && handle_mpp > 0 && std::abs(MmPerPoint(*l) - handle_mpp) > 0.08 * handle_mpp)
                Redraw();
            if (l == nullptr || card.Visibility() != Visibility::Visible)
                return;
            // The body scrolls in a short view: the card ends over the
            // bottom bar.
            double floor = w.Dock().TransformToVisual(w.CardLayer()).TransformPoint({ 0, 0 }).Y;
            double frame = card.ActualHeight() > 0 ? card.ActualHeight() - scroll.ActualHeight() : 70;
            double room = std::max(160.0, floor - 2 * card_margin - frame);
            if (std::abs(scroll.MaxHeight() - room) > 0.5)
                scroll.MaxHeight(room);
            if (card_moved)
                return;
            double box[4];
            if (!ScreenBox(box))
                return;
            card.UpdateLayout();
            double height = card.ActualHeight();
            bool same = has_last_box && std::abs(height - last_height) < 0.5;
            for (int k = 0; same && k < 4; k++)
                same = std::abs(box[k] - last_box[k]) < 0.5;
            if (same)
                return;
            std::copy_n(box, 4, last_box);
            last_height = height;
            has_last_box = true;
            w.PlaceCard(card, box);
            double top = Canvas::GetTop(card), lowest = std::max(card_margin, floor - card_margin - height);
            if (top > lowest)
                Canvas::SetTop(card, lowest);
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
            if (field == "relief")
                return l.relief > 0 ? l.relief : zs::label_default_relief;
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
            else if (field == "relief")
                SetRelief(v);
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

        // A typed number that leaves its field after another label was
        // picked is for the label that it was typed for.
        int64_t edit_label = -1;

        void WatchEdit(NumberBox const &box)
        {
            box.GotFocus([this](auto &&, auto &&) {
                zs::Label *now = Selected();
                edit_label = now != nullptr ? (int64_t)now->id : -1;
            });
            // After the commit that the field makes when it loses the focus.
            box.LostFocus([this](auto &&, auto &&) {
                auto weak = w.get_weak();
                w.queue.TryEnqueue([weak, this] {
                    if (auto self = weak.get())
                        edit_label = -1;
                });
            });
        }

        void OnNumberBox(NumberBox const &box, int item, std::string const &field, double v, double tolerance)
        {
            if (updating)
                return;
            zs::Label *current = Selected();
            if (current == nullptr || (edit_label >= 0 && (int64_t)current->id != edit_label))
                return;
            if (std::isnan(v) || v < box.Minimum() || v > box.Maximum())
            {
                if (!std::isnan(v))
                    w.ShowToast(L"Use " + Format(L"%g", box.Minimum()) + L" to " + Format(L"%g", box.Maximum()) + L".");
                // The field shows the value of the label again.
                updating = true;
                box.Value(InputValue(*current, item, field));
                updating = false;
                return;
            }
            OnNumber(item, field, v, tolerance);
        }

        NumberBox NumberField(double value, double min, double max, double step, int item, std::string const &field, std::wstring const &tip)
        {
            NumberBox box = MakeNumber(value, min, max, step);
            if (!tip.empty())
                ToolTipService::SetToolTip(box, box_value(tip));
            AddInput(box, item, field);
            double tolerance = (step >= 1 ? 0.1 : step >= 0.1 ? 0.01 : 0.001) / 2;
            WatchEdit(box);
            box.ValueChanged([this, item, field, tolerance](NumberBox const &sender, NumberBoxValueChangedEventArgs const &e) {
                OnNumberBox(sender, item, field, e.NewValue(), tolerance);
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
            auto add_chip = [&](wchar_t const *text, int32_t column) {
                ColumnDefinition c;
                c.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                row.ColumnDefinitions().Append(c);
                Primitives::ToggleButton b;
                b.Content(box_value(text));
                b.FontSize(12);
                b.Padding(ThicknessHelper::FromLengths(2, 3, 2, 3));
                b.MinWidth(0);
                b.HorizontalAlignment(HorizontalAlignment::Stretch);
                b.AllowFocusOnInteraction(false);
                Automation::AutomationProperties::SetName(b, text);
                Grid::SetColumn(b, column);
                row.Children().Append(b);
                return b;
            };
            // An SVG picture: its chip, and the chips to make it another
            // shape.
            int32_t first_chip = 0;
            if (kind == "svg")
            {
                Primitives::ToggleButton b = add_chip(L"SVG", 0);
                b.IsChecked(true);
                ToolTipService::SetToolTip(b, box_value(L"An SVG picture"));
                b.Click([](IInspectable const &sender, auto &&) { sender.as<Primitives::ToggleButton>().IsChecked(true); });
                first_chip = 1;
            }
            for (size_t k = 0; k < zs::label_kind_count; k++)
            {
                Primitives::ToggleButton b = add_chip(zs::label_kind_names[k], first_chip + (int32_t)k);
                b.IsChecked(kind == zs::label_kinds[k]);
                std::wstring tip = std::strcmp(zs::label_kinds[k], "polyline") == 0
                                       ? std::wstring(L"A free line: click points on the face")
                                       : L"Make this shape a " + zs::ToWide(zs::label_kinds[k]);
                ToolTipService::SetToolTip(b, box_value(tip));
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
                auto shown = std::make_shared<std::wstring>(t.Text());
                t.TextChanged([this, i, shown](IInspectable const &sender, auto &&) {
                    zs::Label *now = Selected();
                    std::wstring value{ sender.as<TextBox>().Text() };
                    if (value == *shown)
                        return;
                    *shown = value;
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
                TextBlock unit = SmallText(w.Root(), f[k].unit, true);
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
                    box.Children().Append(SmallText(w.Root(), L"Click points on the face. Click Done at the end.", true));
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
            TextBlock mm = SmallText(w.Root(), L"mm", true);
            mm.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(mm, 3);
            at.Children().Append(mm);
            box.Children().Append(at);
            return box;
        }

        void BuildItems(zs::Label const &l)
        {
            // The inputs of the items go. Turn, relief, and depth stay (the
            // first three).
            inputs.resize(std::min<size_t>(inputs.size(), 3));
            items.Children().Clear();
            for (size_t i = 0; i < zs::LabelItemCount(l); i++)
            {
                if (i > 0)
                {
                    Border rule;
                    rule.Height(1);
                    rule.Background(TokenBrush(w.Root(), L"ZsLine"));
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
            // An ink label in the filament of the part does not show.
            bool same = l.filament == base && l.mode == zs::label_ink;
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
            for (int k = 0; k < zs::label_mode_count; k++)
                mode_buttons[k].IsChecked(l.mode == k);
            relief_row.Visibility(l.mode != zs::label_ink ? Visibility::Visible : Visibility::Collapsed);
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
                Fact(w.Root(), stats, L"Thinnest stroke", Format(L"%.2f mm", InfoNumber(info, L"thinnest")), InfoNumber(info, L"thinnest") < 2 * lw);
            if (InfoNumber(info, L"clean_size") > 0)
            {
                wchar_t text[96];
                swprintf_s(text, L"clean from %.1f mm, fair from %.1f mm", InfoNumber(info, L"clean_size"), InfoNumber(info, L"fair_size"));
                Fact(w.Root(), stats, L"Text size", text, false);
            }
            check.Children().Append(stats);
            std::wstring advice = InfoText(info, L"advice");
            if (!advice.empty())
                check.Children().Append(SmallText(w.Root(), advice, false));
            if (InfoFlag(info, L"same_filament"))
                return;
            bool sliced = InfoFlag(info, L"sliced");
            int n = (int)std::lround(InfoNumber(info, sliced ? L"changes" : L"estimate_changes"));
            Grid facts = FactsGrid();
            Fact(w.Root(), facts, sliced ? L"Adds" : L"Adds about", std::to_wstring(n) + (n == 1 ? L" filament change" : L" filament changes"), false);
            Fact(w.Root(), facts, L"Time", std::to_wstring(std::lround(InfoNumber(info, L"minutes"))) + L" min", false);
            Fact(w.Root(), facts, L"Flush", Format(L"%.1f g", InfoNumber(info, L"grams")), false);
            if (InfoNumber(info, L"layers") > 0)
            {
                wchar_t text[64];
                swprintf_s(text, L"%ld (%.1f to %.1f mm)", std::lround(InfoNumber(info, L"layers")), InfoNumber(info, L"z_min"), InfoNumber(info, L"z_max"));
                Fact(w.Root(), facts, L"Layers", text, false);
            }
            cost.Children().Append(facts);
            if (!sliced)
                cost.Children().Append(SmallText(w.Root(), L"An estimate. The slice gives the count.", true));
            int top = (int)std::lround(InfoNumber(info, L"top_changes", -1));
            if (InfoText(info, L"kind") == L"side" && n > 10 && top >= 0)
                cost.Children().Append(SmallText(w.Root(), L"On the top face, this label costs " + std::to_wstring(top) + (top == 1 ? L" change." : L" changes."), false));
        }

        void CloseTool()
        {
            Flush();
            Release();
            w.meshes.CheckAll();
            labels.clear();
            outlines.clear();
            guides.clear();
            face_index = -1;
            handle_mpp = 0;
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
        l.relief = find(L"Relief").as<NumberBox>();
        l.relief_row = find(L"ReliefRow").as<Grid>();
        l.depth_mm = find(L"DepthMm").as<NumberBox>();
        l.depth1 = find(L"Depth1").as<Primitives::ToggleButton>();
        l.depth2 = find(L"Depth2").as<Primitives::ToggleButton>();
        l.chips = find(L"Chips").as<VariableSizedWrapGrid>();
        l.check = find(L"Check").as<StackPanel>();
        l.cost = find(L"Cost").as<StackPanel>();
        SetRounder(l.turn, 0.1);
        SetRounder(l.relief, 0.01);
        SetRounder(l.depth_mm, 0.001);
        l.relief.Value(zs::label_default_relief);
        CardLayer().Children().Append(l.card);

        // The turn, the relief, and the depth are the first three inputs.
        l.AddInput(l.turn, -1, "turn");
        l.AddInput(l.relief, -1, "relief");
        l.AddInput(l.depth_mm, -1, "depth");
        l.turn.ValidationMode(NumberBoxValidationMode::Disabled);
        l.WatchEdit(l.turn);
        l.turn.ValueChanged([this](NumberBox const &sender, NumberBoxValueChangedEventArgs const &e) { label->OnNumberBox(sender, -1, "turn", e.NewValue(), 0.05); });
        l.relief.ValidationMode(NumberBoxValidationMode::Disabled);
        l.WatchEdit(l.relief);
        l.relief.ValueChanged([this](NumberBox const &sender, NumberBoxValueChangedEventArgs const &e) { label->OnNumberBox(sender, -1, "relief", e.NewValue(), 0.005); });
        l.depth_mm.ValidationMode(NumberBoxValidationMode::Disabled);
        l.WatchEdit(l.depth_mm);
        l.depth_mm.ValueChanged([this](NumberBox const &sender, NumberBoxValueChangedEventArgs const &e) { label->OnNumberBox(sender, -1, "depth", e.NewValue(), 0.0005); });

        // The modes act as a radio group: the button of the mode stays on.
        for (int k = 0; k < zs::label_mode_count; k++)
        {
            l.mode_buttons[k] = find((L"Mode" + std::to_wstring(k)).c_str()).as<Primitives::ToggleButton>();
            l.mode_buttons[k].Click([this, k](IInspectable const &sender, auto &&) {
                sender.as<Primitives::ToggleButton>().IsChecked(label->Selected() != nullptr && label->Selected()->mode == k);
                queue.TryEnqueue([weak = get_weak(), k] {
                    if (auto self = weak.get())
                        self->label->SetMode(k);
                });
            });
        }
        find(L"PlaceSvg").as<Button>().Click([this](auto &&, auto &&) {
            // The dialog runs after the click ends.
            queue.TryEnqueue([weak = get_weak()] {
                if (auto self = weak.get())
                    self->label->PickSvg();
            });
        });
        // The color tokens in code follow the theme: the fields again.
        l.card.ActualThemeChanged([this](auto &&, auto &&) {
            label->key.clear();
            label->chips_key.clear();
            label->ShowCard();
        });

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
            l.SetCursor(-1);
            return;
        }
        l.on = true;
        l.SetCursor((int)InputSystemCursorShape::Cross);
        l.core = model != nullptr ? model->Active() : nullptr;
        if (model != nullptr && !SelectedParts().empty())
            l.Load(PrimaryPart(), -1);
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

    void MainWindow::LabelHover(double x, double y)
    {
        if (label->on && !label->dragging)
            label->SetCursor(label->CursorAt(x, y));
    }

    void MainWindow::LabelDropSvg(std::wstring const &path, double x, double y)
    {
        std::wstring svg;
        if (ReadSvgFile(path, svg))
            label->DropSvg(svg, path, x, y, label->OverView(x, y));
    }

    bool MainWindow::LabelHasSelection()
    {
        return label->Selected() != nullptr;
    }

    std::string MainWindow::LabelCopyJson()
    {
        return label->CopyJson();
    }

    bool MainWindow::LabelPaste(std::string const &json, bool at_point, double x, double y)
    {
        return label->Paste(json, at_point, x, y);
    }

    void MainWindow::LabelRemoveSelected()
    {
        label->Remove();
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
        else if (verb == L"lfield" && words.size() >= 2)
        {
            // lfield name v: the number field of this name gets a value.
            bool found = false;
            for (auto const &in : l.inputs)
            {
                auto box = in.widget.try_as<NumberBox>();
                if (box != nullptr && in.field == narrow(0))
                {
                    box.Value(number(1));
                    zs::Log("dev: label field %s: asked %.2f, shows %.2f, range %.2f to %.2f, core %.2f\n", in.field.c_str(), number(1), box.Value(), box.Minimum(), box.Maximum(),
                            l.Selected() != nullptr ? l.InputValue(*l.Selected(), in.item, in.field) : -1.0);
                    found = true;
                    break;
                }
            }
            if (!found)
                zs::Log("dev: label field not found\n");
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
        else if (verb == L"laltdrag")
        {
            // A move with Alt: no snap.
            if (l.ScreenCenter(c) && ToolPress(c[0], c[1], false))
            {
                pointer_alt = true;
                for (int k = 1; k <= 10; k++)
                    ToolDrag(c[0] + number(0) * k / 10, c[1] + number(1) * k / 10, false);
                zs::Log("dev: label: %zu guide lines\n", l.guides.size() / 4);
                ToolRelease();
                pointer_alt = false;
            }
            else
                zs::Log("dev: no label to drag\n");
        }
        else if (verb == L"lhold")
        {
            // A drag from the center that stays pressed, so the guides show.
            if (l.ScreenCenter(c) && ToolPress(c[0], c[1], false))
            {
                for (int k = 1; k <= 10; k++)
                    ToolDrag(c[0] + number(0) * k / 10, c[1] + number(1) * k / 10, false);
                zs::Log("dev: label: %zu guide lines\n", l.guides.size() / 4);
            }
            else
                zs::Log("dev: no label to hold\n");
        }
        else if (verb == L"lrelease")
            ToolRelease();
        else if (verb == L"lscale" || verb == L"lsscale")
        {
            // A drag of the upper right corner handle to k times its
            // distance from the center. lsscale: with Shift.
            zs::Label *s = l.Selected();
            zs::LabelHandles g;
            double q[2];
            if (s != nullptr && l.HandlesOf(*s, g) && l.ScreenCenter(c) && l.ScreenOf(*s, g.box[2], g.box[3], q) && ToolPress(q[0], q[1], false))
            {
                for (int k = 1; k <= 10; k++)
                {
                    double kk = 1 + (number(0) - 1) * k / 10;
                    double ky = verb == L"lsscale" && words.size() > 1 ? 1 + (number(1) - 1) * k / 10 : kk;
                    ToolDrag(c[0] + (q[0] - c[0]) * kk, c[1] + (q[1] - c[1]) * ky, verb == L"lsscale");
                }
                ToolRelease();
            }
            else
                zs::Log("dev: no handle\n");
        }
        else if (verb == L"lturnh" || verb == L"lsturnh")
        {
            // A drag of the turn handle by deg degrees around the center.
            // lsturnh: with Shift.
            zs::Label *s = l.Selected();
            zs::LabelHandles g;
            double q[2];
            if (s != nullptr && l.HandlesOf(*s, g) && l.ScreenCenter(c) && l.ScreenOf(*s, g.turn[0], g.turn[1], q) && ToolPress(q[0], q[1], false))
            {
                double r0 = std::hypot(q[0] - c[0], q[1] - c[1]), a0 = std::atan2(q[1] - c[1], q[0] - c[0]);
                for (int k = 1; k <= 10; k++)
                {
                    double ang = a0 - number(0) * pi / 180 * k / 10;
                    ToolDrag(c[0] + r0 * std::cos(ang), c[1] + r0 * std::sin(ang), verb == L"lsturnh");
                }
                ToolRelease();
            }
            else
                zs::Log("dev: no turn handle\n");
        }
        else if (verb == L"lhandleclick")
        {
            // A press and a release on the turn handle, with no move.
            zs::Label *s = l.Selected();
            zs::LabelHandles g;
            double q[2];
            if (s != nullptr && l.HandlesOf(*s, g) && l.ScreenOf(*s, g.turn[0], g.turn[1], q) && ToolPress(q[0], q[1], false))
            {
                ToolRelease();
                l.Click(q[0], q[1]);
            }
            else
                zs::Log("dev: no turn handle\n");
        }
        else if (verb == L"lcursor")
        {
            // The pointer over the corner, the turn handle, the body, and
            // a place away from the label.
            zs::Label *s = l.Selected();
            zs::LabelHandles g;
            double a[2], b[2];
            if (s != nullptr && l.HandlesOf(*s, g) && l.ScreenCenter(c) && l.ScreenOf(*s, g.box[2], g.box[3], a) && l.ScreenOf(*s, g.turn[0], g.turn[1], b))
                zs::Log("dev: label cursors: corner %d, turn %d, body %d, away %d\n", l.CursorAt(a[0], a[1]), l.CursorAt(b[0], b[1]), l.CursorAt(c[0], c[1]), l.CursorAt(4, 4));
        }
        else if (verb == L"lsvg")
            l.PlaceSvgFile(words.empty() ? std::wstring() : words[0]);
        else if (verb == L"ldropsvg")
        {
            // An SVG file dropped on the front face of part 0, dx and dz mm
            // from its middle. "away": on the bed beside the part. "card":
            // on the middle of the label card.
            zs_part part{};
            float qx, qy;
            std::wstring where = words.size() > 1 ? words[1] : L"";
            if (where == L"away" && zs_app_part_get(model->Active(), 0, &part) == ZS_OK &&
                zs_view_pixel_of(view, part.x + part.size_x / 2 + 25, part.y, 0, &qx, &qy))
                LabelDropSvg(words[0], qx / Scale(), qy / Scale());
            else if (where == L"card")
            {
                auto at = l.card.TransformToVisual(ViewPanel()).TransformPoint({ (float)(l.card.ActualWidth() / 2), (float)(l.card.ActualHeight() / 2) });
                zs::Log("dev: label: over the view at the card: %d\n", l.OverView(at.X, at.Y) ? 1 : 0);
                LabelDropSvg(words[0], at.X, at.Y);
            }
            else if (words.size() > 2 && zs_app_part_get(model->Active(), 0, &part) == ZS_OK &&
                     zs_view_pixel_of(view, part.x + number(1), part.y - part.size_y / 2, part.size_z / 2 + number(2), &qx, &qy))
            {
                zs::Log("dev: label: over the view at the part: %d\n", l.OverView(qx / Scale(), qy / Scale()) ? 1 : 0);
                LabelDropSvg(words[0], qx / Scale(), qy / Scale());
            }
            else
                zs::Log("dev: no front face\n");
        }
        else if (verb == L"lmode")
        {
            for (int k = 0; k < zs::label_mode_count; k++)
                if (narrow(0) == zs::label_modes[k])
                    l.SetMode(k);
            if (words.size() > 1)
                l.SetRelief(number(1));
        }
        else if (verb == L"ldraw")
            l.DrawPoints((int)number(0));
        else if (verb == L"linfo")
            l.LoadInfo();
        else if (verb == L"lflush")
            l.Flush();
        else if (verb != L"llog")
            return false;
        zs::Log("dev: label: tool %s, part %lld, %zu labels, sel %lld, pending %lld, drawing %d, curve %.0f, card %s, relief row %s, guides %zu, history %zu of %zu, toast \"%s\"\n", l.on ? "on" : "off",
                (long long)l.index, l.labels.size(), (long long)l.sel, (long long)l.pending, l.drawing, l.curve,
                l.card.Visibility() == Visibility::Visible ? "shown" : "hidden", l.relief_row.Visibility() == Visibility::Visible ? "shown" : "hidden",
                l.guides.size() / 4, zs_app_history_current(model->Active()) + 1, zs_app_history_count(model->Active()), zs::ToUtf8(std::wstring(ToastText().Text())).c_str());
        for (auto const &x : l.labels)
        {
            std::string kinds;
            for (size_t i = 0; i < zs::LabelItemCount(x); i++)
                kinds += (i > 0 ? "," : "") + zs::LabelItemKind(zs::LabelItem(x, i));
            zs::Log("dev: label %u %s: %zu items (%s), filament %d, depth %.2f, mode %s, relief %.2f, stretch %.3f %.3f, at %.2f %.2f %.2f, normal %.2f %.2f %.2f, turn %.1f, size %.2f%s\n", x.id,
                    zs::ToUtf8(zs::LabelTitle(x)).c_str(), zs::LabelItemCount(x), kinds.c_str(), x.filament, x.depth, zs::label_modes[x.mode], x.relief,
                    x.has_stretch ? x.stretch[0] : 1.0, x.has_stretch ? x.stretch[1] : 1.0, x.origin[0], x.origin[1], x.origin[2], x.normal[0],
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
