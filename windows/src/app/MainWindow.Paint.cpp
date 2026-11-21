// The Paint tool and its card. It follows the GTK shell
// (linux/src/ui/paint-tool.c and paint-card.c).
//
// The tool has a paint session for the mesh of the part (zs_part_meshes.h),
// and the view draws that mesh in place of the beads. A stroke changes the
// session at once. Its end gives the paint to the part: one step of the
// history, and a slice. `synced` is the text of the paint that the session
// has, so an undo that changes the paint of the part shows at the next
// reload. A new mesh number means that the part moved or turned, and the
// view gets the mesh again.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>
#include <optional>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Primitives = Microsoft::UI::Xaml::Controls::Primitives;
using Windows::System::VirtualKey;

namespace
{
    wchar_t const *const smart_hint = L"Click a raised letter, a logo, or a face to paint it. Shift and a click add more. A right drag turns the view.";
    wchar_t const *const brush_hint = L"Drag over the surface to paint it. A right drag turns the view.";

    wchar_t const *const card_markup = LR"xaml(
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="280" Padding="12" Visibility="Collapsed"
        Background="#FAFFFFFF" BorderBrush="#DDE0E4" BorderThickness="1" CornerRadius="8">
  <StackPanel Spacing="6">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" />
        <ColumnDefinition Width="Auto" />
      </Grid.ColumnDefinitions>
      <TextBlock Text="Paint" FontWeight="Bold" VerticalAlignment="Center" />
      <Button x:Name="Close" Grid.Column="1" Background="Transparent" BorderThickness="0" Padding="6"
              AllowFocusOnInteraction="False" AutomationProperties.Name="Close the paint card">
        <FontIcon Glyph="&#xE711;" FontSize="11" />
      </Button>
    </Grid>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" />
        <ColumnDefinition Width="*" />
      </Grid.ColumnDefinitions>
      <ToggleButton x:Name="Smart" Content="Smart select" HorizontalAlignment="Stretch" AllowFocusOnInteraction="False"
                    ToolTipService.ToolTip="Click a region: a raised letter, a logo, or a face. Shift and a click add regions." />
      <ToggleButton x:Name="Brush" Grid.Column="1" Content="Brush" HorizontalAlignment="Stretch" AllowFocusOnInteraction="False"
                    ToolTipService.ToolTip="Drag over the surface to paint it." />
    </Grid>
    <Grid x:Name="SizeRow" ColumnSpacing="6" Visibility="Collapsed">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto" />
        <ColumnDefinition Width="*" />
        <ColumnDefinition Width="56" />
      </Grid.ColumnDefinitions>
      <TextBlock Text="Size" VerticalAlignment="Center" />
      <Slider x:Name="Size" Grid.Column="1" Minimum="0.3" Maximum="10" StepFrequency="0.1" SmallChange="0.1"
              IsThumbToolTipEnabled="False" AllowFocusOnInteraction="False" VerticalAlignment="Center"
              AutomationProperties.Name="The radius of the brush" ToolTipService.ToolTip="The radius of the brush" />
      <TextBlock x:Name="SizeText" Grid.Column="2" FontSize="12" Foreground="#5B6168" TextAlignment="Right" VerticalAlignment="Center" />
    </Grid>
    <TextBlock Text="Filament" FontSize="12" FontWeight="SemiBold" />
    <VariableSizedWrapGrid x:Name="Chips" Orientation="Horizontal" ItemWidth="30" ItemHeight="30" MaximumRowsOrColumns="8" />
    <TextBlock x:Name="Notice" Visibility="Collapsed" FontSize="12" Foreground="#B45309" TextWrapping="WrapWholeWords"
               Text="The plate has one filament. Add a filament (+) to paint with it." />
    <TextBlock x:Name="Hint" FontSize="12" Foreground="#5B6168" TextWrapping="WrapWholeWords" />
    <Button x:Name="Clear" Content="Remove all paint" AllowFocusOnInteraction="False"
            ToolTipService.ToolTip="The whole part prints with its own filament again" />
  </StackPanel>
</Border>)xaml";
}

namespace winrt::ZSlice::implementation
{
    struct MainWindow::PaintState
    {
        // A region of the smart select: its id and its triangles.
        struct Region
        {
            uint32_t id = 0;
            std::vector<uint32_t> tris;
        };

