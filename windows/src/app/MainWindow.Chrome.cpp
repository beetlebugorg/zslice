// The chrome that all apps share: the layer rail, the timeline of the history,
// the print in the bottom bar, the search in the header, and the Open button
// on an empty plate. The layout and the colors follow web/app/index.html and
// web/app/style.css, and the rail follows web/app/layers.js.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include "MainWindow.Printers.h"

#include <algorithm>
#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

namespace
{
    // The color and the words of each kind of step, and its glyph on the
    // 18 x 18 grid (web/app/history.js). Rectangles and circles are paths.
    struct StepLook
    {
        char const *kind;
        uint32_t rgb;
        wchar_t const *label;
        wchar_t const *glyph;
        wchar_t const *dashed;
    };

    StepLook const looks[] = {
        { "walls", 0xD9480F, L"Walls", L"M5.5 2.5h7a3 3 0 0 1 3 3v7a3 3 0 0 1-3 3h-7a3 3 0 0 1-3-3v-7a3 3 0 0 1 3-3zM7 6h4a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1z", nullptr },
        { "infill", 0x2B8A3E, L"Infill", L"M3.5 2.5h11a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1zM2.5 9 9 2.5M2.5 15.5 15.5 2.5M9 15.5 15.5 9M2.5 9 9 15.5M2.5 2.5l13 13M9 2.5 15.5 9", nullptr },
        { "surface", 0x1C7ED6, L"Top and bottom", L"M2.5 3.5h13M2.5 14.5h13", L"M2.5 6h13M2.5 12h13" },
        { "speed", 0x7C3AED, L"Speed", L"M3 13.5a6.5 6.5 0 1 1 12 0M9 11 12.5 6.5M10 11a1 1 0 1 1-2 0a1 1 0 1 1 2 0z", nullptr },
        { "heat", 0xDC2626, L"Temperature and cooling", L"M7 10.6V4a2 2 0 0 1 4 0v6.6a3.6 3.6 0 1 1-4 0zM9 12.5V7", nullptr },
        { "support", 0x6B7280, L"Support", L"M2 4.5h14l-2 3H4zM5 7.5v8M9 7.5v8M13 7.5v8M3.5 15.5h11", nullptr },
        { "layers", 0xD99000, L"Layers", L"M9 2.5 16 6l-7 3.5L2 6zM2 9.5 9 13l7-3.5M2 12.5 9 16l7-3.5", nullptr },
        { "move", 0x0C949E, L"Move", L"M2 9h14M9 2v14M13.7 6.8 16 9l-2.3 2.2M4.3 6.8 2 9l2.3 2.2M6.8 4.3 9 2l2.2 2.3M6.8 13.7 9 16l2.2-2.3", nullptr },
        { "rotate", 0x0C949E, L"Turn", L"M14.5 9a5.5 5.5 0 1 1-1.6-3.9M13.6 2.2v3.3h-3.3", nullptr },
        { "scale", 0x0C949E, L"Scale", L"M3 15 15 3M10 3h5v5M3 10v5h5", nullptr },
        { "add", 0x0C949E, L"Part added", L"M3.5 9h11M9 3.5v11", nullptr },
        { "remove", 0x0C949E, L"Part removed", L"M3.5 9h11", nullptr },
        { "quality", 0xDB2777, L"Quality", L"M9 2.2l2 4.3 4.7.6-3.4 3.2.9 4.6L9 12.6l-4.2 2.3.9-4.6-3.4-3.2 4.7-.6z", nullptr },
        { "filament", 0x4F46E5, L"Filaments", L"M3.5 2.5h.5a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1h-.5a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1zM14 2.5h.5a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H14a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1zM5 6.5h8M5 9h8M5 11.5h8", nullptr },
        { "label", 0xA21CAF, L"Labels", L"M2.5 4.5h8l5 4.5-5 4.5h-8zM5 9h4", nullptr },
        { "printer", 0x334155, L"Printer", L"M5 6.5V2.5h8v4M5 13H2.5V6.5h13V13H13M5 10.5h8v5H5z", nullptr },
        { "start", 0x808080, L"Start", L"M14.5 9a5.5 5.5 0 1 1-11 0a5.5 5.5 0 1 1 11 0zM10.5 9a1.5 1.5 0 1 1-3 0a1.5 1.5 0 1 1 3 0z", nullptr },
        { "other", 0x808080, L"Other", L"M4.6 9a.6.6 0 1 1-1.2 0a.6.6 0 1 1 1.2 0zM9.6 9a.6.6 0 1 1-1.2 0a.6.6 0 1 1 1.2 0zM14.6 9a.6.6 0 1 1-1.2 0a.6.6 0 1 1 1.2 0z", nullptr },
    };

