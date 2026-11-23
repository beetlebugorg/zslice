// The cards over the view: the line card and the part card. A card sits
// beside what it describes and never covers it. The behavior follows the
// GTK shell (linux/src/ui/line-card.c and part-card.c).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;

namespace
{
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

    void MainWindow::WireCards()
    {
        LineClose().Click([this](auto &&, auto &&) { ClearSelection(); });
        PartClose().Click([this](auto &&, auto &&) { ClearSelection(); });
        MakeCardMovable(LineCard(), LineCardHead(), &line_card_moved);
        WireLineMark();
        MakeCardMovable(PartCard(), PartCardHead(), &part_card_moved);

        LineFade().Click([this](auto &&, auto &&) {
            if (view == nullptr)
                return;
            zs_view_isolate(view, LineFade().IsChecked().GetBoolean() ? 1 : 0);
            RequestDraw();
        });
        LineAll().Click([this](auto &&, auto &&) {
            if (SelectedPath() < 0)
                return;
            ShowSettingsPane(true);
            ShowSelected();
        });
        auto edit = [this](int kind, double value) {
            if (model == nullptr || SelectedPath() < 0)
                return;
            if (EditSelectedLine(kind, value) == ZS_OK)
            {
                ClearSelection();
                model->RequestSlice();
                NoteChange();
            }
        };
        LineSkip().Click([edit](auto &&, auto &&) { edit(0, 1); });
        LineLess().Click([edit](auto &&, auto &&) { edit(1, 0.9); });
        LineMore().Click([edit](auto &&, auto &&) { edit(1, 1.1); });

        auto one = [this](auto const &action) {
            if (model != nullptr && SelectedParts().size() == 1)
                action(model->Active(), (size_t)PrimaryPart());
        };
        PartDuplicate().Click([this, one](auto &&, auto &&) {
            one([this](zs_app *app, size_t i) {
                ptrdiff_t copy = zs_app_part_duplicate(app, i);
                if (copy >= 0)
                {
                    SelectPart(copy);
                    PlateEdited();
                }
            });
        });
        PartSplit().Click([this, one](auto &&, auto &&) {
            one([this](zs_app *app, size_t i) {
                if (zs_app_part_split(app, i) > 0)
                {
                    ClearSelection();
                    PlateEdited();
                }
                else
                {
                    ShowToast(L"This part is one piece.");
                }
            });
        });
        PartBest().Click([this, one](auto &&, auto &&) {
            one([this](zs_app *app, size_t i) {
                if (zs_app_part_place(app, i, ZS_PLACE_SMART, 0) == ZS_OK)
                    PlateEdited();
            });
        });
        PartLess().Click([this, one](auto &&, auto &&) {
            one([this](zs_app *app, size_t i) {
                if (zs_app_part_place(app, i, ZS_PLACE_LESS_SUPPORT, 0) == ZS_OK)
                    PlateEdited();
            });
        });
        PartReset().Click([this, one](auto &&, auto &&) {
            one([this](zs_app *app, size_t i) {
                if (zs_app_part_reset(app, i) == ZS_OK)
                    PlateEdited();
            });
        });
        for (int axis = 0; axis < 2; axis++)
        {
            auto button = axis == 0 ? PartMirrorX() : PartMirrorY();
            button.Click([this, one, axis](auto &&, auto &&) {
                one([this, axis](zs_app *app, size_t i) {
                    if (zs_app_part_mirror(app, i, axis) == ZS_OK)
                        PlateEdited();
                });
            });
        }
        for (int field = 0; field < 6; field++)
        {
            PoseBox(field).KeyDown([this, field](auto &&, Input::KeyRoutedEventArgs const &e) {
                if (e.Key() != Windows::System::VirtualKey::Enter)
                    return;
                ApplyPose(field);
                e.Handled(true);
            });
            // A field that lost the focus shows the part again.
            PoseBox(field).LostFocus([this](auto &&, auto &&) { FillPartCard(); });
        }
        PartEarlier().Click([this](auto &&, auto &&) { MovePartInOrder(-1); });
        PartLater().Click([this](auto &&, auto &&) { MovePartInOrder(1); });
        auto commit_scale = [this]() {
            if (!scale_edited || model == nullptr)
                return;
            scale_edited = false;
            zs_app *app = model->Active();
            ptrdiff_t scale_index = app == scale_app ? zs_app_part_index(app, scale_part) : -1;
            if (scale_index < 0)
                return;
            std::wstring text{ PartScale().Text() };
            wchar_t *end = nullptr;
            double percent = wcstod(text.c_str(), &end);
            zs_part p{};
            if (end == text.c_str() || !(percent > 0) || zs_app_part_get(app, (size_t)scale_index, &p) != ZS_OK)
                return;
            double scale = std::clamp(percent, 1.0, 100000.0) / 100;
            if (std::abs(scale - p.scale_x) < 1e-6)
                return;
            if (zs_app_part_scale(app, (size_t)scale_index, scale, scale, scale) == ZS_OK)
                PlateEdited();
        };
        // The part that the field shows when the typing starts.
        PartScale().GotFocus([this](auto &&, auto &&) {
            scale_edited = false;
            scale_app = model != nullptr ? model->Active() : nullptr;
            std::vector<int64_t> shown_parts = SelectedParts();
            scale_part = shown_parts.size() == 1 ? zs_app_part_id(model->Active(), (size_t)shown_parts[0]) : 0;
        });
        PartScale().TextChanged([this](auto &&, auto &&) {
            if (std::wstring(PartScale().Text()) != scale_shown)
                scale_edited = true;
        });
        PartScale().KeyDown([commit_scale](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() == Windows::System::VirtualKey::Enter)
            {
                commit_scale();
                e.Handled(true);
            }
        });
        PartScale().LostFocus([this, commit_scale](auto &&, auto &&) {
            commit_scale();
            scale_part = 0;
            // The card can show another part now.
            FillPartCard();
        });
        PartMake().Click([this](auto &&, auto &&) {
            if (model == nullptr || SelectedParts().size() != 1)
                return;
            size_t want = (size_t)std::max(2.0, PartMakeCount().Value());
            size_t plates = 0, plates_before = model->PlateCount(), make_plate = model->ActivePlate();
            ptrdiff_t made = zs_set_fill(model->Set(), model->ActivePlate(), (size_t)PrimaryPart(), want, &plates);
            if (made < 0)
                ShowToast(L"No copies were made.");
            else if ((size_t)made < want)
                ShowToast(to_hstring(made) + L" of " + to_hstring(want) + L" fit: the part is too big for more plates.");
            else
                ShowToast(to_hstring(made) + L" in all, on " + to_hstring(plates) + L" plates.");
            ClearSelection();
            zs_set_changed(model->Set(), make_plate);
            for (size_t i = plates_before; i < model->PlateCount(); i++)
                zs_set_changed(model->Set(), i);
            NoteChange();
            ShowPlate();
        });
        PartNewPlate().Click([this](auto &&, auto &&) {
            if (model == nullptr || SelectedParts().empty())
                return;
            std::vector<int64_t> list = SelectedParts();
            std::sort(list.rbegin(), list.rend());
            ClearSelection();
            // All of them go to one new plate.
            ptrdiff_t to = -1;
            for (int64_t i : list)
            {
                ptrdiff_t moved = zs_set_part_move(model->Set(), model->ActivePlate(), (size_t)i, to);
                if (moved < 0)
                    break;
                to = moved;
            }
            PlateEdited();
        });
        PartRemove().Click([this](auto &&, auto &&) {
            if (model == nullptr || SelectedParts().empty())
                return;
            std::vector<int64_t> list = SelectedParts();
            std::sort(list.rbegin(), list.rend());
            ClearSelection();
            for (int64_t i : list)
                zs_app_part_remove(model->Active(), (size_t)i);
            PlateEdited();
        });
        PartsDuplicate().Click([this](auto &&, auto &&) {
            if (model == nullptr)
                return;
            for (int64_t i : SelectedParts())
                zs_app_part_duplicate(model->Active(), (size_t)i);
            PlateEdited();
        });
        PartsArrange().Click([this](auto &&, auto &&) {
            if (model == nullptr)
                return;
            zs_app_plate_arrange(model->Active());
            PlateEdited();
        });

