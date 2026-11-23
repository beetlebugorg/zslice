// The history behind a button of the bottom bar, as in web/app/history.js.
//
// The button opens the list of the steps over it, the newest first (Ctrl+H
// opens and closes it). A number on the button counts the changes since the
// last open or save, from the times of the steps. Each change of the step
// now or an earlier step has an undo button for that change alone. A right
// click on a step goes to it, or clears the history after it.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

#include "pch.h"
#include "MainWindow.xaml.h"
#include <algorithm>
#include <limits>

#include <charconv>
#include <ctime>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
namespace Input = Microsoft::UI::Xaml::Input;
namespace Media = Microsoft::UI::Xaml::Media;
using Windows::System::VirtualKey;

namespace
{
    std::wstring Clock(int64_t ms)
    {
        time_t seconds = (time_t)(ms / 1000);
        tm local{};
        if (localtime_s(&local, &seconds) != 0)
            return {};
        wchar_t text[32];
        return wcsftime(text, ARRAYSIZE(text), L"%X", &local) > 0 ? std::wstring(text) : std::wstring();
    }

    std::vector<std::string> Lines(char const *text, size_t len)
    {
        std::vector<std::string> out;
        std::string all(text != nullptr ? text : "", text != nullptr ? len : 0);
        size_t at = 0;
        for (;;)
        {
            size_t end = all.find('\n', at);
            out.push_back(all.substr(at, end == std::string::npos ? end : end - at));
            if (end == std::string::npos)
                return out;
            at = end + 1;
        }
    }

    TextBlock Words(std::wstring const &text, double size, Media::Brush const &brush = nullptr)
    {
        TextBlock t;
        t.Text(text);
        t.FontSize(size);
        t.TextWrapping(TextWrapping::Wrap);
        if (brush != nullptr)
            t.Foreground(brush);
        return t;
    }

    Button FlatButton(hstring const &text)
    {
        Button b;
        b.Content(box_value(text));
        b.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
        b.MinHeight(24);
        b.MinWidth(0);
        b.FontSize(12);
        b.Padding(ThicknessHelper::FromLengths(8, 1, 8, 1));
        b.VerticalAlignment(VerticalAlignment::Center);
        return b;
    }

    bool FindInfo(std::string const &name, zs_setting_info &out)
    {
        size_t n = zs_setting_count();
        for (size_t i = 0; i < n; i++)
            if (zs_setting_get_info(i, &out) == ZS_OK && name == out.name)
                return true;
        return false;
    }

    std::wstring ChangeCount(size_t n)
    {
        return std::to_wstring(n) + (n == 1 ? L" change" : L" changes");
    }

    int64_t NowMs()
    {
        return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    }
}

namespace winrt::ZSlice::implementation
{
    Media::Brush TokenBrush(FrameworkElement const &element, wchar_t const *key);
    Windows::UI::Color StepColor(char const *kind);
    std::wstring StepLabel(char const *kind);
    UIElement StepGlyph(char const *kind, double size);