    StepLook const &LookOf(char const *kind)
    {
        for (auto const &look : looks)
            if (kind != nullptr && strcmp(look.kind, kind) == 0)
                return look;
        return looks[std::size(looks) - 2 + 1];
    }

    Shapes::Path GlyphPath(wchar_t const *data, double size, bool dashed)
    {
        std::wstring scale = std::to_wstring(size / 18);
        std::wstring xaml = L"<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Stroke='White' StrokeThickness='1.6' "
                            L"StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round' ";
        if (dashed)
            xaml += L"StrokeDashArray='1 1.2' ";
        xaml += L"Data='";
        xaml += data;
        xaml += L"'><Path.RenderTransform><ScaleTransform ScaleX='" + scale + L"' ScaleY='" + scale + L"'/></Path.RenderTransform></Path>";
        return Markup::XamlReader::Load(xaml).as<Shapes::Path>();
    }

    // A color token of App.xaml, for the theme of the window.

    std::wstring FormatTime(double seconds)
    {
        int minutes = (int)std::lround(seconds / 60);
        if (minutes < 60)
            return std::to_wstring(minutes) + L" min";
        return std::to_wstring(minutes / 60) + L" h " + std::to_wstring(minutes % 60) + L" min";
    }
}

namespace winrt::ZSlice::implementation
{
    // The color, the name, and the glyph of a kind of history step.
    Windows::UI::Color StepColor(char const *kind)
    {
        uint32_t rgb = LookOf(kind).rgb;
        return Windows::UI::Color{ 255, (uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb };
    }

    std::wstring StepLabel(char const *kind)
    {
        return LookOf(kind).label;
    }

    UIElement StepGlyph(char const *kind, double size)
    {
        StepLook const &look = LookOf(kind);
        Grid box;
        box.Width(size);
        box.Height(size);
        box.Children().Append(GlyphPath(look.glyph, size, false));
        if (look.dashed != nullptr)
            box.Children().Append(GlyphPath(look.dashed, size, true));
        return box;
    }

    // A color token of App.xaml, in the theme of the element.
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key)
    {
        wchar_t const *theme = element.ActualTheme() == ElementTheme::Dark ? L"Dark" : L"Light";
        auto dictionary = Application::Current().Resources().MergedDictionaries().GetAt(1).ThemeDictionaries().Lookup(box_value(theme)).as<ResourceDictionary>();
        return dictionary.Lookup(box_value(key)).as<Media::Brush>();
    }