        // The cut: the plane shows while the popup is open.
        auto show_cut = [this]() {
            if (view == nullptr || model == nullptr || SelectedParts().size() != 1)
                return;
            zs_part p{};
            if (zs_app_part_get(model->Active(), (size_t)PrimaryPart(), &p) != ZS_OK)
                return;
            double m = 0.55 * std::max(p.size_x, p.size_y) + 4;
            zs_view_set_cut(view, p.x - m, p.y - m, p.x + m, p.y + m, CutHeight().Value());
            RequestDraw();
        };
        PartCutFlyout().Opened([this, show_cut](auto &&, auto &&) {
            if (model == nullptr || SelectedParts().size() != 1)
                return;
            zs_part p{};
            if (zs_app_part_get(model->Active(), (size_t)PrimaryPart(), &p) != ZS_OK)
                return;
            CutHeight().Minimum(0.2);
            CutHeight().Maximum(std::max(0.4, p.size_z - 0.2));
            CutHeight().Value(std::round(p.size_z / 2 * 10) / 10);
            show_cut();
        });
        PartCutFlyout().Closed([this](auto &&, auto &&) {
            if (view == nullptr)
                return;
            zs_view_set_cut(view, 0, 0, 0, 0, 0);
            RequestDraw();
        });
        CutHeight().ValueChanged([show_cut](auto &&, auto &&) { show_cut(); });
        CutGo().Click([this](auto &&, auto &&) {
            if (model == nullptr || SelectedParts().size() != 1)
                return;
            size_t part = (size_t)PrimaryPart();
            double pegs = CutPegs().Value(), peg_d = CutPegSize().Value();
            ptrdiff_t n = zs_app_part_cut(model->Active(), part, CutHeight().Value(), CutFlip().IsChecked().GetBoolean() ? 1 : 0,
                                          std::isnan(pegs) ? 0 : (int)pegs, std::isnan(peg_d) ? 5 : peg_d);
            PartCutFlyout().Hide();
            if (n > 0)
            {
                ClearSelection();
                PlateEdited();
            }
            else
            {
                ShowToast(L"The cut did not make two parts.");
            }
        });
    }

    void MainWindow::MakeCardMovable(FrameworkElement const &card, FrameworkElement const &head, bool *moved)
    {
        struct Drag
        {
            bool on = false;
            double x = 0, y = 0;
        };
        auto state = std::make_shared<Drag>();
        head.PointerPressed([this, card, head, state](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto at = e.GetCurrentPoint(CardLayer()).Position();
            state->on = true;
            state->x = at.X - Canvas::GetLeft(card);
            state->y = at.Y - Canvas::GetTop(card);
            head.CapturePointer(e.Pointer());
            e.Handled(true);
        });
        head.PointerMoved([this, card, state, moved](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!state->on)
                return;
            auto at = e.GetCurrentPoint(CardLayer()).Position();
            Canvas::SetLeft(card, at.X - state->x);
            Canvas::SetTop(card, at.Y - state->y);
            *moved = true;
            e.Handled(true);
        });
        auto end = [head, state](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!state->on)
                return;
            state->on = false;
            head.ReleasePointerCapture(e.Pointer());
        };
        head.PointerReleased(end);
        head.PointerCaptureLost(end);
    }

    void MainWindow::HideCards()
    {
        LineCard().Visibility(Visibility::Collapsed);
        PartCard().Visibility(Visibility::Collapsed);
        LineSettings().Children().Clear();
        line_editors.clear();
    }

    // Beside the box (points of the view), inside the view, and off it.
    void MainWindow::PlaceCard(FrameworkElement const &card, double const box[4])
    {
        double const margin = 10;
        double left = 60; // the tool strip
        double right = CardLayer().ActualWidth() - margin;
        // The panel over the view covers the right of it, with the rail. Its
        // width is set before it shows.
        if (panel_mode == PanelMode::Over)
            right -= SettingsPane().Width();
        else if (LayerCard().Visibility() == Visibility::Visible)
            right -= LayerCard().ActualWidth() + 16;
        // A narrow free area: the card wraps, and stays off the panel.
        card.MaxWidth(std::max(240.0, right - left));
        card.UpdateLayout();
        double w = card.ActualWidth(), h = card.ActualHeight();
        if (w <= 0 || h <= 0)
        {
            card.Measure({ (float)card.MaxWidth(), 10000 });
            w = card.DesiredSize().Width;
            h = card.DesiredSize().Height;
        }
        double top = margin;
        double bottom = CardLayer().ActualHeight() - 66; // the plate bar
        double x, y;
        double cy = std::clamp((box[1] + box[3] - h) / 2, top, std::max(top, bottom - h));
        double cx = std::clamp((box[0] + box[2] - w) / 2, left, std::max(left, right - w));
        if (box[2] + margin + w <= right)
        {
            x = box[2] + margin;
            y = cy;
        }
        else if (box[0] - margin - w >= left)
        {
            x = box[0] - margin - w;
            y = cy;
        }
        else if (box[1] - margin - h >= top)
        {
            x = cx;
            y = box[1] - margin - h;
        }
        else if (box[3] + margin + h <= bottom)
        {
            x = cx;
            y = box[3] + margin;
        }
        else
        {
            // No free side: the corner farthest from the box.
            x = (box[0] + box[2]) / 2 > (left + right) / 2 ? left : right - w;
            y = top;
        }
        Canvas::SetLeft(card, std::clamp(x, left, std::max(left, right - w)));
        Canvas::SetTop(card, std::clamp(y, top, std::max(top, bottom - h)));
    }

    // The panel opened, closed, or changed: each open card moves clear of
    // it, unless the user placed the card.
    void MainWindow::PlaceOpenCards()
    {
        PlaceLineCard();
        PlacePartCard();
        std::fill(std::begin(measure_box), std::end(measure_box), 0.0);
        if (MeasureCard().Visibility() == Visibility::Visible)
            PlaceMeasure();
        LabelPlace(true);
        RangePlace(true);
    }

    void MainWindow::PlaceLineCard()
    {
        if (LineCard().Visibility() != Visibility::Visible || line_card_moved || view == nullptr || SelectedPath() < 0)
            return;
        double box[4] = { click_x - 12, click_y - 12, click_x + 12, click_y + 12 };
        float r[4];
        if (zs_view_path_rect(view, (size_t)SelectedPath(), r))
        {
            double s = Scale();
            box[0] = std::min(box[0], r[0] / s - 12);
            box[1] = std::min(box[1], r[1] / s - 12);
            box[2] = std::max(box[2], r[2] / s + 12);
            box[3] = std::max(box[3], r[3] / s + 12);
        }
        PlaceCard(LineCard(), box);
    }

    void MainWindow::PlacePartCard()
    {
        if (PartCard().Visibility() != Visibility::Visible || part_card_moved || view == nullptr || model == nullptr)
            return;
        // A narrow view beside a pinned panel: the card stays in the view.
        PartCard().Width(std::clamp(CardLayer().ActualWidth() - 66, 240.0, 320.0));
        double box[4] = { 1e9, 1e9, -1e9, -1e9 };
        double s = Scale();
        for (int64_t i : SelectedParts())
        {
            zs_part p{};
            if (zs_app_part_get(model->Active(), (size_t)i, &p) != ZS_OK)
                continue;
            // The gizmo counts too: the arrows end at 1.5 radii.
            double ring = 1.5 * (0.62 * std::max({ p.size_x, p.size_y, p.size_z }) + 4);
            double hx = std::max(p.size_x / 2, ring), hy = std::max(p.size_y / 2, ring);
            double top = std::max(p.size_z, p.size_z / 2 + ring);
            for (int k = 0; k < 8; k++)
            {
                float qx, qy;
                if (!zs_view_pixel_of(view, p.x + (k & 1 ? hx : -hx), p.y + (k & 2 ? hy : -hy), k & 4 ? top : 0, &qx, &qy))
                    continue;
                box[0] = std::min(box[0], qx / s);
                box[1] = std::min(box[1], qy / s);
                box[2] = std::max(box[2], qx / s);
                box[3] = std::max(box[3], qy / s);
            }
        }
        if (box[0] > box[2])
        {
            box[0] = box[2] = CardLayer().ActualWidth() - 40;
            box[1] = box[3] = 60;
        }
        PlaceCard(PartCard(), box);
    }

    // The support mark at the selected line: above a support line (the
    // support goes down from the mark), or on the layer of another line.
    int64_t MainWindow::MarkOfSelection()
    {
        zs_app *app = model->Active();
        double x, y, z;
        if (zs_app_mark_count(app) == 0 || !MenuPlace(x, y, z))
            return -1;
        zs_toolpaths tp{};
        if (zs_app_toolpaths(app, &tp) != ZS_OK)
            return -1;
        int feature = tp.path_features[SelectedPath()];
        bool support = feature == ZS_FEATURE_SUPPORT || feature == ZS_FEATURE_SUPPORT_INTERFACE;
        auto at = [&](double px, double py) { return support ? zs_app_mark_at(app, px, py, z + 500, 500) : zs_app_mark_at(app, px, py, z, 0.05); };
        ptrdiff_t mark = at(x, y);
        // A slice can renumber the lines, and the selection then has no
        // segment: any point of the line finds its mark.
        if (mark < 0 && SelectedSegment() < 0)
        {
            uint32_t first = SelectedPath() == 0 ? 0 : tp.path_ends[SelectedPath() - 1], end = tp.path_ends[SelectedPath()];
            for (uint32_t i = first; i < end && mark < 0; i++)
                mark = at(tp.points[2 * i], tp.points[2 * i + 1]);
        }
        return mark >= 0 ? (int64_t)mark : -1;
    }

    void MainWindow::WireLineMark()
    {
        LineMarkKind().SelectionChanged([this](auto &&, auto &&) {
            int32_t kind = LineMarkKind().SelectedIndex();
            double r = 3;
            if (line_mark_filling || model == nullptr || line_mark < 0 || kind < 0 ||
                zs_app_mark_get(model->Active(), (size_t)line_mark, nullptr, nullptr, nullptr, &r, nullptr) != ZS_OK)
                return;
            if (zs_app_mark_set(model->Active(), (size_t)line_mark, kind, r) == ZS_OK)
                SupportEdited();
        });
        LineMarkRadius().ValueChanged([this](NumberBox const &, NumberBoxValueChangedEventArgs const &e) {
            if (line_mark_filling || model == nullptr || line_mark < 0)
                return;
            int kind = 0;
            double r = 3;
            if (zs_app_mark_get(model->Active(), (size_t)line_mark, nullptr, nullptr, nullptr, &r, &kind) != ZS_OK)
                return;
            // An empty entry has no value: the radius stays.
            if (std::isnan(e.NewValue()))
            {
                line_mark_filling = true;
                LineMarkRadius().Value(r);
                line_mark_filling = false;
                return;
            }
            double value = std::clamp(e.NewValue(), 0.5, 30.0);
            if (std::abs(value - r) > 1e-6 && zs_app_mark_set(model->Active(), (size_t)line_mark, kind, value) == ZS_OK)
                SupportEdited();
        });
        LineMarkRemove().Click([this](auto &&, auto &&) {
            if (model == nullptr || line_mark < 0)
                return;
            zs_app_mark_remove(model->Active(), (size_t)line_mark);
            line_mark = -1;
            LineMark().Visibility(Visibility::Collapsed);
            SupportEdited();
        });
    }

    void MainWindow::FillLineMark()
    {
        line_mark = MarkOfSelection();
        double r = 3;
        int kind = 0;
        bool shown = line_mark >= 0 && zs_app_mark_get(model->Active(), (size_t)line_mark, nullptr, nullptr, nullptr, &r, &kind) == ZS_OK;
        LineMark().Visibility(shown ? Visibility::Visible : Visibility::Collapsed);
        if (!shown)
        {
            line_mark = -1;
            return;
        }
        line_mark_filling = true;
        if (LineMarkKind().SelectedIndex() != kind)
            LineMarkKind().SelectedIndex(kind);
        if (LineMarkRadius().Value() != r)
            LineMarkRadius().Value(r);
        line_mark_filling = false;
    }

    void MainWindow::FillLineCard()
    {
        if (model == nullptr || SelectedPath() < 0)
        {
            LineCard().Visibility(Visibility::Collapsed);
            line_editors.clear();
            return;
        }
        zs_app *app = model->Active();
        zs_inspect info{};
        if (zs_app_inspect(app, (size_t)SelectedPath(), &info) != ZS_OK)
        {
            LineCard().Visibility(Visibility::Collapsed);
            return;
        }
        // A printer with more than one nozzle: the nozzle of the line.
        std::wstring nozzle = info.nozzle == 1 ? std::wstring(L" · main nozzle")
                              : info.nozzle == 2 ? std::wstring(L" · 2nd nozzle")
                              : info.nozzle > 2  ? L" · nozzle T" + std::to_wstring(info.nozzle - 1)
                                                 : std::wstring();
        LineTitle().Text(zs::ToWide(info.title) + L" · layer " + std::to_wstring(info.layer + 1) + nozzle);
        wchar_t text[64];
        swprintf_s(text, L"%.0f mm/s", info.planned_speed);
        LinePlanned().Text(text);
        swprintf_s(text, L"%.0f mm/s", info.speed);
        LineReal().Text(text);
        swprintf_s(text, L"%.1f mm³/s", info.flow);
        LineFlow().Text(text);
        // The speed limits of a nozzle after the first.
        std::wstring limits = info.nozzle >= 2 && info.nozzle_text != nullptr ? zs::ToWide(info.nozzle_text) : L"";
        LineNozzle().Text(limits);
        LineNozzle().Visibility(limits.empty() ? Visibility::Collapsed : Visibility::Visible);
        FillLineNotes(info);

        zs_measure m{};
        size_t segment = SelectedSegment() < 0 ? 0 : (size_t)SelectedSegment();
        if (zs_app_measure(app, (size_t)SelectedPath(), segment, &m) == ZS_OK)
        {
            wchar_t size[128] = L"";
            if (m.shape == 1)
                swprintf_s(size, L"Circle ⌀ %.2f mm · ", 2 * m.radius);
            else if (m.shape == 2)
                swprintf_s(size, L"Arc r %.2f mm · ", m.radius);
            wchar_t rest[96];
            swprintf_s(rest, L"segment %.2f mm · %s %.1f mm", m.segment_length, m.closed ? L"loop" : L"path", m.path_length);
            LineSize().Text(std::wstring(size) + rest);
            LineSize().Visibility(Visibility::Visible);
        }
        else
        {
            LineSize().Visibility(Visibility::Collapsed);
        }

        // The settings that matter most for this line, from the core.
        LineSettings().Children().Clear();
        std::vector<SettingEditor> kept;
        kept.swap(setting_editors);
        zs_pick picks[4];
        size_t n = 0;
        if (zs_app_inspect_picks(app, (size_t)SelectedPath(), picks, 4, &n) != ZS_OK)
            n = 0;
        for (size_t i = 0; i < n; i++)
        {
            zs_setting_info s{};
            if (!FindSetting(picks[i].name, s))
                continue;
            Grid row;
            row.ColumnSpacing(6);
            ColumnDefinition label_column, editor_column;
            label_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
            editor_column.Width(GridLengthHelper::FromValueAndType(130, GridUnitType::Pixel));
            row.ColumnDefinitions().Append(label_column);
            row.ColumnDefinitions().Append(editor_column);
            StackPanel labels;
            labels.VerticalAlignment(VerticalAlignment::Center);
            TextBlock name;
            name.Text(zs::ToWide(s.label));
            name.TextWrapping(TextWrapping::WrapWholeWords);
            name.FontSize(13);
            ToolTipService::SetToolTip(name, box_value(PlainDoc(s.doc)));
            labels.Children().Append(name);
            row.Children().Append(labels);
            FrameworkElement editor = MakeEditor(s);
            Grid::SetColumn(editor, 1);
            row.Children().Append(editor);
            LineSettings().Children().Append(row);
        }
        // The editors of the card refresh as the pane's do.
        line_editors.swap(setting_editors);
        setting_editors.swap(kept);
        setting_editors.insert(setting_editors.end(), line_editors.begin(), line_editors.end());

        FillLineFilament();
        FillLineMark();
        PartCard().Visibility(Visibility::Collapsed);
        LineCard().Visibility(Visibility::Visible);
        PlaceLineCard();
    }

    // What a support line holds up, and the warnings of the check at this
    // line, as the Mac and web cards show them. Only a check that has run:
    // the check of a whole slice can take too long for a click.
    void MainWindow::FillLineNotes(zs_inspect const &info)
    {
        static wchar_t const *const names[ZS_FEATURE_COUNT] = { L"outer wall", L"inner wall", L"skin", L"sparse infill", L"ironing", L"skirt or brim",
                                                                L"support", L"support interface", L"slope smoothing", L"slope ironing", L"bridge" };
        auto box = LineNotes();
        box.Children().Clear();
        auto add = [&](std::wstring const &words, bool warn) {
            TextBlock note;
            note.Text(words);
            note.FontSize(12);
            note.TextWrapping(TextWrapping::WrapWholeWords);
            note.Foreground(TokenBrush(Root(), warn ? L"ZsWarning" : L"ZsDim"));
            box.Children().Append(note);
        };
        if (info.holds_layer != ZS_NO_PATH)
        {
            std::wstring what = info.holds_feature >= 0 && info.holds_feature < ZS_FEATURE_COUNT ? names[info.holds_feature] : L"part";
            size_t up = info.holds_layer - info.layer;
            add(L"Holds up: " + what + L" on layer " + std::to_wstring(info.holds_layer + 1) + L", " + std::to_wstring(up) + (up == 1 ? L" layer up." : L" layers up."), false);
        }
        else if (info.feature == ZS_FEATURE_SUPPORT || info.feature == ZS_FEATURE_SUPPORT_INTERFACE)
        {
            add(L"Holds up: no part line over it on the next layers.", false);
        }
        zs_app *app = model->Active();
        zs_issue const *issues = nullptr;
        size_t n = 0;
        char const *words = nullptr;
        zs_toolpaths tp{};
        if (zs_app_checks_ready(app) != 0 && zs_app_checks(app, &issues, &n, &words) == ZS_OK && zs_app_toolpaths(app, &tp) == ZS_OK && info.path < tp.path_count)
        {
            uint32_t start = info.path == 0 ? 0 : tp.path_ends[info.path - 1], end = tp.path_ends[info.path];
            uint32_t seen = 0;
            int kinds = 0;
            for (size_t i = 0; i < n && kinds < 2; i++)
            {
                zs_issue const &issue = issues[i];
                bool wanted = issue.kind == ZS_ISSUE_FLOW || issue.kind == ZS_ISSUE_COOLING || issue.kind == ZS_ISSUE_OVERHANG || issue.kind == ZS_ISSUE_ISLAND ||
                              issue.kind == ZS_ISSUE_BRIDGE;
                if (issue.severity < 1 || !wanted || issue.layer != info.layer || (seen & (1u << issue.kind)) != 0)
                    continue;
                // Its own issue, or one within 3 mm of the line.
                bool hit = issue.path == info.path;
                for (uint32_t k = start; k < end && !hit; k++)
                    hit = std::hypot(tp.points[2 * k] - issue.x, tp.points[2 * k + 1] - issue.y) <= 3;
                if (!hit)
                    continue;
                seen |= 1u << issue.kind;
                kinds++;
                add(L"⚠ " + zs::ToWide(std::string(words + issue.text_start, issue.text_len)), true);
            }
        }
        box.Visibility(box.Children().Size() > 0 ? Visibility::Visible : Visibility::Collapsed);
    }

    // The check of the slice is ready: only the notes change, so an editor
    // of the card keeps its focus.
    void MainWindow::RefreshLineNotes()
    {
        if (model == nullptr || SelectedPath() < 0 || LineCard().Visibility() != Visibility::Visible)
            return;
        zs_inspect info{};
        if (zs_app_inspect(model->Active(), (size_t)SelectedPath(), &info) == ZS_OK)
            FillLineNotes(info);
    }

    void MainWindow::FillPartCard()
    {
        if (model == nullptr || SelectedParts().empty())
        {
            PartCard().Visibility(Visibility::Collapsed);
            return;
        }
        zs_app *app = model->Active();
        bool many = SelectedParts().size() > 1;
        PartSingle().Visibility(many ? Visibility::Collapsed : Visibility::Visible);
        PartsDuplicate().Visibility(many ? Visibility::Visible : Visibility::Collapsed);
        PartsArrange().Visibility(many ? Visibility::Visible : Visibility::Collapsed);
        PartAddSetting().Content(box_value(many ? L"+ Add a setting for these parts" : L"+ Add a setting for this part"));
        ToolTipService::SetToolTip(PartAddSetting(), box_value(many ? L"Search the settings that a part can have of its own: the edit goes to each of these parts"
                                                                    : L"Search the settings that a part can have of its own"));
        if (many)
        {
            PartTitle().Text(std::to_wstring(SelectedParts().size()) + L" parts");
            PartFacts().Text(L"Drag one to move them all.");
        }
        else
        {
            zs_part p{};
            if (zs_app_part_get(app, (size_t)PrimaryPart(), &p) != ZS_OK)
            {
                PartCard().Visibility(Visibility::Collapsed);
                return;
            }
            PartTitle().Text(p.name != nullptr && p.name[0] != 0 ? zs::ToWide(p.name) : L"Part");
            int turn = (((int)std::lround(p.rotation) % 360) + 360) % 360;
            wchar_t facts[96];
            if (turn != 0)
                swprintf_s(facts, L"%.1f × %.1f × %.1f mm · turned %d°", p.size_x, p.size_y, p.size_z, turn);
            else
                swprintf_s(facts, L"%.1f × %.1f × %.1f mm", p.size_x, p.size_y, p.size_z);
            PartFacts().Text(facts);
            auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot());
            if (focused == nullptr || focused != PartScale().try_as<Windows::Foundation::IInspectable>())
            {
                wchar_t scale[32];
                swprintf_s(scale, L"%.4g", p.scale_x * 100);
                scale_shown = scale;
                scale_edited = false;
                PartScale().Text(scale);
            }
            ShowPose(p);
            // Why the part floats over the bed.
            char float_note[256] = "";
            size_t float_len = 0;
            bool floats = zs_app_part_float_note(app, (size_t)PrimaryPart(), float_note, sizeof float_note, &float_len) == ZS_OK;
            PartFloatNote().Text(floats ? zs::ToWide(float_note) : std::wstring());
            PartFloatNote().Visibility(floats ? Visibility::Visible : Visibility::Collapsed);
            FillPartOrder();
            FillPartExtras();
        }
        LineCard().Visibility(Visibility::Collapsed);
        PartCard().Visibility(Visibility::Visible);
        PlacePartCard();
    }

    Microsoft::UI::Xaml::Controls::TextBox MainWindow::PoseBox(int field)
    {
        switch (field)
        {
        case 0: return PartPose0();
        case 1: return PartPose1();
        case 2: return PartPose2();
        case 3: return PartPose3();
        case 4: return PartPose4();
        default: return PartPose5();
        }
    }

    // The pose follows the part, except the field that the user types in.
    void MainWindow::ShowPose(zs_part const &p)
    {
        double values[6] = { p.x, p.y, p.z, p.angle_x, p.angle_y, p.angle_z };
        auto focused = Input::FocusManager::GetFocusedElement(Content().XamlRoot());
        for (int field = 0; field < 6; field++)
        {
            auto box = PoseBox(field);
            if (focused != nullptr && focused == box.try_as<Windows::Foundation::IInspectable>())
                continue;
            wchar_t text[32];
            swprintf_s(text, L"%.2f", std::round(values[field] * 100) / 100 + 0.0);
            box.Text(text);
        }
    }

    // Enter: one change of the part, and the physics after it.
    void MainWindow::ApplyPose(int field)
    {
        std::vector<int64_t> parts = SelectedParts();
        zs_part p{};
        if (parts.size() != 1 || zs_app_part_get(model->Active(), (size_t)parts[0], &p) != ZS_OK)
            return;
        zs_app *app = model->Active();
        size_t i = (size_t)parts[0];
        std::wstring text{ PoseBox(field).Text() };
        wchar_t *end = nullptr;
        double v = wcstod(text.c_str(), &end);
        if (end == text.c_str() || !std::isfinite(v))
            return;
        int rc = ZS_OK;
        if (field <= 1)
        {
            if (std::abs(v - (field == 0 ? p.x : p.y)) < 1e-6)
                return;
            rc = zs_app_part_move(app, i, field == 0 ? v : p.x, field == 1 ? v : p.y);
        }
        else if (field == 2)
        {
            if (std::abs(v - p.z) < 1e-6)
                return;
            rc = zs_app_part_lift(app, i, v);
        }
        else
        {
            double angles[3] = { p.angle_x, p.angle_y, p.angle_z };
            if (std::abs(v - angles[field - 3]) < 1e-6)
                return;
            angles[field - 3] = v;
            rc = zs_app_part_set_angles(app, i, angles[0], angles[1], angles[2]);
        }
        if (rc != ZS_OK)
            return;
        PlateEdited();
        CheckFall();
    }

    // The place of the part in the print order, shown only with
    // project.print_sequence = by_object and two parts or more.
    void MainWindow::FillPartOrder()
    {
        if (model == nullptr || SelectedParts().size() != 1)
            return;
        size_t count = zs_app_part_count(model->Active()), part = (size_t)PrimaryPart();
        bool on = count > 1 && model->GetSetting("project.print_sequence") == "by_object";
        PartOrderRow().Visibility(on ? Visibility::Visible : Visibility::Collapsed);
        if (!on)
            return;
        PartOrderText().Text(L"Prints " + std::to_wstring(part + 1) + L" of " + std::to_wstring(count));
        PartEarlier().IsEnabled(part > 0);
        PartLater().IsEnabled(part + 1 < count);
    }

    // The plate list is the print order. The part stays selected at its
    // new place.
    void MainWindow::MovePartInOrder(int direction)
    {
        if (model == nullptr || SelectedParts().size() != 1 || falling)
            return;
        size_t part = (size_t)PrimaryPart();
        if (direction < 0 && part == 0)
            return;
        size_t to = direction < 0 ? part - 1 : part + 1;
        if (zs_app_part_reorder(model->Active(), part, to) != ZS_OK)
            return;
        SelectPart((int64_t)to);
        PlateEdited();
    }
}