    void MainWindow::WireHistory()
    {
        HistoryFlyout().Opening([this](auto &&, auto &&) {
            history_timer.Stop();
            if (model != nullptr && model->HistoryCommit())
                RefreshHistoryButtons();
            // It opens over the button, and never covers it.
            Windows::Foundation::Rect size{ 0, 0, (float)HistoryButton().ActualWidth(), (float)HistoryButton().ActualHeight() };
            auto button = HistoryButton().TransformToVisual(Root()).TransformBounds(size);
            HistoryScroll().MaxHeight(std::max(160.0, std::min(500.0, (double)button.Y - 110)));
            FillHistoryList();
        });
        HistoryFlyout().Opened([this](auto &&, auto &&) { HistoryScroll().Focus(FocusState::Programmatic); });
        HistoryClose().Click([this](auto &&, auto &&) { HistoryFlyout().Hide(); });
        // The list shows the newest first: up is the next step.
        HistoryScroll().PreviewKeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (model == nullptr)
                return;
            bool ctrl = (Microsoft::UI::Input::InputKeyboardSource::GetKeyStateForCurrentThread(VirtualKey::Control) &
                         Windows::UI::Core::CoreVirtualKeyStates::Down) == Windows::UI::Core::CoreVirtualKeyStates::Down;
            if (ctrl && e.Key() == VirtualKey::H)
            {
                HistoryFlyout().Hide();
                e.Handled(true);
                return;
            }
            if (ctrl)
                return;
            zs_app *app = model->Active();
            size_t now = zs_app_history_current(app), count = zs_app_history_count(app);
            if (e.Key() == VirtualKey::Up && now + 1 < count)
                GoToStep(now + 1);
            else if (e.Key() == VirtualKey::Down && now > 0)
                GoToStep(now - 1);
            else if (e.Key() != VirtualKey::Up && e.Key() != VirtualKey::Down)
                return;
            e.Handled(true);
        });
    }

    // An open or a save: the count of the button starts again.
    void MainWindow::MarkHistorySaved()
    {
        history_saved_ms = NowMs();
        history_shown_app = nullptr;
        RefreshHistoryButton();
    }

    // The changes since the last open or save: the steps after it, and the
    // steps before it that an undo took back.
    size_t MainWindow::UnsavedChanges()
    {
        zs_app *app = model->Active();
        size_t count = zs_app_history_count(app), now = zs_app_history_current(app), n = 0;
        for (size_t i = 1; i < count; i++)
        {
            zs_history_step step{};
            if (zs_app_history_step(app, i, &step) != ZS_OK)
                continue;
            bool after = step.time_ms > history_saved_ms;
            if (i <= now ? after : !after)
                n++;
        }
        return n;
    }

    // The button, its count, and the head of the list.
    void MainWindow::RefreshHistoryButton()
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        size_t count = zs_app_history_count(app), now = zs_app_history_current(app);
        if (app == history_shown_app && count == history_shown_count && now == history_shown_now)
            return;
        history_shown_app = app;
        history_shown_count = count;
        history_shown_now = now;
        size_t changes = count > 0 ? count - 1 : 0;
        size_t unsaved = UnsavedChanges();
        HistoryCount().Visibility(unsaved > 0 ? Visibility::Visible : Visibility::Collapsed);
        HistoryCountText().Text(unsaved > 9 ? std::wstring(L"9+") : std::to_wstring(unsaved));
        std::wstring tip = L"History (" + ChangeCount(changes) + L").";
        if (unsaved > 0)
            tip += L" " + std::to_wstring(unsaved) + L" since you opened or saved.";
        tip += L" Ctrl+H";
        ToolTipService::SetToolTip(HistoryButton(), box_value(tip));
        std::wstring name = L"History, " + ChangeCount(changes);
        if (unsaved > 0)
            name += L", " + std::to_wstring(unsaved) + L" not saved";
        Automation::AutomationProperties::SetName(HistoryButton(), name);
        std::wstring sum;
        if (changes > 0)
        {
            sum = ChangeCount(changes);
            if (now + 1 < count)
                sum += L", at change " + std::to_wstring(now);
        }
        HistorySum().Text(sum);
    }

    void MainWindow::GoToStep(size_t step)
    {
        if (model == nullptr)
            return;
        history_timer.Stop();
        AfterRestore(model->HistoryGoto(step));
        if (HistoryFlyout().IsOpen())
            FillHistoryList();
    }

    // A double click on a change goes to its step and opens the change
    // where it was made: on its part, in its layers, or for the print.
    void MainWindow::OpenHistoryChange(size_t step, std::string const &line)
    {
        if (model == nullptr)
            return;
        size_t first = line.find('\t');
        if (first == std::string::npos)
            return;
        size_t second = line.find('\t', first + 1);
        std::string scope = line.substr(0, first);
        std::string key = line.substr(first + 1, second == std::string::npos ? second : second - first - 1);
        if (step != zs_app_history_current(model->Active()))
            GoToStep(step);
        zs_app *app = model->Active();
        HistoryFlyout().Hide();
        // An edit of a change outside some layers must not go to a profile.
        if (scope.rfind("layers:", 0) != 0)
            LeaveProfile();
        if (scope.rfind("part:", 0) == 0)
        {
            std::string name = scope.substr(5);
            int64_t part = -1;
            for (size_t i = 0, n = zs_app_part_count(app); i < n && part < 0; i++)
            {
                zs_part info{};
                if (zs_app_part_get(app, i, &info) == ZS_OK && info.name != nullptr && name == info.name)
                    part = (int64_t)i;
            }
            if (part < 0)
                return;
            // The place of the part: its card.
            if (key.empty() || key[0] == '(' || key == "position" || key == "rotation" || key == "orientation" || key == "scale")
            {
                SelectPart(part);
                return;
            }
            ShowSettingsPane(true);
            SetSettingsScope(part);
        }
        else if (scope.rfind("layers:", 0) == 0)
        {
            size_t colon = scope.find(':', 7);
            if (colon == std::string::npos)
                return;
            double z_min = 0, z_max = 0;
            char const *low = scope.data() + 7, *high = scope.data() + colon + 1, *end = scope.data() + scope.size();
            if (std::from_chars(low, scope.data() + colon, z_min).ec != std::errc{} || std::from_chars(high, end, z_max).ec != std::errc{})
                return;
            OpenProfile(z_min, z_max);
        }
        else if (settings_scope >= 0)
        {
            SetSettingsScope(-1);
        }
        zs_setting_info info{};
        if (key.empty() || key[0] == '(' || key == "quality" || !FindInfo(key, info))
            return;
        ShowSettingsPane(true);
        detail_from = settings_page;
        ShowDetail(info.name);
    }

    void MainWindow::ClearHistoryAfter(size_t step)
    {
        if (model == nullptr)
            return;
        history_timer.Stop();
        model->HistoryCommit();
        AfterRestore(model->HistoryTruncate(step));
        RefreshHistoryButtons();
        if (HistoryFlyout().IsOpen())
            FillHistoryList();
    }

    void MainWindow::ShowStepMenu(FrameworkElement const &target, Windows::Foundation::Point at, size_t step)
    {
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        size_t now = zs_app_history_current(app), count = zs_app_history_count(app);
        std::wstring name = step == 0 ? L"the start" : L"change " + std::to_wstring(step);
        MenuFlyout menu;
        MenuFlyoutItem go;
        go.Text(L"Go to this change");
        go.IsEnabled(step != now);
        go.Click([this, step](auto &&, auto &&) { GoToStep(step); });
        menu.Items().Append(go);
        menu.Items().Append(MenuFlyoutSeparator{});
        MenuFlyoutItem clear;
        clear.Text(step < now ? L"Go to " + name + L" and clear the history after it" : L"Clear the history after " + name);
        ToolTipService::SetToolTip(clear, box_value(L"The later changes go from the history, and redo cannot bring them back."));
        clear.IsEnabled(step + 1 < count);
        clear.Click([this, step](auto &&, auto &&) { ClearHistoryAfter(step); });
        menu.Items().Append(clear);
        menu.ShowAt(target, at);
    }

    // The steps, the newest first, and the edits of lines.
    void MainWindow::FillHistoryList()
    {
        auto list = HistoryList();
        list.Children().Clear();
        if (model == nullptr)
            return;
        zs_app *app = model->Active();
        size_t count = zs_app_history_count(app), now = zs_app_history_current(app);
        auto dim = TokenBrush(Root(), L"ZsDim");
        auto accent = TokenBrush(Root(), L"ZsAccent");
        if (count <= 1)
        {
            TextBlock none = Words(L"No changes yet. Each change of a setting or of the plate shows here, and you can go back to it.", 13, dim);
            none.Padding(ThicknessHelper::FromLengths(6, 16, 6, 16));
            list.Children().Append(none);
        }
        FrameworkElement now_row{ nullptr };
        for (size_t i = count; count > 1 && i-- > 0;)
        {
            zs_history_step step{};
            if (zs_app_history_step(app, i, &step) != ZS_OK)
                continue;
            auto word_lines = Lines(step.text, step.text_len);
            auto change_lines = Lines(step.changes, step.changes_len);
            char const *kind = i == 0 ? "start" : step.kind;

            StackPanel body;
            body.Spacing(4);
            // The head: the glyph of the kind on its color, the step and
            // its kind, the time, and Now or Go to.
            Grid head;
            head.ColumnSpacing(8);
            for (int c = 0; c < 4; c++)
            {
                ColumnDefinition column;
                column.Width(c == 1 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                head.ColumnDefinitions().Append(column);
            }
            Border dot;
            dot.Width(22);
            dot.Height(22);
            dot.CornerRadius(CornerRadiusHelper::FromUniformRadius(11));
            dot.Background(Media::SolidColorBrush(StepColor(kind)));
            Grid glyph;
            glyph.Width(14);
            glyph.Height(14);
            glyph.Children().Append(StepGlyph(kind, 14));
            dot.Child(glyph);
            head.Children().Append(dot);
            StackPanel titles;
            titles.Orientation(Orientation::Horizontal);
            titles.Spacing(6);
            titles.VerticalAlignment(VerticalAlignment::Center);
            TextBlock title = Words(i == 0 ? std::wstring(L"Start") : L"Change " + std::to_wstring(i), 13);
            title.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
            titles.Children().Append(title);
            if (i != 0)
            {
                TextBlock what = Words(StepLabel(kind), 11.5, dim);
                what.VerticalAlignment(VerticalAlignment::Center);
                titles.Children().Append(what);
            }
            Grid::SetColumn(titles, 1);
            head.Children().Append(titles);
            TextBlock when = Words(Clock(step.time_ms), 12, dim);
            when.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(when, 2);
            head.Children().Append(when);
            Button go{ nullptr };
            if (i == now)
            {
                Border badge;
                badge.Background(accent);
                badge.CornerRadius(CornerRadiusHelper::FromUniformRadius(9));
                badge.Padding(ThicknessHelper::FromLengths(8, 2, 8, 2));
                badge.VerticalAlignment(VerticalAlignment::Center);
                TextBlock text;
                text.Text(L"Now");
                text.FontSize(11);
                text.FontWeight(Microsoft::UI::Text::FontWeights::Bold());
                text.Foreground(Media::SolidColorBrush(Microsoft::UI::Colors::White()));
                badge.Child(text);
                Grid::SetColumn(badge, 3);
                head.Children().Append(badge);
            }
            else
            {
                go = FlatButton(L"Go to");
                go.Opacity(0);
                ToolTipService::SetToolTip(go, box_value(L"Go to this step: the print slices as it was then. The later changes stay until you edit something."));
                go.Click([this, i](auto &&, auto &&) { GoToStep(i); });
                Grid::SetColumn(go, 3);
                head.Children().Append(go);
            }
            body.Children().Append(head);

            if (i == 0)
            {
                body.Children().Append(Words(L"The settings and the plate when the history started.", 12.5, dim));
            }
            else
            {
                size_t shown = 0;
                for (size_t k = 0; k < word_lines.size() && k < change_lines.size(); k++)
                {
                    auto const &words = word_lines[k];
                    size_t tab = words.find('\t');
                    if (tab == std::string::npos)
                        continue;
                    shown++;
                    std::string line = change_lines[k];
                    Grid change;
                    change.ColumnSpacing(6);
                    change.Padding(ThicknessHelper::FromLengths(4, 0, 0, 0));
                    change.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
                    ColumnDefinition text_column, undo_column;
                    text_column.Width(GridLengthHelper::FromValueAndType(1, GridUnitType::Star));
                    undo_column.Width(GridLengthHelper::Auto());
                    change.ColumnDefinitions().Append(text_column);
                    change.ColumnDefinitions().Append(undo_column);
                    StackPanel text;
                    text.Children().Append(Words(zs::ToWide(words.substr(0, tab)), 11, dim));
                    text.Children().Append(Words(zs::ToWide(words.substr(tab + 1)), 12.5));
                    change.Children().Append(text);
                    size_t first = line.find('\t');
                    if (first != std::string::npos)
                    {
                        size_t second = line.find('\t', first + 1);
                        std::string key = line.substr(first + 1, second == std::string::npos ? second : second - first - 1);
                        zs_setting_info info{};
                        bool is_setting = key.find('.') != std::string::npos && FindInfo(key, info);
                        if (is_setting || line.rfind("part:", 0) == 0)
                        {
                            ToolTipService::SetToolTip(change, box_value(is_setting ? L"Double-click to open this setting." : L"Double-click to open this part."));
                            change.DoubleTapped([this, i, line](auto &&, Input::DoubleTappedRoutedEventArgs const &e) {
                                e.Handled(true);
                                OpenHistoryChange(i, line);
                            });
                        }
                    }
                    if (i <= now && zs_history_revertible(line.data(), line.size()) == 1)
                    {
                        Button undo = FlatButton(L"↶");
                        ToolTipService::SetToolTip(undo, box_value(L"Undo only this change. The later changes stay."));
                        Automation::AutomationProperties::SetName(undo, L"Undo only this change");
                        undo.Click([this, line](auto &&, auto &&) { RevertChange(line); });
                        Grid::SetColumn(undo, 1);
                        change.Children().Append(undo);
                    }
                    body.Children().Append(change);
                }
                if (shown == 0)
                    body.Children().Append(Words(L"Other changes (formulas, global settings, or the plate).", 12.5, dim));
            }

            Border row;
            row.CornerRadius(CornerRadiusHelper::FromUniformRadius(8));
            row.Padding(ThicknessHelper::FromLengths(10, 8, 10, 8));
            row.Opacity(i > now ? 0.55 : 1);
            if (i == now)
            {
                auto color = accent.as<Media::SolidColorBrush>().Color();
                color.A = 0x2E;
                row.Background(Media::SolidColorBrush(color));
                row.BorderBrush(accent);
                row.BorderThickness(ThicknessHelper::FromLengths(3, 0, 0, 0));
                now_row = row;
            }
            else
            {
                row.Background(Media::SolidColorBrush(Microsoft::UI::Colors::Transparent()));
                ToolTipService::SetToolTip(row, box_value(L"Click to go to this step"));
            }
            row.Child(body);
            if (go != nullptr)
            {
                row.PointerEntered([go](auto &&, auto &&) { go.Opacity(1); });
                row.PointerExited([go](auto &&, auto &&) { go.Opacity(0); });
            }
            row.Tapped([this, i, now](auto &&, Input::TappedRoutedEventArgs const &e) {
                if (i != now)
                {
                    e.Handled(true);
                    GoToStep(i);
                }
            });
            row.RightTapped([this, i, row](auto &&, Input::RightTappedRoutedEventArgs const &e) {
                e.Handled(true);
                ShowStepMenu(row, e.GetPosition(row), i);
            });
            list.Children().Append(row);
        }
        if (now_row != nullptr)
        {
            auto weak = get_weak();
            queue.TryEnqueue([weak, now_row] {
                if (auto self = weak.get(); self != nullptr && self->HistoryFlyout().IsOpen())
                    now_row.StartBringIntoView();
            });
        }

        // The steps after the step now: one button clears them.
        if (count > 0 && now + 1 < count)
        {
            size_t later = count - 1 - now;
            Button clear = FlatButton(later == 1 ? hstring(L"Clear the later change") : L"Clear the " + to_hstring(later) + L" later changes");
            clear.HorizontalAlignment(HorizontalAlignment::Right);
            clear.Margin(ThicknessHelper::FromLengths(0, 6, 8, 6));
            ToolTipService::SetToolTip(clear, box_value(L"The changes after the step now go from the history. Redo cannot bring them back."));
            clear.Click([this, now](auto &&, auto &&) { ClearHistoryAfter(now); });
            list.Children().Append(clear);
        }

        // The edits of lines: each with its layer and what it does.
        size_t edits = zs_app_edit_count(app);
        if (edits == 0)
            return;
        Border box;
        box.BorderThickness(ThicknessHelper::FromLengths(0, 1, 0, 0));
        box.BorderBrush(TokenBrush(Root(), L"ZsLine"));
        box.Margin(ThicknessHelper::FromLengths(0, 12, 0, 0));
        box.Padding(ThicknessHelper::FromLengths(12, 8, 12, 8));
        StackPanel inner;
        inner.Spacing(2);
        TextBlock heading = Words(L"Line edits (" + std::to_wstring(edits) + L")", 13);
        heading.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
        inner.Children().Append(heading);
        for (size_t e = 0; e < edits; e++)
        {
            int edit_kind = 0, applied = 0;
            double value = 0;
            size_t layer = 0;
            if (zs_app_edit_get(app, e, &edit_kind, &value, &layer, &applied) != ZS_OK)
                continue;
            wchar_t what[64];
            if (edit_kind == 0)
                swprintf_s(what, L"does not print");
            else if (edit_kind == 2)
                swprintf_s(what, L"a drop of %.1f mm", value);
            else
                swprintf_s(what, L"%.0f %% plastic", value * 100);
            Grid row;
            row.ColumnSpacing(6);
            for (int c = 0; c < 3; c++)
            {
                ColumnDefinition column;
                column.Width(c == 0 ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
                row.ColumnDefinitions().Append(column);
            }
            TextBlock text = Words(L"Layer " + std::to_wstring(layer + 1) + L": " + what, 12.5);
            text.VerticalAlignment(VerticalAlignment::Center);
            row.Children().Append(text);
            if (applied != 1)
            {
                TextBlock wait = Words(L"waits: its line is not in this slice", 11, TokenBrush(Root(), L"ZsWarning"));
                wait.MaxWidth(130);
                wait.VerticalAlignment(VerticalAlignment::Center);
                Grid::SetColumn(wait, 1);
                row.Children().Append(wait);
            }
            Button remove = FlatButton(L"×");
            ToolTipService::SetToolTip(remove, box_value(L"Remove this edit: the line prints as the slice makes it"));
            Automation::AutomationProperties::SetName(remove, L"Remove the edit of layer " + to_hstring(layer + 1));
            remove.Click([this, e](auto &&, auto &&) {
                if (model == nullptr || zs_app_edit_remove(model->Active(), e) != ZS_OK)
                    return;
                model->RequestSlice();
                NoteChange();
                FillHistoryList();
            });
            Grid::SetColumn(remove, 2);
            row.Children().Append(remove);
            inner.Children().Append(row);
        }
        box.Child(inner);
        list.Children().Append(box);
    }

    // Undoes one change, and keeps the later ones.
    void MainWindow::RevertChange(std::string const &line)
    {
        if (model == nullptr)
            return;
        int rc = zs_app_history_revert(model->Active(), line.data(), line.size());
        if (rc != ZS_OK)
        {
            ShowToast(rc == 15 ? hstring(L"A move of a part cannot be undone alone: go to the step before it.")
                               : L"The change was not undone (" + to_hstring(rc) + L").");
            return;
        }
        history_timer.Stop();
        model->HistoryCommit();
        model->RequestSlice();
        RefreshSettingValues();
        RefreshHistoryButtons();
        PrintersNoteChange();
        if (HistoryFlyout().IsOpen())
            FillHistoryList();
    }

    // One row on a wide view. On a narrow view the replay and the print
    // each take a row of their own.
    void MainWindow::LayoutDock(double width)
    {
        bool narrow = width <= 760;
        // On a narrow view the facts of the print wrap beside the button.
        SummaryDetail().MaxWidth(narrow ? std::max(120.0, width - ExportButton().ActualWidth() - 76) : std::numeric_limits<double>::infinity());
        if (dock_laid_out && narrow == dock_narrow)
            return;
        dock_laid_out = true;
        dock_narrow = narrow;
        Grid::SetColumn(ScrubRow(), narrow ? 0 : 2);
        Grid::SetRow(ScrubRow(), narrow ? 1 : 0);
        Grid::SetColumnSpan(ScrubRow(), narrow ? 4 : 1);
        ScrubRow().BorderThickness(narrow ? ThicknessHelper::FromUniformLength(0) : ThicknessHelper::FromLengths(1, 0, 0, 0));
        ScrubRow().Padding(narrow ? ThicknessHelper::FromUniformLength(0) : ThicknessHelper::FromLengths(8, 0, 0, 0));
        Grid::SetColumn(DockSummary(), narrow ? 0 : 3);
        Grid::SetRow(DockSummary(), narrow ? 2 : 0);
        Grid::SetColumnSpan(DockSummary(), narrow ? 4 : 1);
        DockSummary().BorderThickness(narrow ? ThicknessHelper::FromLengths(0, 1, 0, 0) : ThicknessHelper::FromLengths(1, 0, 0, 0));
        DockSummary().Padding(narrow ? ThicknessHelper::FromLengths(0, 2, 0, 0) : ThicknessHelper::FromLengths(12, 0, 0, 0));
        DockSummary().ColumnDefinitions().GetAt(0).Width(narrow ? GridLengthHelper::FromValueAndType(1, GridUnitType::Star) : GridLengthHelper::Auto());
    }
}