    void MainWindow::WireChrome()
    {
        // The rail and the toast stay over the bottom bar.
        Dock().SizeChanged([this](auto &&, auto &&) {
            double h = Dock().ActualHeight();
            LayerCard().Margin(ThicknessHelper::FromLengths(0, 140, 14, h + 24));
            ToastCard().Margin(ThicknessHelper::FromLengths(0, 0, 0, h + 12));
            FitTimeline();
            PlaceEmptyOpen();
        });
        TimelineCount().SizeChanged([this](auto &&, auto &&) { FitTimeline(); });
        LayerCard().SizeChanged([this](auto &&, auto &&) { UpdateLayerRail(); });
        LayerHiBubble().SizeChanged([this](auto &&, auto &&) { UpdateLayerRail(); });
        LayerCard().PointerPressed([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (layer_count == 0)
                return;
            size_t at = LayerAt(e.GetCurrentPoint(LayerCard()).Position().Y);
            size_t hi = (size_t)std::lround(LayerSlider().Value()) - 1;
            size_t to_hi = at > hi ? at - hi : hi - at, to_lo = at > layer_lo ? at - layer_lo : layer_lo - at;
            rail_drag = to_hi <= to_lo ? 1 : 2;
            LayerCard().CapturePointer(e.Pointer());
            RailMove(at);
            e.Handled(true);
        });
        LayerCard().PointerMoved([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (rail_drag == 0)
                return;
            RailMove(LayerAt(e.GetCurrentPoint(LayerCard()).Position().Y));
            e.Handled(true);
        });
        auto ended = [this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (rail_drag == 0)
                return;
            rail_drag = 0;
            LayerCard().ReleasePointerCapture(e.Pointer());
            e.Handled(true);
        };
        LayerCard().PointerReleased(ended);
        LayerCard().PointerCaptureLost(ended);

        WireSearch();
        Root().SizeChanged([this](auto &&, SizeChangedEventArgs const &e) {
            double width = e.NewSize().Width;
            SearchField().Width(std::clamp(width * 0.3, 200.0, 380.0));
            HeaderSearch().PlaceholderText(width < 900 ? L"Search" : L"Search settings and actions");
            LayoutHeader();
        });

        HeaderEnd().SizeChanged([this](auto &&, auto &&) { LayoutHeader(); });
        SearchField().SizeChanged([this](auto &&, auto &&) { LayoutHeader(); });

        ViewSign().Click([this](auto &&, auto &&) { Set2D(false); });
        ExportButton().Click([this](auto &&, auto &&) {
            if (printers != nullptr)
                printers->PrimaryAction();
        });
    }

    // The search stays in the middle of the window. The end group never gets
    // narrower than its content: it pushes the search to the left.
    void MainWindow::LayoutHeader()
    {
        double width = ToolRow().ActualWidth() - 14 - 12;
        bool field = SearchField().Visibility() == Visibility::Visible;
        double search = field ? SearchField().ActualWidth() : SearchOpen().ActualWidth();
        double end = HeaderEnd().ActualWidth();
        double left = std::max(0.0, std::min((width - search) / 2, width - search - end));
        ToolRow().ColumnDefinitions().GetAt(0).Width(GridLengthHelper::FromPixels(left));
    }

    // The layer at a height of the rail. The knobs go 9 px from each end.
    size_t MainWindow::LayerAt(double y)
    {
        double height = LayerCard().ActualHeight();
        double f = 1 - (y - 9) / std::max(1.0, height - 18);
        return (size_t)std::lround(std::clamp(f, 0.0, 1.0) * (double)(layer_count > 0 ? layer_count - 1 : 0));
    }

    void MainWindow::RailMove(size_t at)
    {
        size_t hi = (size_t)std::lround(LayerSlider().Value()) - 1;
        if (rail_drag == 1)
        {
            layer_lo = std::min(layer_lo, at);
            hi = at;
        }
        else
        {
            layer_lo = at;
            hi = std::max(hi, at);
        }
        if ((size_t)std::lround(LayerSlider().Value()) != hi + 1)
            LayerSlider().Value((double)hi + 1);
        else
            ApplyLayerRange();
        UpdateLayerRail();
    }

    // Moves the lowest layer that shows (Shift and the arrow keys).
    void MainWindow::StepLayerLo(int direction)
    {
        if (layer_count == 0)
            return;
        size_t hi = (size_t)std::lround(LayerSlider().Value()) - 1;
        layer_lo = (size_t)std::clamp<int64_t>((int64_t)layer_lo + direction, 0, (int64_t)layer_count - 1);
        if (layer_lo > hi)
            LayerSlider().Value((double)layer_lo + 1);
        else
            ApplyLayerRange();
        UpdateLayerRail();
    }