        explicit PaintState(MainWindow &window) : w(window) {}

        MainWindow &w;
        bool on = false;
        // The part, its filament (from 1), and the mesh number that the
        // view has (0: none).
        int64_t index = -1;
        int base = 1;
        unsigned gen = 0;
        std::optional<std::string> synced;
        bool brush = false;
        double size = 2;
        int filament = 2;
        std::optional<Region> hover;
        std::vector<Region> selection;
        // A press of the tool, and a stroke of the brush with the triangles
        // that it changed. A reload waits for the end of the press.
        bool pressed = false, stroke = false, reload_wanted = false;
        long changed = 0;
        // The states for the view, with the lit bit.
        std::vector<uint8_t> states;

        Border card{ nullptr };
        Primitives::ToggleButton smart_button{ nullptr }, brush_button{ nullptr };
        Grid size_row{ nullptr };
        Slider size_slider{ nullptr };
        TextBlock size_text{ nullptr }, notice{ nullptr }, hint{ nullptr };
        VariableSizedWrapGrid chips{ nullptr };
        std::string chips_key;
        bool updating = false, card_queued = false;

        zs_paint *Session()
        {
            if (!on || gen == 0 || w.model == nullptr)
                return nullptr;
            zs::PartMesh *e = w.meshes.Get(w.model->Active(), index);
            return e != nullptr && e->gen == gen ? e->session : nullptr;
        }

        // The state of a filament number: the filament of the part is 0.
        uint8_t StateOf(int value) const
        {
            return value == base ? (uint8_t)0 : (uint8_t)std::clamp(value, 0, 127);
        }

        void ClearSelection()
        {
            hover.reset();
            selection.clear();
        }

        std::optional<std::string> PaintText()
        {
            zs_app *app = w.model->Active();
            size_t len = 0;
            if (zs_app_part_paint_get(app, (size_t)index, nullptr, 0, &len) != ZS_OK)
                return std::nullopt;
            std::string text(len + 1, '\0');
            if (zs_app_part_paint_get(app, (size_t)index, text.data(), text.size(), &len) != ZS_OK)
                return std::nullopt;
            text.resize(len);
            return text;
        }

        // The paint of the session to the part: one step of the history,
        // and a slice.
        void Commit()
        {
            zs_paint *s = Session();
            char const *text = nullptr;
            size_t len = 0;
            if (s == nullptr || zs_paint_text(s, &text, &len) != ZS_OK)
                return;
            synced = std::string(text != nullptr ? text : "", len);
            if (zs_app_part_paint_set(w.model->Active(), (size_t)index, synced->c_str(), len) != ZS_OK)
            {
                w.ShowToast(L"The paint did not go to the part.");
                return;
            }
            w.model->RequestSlice();
            if (w.model->HistoryCommit())
                w.RefreshHistoryButtons();
            w.FillPartExtras();
        }

        // The palette of the view: state 0 is the filament of the part,
        // state k is filament k.
        void Colors()
        {
            if (w.view == nullptr || !on)
                return;
            uint32_t rgb[32];
            rgb[0] = w.FilamentRgb(base);
            for (int k = 1; k < 32; k++)
                rgb[k] = w.FilamentRgb(k);
            zs_view_paint_colors(w.view, rgb, 32);
        }

        void Light(Region const &r, size_t n)
        {
            for (uint32_t t : r.tris)
                if (t < n && states[t] != 255)
                    states[t] |= 128;
        }

        // The states to the view, with the light of the region under the
        // pointer and of the selection, and the pieces of split triangles.
        void Upload()
        {
            zs_paint *s = Session();
            if (s == nullptr || w.view == nullptr)
                return;
            uint8_t const *st = nullptr;
            size_t n = zs_paint_states(s, &st);
            states.assign(st, st + n);
            // The region under the pointer lights only in the smart select.
            if (!brush && hover.has_value())
                Light(*hover, n);
            for (auto const &r : selection)
                Light(r, n);
            float const *leaves = nullptr;
            size_t nl = zs_paint_leaves(s, &leaves);
            zs_view_paint_states(w.view, states.data(), n, leaves, nl);
            w.RequestDraw();
        }

