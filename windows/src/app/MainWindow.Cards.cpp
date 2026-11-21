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
    void MainWindow::WireCards()
    {
        LineClose().Click([this](auto &&, auto &&) { ClearSelection(); });
        PartClose().Click([this](auto &&, auto &&) { ClearSelection(); });
        MakeCardMovable(LineCard(), LineCardHead(), &line_card_moved);
        MakeCardMovable(PartCard(), PartCardHead(), &part_card_moved);

        LineFade().Click([this](auto &&, auto &&) {
            if (view == nullptr)
                return;
            zs_view_isolate(view, LineFade().IsChecked().GetBoolean() ? 1 : 0);
            RequestDraw();
        });
        LineAll().Click([this](auto &&, auto &&) {
            if (selected_path < 0)
                return;
            zs_inspect info{};
            if (zs_app_inspect(model->Active(), (size_t)selected_path, &info) != ZS_OK)
                return;
            ShowSettingsPane(true);
            zs_pick picks[1];
            size_t n = 0;
            if (zs_app_inspect_picks(model->Active(), (size_t)selected_path, picks, 1, &n) == ZS_OK && n > 0)
            {
                detail_from = SettingsPage::Sections;
                ShowDetail(picks[0].name);
            }
        });
        auto edit = [this](int kind, double value) {
            if (model == nullptr || selected_path < 0)
                return;
            if (zs_app_edit_add(model->Active(), (size_t)selected_path, kind, value) == ZS_OK)
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
            if (model != nullptr && selected_parts.size() == 1)
                action(model->Active(), (size_t)selected_parts[0]);
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
                    StatusText().Text(L"This part is one piece.");
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
        auto commit_scale = [this, one]() {
            one([this](zs_app *app, size_t i) {
                std::wstring text{ PartScale().Text() };
                wchar_t *end = nullptr;
                double percent = wcstod(text.c_str(), &end);
                zs_part p{};
                if (end == text.c_str() || percent <= 0 || zs_app_part_get(app, i, &p) != ZS_OK)
                {
                    FillPartCard();
                    return;
                }
                double scale = percent / 100;
                if (std::abs(scale - p.scale_x) < 1e-4 && std::abs(scale - p.scale_y) < 1e-4 && std::abs(scale - p.scale_z) < 1e-4)
                    return;
                if (zs_app_part_scale(app, i, scale, scale, scale) == ZS_OK)
                    PlateEdited();
            });
        };
        PartScale().KeyDown([commit_scale](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() == Windows::System::VirtualKey::Enter)
            {
                commit_scale();
                e.Handled(true);
            }
        });
        PartScale().LostFocus([commit_scale](auto &&, auto &&) { commit_scale(); });
        PartMake().Click([this](auto &&, auto &&) {
            if (model == nullptr || selected_parts.size() != 1)
                return;
            size_t want = (size_t)std::max(1.0, PartMakeCount().Value());
            size_t plates = 0;
            ptrdiff_t made = zs_set_fill(model->Set(), model->ActivePlate(), (size_t)selected_parts[0], want, &plates);
            if (made < 0)
                StatusText().Text(L"No copies were made.");
            else if ((size_t)made < want)
                StatusText().Text(to_hstring(made) + L" of " + to_hstring(want) + L" fit: the part is too big for more plates.");
            else
                StatusText().Text(to_hstring(made) + L" in all, on " + to_hstring(plates) + L" plates.");
            ClearSelection();
            for (size_t i = 0; i < model->PlateCount(); i++)
                zs_set_changed(model->Set(), i);
            NoteChange();
            ShowPlate();
        });
        PartNewPlate().Click([this](auto &&, auto &&) {
            if (model == nullptr || selected_parts.empty())
                return;
            std::vector<int64_t> list = selected_parts;
            std::sort(list.rbegin(), list.rend());
            ClearSelection();
            for (int64_t i : list)
                zs_set_part_move(model->Set(), model->ActivePlate(), (size_t)i, -1);
            PlateEdited();
        });
        PartRemove().Click([this](auto &&, auto &&) {
            if (model == nullptr || selected_parts.empty())
                return;
            std::vector<int64_t> list = selected_parts;
            std::sort(list.rbegin(), list.rend());
            ClearSelection();
            for (int64_t i : list)
                zs_app_part_remove(model->Active(), (size_t)i);
            PlateEdited();
        });
        PartsDuplicate().Click([this](auto &&, auto &&) {
            if (model == nullptr)
                return;
            for (int64_t i : std::vector<int64_t>(selected_parts))
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
            if (view == nullptr || model == nullptr || selected_parts.size() != 1)
                return;
            zs_part p{};
            if (zs_app_part_get(model->Active(), (size_t)selected_parts[0], &p) != ZS_OK)
                return;
            double m = 0.55 * std::max(p.size_x, p.size_y) + 4;
            zs_view_set_cut(view, p.x - m, p.y - m, p.x + m, p.y + m, CutHeight().Value());
            RequestDraw();
        };
        PartCutFlyout().Opened([this, show_cut](auto &&, auto &&) {
            if (model == nullptr || selected_parts.size() != 1)
                return;
            zs_part p{};
            if (zs_app_part_get(model->Active(), (size_t)selected_parts[0], &p) != ZS_OK)
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
            if (model == nullptr || selected_parts.size() != 1)
                return;
            size_t part = (size_t)selected_parts[0];
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
                StatusText().Text(L"The cut did not make two parts.");
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
        card.UpdateLayout();
        double w = card.ActualWidth(), h = card.ActualHeight();
        if (w <= 0 || h <= 0)
        {
            card.Measure({ 10000, 10000 });
            w = card.DesiredSize().Width;
            h = card.DesiredSize().Height;
        }
        double const margin = 10;
        double left = 60; // the tool strip
        double right = CardLayer().ActualWidth() - margin;
        if (LayerCard().Visibility() == Visibility::Visible)
            right -= LayerCard().ActualWidth() + 16;
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
        Canvas::SetLeft(card, x);
        Canvas::SetTop(card, y);
    }

    void MainWindow::PlaceLineCard()
    {
        if (LineCard().Visibility() != Visibility::Visible || line_card_moved || view == nullptr || selected_path < 0)
            return;
        double box[4] = { click_x - 12, click_y - 12, click_x + 12, click_y + 12 };
        float r[4];
        if (zs_view_path_rect(view, (size_t)selected_path, r))
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
        double box[4] = { 1e9, 1e9, -1e9, -1e9 };
        double s = Scale();
        for (int64_t i : selected_parts)
        {
            zs_part p{};
            if (zs_app_part_get(model->Active(), (size_t)i, &p) != ZS_OK)
                continue;
            // The rings of the Turn tool count too.
            double ring = 0.62 * std::max({ p.size_x, p.size_y, p.size_z }) + 4;
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

    void MainWindow::FillLineCard()
    {
        if (model == nullptr || selected_path < 0)
        {
            LineCard().Visibility(Visibility::Collapsed);
            line_editors.clear();
            return;
        }
        zs_app *app = model->Active();
        zs_inspect info{};
        if (zs_app_inspect(app, (size_t)selected_path, &info) != ZS_OK)
        {
            LineCard().Visibility(Visibility::Collapsed);
            return;
        }
        LineTitle().Text(zs::ToWide(info.title) + L" · layer " + std::to_wstring(info.layer + 1));
        wchar_t text[64];
        swprintf_s(text, L"%.0f mm/s", info.planned_speed);
        LinePlanned().Text(text);
        swprintf_s(text, L"%.0f mm/s", info.speed);
        LineReal().Text(text);
        swprintf_s(text, L"%.1f mm³/s", info.flow);
        LineFlow().Text(text);
        std::wstring note = zs::ToWide(info.slow_text != nullptr ? info.slow_text : "");
        LineNote().Text(note);
        LineNote().Visibility(note.empty() ? Visibility::Collapsed : Visibility::Visible);

        zs_measure m{};
        size_t segment = selected_segment < 0 ? 0 : (size_t)selected_segment;
        if (zs_app_measure(app, (size_t)selected_path, segment, &m) == ZS_OK)
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
        if (zs_app_inspect_picks(app, (size_t)selected_path, picks, 4, &n) != ZS_OK)
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
            if (picks[i].why != nullptr && picks[i].why[0] != 0)
            {
                TextBlock why;
                why.Text(zs::ToWide(picks[i].why));
                why.TextWrapping(TextWrapping::WrapWholeWords);
                why.FontSize(11);
                why.Opacity(0.7);
                labels.Children().Append(why);
            }
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

        PartCard().Visibility(Visibility::Collapsed);
        LineCard().Visibility(Visibility::Visible);
        PlaceLineCard();
    }

    void MainWindow::FillPartCard()
    {
        if (model == nullptr || selected_parts.empty())
        {
            PartCard().Visibility(Visibility::Collapsed);
            return;
        }
        zs_app *app = model->Active();
        bool many = selected_parts.size() > 1;
        PartSingle().Visibility(many ? Visibility::Collapsed : Visibility::Visible);
        PartsDuplicate().Visibility(many ? Visibility::Visible : Visibility::Collapsed);
        PartsArrange().Visibility(many ? Visibility::Visible : Visibility::Collapsed);
        if (many)
        {
            PartTitle().Text(std::to_wstring(selected_parts.size()) + L" parts");
            PartFacts().Text(L"Drag one to move them all.");
        }
        else
        {
            zs_part p{};
            if (zs_app_part_get(app, (size_t)selected_parts[0], &p) != ZS_OK)
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
                PartScale().Text(scale);
            }
        }
        LineCard().Visibility(Visibility::Collapsed);
        PartCard().Visibility(Visibility::Visible);
        PlacePartCard();
    }
}