    void MainWindow::ApplyLayerRange()
    {
        if (view == nullptr || layer_count == 0)
            return;
        size_t hi = (size_t)std::lround(LayerSlider().Value()) - 1;
        if (layer_lo > 0)
            zs_view_set_layer_range(view, layer_lo, hi);
        else
            zs_view_set_layer(view, hi);
        RequestDraw();
    }

    void MainWindow::UpdateLayerRail()
    {
        if (layer_count == 0)
            return;
        size_t hi = (size_t)std::lround(LayerSlider().Value()) - 1;
        hi = std::min(hi, layer_count - 1);
        layer_lo = std::min(layer_lo, hi);
        double height = LayerCard().ActualHeight();
        double max = (double)std::max<size_t>(1, layer_count - 1);
        auto y = [&](size_t v) { return 9 + (height - 18) * (1 - (double)v / max); };
        double hi_y = y(hi), lo_y = y(layer_lo);
        Canvas::SetTop(LayerHighlight(), hi_y);
        LayerHighlight().Height(std::max(0.0, lo_y - hi_y));
        Canvas::SetTop(LayerHiKnob(), hi_y - 9);
        Canvas::SetTop(LayerHiShade(), hi_y - 9);
        Canvas::SetTop(LayerLoKnob(), lo_y - 9);
        Canvas::SetTop(LayerLoShade(), lo_y - 9);

        // The number of a layer that slows down to cool has a snowflake.
        zs_toolpaths tp{};
        bool slowed = model != nullptr && zs_app_toolpaths(model->Active(), &tp) == ZS_OK && tp.layer_slowed != nullptr &&
                      hi < tp.layer_count && tp.layer_slowed[hi] != 0;
        LayerText().Text((slowed ? L"❄ " : L"") + to_hstring(hi + 1));
        auto place = [](FrameworkElement const &bubble, double top) {
            Canvas::SetLeft(bubble, -4 - bubble.ActualWidth());
            Canvas::SetTop(bubble, top - 10);
        };
        place(LayerHiBubble(), hi_y);
        bool show_lo = layer_lo > 0 && layer_lo < hi;
        LayerLoBubble().Visibility(show_lo ? Visibility::Visible : Visibility::Collapsed);
        if (show_lo)
        {
            LayerLoText().Text(to_hstring(layer_lo + 1));
            place(LayerLoBubble(), std::max(lo_y, hi_y + LayerHiBubble().ActualHeight() + 2));
        }
    }

    // The marks scroll in the room that the bar has. The count stays in sight.
    void MainWindow::FitTimeline()
    {
        double room = Dock().ColumnDefinitions().GetAt(1).ActualWidth() - 9;
        double fixed = UndoButton().ActualWidth() + RedoButton().ActualWidth() + HistoryButton().ActualWidth() +
                       TimelineCount().ActualWidth() + 12 + 9 + 10;
        TimelineScroll().MaxWidth(std::clamp(room - fixed, 40.0, 420.0));
    }