        // The mesh of the part to the view (again if the part moved), and
        // the paint of the part to the session if it changed (an undo).
        bool SyncPart()
        {
            zs::PartMesh *e = w.meshes.Get(w.model->Active(), index);
            if (e == nullptr || w.view == nullptr)
                return false;
            if (e->gen != gen)
            {
                ClearSelection();
                if (!zs_view_paint_mesh(w.view, e->verts.data(), e->nv, e->faces.data(), e->nf))
                    return false;
                gen = e->gen;
                synced.reset();
            }
            auto text = PaintText();
            if (!text.has_value())
                return false;
            if (!synced.has_value() || *text != *synced)
            {
                // The regions stay. Their light follows the new paint.
                zs_paint_set_text(e->session, text->c_str(), text->size());
                synced = std::move(text);
            }
            base = w.PartFilament(index);
            Colors();
            return true;
        }

        void OpenOn(int64_t part)
        {
            if (w.model == nullptr || w.view == nullptr)
                return;
            zs_app *app = w.model->Active();
            if (part < 0 || (size_t)part >= zs_app_part_count(app))
            {
                w.ShowToast(L"Open a model to paint it.");
                return;
            }
            index = part;
            gen = 0;
            ClearSelection();
            if (!SyncPart())
            {
                gen = 0;
                zs_view_paint_mesh(w.view, nullptr, 0, nullptr, 0);
                w.ShowToast(L"The paint tool cannot open this part.");
                return;
            }
            // Paint with another filament than the part's at first.
            int count = (int)zs_app_filament_count(app);
            if (filament == base || filament > count || filament < 1)
                filament = count > 1 ? (base == 1 ? 2 : 1) : 1;
            Upload();
            UpdateCard();
        }

        void CloseTool()
        {
            Release();
            ClearSelection();
            gen = 0;
            index = -1;
            synced.reset();
            if (w.view != nullptr)
            {
                zs_view_paint_mesh(w.view, nullptr, 0, nullptr, 0);
                w.RequestDraw();
            }
        }

        // The part to paint: the selected part, or else the first part.
        int64_t WantedPart()
        {
            if (!w.selected_parts.empty())
                return w.selected_parts[0];
            return w.model != nullptr && zs_app_part_count(w.model->Active()) >= 1 ? 0 : -1;
        }

        // After a slice, an undo or a redo, or another plate.
        void Reload()
        {
            if (!on || w.model == nullptr)
                return;
            if (pressed)
            {
                reload_wanted = true;
                return;
            }
            reload_wanted = false;
            w.meshes.CheckAll();
            if (index < 0 || (size_t)index >= zs_app_part_count(w.model->Active()))
            {
                CloseTool();
                OpenOn(WantedPart());
                return;
            }
            if (!SyncPart())
            {
                CloseTool();
                return;
            }
            Upload();
            UpdateCard();
        }

        // ---- the picks ----

        int64_t Hit(double x, double y, float p[3])
        {
            zs_paint *s = Session();
            float r[6];
            double scale = w.Scale();
            uint32_t tri = 0;
            float d = 0;
            if (s == nullptr || w.view == nullptr || !zs_view_ray(w.view, (float)(x * scale), (float)(y * scale), r) ||
                zs_paint_hit(s, r, &tri, &d) != 1)
                return -1;
            for (int k = 0; k < 3; k++)
                p[k] = r[k] + r[3 + k] * d;
            return tri;
        }

        // The region of a triangle. A region with the id of `same` gives
        // nothing and sets *is_same: a hover over one region costs a lookup.
        std::optional<Region> RegionOf(uint32_t tri, Region const *same, bool *is_same)
        {
            zs_paint *s = Session();
            uint32_t const *list = nullptr;
            size_t n = 0;
            uint32_t id = 0;
            if (is_same != nullptr)
                *is_same = false;
            if (s == nullptr || zs_paint_region(s, tri, &list, &n, &id) != ZS_OK)
                return std::nullopt;
            if (same != nullptr && same->id == id)
            {
                if (is_same != nullptr)
                    *is_same = true;
                return std::nullopt;
            }
            Region r;
            r.id = id;
            r.tris.assign(list, list + n);
            return r;
        }

        long Fill(std::vector<uint32_t> const &tris, uint8_t state)
        {
            zs_paint *s = Session();
            if (s == nullptr || tris.empty())
                return 0;
            int c = zs_paint_fill(s, tris.data(), tris.size(), state);
            return c > 0 ? c : 0;
        }