    // The steps of the history in the bar, the oldest at the left.
    void MainWindow::RefreshTimeline()
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        size_t count = zs_app_history_count(app), now = zs_app_history_current(app);
        if (count == timeline_count && now == timeline_now && app == timeline_app)
            return;
        timeline_count = count;
        timeline_now = now;
        timeline_app = app;
        auto marks = TimelineMarks();
        marks.Children().Clear();
        if (count <= 1)
        {
            TimelineCount().Text(L"Your changes show here");
            return;
        }
        TimelineCount().Text(to_hstring(now) + L" / " + to_hstring(count - 1));
        // At most 60 marks, around the step now.
        size_t first = count > 60 ? std::min(now > 30 ? now - 30 : 0, count - 60) : 0, end = std::min(count, first + 60);
        for (size_t i = first; i < end; i++)
        {
            zs_history_step step{};
            if (zs_app_history_step(app, i, &step) != ZS_OK)
                continue;
            if (i > first)
            {
                Shapes::Rectangle line;
                line.Width(10);
                line.Height(2);
                line.VerticalAlignment(VerticalAlignment::Center);
                line.Fill(TokenBrush(Root(), L"ZsLine"));
                line.Opacity(i > now ? 0.4 : 1);
                marks.Children().Append(line);
            }
            StepLook const &look = LookOf(i == 0 ? "start" : step.kind);
            bool here = i == now;
            double size = here ? 26 : 22, glyph = here ? 18 : 15;
            Button mark;
            mark.Width(size);
            mark.Height(size);
            mark.MinWidth(0);
            mark.MinHeight(0);
            mark.Padding(ThicknessHelper::FromUniformLength(0));
            mark.VerticalAlignment(VerticalAlignment::Center);
            mark.CornerRadius(CornerRadiusHelper::FromUniformRadius(size / 2));
            Windows::UI::Color color{ 255, (uint8_t)(look.rgb >> 16), (uint8_t)(look.rgb >> 8), (uint8_t)look.rgb };
            mark.Background(Media::SolidColorBrush(color));
            mark.BorderThickness(ThicknessHelper::FromUniformLength(2));
            mark.BorderBrush(here ? TokenBrush(Root(), L"ZsAccent") : Media::Brush(Media::SolidColorBrush(Windows::UI::Color{ 0xD9, 255, 255, 255 })));
            mark.Opacity(i > now ? 0.4 : 1);
            Grid box;
            box.Width(glyph);
            box.Height(glyph);
            box.Children().Append(GlyphPath(look.glyph, glyph, false));
            if (look.dashed != nullptr)
                box.Children().Append(GlyphPath(look.dashed, glyph, true));
            mark.Content(box);

            std::string words(step.text != nullptr ? step.text : "", step.text != nullptr ? step.text_len : 0);
            std::replace(words.begin(), words.end(), '\t', ':');
            std::wstring tip = (i == 0 ? std::wstring(L"Start") : L"Change " + std::to_wstring(i)) + L" · " + look.label;
            if (!words.empty())
                tip += L". " + zs::ToWide(words);
            Automation::AutomationProperties::SetName(mark, tip);
            mark.Click([this, i](auto &&, auto &&) { GoToStep(i); });
            // A short hover shows the card of the step.
            mark.PointerEntered([this, mark, i](auto &&, auto &&) { HoverMark(mark, i); });
            mark.PointerExited([this](auto &&, auto &&) { LeaveHistoryCard(); });
            mark.RightTapped([this, mark, i](auto &&, Input::RightTappedRoutedEventArgs const &e) {
                e.Handled(true);
                ShowStepMenu(mark, e.GetPosition(mark), i);
            });
            marks.Children().Append(mark);
        }
        // The step now stays in sight.
        double share = end > first + 1 ? (double)(std::min(now, end - 1) - first) / (double)(end - first - 1) : 0;
        auto weak = get_weak();
        queue.TryEnqueue([weak, share] {
            if (auto self = weak.get())
                self->TimelineScroll().ChangeView(box_value(share * self->TimelineScroll().ScrollableWidth()).as<Windows::Foundation::IReference<double>>(), nullptr, nullptr, true);
        });
    }

    // The print in the bottom bar: its time, its numbers, and a badge.
    void MainWindow::RefreshSummary()
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        int state = zs_app_state(app);
        DockSummary().Visibility(state == ZS_STATE_EMPTY ? Visibility::Collapsed : Visibility::Visible);
        DockSummary().Opacity(state == ZS_STATE_SLICING ? 0.55 : 1);
        ExportButton().IsEnabled(state == ZS_STATE_DONE);
        if (printers != nullptr)
            printers->RefreshPrimary();
        if (state != ZS_STATE_DONE)
            ShowCheckCount(0);
        if (state == ZS_STATE_SLICING)
            return;
        ShowBusy(L"");
        zs_stats stats{};
        if (state != ZS_STATE_DONE || zs_app_stats(app, &stats) != ZS_OK)
        {
            SummaryTime().Text(state == ZS_STATE_FAILED ? L"Slice failed" : L"—");
            SummaryDetail().Text(L"");
            SummaryWarnBox().Visibility(Visibility::Collapsed);
            SummaryFacts().Children().Clear();
            SummaryTook().Text(L"");
            UpdateSummaryBadge(false);
            return;
        }
        SummaryTime().Text(FormatTime(stats.print_time_s));
        double per_g = atof(model->GetSetting("filament.price_per_kg").c_str()) / 1000;
        double per_h = atof(model->GetSetting("machine.hour_rate").c_str());
        double cost = stats.filament_g * per_g + stats.print_time_s / 3600 * per_h;
        wchar_t text[160];
        swprintf_s(text, L"%.1f g · %.2f m", stats.filament_g, stats.filament_mm / 1000);
        std::wstring detail = text;
        if (cost > 0)
        {
            swprintf_s(text, L" · cost %.2f", cost);
            detail += text;
        }
        detail += L" · " + std::to_wstring(stats.layer_count) + L" layers";
        double grams[16]{};
        uint32_t changes = 0;
        double flush = 0;
        if (zs_app_filament_stats(app, grams, 16, &changes, &flush) == ZS_OK && changes > 0)
            detail += L" · " + std::to_wstring(changes) + (changes == 1 ? L" change" : L" changes");
        SummaryDetail().Text(detail);
        if (slice_ms > 0)
        {
            wchar_t took[48];
            if (slice_ms < 1000)
                swprintf_s(took, L"Sliced in %.0f ms", slice_ms);
            else
                swprintf_s(took, L"Sliced in %.1f s", slice_ms / 1000);
            SummaryTook().Text(took);
        }
        else
        {
            SummaryTook().Text(L"");
        }

        // The problems of the check: a warning or worse. The Check button
        // and the badge show the same count.
        size_t problems = 0;
        zs_issue const *issues = nullptr;
        size_t n = 0;
        char const *words = nullptr;
        if (zs_app_checks(app, &issues, &n, &words) == ZS_OK)
            for (size_t i = 0; i < n; i++)
                if (issues[i].severity >= 1)
                    problems++;
        ShowCheckCount(problems);
        FillFacts();
        bool warn = FillSummaryWarn();
        if (!warn)
            SummaryWarnBox().Visibility(Visibility::Collapsed);
        UpdateSummaryBadge(warn);
    }

    void MainWindow::ShowBusy(winrt::param::hstring const &text)
    {
        hstring words = text;
        BusyText().Text(words);
        BusyPill().Visibility(words.empty() ? Visibility::Collapsed : Visibility::Visible);
    }

    // The Open button sits on the middle of the bed of an empty plate.
    void MainWindow::PlaceEmptyOpen()
    {
        if (view == nullptr || model == nullptr)
            return;
        bool empty = zs_app_part_count(model->Active()) == 0 && !show_2d;
        if (!empty)
        {
            EmptyHint().Visibility(Visibility::Collapsed);
            return;
        }
        double bed_x, bed_y;
        BedSize(bed_x, bed_y);
        float px = 0, py = 0;
        zs_view_pixel_of(view, bed_x / 2, bed_y / 2, 0, &px, &py);
        auto button = EmptyOpen();
        double w = button.ActualWidth(), h = button.ActualHeight(), x = px / Scale(), y = py / Scale();
        double room_w = ViewPanel().ActualWidth(), room_h = ViewPanel().ActualHeight() - Dock().ActualHeight();
        bool fits = x - w / 2 > 4 && x + w / 2 < room_w - 4 && y - h / 2 > 4 && y + h / 2 < room_h - 4;
        EmptyHint().Visibility(fits ? Visibility::Visible : Visibility::Collapsed);
        Canvas::SetLeft(button, x - w / 2);
        Canvas::SetTop(button, y - h / 2);
    }
}