        // One step of the brush at a point of the surface.
        void Dab(float const p[3])
        {
            zs_paint *s = Session();
            if (s == nullptr)
                return;
            int n = zs_paint_brush(s, p[0], p[1], p[2], (float)size, StateOf(filament), (float)std::max(0.1, size / 6));
            if (n > 0)
            {
                changed += n;
                Upload();
            }
        }

        // ---- the pointer ----

        bool Press(double x, double y, bool shift)
        {
            if (!on || w.view == nullptr)
                return false;
            pressed = true;
            float p[3];
            int64_t tri = Hit(x, y, p);
            if (!brush)
            {
                auto r = tri >= 0 ? RegionOf((uint32_t)tri, nullptr, nullptr) : std::nullopt;
                if (!r.has_value())
                {
                    if (!shift)
                        selection.clear();
                    Upload();
                    return true;
                }
                bool have = false;
                for (auto const &q : selection)
                    have = have || q.id == r->id;
                if (!shift)
                    selection.clear();
                long c = Fill(r->tris, StateOf(filament));
                if (!(shift && have))
                    selection.push_back(std::move(*r));
                if (c > 0)
                    Commit();
                Upload();
                return true;
            }
            stroke = true;
            changed = 0;
            if (tri >= 0)
                Dab(p);
            return true;
        }

        void Drag(double x, double y)
        {
            if (!stroke)
                return;
            float p[3];
            if (Hit(x, y, p) >= 0)
                Dab(p);
        }

        void Release()
        {
            if (!pressed)
                return;
            pressed = false;
            if (stroke)
            {
                stroke = false;
                if (changed > 0)
                    Commit();
                changed = 0;
            }
            if (reload_wanted)
                Reload();
        }

        void Hover(double x, double y)
        {
            if (!on || brush || pressed)
                return;
            float p[3];
            int64_t tri = Hit(x, y, p);
            bool same = false;
            auto r = tri >= 0 ? RegionOf((uint32_t)tri, hover.has_value() ? &*hover : nullptr, &same) : std::nullopt;
            if (same || (!r.has_value() && !hover.has_value()))
                return;
            hover = std::move(r);
            Upload();
        }

        // ---- the card ----

        void SetMode(bool to_brush)
        {
            brush = to_brush;
            hover.reset();
            Upload();
            UpdateCard();
        }

        void SetSize(double mm)
        {
            if (std::isfinite(mm))
                size = std::clamp(mm, 0.3, 10.0);
        }

        void SetFilament(int value)
        {
            if (value < 1)
                return;
            filament = value;
            // The selection gets the new filament.
            long c = 0;
            for (auto const &r : selection)
                c += Fill(r.tris, StateOf(value));
            if (c > 0)
                Commit();
            Upload();
            UpdateCard();
        }

        void AddFilament()
        {
            int64_t i = w.AddFilament();
            if (i < 0)
                return;
            Colors();
            SetFilament((int)i + 1);
        }

        void ClearPaint()
        {
            zs::PartMesh *e = w.model != nullptr ? w.meshes.Get(w.model->Active(), index) : nullptr;
            if (e == nullptr || Session() == nullptr)
                return;
            std::vector<uint32_t> all(e->nf);
            for (size_t i = 0; i < e->nf; i++)
                all[i] = (uint32_t)i;
            if (Fill(all, 0) > 0)
                Commit();
            selection.clear();
            Upload();
        }

        void UpdateCard()
        {
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

        void ApplyCard()
        {
            updating = true;
            smart_button.IsChecked(!brush);
            brush_button.IsChecked(brush);
            size_row.Visibility(brush ? Visibility::Visible : Visibility::Collapsed);
            if (std::abs(size_slider.Value() - size) > 1e-9)
                size_slider.Value(size);
            ShowSize();
            hint.Text(brush ? brush_hint : smart_hint);
            DrawChips();
            updating = false;
        }

        void ShowSize()
        {
            wchar_t text[32];
            swprintf_s(text, L"%.1f mm", size);
            size_text.Text(text);
        }

        void DrawChips()
        {
            if (w.model == nullptr)
                return;
            size_t n = zs_app_filament_count(w.model->Active());
            std::string key = std::to_string(filament) + " " + std::to_string(base);
            for (size_t i = 0; i < n; i++)
                key += " " + w.FilamentValue(i, "filament.color") + " " + w.FilamentValue(i, "filament.material");
            if (key == chips_key)
                return;
            chips_key = key;
            chips.Children().Clear();
            for (size_t i = 0; i < n; i++)
            {
                int k = (int)i + 1;
                std::string color = w.FilamentValue(i, "filament.color");
                std::string mat = w.FilamentValue(i, "filament.material");
                Button chip = w.MakeFilamentChip(color, std::to_wstring(k), k == filament);
                std::wstring tip = L"Paint with filament " + std::to_wstring(k) + L" (" + (mat.empty() ? std::wstring(L"filament") : zs::ToWide(mat)) +
                                   L", " + zs::ToWide(color) + L")" + (k == base ? L": the filament of the part" : L"");
                ToolTipService::SetToolTip(chip, box_value(tip));
                Automation::AutomationProperties::SetName(chip, L"Paint with filament " + std::to_wstring(k));
                chip.Click([this, k](auto &&, auto &&) { SetFilament(k); });
                chips.Children().Append(chip);
            }
            Button plus = w.MakeFilamentChip({}, L"+", false);
            ToolTipService::SetToolTip(plus, box_value(L"Add a filament to the plate"));
            Automation::AutomationProperties::SetName(plus, L"Add a filament to the plate");
            plus.Click([this](auto &&, auto &&) { AddFilament(); });
            chips.Children().Append(plus);
            // No other filament: the paint does not show.
            notice.Visibility(n <= 1 ? Visibility::Visible : Visibility::Collapsed);
        }
    };

    void MainWindow::WirePaint()
    {
        paint = std::make_shared<PaintState>(*this);
        auto &p = *paint;
        p.card = Markup::XamlReader::Load(card_markup).as<Border>();
        auto find = [&](wchar_t const *name) { return p.card.FindName(name); };
        p.smart_button = find(L"Smart").as<Primitives::ToggleButton>();
        p.brush_button = find(L"Brush").as<Primitives::ToggleButton>();
        p.size_row = find(L"SizeRow").as<Grid>();
        p.size_slider = find(L"Size").as<Slider>();
        p.size_text = find(L"SizeText").as<TextBlock>();
        p.chips = find(L"Chips").as<VariableSizedWrapGrid>();
        p.notice = find(L"Notice").as<TextBlock>();
        p.hint = find(L"Hint").as<TextBlock>();
        Canvas::SetLeft(p.card, 64);
        Canvas::SetTop(p.card, 10);
        CardLayer().Children().Append(p.card);

        find(L"Close").as<Button>().Click([this](auto &&, auto &&) { SetTool(Tool::Select); });
        find(L"Clear").as<Button>().Click([this](auto &&, auto &&) { paint->ClearPaint(); });
        p.smart_button.Click([this](auto &&, auto &&) { paint->SetMode(false); });
        p.brush_button.Click([this](auto &&, auto &&) { paint->SetMode(true); });
        p.size_slider.ValueChanged([this](auto &&, Primitives::RangeBaseValueChangedEventArgs const &e) {
            if (paint->updating)
                return;
            paint->SetSize(e.NewValue());
            paint->ShowSize();
        });
        p.ApplyCard();
    }

    void MainWindow::PaintTool(bool on)
    {
        auto &p = *paint;
        if (on == p.on)
            return;
        if (!on)
        {
            p.CloseTool();
            p.on = false;
            p.card.Visibility(Visibility::Collapsed);
            return;
        }
        p.on = true;
        p.card.Visibility(Visibility::Visible);
        p.OpenOn(p.WantedPart());
        ViewPanel().Focus(FocusState::Programmatic);
    }

    bool MainWindow::PaintPress(double x, double y, bool shift)
    {
        return paint->Press(x, y, shift);
    }

    bool MainWindow::PaintPressed()
    {
        return paint->pressed;
    }

    void MainWindow::PaintDrag(double x, double y)
    {
        paint->Drag(x, y);
    }

    void MainWindow::PaintRelease()
    {
        paint->Release();
    }

    void MainWindow::PaintHover(double x, double y)
    {
        paint->Hover(x, y);
    }

    void MainWindow::PaintReload()
    {
        paint->Reload();
    }

    // Another part selected (Ctrl and a click): paint that part.
    void MainWindow::PaintPartSelected(int64_t part)
    {
        auto &p = *paint;
        if (!p.on || part < 0 || part == p.index)
            return;
        p.Release();
        p.OpenOn(part);
    }

    // A new color or a new list of filaments.
    void MainWindow::PaintFilamentsChanged()
    {
        auto &p = *paint;
        if (!p.on)
            return;
        p.base = PartFilament(p.index);
        // The chosen filament can be gone from the list.
        int count = (int)zs_app_filament_count(model->Active());
        if (p.filament > count)
            p.filament = count > 1 ? (p.base == 1 ? 2 : 1) : 1;
        p.Colors();
        p.Upload();
        p.UpdateCard();
    }

#ifdef ZS_DEV_HOOKS
    // The steps of the Paint tool. See MainWindow.DevHooks.cpp.
    bool MainWindow::RunPaintStep(std::wstring const &verb, std::vector<std::wstring> const &words)
    {
        auto &p = *paint;
        auto number = [&](size_t i) { return i < words.size() ? _wtof(words[i].c_str()) : 0.0; };
        // The point of the mesh nearest to the middle of the part on the
        // screen: the middle of a part with a hollow can be air.
        auto on_mesh = [&](double &x, double &y) {
            zs_part part{};
            float cx = 0, cy = 0;
            if (zs_app_part_get(model->Active(), (size_t)std::max<int64_t>(p.index, 0), &part) != ZS_OK ||
                !zs_view_pixel_of(view, part.x, part.y, part.size_z / 2, &cx, &cy))
                return false;
            float q[3];
            for (double r = 0; r < 200; r += 2)
            {
                for (int a = 0; a < 24; a++)
                {
                    x = cx / Scale() + r * std::cos(a * 3.14159265 / 12);
                    y = cy / Scale() + r * std::sin(a * 3.14159265 / 12);
                    if (p.Hit(x, y, q) >= 0)
                        return true;
                }
            }
            return false;
        };
        if (verb == L"pclick" || verb == L"pstroke")
        {
            double x = 0, y = 0;
            if (!on_mesh(x, y))
                zs::Log("dev: no point of the mesh\n");
            else if (verb == L"pclick")
            {
                press_shift = !words.empty() && words[0] == L"shift";
                bool took = ToolPress(x, y, false);
                press_shift = false;
                if (took)
                    ToolRelease();
                ToolClick(x, y, false, false);
            }
            else if (ToolPress(x, y, false))
            {
                for (int k = 1; k <= 16; k++)
                    ToolDrag(x + number(0) * k / 16, y + number(1) * k / 16, false);
                ToolRelease();
            }
        }
        else if (verb == L"pmode" && !words.empty())
            p.SetMode(words[0] == L"brush");
        else if (verb == L"psize")
        {
            p.SetSize(number(0));
            p.UpdateCard();
        }
        else if (verb == L"pfilament")
            p.SetFilament((int)number(0));
        else if (verb == L"paddfilament")
            p.AddFilament();
        else if (verb == L"pclear")
            p.ClearPaint();
        else if (verb == L"phover")
            p.Hover(number(0), number(1));
        else if (verb == L"pselect")
            SelectPart((int64_t)number(0));
        else if (verb != L"plog")
            return false;
        size_t painted = 0, split = 0, n = 0, nl = 0;
        if (zs_paint *s = p.Session())
        {
            uint8_t const *st = nullptr;
            n = zs_paint_states(s, &st);
            for (size_t i = 0; i < n; i++)
            {
                painted += st[i] != 0;
                split += st[i] == 255;
            }
            nl = zs_paint_leaves(s, nullptr);
        }
        uint32_t used = 0;
        if (p.index >= 0)
            zs_app_part_paint_used(model->Active(), (size_t)p.index, &used);
        zs::Log("dev: paint: tool %s, part %lld, %s, size %.1f, filament %d, base %d, %zu of %zu triangles painted (%zu split, %zu pieces), used 0x%x, selection %zu, hover %s, card %s, %zu filaments\n",
                p.on ? "on" : "off", (long long)p.index, p.brush ? "brush" : "smart", p.size, p.filament, p.base, painted, n, split, nl, used,
                p.selection.size(), p.hover.has_value() ? "yes" : "no", p.card.Visibility() == Visibility::Visible ? "shown" : "hidden",
                zs_app_filament_count(model->Active()));
        return true;
    }
#endif
}
